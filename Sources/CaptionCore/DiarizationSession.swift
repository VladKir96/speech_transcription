import Foundation
import OSLog

public enum DiarizationEvent: Sendable {
    case status(DiarizationStatus, String?)
    case timelineUpdated(inferenceTime: Duration)
}

/// The lock is held only while moving samples into the bounded stream or publishing metadata.
/// Each detached worker owns its native inference sessions until it has finished shutting down.
public final class DiarizationSession: @unchecked Sendable {
    private struct State {
        var generation = UUID()
        var worker: Task<Void, Never>?
        var input: AsyncStream<AudioChunk>.Continuation?
        var acceptAfter = 0.0
        var activeStart: Double?
        var eligible: [Range<Double>] = []
        var settings = DiarizationOptions()
        var dropped = false
        var timeline = SpeakerTimeline()
        var tracker = OnlineSpeakerTracker()
    }
    private let lock = NSLock()
    private var state = State()
    private static let log = Logger(subsystem: "local.caption", category: "diarization")

    public init() {}

    public func begin(models: ModelStore, settings: DiarizationOptions, after start: Double,
                      notify: @escaping @Sendable (DiarizationEvent) async -> Void) {
        lock.withLock {
            stopLocked(at: start)
            let previous = state.worker
            let generation = state.generation
            state.acceptAfter = start
            state.settings = settings
            state.worker = Task.detached(priority: .background) { [self] in
                await previous?.value
                guard !Task.isCancelled else { return }
                do {
                    guard let assets = try await models.diarizationModels() else {
                        await notify(.status(.unavailable, "Install both speaker models in Settings → Models."))
                        return
                    }
                    try Task.checkCancellation()
                    let engine = try NativeSpeakerAnalysis(segmentation: assets.segmentation, embedding: assets.embedding)
                    let feed = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .bufferingNewest(24))
                    let ready = lock.withLock {
                        guard state.generation == generation else { return false }
                        state.input = feed.continuation
                        return true
                    }
                    guard ready else { return }
                    await notify(.status(.active, nil))
                    var rolling = RollingSpeakerAudio(mode: settings.mode)
                    var wasBehind = false
                    for await chunk in feed.stream {
                        try Task.checkCancellation()
                        guard let window = rolling.append(chunk) else { continue }
                        let started = ContinuousClock.now
                        let analysis = try engine.analyze(window.samples, start: window.start)
                        let duration = started.duration(to: .now)
                        try Task.checkCancellation()
                        let lag = publish(analysis, start: window.start, end: window.end,
                                          settings: settings, generation: generation)
                        guard let lag else { break }
                        if lag != wasBehind {
                            wasBehind = lag
                            await notify(.status(lag ? .behind : .active,
                                lag ? "Speaker analysis fell behind. Some speaker labels may be missing." : nil))
                        }
                        await notify(.timelineUpdated(inferenceTime: duration))
                    }
                } catch is CancellationError {
                    return
                } catch {
                    let affected = lock.withLock {
                        guard state.generation == generation else { return false }
                        finishInput(at: max(state.acceptAfter, state.timeline.coveredThrough))
                        return true
                    }
                    if affected {
                        Self.log.error("Speaker inference failed: \(error.localizedDescription, privacy: .private)")
                        await notify(.status(.error, "Speaker analysis failed. Try enabling it again or reinstall the speaker models."))
                    }
                }
            }
        }
    }

    public func stop(at end: Double) {
        lock.withLock { stopLocked(at: end) }
    }

    public func waitForShutdown() async {
        let worker = lock.withLock { state.worker }
        await worker?.value
    }

    private func stopLocked(at end: Double) {
        state.generation = UUID()
        state.worker?.cancel()
        finishInput(at: end)
    }

    private func finishInput(at end: Double) {
        state.input?.finish()
        state.input = nil
        if let start = state.activeStart, end > start {
            state.eligible.append(start..<end)
            state.eligible = Array(state.eligible.suffix(32))
        }
        state.activeStart = nil
        state.dropped = false
    }

    func offer(_ chunk: AudioChunk) {
        lock.withLock {
            guard let input = state.input, chunk.start >= state.acceptAfter else { return }
            if state.activeStart == nil { state.activeStart = chunk.start }
            if case .dropped = input.yield(chunk) { state.dropped = true }
        }
    }

    private func publish(_ analysis: SpeakerAnalysis, start: Double, end: Double,
                         settings: DiarizationOptions, generation: UUID) -> Bool? {
        lock.withLock {
            guard state.generation == generation else { return nil }
            let speakers = state.tracker.match(analysis.observations, settings: settings)
            let intervals = analysis.frames.map {
                SpeakerInterval(start: $0.start, end: $0.end, speaker: speakers[$0.mask],
                                overlap: $0.mask.nonzeroBitCount > 1, confidence: Double($0.confidence))
            }
            state.timeline.replace(start: start, end: end - 0.12, with: intervals)
            defer { state.dropped = false }
            return state.dropped
        }
    }

    /// A complete caption must be within one activation interval to acquire a label.
    public func refresh(_ segment: TranscriptSegment) -> TranscriptSegment {
        guard segment.source == .system else { return segment }
        var result = segment
        let info = info(for: segment)
        if let attribution = info.attribution { attribution.apply(to: &result) }
        return result
    }

    func useSpeakerQueue(for segments: [TranscriptSegment]) -> Bool {
        lock.withLock {
            state.settings.speakerAwarePhrases && segments.contains { eligible($0) }
        }
    }

    func resolve(_ segment: TranscriptSegment, wait: Bool) async -> TranscriptSegment {
        var observation = info(for: segment)
        guard observation.attribution != nil else { return segment }
        if wait {
            let deadline = ContinuousClock.now.advanced(by: observation.wait)
            while observation.waiting, ContinuousClock.now < deadline, !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(80)) } catch { break }
                observation = info(for: segment)
            }
        }
        var result = segment
        observation.attribution?.apply(to: &result)
        return result
    }

    private func eligible(_ segment: TranscriptSegment) -> Bool {
        if let start = state.activeStart, segment.start >= start { return true }
        return state.eligible.contains { segment.start >= $0.lowerBound && segment.end <= $0.upperBound }
    }

    private func info(for segment: TranscriptSegment)
        -> (attribution: SpeakerAttribution?, waiting: Bool, wait: Duration) {
        lock.withLock {
            let delay = state.settings.mode.translationWait
            guard eligible(segment) else { return (nil, false, delay) }
            let attribution = state.timeline.attribution(start: segment.start, end: segment.end)
            let waiting = state.input != nil && state.activeStart.map { segment.start >= $0 } == true
                && state.timeline.coveredThrough < segment.end - 0.12
            return (attribution, waiting, delay)
        }
    }
}

private struct RollingSpeakerAudio {
    let mode: DiarizationMode
    private var samples: [Float] = []
    private var start = 0.0
    private var processed = 0
    init(mode: DiarizationMode) { self.mode = mode }

    mutating func append(_ chunk: AudioChunk) -> AudioChunk? {
        let rate = Double(AudioChunk.rate)
        let displacement = chunk.start - (start + Double(samples.count) / rate)
        if samples.isEmpty || abs(displacement) > 0.12 {
            samples.removeAll(keepingCapacity: true)
            start = chunk.start
            processed = 0
        } else if displacement > 0.025 {
            samples.append(contentsOf: repeatElement(0, count: Int(displacement * rate)))
        }
        let trim = displacement < -0.025 && !samples.isEmpty
            ? min(Int(-displacement * rate), chunk.samples.count) : 0
        samples.append(contentsOf: chunk.samples.dropFirst(trim))
        processed += chunk.samples.count - trim
        let excess = max(0, samples.count - mode.length)
        if excess > 0 {
            samples.removeFirst(excess)
            start += Double(excess) / rate
        }
        guard samples.count >= mode.warmup, processed >= mode.hop else { return nil }
        processed = 0
        return AudioChunk(start: start, samples: samples)
    }
}
