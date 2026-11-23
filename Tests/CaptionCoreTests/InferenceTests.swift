import AVFoundation
import Foundation
import Testing
@testable import CaptionCore

private let modelRoot = ProcessInfo.processInfo.environment["LOCALCAPTION_TEST_MODELS"]
    .map { URL(fileURLWithPath: $0, isDirectory: true) }

private func model(_ root: URL, id: String, filename: String) -> URL {
    let nested = root.appendingPathComponent(id).appendingPathComponent(filename)
    return FileManager.default.fileExists(atPath: nested.path) ? nested : root.appendingPathComponent(filename)
}

private func fixture(_ name: String) throws -> [Float] {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "wav"))
    let audio = try AVAudioFile(forReading: url)
    #expect(audio.processingFormat.sampleRate == 16_000)
    #expect(audio.processingFormat.channelCount == 1)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: audio.processingFormat,
                                             frameCapacity: AVAudioFrameCount(audio.length)))
    try audio.read(into: buffer)
    let samples = try #require(buffer.floatChannelData?[0])
    return Array(UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength)))
}

@Suite(.serialized, .enabled(if: modelRoot != nil, "Set LOCALCAPTION_TEST_MODELS to run actual local models"))
struct ModelIntegrationTests {
    @Test func whisperBothModelsAndLanguages() async throws {
        let root = try #require(modelRoot)
        let english = try fixture("en")
        let russian = try fixture("ru")
        let engine = WhisperRecognition()
        for (id, filename) in [("small", "ggml-small-q5_1.bin"),
                               ("turbo", "ggml-large-v3-turbo-q5_0.bin")] {
            let clock = ContinuousClock()
            let loadStart = clock.now
            let gpu = try await engine.prepare(model: model(root, id: id, filename: filename), metal: true)
            let load = loadStart.duration(to: clock.now)
            for (language, samples, expected) in [("en", english, "speech"), ("ru", russian, "речи")] {
                let initial = clock.now
                let partial = try await engine.recognize(Array(samples.prefix(25_600)), language: .auto, prompt: nil,
                                                         final: false, profile: .lowLatency)
                let partialTime = initial.duration(to: clock.now)
                let start = clock.now
                let result = try await engine.recognize(samples, language: .auto, prompt: nil,
                                                        final: true, profile: .highAccuracy)
                let text = result.pieces.map(\.text).joined(separator: " ")
                print("BENCH \(id) \(gpu ? "Metal" : "CPU") \(language) load=\(load) partial=\(partialTime) final=\(start.duration(to: clock.now)) audio=\(Double(samples.count) / 16_000)s partialText=\(partial.pieces.map(\.text).joined(separator: " "))")
                #expect(result.language == language)
                #expect(text.lowercased().contains(expected), "Recognized: \(text)")
                #expect(!partial.pieces.isEmpty)
            }
        }
    }

    @Test func marianBidirectionalTranslationUsesNativeInference() async throws {
        let root = try #require(modelRoot)
        let engine = MarianTranslation()
        let pairs = [
            ("opus-en-ru", "The microphone records sound.", "микрофон"),
            ("opus-ru-en", "Микрофон записывает звук.", "microphone")
        ]
        for (direction, source, expected) in pairs {
            let folder = root.appendingPathComponent(direction, isDirectory: true)
            let clock = ContinuousClock()
            let start = clock.now
            let translated = try await engine.translate(source, modelFolder: folder)
            let cold = start.duration(to: clock.now)
            let warmStart = clock.now
            let warm = try await engine.translate(source, modelFolder: folder)
            print("BENCH Marian \(direction) cold=\(cold) warm=\(warmStart.duration(to: clock.now)) result=\(translated)")
            #expect(translated.lowercased().contains(expected))
            #expect(translated != source)
            #expect(warm == translated)
        }
    }

    @Test func concurrentSourcesKeepIndependentLanguageAndTime() async throws {
        let root = try #require(modelRoot)
        let engine = WhisperRecognition()
        _ = try await engine.prepare(model: model(root, id: "small", filename: "ggml-small-q5_1.bin"), metal: true)
        let results = Events()
        let vad = model(root, id: "silero", filename: "ggml-silero-v6.2.0.bin")
        let sessionID = UUID()
        let english = try fixture("en")
        let russian = try fixture("ru")
        async let system: Void = feed(.system, at: 0, audio: Array(repeating: 0, count: 32_000) + english,
                                     engine: engine, vad: vad, results: results, session: sessionID)
        async let microphone: Void = feed(.microphone, at: 0.5, audio: russian + Array(repeating: 0, count: 16_000) + russian,
                                         engine: engine, vad: vad, results: results, session: sessionID)
        _ = await (system, microphone)
        let segments = await results.finals
        let issues = await results.issues
        #expect(issues.isEmpty)
        let a = segments.filter { $0.source == .system }
        let b = segments.filter { $0.source == .microphone }
        #expect(a.first?.language == "en")
        #expect(a.first.map { $0.start >= 1.65 } == true)
        #expect(b.count >= 2)
        #expect(b.allSatisfy { $0.language == "ru" && $0.sessionID == sessionID })
        #expect(zip(b, b.dropFirst()).allSatisfy { $0.end <= $1.start })
    }

    @Test func pacedAudioProducesAnEarlyPartialWithEitherWhisperModel() async throws {
        let root = try #require(modelRoot)
        let samples = try fixture("en")
        let vad = model(root, id: "silero", filename: "ggml-silero-v6.2.0.bin")
        let engine = WhisperRecognition()
        let clock = ContinuousClock()
        for (id, filename) in [("small", "ggml-small-q5_1.bin"),
                               ("turbo", "ggml-large-v3-turbo-q5_0.bin")] {
            _ = try await engine.prepare(model: model(root, id: id, filename: filename), metal: true)
            let events = Events()
            let feed = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .bufferingNewest(32))
            let pipeline = StreamingTranscription(source: .system, sessionID: UUID(), options: SessionOptions(),
                                                  engine: engine, vadURL: vad) { await events.record($0) }
            let consumer = Task { await pipeline.consume(feed.stream) }
            let start = clock.now
            for sample in stride(from: 0, to: 48_000, by: 1_600) {
                try await clock.sleep(until: start + .milliseconds(Int64((sample + 1_600) / 16)))
                feed.continuation.yield(AudioChunk(start: Double(sample) / 16_000,
                    samples: Array(samples[sample..<(sample + 1_600)])))
            }
            for _ in 0..<60 {
                if await events.firstPartialAt != nil { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            feed.continuation.finish()
            await consumer.value
            let first = try #require(await events.firstPartialAt)
            print("BENCH paced \(id) first partial=\(start.duration(to: first))")
        }
    }

    @Test func longSpeechIsSplitAndRepeatedContentSurvives() async throws {
        let root = try #require(modelRoot)
        let engine = WhisperRecognition()
        _ = try await engine.prepare(model: model(root, id: "small", filename: "ggml-small-q5_1.bin"), metal: true)
        let english = try fixture("en")
        let first = try #require(english.firstIndex(where: { abs($0) >= 0.005 }))
        let last = try #require(english.lastIndex(where: { abs($0) >= 0.005 }))
        let phrase = Array(english[first...last])
        let audio = phrase + phrase + phrase
        let events = Events()
        await feed(.system, at: 2, audio: audio, engine: engine,
                   vad: model(root, id: "silero", filename: "ggml-silero-v6.2.0.bin"),
                   results: events, session: UUID())
        let finals = await events.finals
        #expect(finals.count >= 2)
        #expect(finals.last.map { $0.end > 13 } == true)
        let text = finals.map(\.original).joined(separator: " ").lowercased()
        #expect(text.components(separatedBy: "microphone").count >= 3, "Recognized: \(text)")
        #expect(zip(finals, finals.dropFirst()).allSatisfy { $0.end <= $1.start })
    }

    @Test func silenceDoesNotGenerateFinalSegments() async throws {
        let root = try #require(modelRoot)
        let results = Events()
        let engine = WhisperRecognition()
        await feed(.system, at: 0, audio: Array(repeating: 0, count: 48_000), engine: engine,
                   vad: model(root, id: "silero", filename: "ggml-silero-v6.2.0.bin"),
                   results: results, session: UUID())
        #expect(await results.finals.isEmpty)
        #expect(await results.issues.isEmpty)
    }
}

@Test func partialResultIsProvisionalAndReusesFinalIdentifier() async throws {
    let engine = DeterministicRecognition()
    var settings = SessionOptions()
    settings.enableVAD = false
    let results = Events()
    let pair = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .bufferingNewest(32))
    let pipeline = StreamingTranscription(source: .system, sessionID: UUID(), options: settings, engine: engine,
                                          vadURL: nil) { await results.record($0) }
    let processing = Task { await pipeline.consume(pair.stream) }
    for chunk in 0..<13 {
        pair.continuation.yield(AudioChunk(start: Double(chunk) / 10, samples: Array(repeating: 0.08, count: 1_600)))
    }
    for _ in 0..<100 {
        if await !results.partials.isEmpty { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    pair.continuation.finish()
    await processing.value
    let provisional = try #require(await results.partials.first)
    let final = try #require(await results.finals.first)
    #expect(!provisional.finalized && final.finalized)
    #expect(provisional.id == final.id)
    #expect(final.original == "final phrase")
}

private struct DeterministicRecognition: SpeechRecognitionEngine {
    func recognize(_ samples: [Float], language: SpeechLanguage, prompt: String?, final: Bool,
                   profile: RecognitionProfile) async throws -> RecognitionResult {
        RecognitionResult(language: "en", pieces: [
            RecognitionPiece(text: final ? "final phrase" : "partial phrase", start: 0, end: 1)
        ])
    }
}

private actor Events {
    var finals: [TranscriptSegment] = []
    var partials: [TranscriptSegment] = []
    var firstPartialAt: ContinuousClock.Instant?
    var issues: [String] = []
    func record(_ event: StreamEvent) {
        switch event {
        case let .finalized(_, _, segments): finals.append(contentsOf: segments)
        case let .partial(_, segment):
            if let segment {
                partials.append(segment)
                if firstPartialAt == nil { firstPartialAt = ContinuousClock().now }
            }
        case let .issue(_, reason): issues.append(reason)
        case .activity, .pendingPhrase: break
        }
    }
}

private func feed(_ source: AudioSource, at start: Double, audio: [Float], engine: WhisperRecognition,
                  vad: URL, results: Events, session: UUID) async {
    let pair = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .bufferingNewest(320))
    let pipeline = StreamingTranscription(source: source, sessionID: session, options: SessionOptions(),
                                          engine: engine, vadURL: vad) { await results.record($0) }
    let task = Task { await pipeline.consume(pair.stream) }
    for sample in stride(from: 0, to: audio.count, by: 1_600) {
        pair.continuation.yield(AudioChunk(start: start + Double(sample) / 16_000,
            samples: Array(audio[sample..<min(audio.count, sample + 1_600)])))
    }
    pair.continuation.finish()
    await task.value
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["LOCALCAPTION_TEST_DOWNLOAD"] == "1",
               "Set LOCALCAPTION_TEST_DOWNLOAD=1 to verify the published Silero model download"))
func publishedSileroDownloadInstallsAndReplacesAnInvalidCopy() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try ModelStore(directory: root)
    let descriptor = try #require(store.catalog.first { $0.id == "silero" })
    let progress = AsyncStream<Double>.makeStream(bufferingPolicy: .bufferingNewest(4))
    try await store.install(descriptor) { progress.continuation.yield($0) }
    progress.continuation.finish()
    var observed: [Double] = []
    for await value in progress.stream { observed.append(value) }
    #expect(observed.last == 1)
    let file = try #require(await store.path("silero"))
    try Data("invalid".utf8).write(to: file)
    #expect(await store.path("silero") == nil)
    try await store.install(descriptor) { _ in }
    #expect(await store.installedIDs() == ["silero"])
    try ModelStore.validate(file, asset: try #require(descriptor.assets.first))
    try await store.remove(descriptor)
    #expect(await store.installedIDs().isEmpty)
}

@Test func stereoConversionPreservesRightChannelAndCaptureOffsets() throws {
    let stereo = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                           channels: 2, interleaved: false))
    let input = try #require(AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: 4_800))
    let channels = try #require(input.floatChannelData)
    input.frameLength = 4_800
    for i in 0..<4_800 {
        channels[0][i] = 0
        channels[1][i] = 0.2
    }
    let normalizer = PCMNormalizer()
    let first = try #require(try normalizer.normalize(input, start: 3))
    #expect((1_540...1_660).contains(first.samples.count))
    #expect(first.samples.dropFirst(100).prefix(500).allSatisfy { $0 > 0.05 })
    let consecutive = try #require(try normalizer.normalize(input, start: 3.1))
    #expect(consecutive.start == first.end)
    #expect((1_595...1_605).contains(consecutive.samples.count))
    let afterGap = try #require(try normalizer.normalize(input, start: 9))
    #expect(afterGap.start == 9)
}
