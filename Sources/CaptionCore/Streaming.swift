import Foundation
import OSLog

public struct AudioChunk: Sendable {
    public static let rate = 16_000
    public let start: Double
    public let samples: [Float]
    public var end: Double { start + Double(samples.count) / Double(Self.rate) }

    public init(start: Double, samples: [Float]) {
        self.start = start
        self.samples = samples
    }
}

public struct SampleBuffer: Sendable {
    private var storage: [Float] = []
    private var offset = 0
    public init() {}
    public var count: Int { storage.count - offset }

    public mutating func append(_ samples: [Float]) { storage.append(contentsOf: samples) }

    public mutating func take(_ count: Int) -> [Float]? {
        guard count > 0, self.count >= count else { return nil }
        let samples = Array(storage[offset..<(offset + count)])
        offset += count
        if offset >= 6_400 {
            storage.removeFirst(offset)
            offset = 0
        }
        return samples
    }

    public mutating func reset() {
        storage.removeAll(keepingCapacity: true)
        offset = 0
    }
}

public enum StreamEvent: Sendable {
    case partial(AudioSource, TranscriptSegment?)
    case pendingPhrase(AudioSource, TranscriptSegment?)
    case speakerDrafts(AudioSource, [TranscriptSegment])
    case finalized(AudioSource, UUID, [TranscriptSegment])
    case activity(AudioSource, Double)
    case issue(AudioSource, String)
}

private struct SpeechWindow: Sendable {
    let id: UUID
    let start: Double
    let end: Double
    let samples: [Float]
    let overlap: Double
    let final: Bool
}

private enum SpeechWork {
    case recognize(SpeechWindow)
    case finishPhrase
}

private enum SpeakerPhraseWork {
    case captions([TranscriptSegment])
    case finish
}

public enum TranscriptReconciler {
    public static func pieces(_ input: [RecognitionPiece], duration: Double,
                              overlap: Double, previous: String?) -> [RecognitionPiece] {
        var consumedOverlap = false
        return input.compactMap { piece in
            guard piece.start.isFinite, piece.end.isFinite,
                  piece.noSpeech < 0.72, piece.start < duration,
                  !piece.text.isEmpty else { return nil }
            let start = max(0, piece.start)
            let end = min(duration, max(start + 0.02, piece.end))
            guard end > max(overlap, start) else { return nil }
            var text = piece.text
            if !consumedOverlap, overlap > 0, start < overlap, let previous {
                let current = text.split(whereSeparator: \.isWhitespace)
                let old = previous.split(whereSeparator: \.isWhitespace)
                let overlapWords = max(1, Int(ceil((overlap - start) * 4)))
                let limit = min(current.count, old.count, overlapWords)
                for length in stride(from: limit, through: 1, by: -1) {
                    if old.suffix(length).map(normalize) == current.prefix(length).map(normalize) {
                        text = current.dropFirst(length).joined(separator: " ")
                        break
                    }
                }
                consumedOverlap = true
            }
            guard !text.isEmpty else { return nil }
            return RecognitionPiece(text: text, start: max(start, overlap), end: end, noSpeech: piece.noSpeech)
        }
    }

    private static func normalize(_ text: Substring) -> String {
        text.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }
}

public actor StreamingTranscription {
    private let source: AudioSource
    private let sessionID: UUID
    private let options: SessionOptions
    private let engine: any SpeechRecognitionEngine
    private let diarization: DiarizationSession?
    private let notify: @Sendable (StreamEvent) async -> Void
    private var vad: SileroDetector?
    private var vadCandidates: [URL]
    private var announcedFallback = false

    private let frameSize = 1_600
    private var incoming = SampleBuffer()
    private var frameStart: Double?
    private var inputEnd: Double?
    private var preRoll: [Float] = []
    private var phrase: [Float] = []
    private var phraseID = UUID()
    private var phraseStart = 0.0
    private var leadingOverlap = 0.0
    private var carry: [Float] = []
    private var carryEnd = 0.0
    private var voicedFrames = 0
    private var silenceFrames = 0
    private var nextPartial = 0.0
    private var activityTicks = 0
    private var previousText: String?
    private var previousLanguage: String?
    private var latestPartial: SpeechWindow?
    private var pendingFinals: [SpeechWork] = []
    private var worker: Task<Void, Never>?
    private var lastFinalEnd = 0.0
    private var translationPhraseStart: Double?
    private var lastVoiceEnd: Double?
    private var aggregation: PhraseAggregation
    private var speakerWork: [SpeakerPhraseWork] = []
    private var speakerWorker: Task<Void, Never>?
    private var speakerDrafts: [TranscriptSegment] = []

    public init(source: AudioSource, sessionID: UUID, options: SessionOptions,
                engine: any SpeechRecognitionEngine, vadURL: URL?, fallbackVADURL: URL? = nil,
                diarization: DiarizationSession? = nil,
                notify: @escaping @Sendable (StreamEvent) async -> Void) {
        self.source = source
        self.sessionID = sessionID
        self.options = options
        self.engine = engine
        self.diarization = source == .system ? diarization : nil
        self.notify = notify
        aggregation = PhraseAggregation(pause: options.effectivePhrasePause,
                                        strategy: options.translationStrategy ?? .balanced)
        vadCandidates = [vadURL, fallbackVADURL].compactMap { $0 }
    }

    public func consume(_ stream: AsyncStream<AudioChunk>) async {
        if options.enableVAD { await activateVAD() }
        for await chunk in stream {
            guard !Task.isCancelled else { break }
            await receive(chunk)
        }
        if incoming.count > 0, let start = frameStart, let frame = incoming.take(incoming.count) {
            await process(frame, at: start, flush: true)
        }
        await finalize(keepOverlap: false)
        finishTranslationPhrase()
        while let worker { await worker.value }
        while let speakerWorker { await speakerWorker.value }
        vad = nil
    }

    private static let vadLog = Logger(subsystem: "local.caption", category: "recognition")

    private func activateVAD(afterFailure: Bool = false) async {
        var failed = afterFailure
        while !vadCandidates.isEmpty, !Task.isCancelled {
            let candidate = vadCandidates.removeFirst()
            do {
                let detector = try SileroDetector(url: candidate)
                vad = detector
                Self.vadLog.info("Silero VAD \(detector.version, privacy: .public) ready; source=\(self.source.rawValue, privacy: .public)")
                if failed { await notify(.issue(source, "The preferred Silero model could not load. Check it in Settings → Models.")) }
                return
            } catch {
                failed = true
                Self.vadLog.error("Silero model initialization failed; source=\(self.source.rawValue, privacy: .public) error=\(error.localizedDescription, privacy: .private)")
            }
        }
        if !Task.isCancelled { await reportFallback() }
    }

    private func reportFallback() async {
        guard !announcedFallback else { return }
        announcedFallback = true
        await notify(.issue(source, "Silero VAD is unavailable. Using the audio-level fallback."))
    }

    private func receive(_ chunk: AudioChunk) async {
        guard !chunk.samples.isEmpty, chunk.samples.count <= AudioChunk.rate,
              chunk.start.isFinite, chunk.start >= 0 else { return }
        diarization?.offer(chunk)
        var samples = chunk.samples
        if let inputEnd, abs(chunk.start - inputEnd) > 0.18 {
            if chunk.start > inputEnd {
                await notify(.issue(source, "Audio was interrupted or the processing buffer filled. Resuming at the next available audio."))
            }
            if incoming.count > 0, let start = frameStart, let remaining = incoming.take(incoming.count) {
                await process(remaining, at: start, flush: true)
            }
            await finalize(keepOverlap: false)
            if chunk.start - inputEnd >= options.effectivePhrasePause { finishTranslationPhrase() }
            preRoll.removeAll()
            carry.removeAll()
            vad?.reset()
            incoming.reset()
            frameStart = nil
        } else if let inputEnd, chunk.start < inputEnd - 0.015 {
            let overlap = Int((inputEnd - chunk.start) * Double(AudioChunk.rate))
            guard overlap < samples.count else { return }
            samples.removeFirst(overlap)
        }
        if frameStart == nil { frameStart = max(chunk.start, inputEnd ?? 0) }
        inputEnd = max(inputEnd ?? 0, chunk.end)
        incoming.append(samples)
        while let start = frameStart, let frame = incoming.take(frameSize) {
            frameStart = start + 0.1
            await process(frame, at: start)
        }
    }

    private func process(_ samples: [Float], at start: Double, flush: Bool = false) async {
        let rms = sqrt(samples.reduce(Float.zero) { $0 + $1 * $1 } / Float(samples.count))
        activityTicks += 1
        if activityTicks % 2 == 0 { await notify(.activity(source, min(1, Double(rms) * 6))) }
        var speech = rms > 0.003
        if options.enableVAD {
            while let detector = vad {
                do {
                    let probability = try detector.probability(samples, history: preRoll.suffix(4_800),
                                                               quiet: rms < 0.00025, flush: flush)
                    speech = probability >= (phrase.isEmpty ? 0.38 : 0.30)
                    break
                } catch {
                    Self.vadLog.error("Silero inference failed; source=\(self.source.rawValue, privacy: .public) version=\(detector.version, privacy: .public) error=\(error.localizedDescription, privacy: .private)")
                    vad = nil
                    await activateVAD(afterFailure: true)
                }
            }
        }
        defer {
            preRoll.append(contentsOf: samples)
            if preRoll.count > 5_120 { preRoll.removeFirst(preRoll.count - 5_120) }
        }

        var phraseLimit = false
        var phraseQuiet = false
        if options.translate {
            let end = start + Double(samples.count) / Double(AudioChunk.rate)
            if speech {
                if translationPhraseStart == nil { translationPhraseStart = start }
                lastVoiceEnd = end
            }
            if let first = translationPhraseStart, let lastVoiceEnd {
                phraseLimit = end - first + 0.0001 >= PhraseAggregation.maximumDuration
                phraseQuiet = !speech && end - lastVoiceEnd + 0.0001 >= options.effectivePhrasePause
            }
        }

        if phrase.isEmpty {
            guard speech else {
                if phraseQuiet || phraseLimit { finishTranslationPhrase() }
                return
            }
            let frameDuration = Double(preRoll.count) / Double(AudioChunk.rate)
            if abs(start - carryEnd) < 0.15, !carry.isEmpty {
                phrase = carry
                leadingOverlap = Double(carry.count) / Double(AudioChunk.rate)
                phraseStart = max(0, start - leadingOverlap)
            } else {
                phrase = preRoll
                leadingOverlap = 0
                phraseStart = max(0, start - frameDuration)
            }
            carry.removeAll()
            voicedFrames = 0
            silenceFrames = 0
            phraseID = UUID()
            nextPartial = options.profile.firstPartial
        }

        phrase.append(contentsOf: samples)
        if speech {
            voicedFrames += 1
            silenceFrames = 0
        } else {
            silenceFrames += 1
        }
        let duration = Double(phrase.count) / Double(AudioChunk.rate)
        if phraseQuiet || phraseLimit {
            await finalize(keepOverlap: speech)
            finishTranslationPhrase()
        } else if duration >= options.profile.maxPhrase {
            await finalize(keepOverlap: speech)
        } else if Double(silenceFrames) / 10 >= options.profile.endSilence {
            await finalize(keepOverlap: false)
        } else if duration >= nextPartial, voicedFrames >= 3, speech {
            nextPartial += options.profile.partialInterval
            latestPartial = window(final: false)
            startWorker()
        }
    }

    private func window(final: Bool) -> SpeechWindow {
        SpeechWindow(id: phraseID, start: phraseStart,
                     end: phraseStart + Double(phrase.count) / Double(AudioChunk.rate),
                     samples: phrase, overlap: leadingOverlap, final: final)
    }

    private func finalize(keepOverlap: Bool) async {
        guard !phrase.isEmpty else { return }
        if keepOverlap {
            carry = Array(phrase.suffix(4_000))
            carryEnd = window(final: true).end
        } else {
            carry.removeAll()
        }
        if latestPartial?.id == phraseID { latestPartial = nil }
        if voicedFrames >= 2 {
            while pendingFinals.count >= 6 {
                try? await Task.sleep(for: .milliseconds(30))
            }
            pendingFinals.append(.recognize(window(final: true)))
            startWorker()
        }
        phrase.removeAll(keepingCapacity: true)
        preRoll.removeAll(keepingCapacity: true)
        voicedFrames = 0
    }

    private func startWorker() {
        guard worker == nil else { return }
        worker = Task { await drain() }
    }

    // Queue the boundary behind the corresponding STT windows, even if inference is still running.
    private func finishTranslationPhrase() {
        guard translationPhraseStart != nil else { return }
        translationPhraseStart = nil
        lastVoiceEnd = nil
        pendingFinals.append(.finishPhrase)
        startWorker()
    }

    private func drain() async {
        defer { worker = nil }
        while true {
            if !pendingFinals.isEmpty {
                switch pendingFinals.removeFirst() {
                case let .recognize(window):
                    await recognize(window)
                case .finishPhrase:
                    if speakerWorker != nil { speakerWork.append(.finish) }
                    else { await emitPhraseBoundary() }
                }
            } else if let partial = latestPartial {
                latestPartial = nil
                await recognize(partial)
            } else {
                break
            }
        }
    }

    private func recognize(_ window: SpeechWindow) async {
        do {
            let prompt = options.profile == .highAccuracy && options.sourceLanguage.rawValue == previousLanguage
                ? previousText.map { String($0.suffix(200)) } : nil
            let result = try await engine.recognize(window.samples, language: options.sourceLanguage,
                                                    prompt: prompt, final: window.final, profile: options.profile)
            let pieces = TranscriptReconciler.pieces(result.pieces, duration: window.end - window.start,
                                                      overlap: window.overlap, previous: previousText)
            if window.final {
                let segments = pieces.enumerated().compactMap { index, piece -> TranscriptSegment? in
                    let start = max(lastFinalEnd, window.start + piece.start)
                    let end = min(window.end, window.start + piece.end)
                    guard start < end else { return nil }
                    lastFinalEnd = end
                    return makeSegment(id: index == 0 ? window.id : UUID(), start: start, end: end,
                                       text: piece.text, language: result.language, final: true)
                }
                if let last = segments.last {
                    previousText = last.original
                    previousLanguage = last.language
                }
                if options.translate {
                    await notify(.partial(source, nil))
                    let attributed = segments.map { diarization?.refresh($0) ?? $0 }
                    if !attributed.isEmpty, speakerWorker != nil || diarization?.useSpeakerQueue(for: attributed) == true {
                        while speakerWork.count >= 12 {
                            try? await Task.sleep(for: .milliseconds(25))
                        }
                        speakerWork.append(.captions(attributed))
                        speakerDrafts.append(contentsOf: attributed)
                        await notify(.speakerDrafts(source, speakerDrafts))
                        if speakerWorker == nil { speakerWorker = Task { await drainSpeakerWork() } }
                    } else {
                        await addToPhrases(attributed, respectSpeakers: false)
                    }
                } else {
                    await notify(.finalized(source, window.id, segments.map { diarization?.refresh($0) ?? $0 }))
                }
            } else if pendingFinals.isEmpty && window.id == phraseID && !phrase.isEmpty {
                let text = pieces.map(\.text).joined(separator: " ")
                if !text.isEmpty {
                    await notify(.partial(source, makeSegment(id: window.id, start: window.start, end: window.end,
                                                              text: text, language: result.language, final: false)))
                }
            }
        } catch {
            if window.final { await notify(.finalized(source, window.id, [])) }
            await notify(.issue(source, error.localizedDescription))
        }
    }

    private func drainSpeakerWork() async {
        defer { speakerWorker = nil }
        while !speakerWork.isEmpty {
            switch speakerWork.removeFirst() {
            case .finish:
                await emitPhraseBoundary()
            case let .captions(captions):
                if let diarization, let last = captions.last, speakerWork.count < 4 {
                    _ = await diarization.resolve(last, wait: true)
                }
                let updated = captions.map { diarization?.refresh($0) ?? $0 }
                let ids = Set(captions.map(\.id))
                speakerDrafts.removeAll { ids.contains($0.id) }
                await notify(.speakerDrafts(source, speakerDrafts))
                await addToPhrases(updated, respectSpeakers: diarization?.useSpeakerQueue(for: updated) == true)
            }
        }
    }

    private func emitPhraseBoundary() async {
        if let phrase = aggregation.finish() {
            await notify(.finalized(source, phrase.id, [phrase]))
        }
    }

    private func addToPhrases(_ segments: [TranscriptSegment], respectSpeakers: Bool) async {
        if respectSpeakers, let diarization { aggregation.refreshPending(using: diarization) }
        for segment in segments {
            if let complete = aggregation.accept(segment, respectSpeakers: respectSpeakers) {
                await notify(.finalized(source, complete.id, [complete]))
            }
        }
        await notify(.pendingPhrase(source, aggregation.pending))
    }

    private func makeSegment(id: UUID, start: Double, end: Double, text: String,
                             language: String, final: Bool) -> TranscriptSegment {
        var translation = TranslationStatus.disabled
        if final, options.translate {
            if language == options.targetLanguage.rawValue {
                translation = .sameLanguage
            } else {
                translation = options.translationModel.installation(from: language, to: options.targetLanguage.rawValue) != nil
                    ? .pending : .unsupported
            }
        }
        return TranscriptSegment(id: id, sessionID: sessionID, source: source, start: start, end: end,
                                 original: text, language: language, finalized: final, translationStatus: translation)
    }
}
