import CInference
import Foundation
import OSLog

public enum DiarizationMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case realTime, highAccuracy
    public var id: String { rawValue }
    public var title: String { self == .realTime ? "Real-Time" : "High Accuracy" }
    var length: Int { AudioChunk.rate * (self == .realTime ? 4 : 10) }
    var warmup: Int { AudioChunk.rate * (self == .realTime ? 2 : 5) }
    var hop: Int { AudioChunk.rate * (self == .realTime ? 1 : 2) }
    var translationWait: Duration { self == .realTime ? .milliseconds(1350) : .milliseconds(2600) }
}

public struct DiarizationOptions: Codable, Sendable {
    public var enabledByDefault = false
    public var mode = DiarizationMode.realTime
    public var speakerLimit = 0
    public var similarity: Double = 0.55
    public var colorSpeakers = true
    public var subtitleNames = true
    public var speakerAwarePhrases = true
    public init() {}
}

public enum DiarizationStatus: Equatable, Sendable {
    case disabled, loading, active, behind, unavailable, error
    public var title: String {
        switch self {
        case .disabled: "Off"
        case .loading: "Loading"
        case .active, .behind: "On"
        case .unavailable: "Unavailable"
        case .error: "Error"
        }
    }
}

public enum SpeakerStatus: String, Codable, Sendable {
    case assigned, unknown, mixed, overlapping
}

struct SessionSpeaker: Sendable, Equatable {
    let id: UUID
    let number: Int
    var name: String { "Speaker \(number)" }
}

struct SpeakerAttribution: Sendable {
    let speaker: SessionSpeaker?
    let status: SpeakerStatus
    let confidence: Double?

    static let unknown = SpeakerAttribution(speaker: nil, status: .unknown, confidence: nil)

    func apply(to segment: inout TranscriptSegment) {
        segment.speakerID = speaker?.id
        segment.speakerName = speaker?.name
        segment.speakerColor = speaker.map { $0.number - 1 }
        segment.speakerStatus = status
        segment.speakerConfidence = confidence
    }
}

struct SpeakerActivity: Sendable {
    var start: Double
    var end: Double
    let mask: UInt8
    let confidence: Float
}

struct SpeakerObservation: Sendable {
    let slot: UInt8
    let start: Double
    let end: Double
    let vector: [Float]
}

struct SpeakerAnalysis: Sendable {
    let frames: [SpeakerActivity]
    let observations: [SpeakerObservation]
}

final class NativeSpeakerAnalysis {
    private let pointer: OpaquePointer
    private static let stride = 270

    init(segmentation: URL, embedding: URL) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard let pointer = lc_speaker_open(segmentation.path, embedding.path, &error) else {
            throw Self.failure(error)
        }
        self.pointer = pointer
    }

    deinit { lc_speaker_close(pointer) }

    func analyze(_ pcm: [Float], start: Double) throws -> SpeakerAnalysis {
        let capacity = 600
        var mask = [UInt8](repeating: 0, count: capacity)
        var scores = [Float](repeating: 0, count: capacity)
        var error: UnsafeMutablePointer<CChar>?
        let count = Int(pcm.withUnsafeBufferPointer {
            lc_speaker_segment(pointer, $0.baseAddress, Int32($0.count), &mask, &scores, Int32(capacity), &error)
        })
        guard count >= 0 else { throw Self.failure(error) }
        var activity: [SpeakerActivity] = []
        let frameSpan = Double(Self.stride) / Double(AudioChunk.rate)
        for i in 0..<count {
            let slot = scores[i] >= 0.46 ? mask[i] : 0
            guard slot != 0 else { continue }
            let start = start + Double(495 + i * Self.stride - Self.stride / 2) / Double(AudioChunk.rate)
            if let last = activity.last, last.mask == slot, abs(last.end - start) < 0.00001 {
                activity[activity.count - 1] = SpeakerActivity(start: last.start, end: start + frameSpan, mask: slot,
                    confidence: last.confidence * 0.94 + scores[i] * 0.06)
            } else {
                activity.append(SpeakerActivity(start: start, end: start + frameSpan, mask: slot, confidence: scores[i]))
            }
        }
        let observations = try [UInt8(1), 2, 4].compactMap { slot -> SpeakerObservation? in
            let runs = activity.filter { $0.mask == slot && $0.confidence >= 0.58 && $0.end - $0.start >= 0.62 }
            guard let run = runs.max(by: { $0.end - $0.start < $1.end - $1.start }) else { return nil }
            let lower = max(0, Int((run.start - start + 0.04) * Double(AudioChunk.rate)))
            let upper = min(pcm.count, Int((min(run.end - 0.04, run.start + 2.65) - start) * Double(AudioChunk.rate)))
            guard upper - lower >= AudioChunk.rate / 2 else { return nil }
            let power = pcm[lower..<upper].reduce(Float.zero) { $0 + $1 * $1 } / Float(upper - lower)
            guard power >= 0.000_000_25 else { return nil }
            var vector = [Float](repeating: 0, count: 256)
            let ok = pcm.withUnsafeBufferPointer {
                lc_speaker_embed(pointer, $0.baseAddress?.advanced(by: lower), Int32(upper - lower), &vector, 256, &error)
            }
            guard ok else { throw Self.failure(error) }
            return SpeakerObservation(slot: slot, start: run.start, end: run.end, vector: vector)
        }
        return SpeakerAnalysis(frames: activity, observations: observations)
    }

    private static func failure(_ error: UnsafeMutablePointer<CChar>?) -> CaptionFailure {
        guard let error else { return CaptionFailure("The speaker models could not process this audio.") }
        defer { lc_string_free(error) }
        return CaptionFailure(String(cString: error))
    }
}

struct OnlineSpeakerTracker {
    private struct Profile {
        let speaker: SessionSpeaker
        var vector: [Float]
        var lastEvidence: Double
    }
    private struct Candidate {
        let observation: SpeakerObservation
    }
    private var profiles: [Profile] = []
    private var candidates: [Candidate] = []

    mutating func match(_ observations: [SpeakerObservation], settings: DiarizationOptions) -> [UInt8: SessionSpeaker] {
        let limit = (1...10).contains(settings.speakerLimit) ? settings.speakerLimit : 10
        let threshold = Float(max(0.3, min(0.85, settings.similarity.isFinite ? settings.similarity : 0.55)))
        var assigned: [UInt8: SessionSpeaker] = [:]
        for evidence in observations.sorted(by: { $0.start < $1.start }) {
            candidates.removeAll { evidence.end - $0.observation.end > 20 }
            let ranked = profiles.indices.map { ($0, Self.dot(profiles[$0].vector, evidence.vector)) }
                .sorted { $0.1 > $1.1 }
            if let (index, score) = ranked.first, score >= threshold {
                let match = profiles[index].speaker
                guard !assigned.values.contains(match), ranked.dropFirst().first.map({ score - $0.1 >= 0.055 }) ?? true else { continue }
                assigned[evidence.slot] = match
                if score > threshold + 0.06, evidence.end - profiles[index].lastEvidence > 0.25 {
                    let blended = zip(profiles[index].vector, evidence.vector).map { $0 * 0.82 + $1 * 0.18 }
                    let norm = sqrt(Self.dot(blended, blended))
                    profiles[index].vector = blended.map { $0 / norm }
                    profiles[index].lastEvidence = evidence.end
                }
                continue
            }
            guard profiles.count < limit else { continue }
            let consistent = candidates.firstIndex {
                let earlier = $0.observation
                return evidence.end - earlier.end > 0.25 && Self.dot(earlier.vector, evidence.vector) >= threshold + 0.05
            }
            let clear = (ranked.first?.1 ?? 0) < threshold - 0.09 && evidence.end - evidence.start >= 1.05
            if clear || consistent != nil {
                let speaker = SessionSpeaker(id: UUID(), number: profiles.count + 1)
                profiles.append(Profile(speaker: speaker, vector: evidence.vector, lastEvidence: evidence.end))
                assigned[evidence.slot] = speaker
                candidates.removeAll { Self.dot($0.observation.vector, evidence.vector) >= threshold }
            } else if !candidates.contains(where: { abs(evidence.end - $0.observation.end) <= 0.25
                && Self.dot($0.observation.vector, evidence.vector) >= threshold }) {
                if candidates.count == 8 { candidates.removeFirst() }
                candidates.append(Candidate(observation: evidence))
            }
        }
        return assigned
    }

    private static func dot(_ left: [Float], _ right: [Float]) -> Float {
        zip(left, right).reduce(0) { $0 + $1.0 * $1.1 }
    }
}

struct SpeakerInterval {
    var start: Double
    var end: Double
    let speaker: SessionSpeaker?
    let overlap: Bool
    let confidence: Double
}

struct SpeakerTimeline {
    var intervals: [SpeakerInterval] = []
    var coveredThrough: Double = 0

    mutating func replace(start: Double, end: Double, with incoming: [SpeakerInterval]) {
        intervals = intervals.compactMap {
            guard $0.start < start, $0.end > end - 65 else { return nil }
            var prefix = $0
            prefix.end = min(start, prefix.end)
            return prefix
        } + incoming
        coveredThrough = end
    }

    func attribution(start: Double, end: Double) -> SpeakerAttribution {
        var durations: [UUID: (speaker: SessionSpeaker, length: Double, score: Double)] = [:]
        var overlap = 0.0
        var ambiguous = 0.0
        for interval in intervals where interval.start < end && interval.end > start {
            let length = min(end, interval.end) - max(start, interval.start)
            if interval.overlap { overlap += length; continue }
            guard let speaker = interval.speaker else { ambiguous += length; continue }
            let previous = durations[speaker.id]
            durations[speaker.id] = (speaker, (previous?.length ?? 0) + length,
                                      (previous?.score ?? 0) + interval.confidence * length)
        }
        let span = end - start
        if overlap >= max(0.10, span * 0.13) {
            return SpeakerAttribution(speaker: nil, status: .overlapping, confidence: nil)
        }
        let ranked = durations.values.sorted { $0.length > $1.length }
        if let second = ranked.dropFirst().first, second.length >= max(0.15, span * 0.12) {
            return SpeakerAttribution(speaker: nil, status: .mixed, confidence: nil)
        }
        guard let first = ranked.first, first.length >= max(0.09, span * 0.31), first.length >= ambiguous else {
            return .unknown
        }
        return SpeakerAttribution(speaker: first.speaker, status: .assigned,
                                  confidence: min(1, first.score / first.length))
    }
}
