import AVFoundation
import CInference
import Foundation
import Testing
@testable import CaptionCore

private let vad63 = modelURL("LOCALCAPTION_TEST_VAD63")
private let vad62ONNX = modelURL("LOCALCAPTION_TEST_VAD62_ONNX")
private let vad62GGML = modelURL("LOCALCAPTION_TEST_VAD62_GGML")
private let playback = modelURL("LOCALCAPTION_TEST_VAD_PLAYBACK")
private let microphone = modelURL("LOCALCAPTION_TEST_VAD_MICROPHONE")
private let whisperModels = modelURL("LOCALCAPTION_TEST_MODELS")

private func modelURL(_ variable: String) -> URL? {
    ProcessInfo.processInfo.environment[variable].map { URL(fileURLWithPath: $0) }
}

@Suite(.serialized, .enabled(if: vad63 != nil, "Set LOCALCAPTION_TEST_VAD63 to the official ONNX model"))
struct NativeSileroTests {
    @Test func validatesSampleRatesFrameSizesAndReset() throws {
        let model = try #require(vad63)
        var reason: UnsafeMutablePointer<CChar>?
        #expect(lc_silero_onnx_open(model.path, 44_100, &reason) == nil)
        #expect(reason != nil)
        lc_string_free(reason)

        for (rate, size) in [(16_000, 512), (8_000, 256)] {
            let detector = try #require(lc_silero_onnx_open(model.path, Int32(rate), nil))
            defer { lc_silero_onnx_close(detector) }
            let quiet = [Float](repeating: 0, count: size)
            let first = quiet.withUnsafeBufferPointer {
                lc_silero_onnx_probability(detector, $0.baseAddress, Int32(size), nil)
            }
            #expect((0..<0.3).contains(first))
            quiet.withUnsafeBufferPointer {
                #expect(lc_silero_onnx_probability(detector, $0.baseAddress, Int32(size - 1), nil) == -1)
                for _ in 0..<40 {
                    #expect(lc_silero_onnx_probability(detector, $0.baseAddress, Int32(size), nil) >= 0)
                }
            }
            var invalid = quiet
            invalid[0] = .nan
            invalid.withUnsafeBufferPointer {
                #expect(lc_silero_onnx_probability(detector, $0.baseAddress, Int32(size), nil) == -1)
            }
            lc_silero_onnx_reset(detector)
            let reset = quiet.withUnsafeBufferPointer {
                lc_silero_onnx_probability(detector, $0.baseAddress, Int32(size), nil)
            }
            #expect(abs(first - reset) < 0.000001)
        }
    }

    @Test func rejectsIncompatibleStateDimensions() throws {
        let model = try #require(vad63)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".onnx")
        defer { try? FileManager.default.removeItem(at: scratch) }
        var bytes = try Data(contentsOf: model)
        // Change the pinned graph's state input width from 128 to 129 without changing protobuf field lengths.
        let input = Data([0x0a, 0x05] + Array("state".utf8) + [0x12, 0x11, 0x0a, 0x0f, 0x08, 0x01,
            0x12, 0x0b, 0x0a, 0x02, 0x08, 0x02, 0x0a, 0x00, 0x0a, 0x03, 0x08, 0x80, 0x01])
        let range = try #require(bytes.range(of: input, options: .backwards))
        bytes[range.upperBound - 2] = 0x81
        try bytes.write(to: scratch)
        #expect(throws: CaptionFailure.self) { try SileroDetector(url: scratch) }
    }

    @Test func matchesNativeWindowsAcrossCaptionFramesAndKeepsStreamsIndependent() throws {
        let model = try #require(vad63)
        let samples = try speech("en")
        let padded = [Float](repeating: 0, count: 3_200) + samples
        let streaming = try SileroDetector(url: model)
        let other = try SileroDetector(url: model)
        let native = try #require(lc_silero_onnx_open(model.path, 16_000, nil))
        defer { lc_silero_onnx_close(native) }
        let silence = [Float](repeating: 0, count: 1_600)
        let initSilence = try other.probability(silence, history: [], quiet: false)
        var processed = 0
        var peak: Float = 0
        for end in stride(from: 1_600, through: padded.count, by: 1_600) {
            let actual = try streaming.probability(Array(padded[(end - 1_600)..<end]), history: [], quiet: false)
            var expected: Float = 0
            padded.withUnsafeBufferPointer { pcm in
                while processed + 512 <= end {
                    expected = max(expected, lc_silero_onnx_probability(native, pcm.baseAddress! + processed, 512, nil))
                    processed += 512
                }
            }
            peak = max(peak, actual)
            #expect(abs(actual - expected) < 0.000001)
            #expect(try other.probability(silence, history: [], quiet: true) == 0)
        }
        #expect(peak > 0.38)
        other.reset()
        #expect(try other.probability(silence, history: [], quiet: false) == initSilence)
    }

    @Test func rejectsCorruptedModelAndUsesLegacyFallback() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let invalid = directory.appendingPathComponent("invalid.onnx")
        try Data("invalid".utf8).write(to: invalid)
        #expect(throws: CaptionFailure.self) { try SileroDetector(url: invalid) }
        guard let vad62GGML else { return }
        let report = VADIssueLog()
        let pipeline = StreamingTranscription(source: .system, sessionID: UUID(), options: SessionOptions(),
            engine: WhisperRecognition(), vadURL: invalid, fallbackVADURL: vad62GGML,
            notify: { await report.receive($0) })
        await pipeline.consume(AsyncStream { output in
            output.yield(AudioChunk(start: 0, samples: [Float](repeating: 0, count: 3_200)))
            output.finish()
        })
        #expect(await report.issues == ["The preferred Silero model could not load. Check it in Settings → Models."])
    }

    @Test func verifiedCatalogPrefers63AndPreserves62() async throws {
        let source = try #require(vad63)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ModelStore(directory: directory)
        let installed = directory.appendingPathComponent("silero-6.3/silero_vad.onnx")
        try FileManager.default.createDirectory(at: installed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: installed)
        if let vad62GGML {
            let legacy = directory.appendingPathComponent("silero/ggml-silero-v6.2.0.bin")
            try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: vad62GGML, to: legacy)
            #expect(await store.voiceActivityModels() == [installed, legacy])
            #expect(await store.voiceActivityModels(preferLegacy: true) == [legacy])
            let handle = try FileHandle(forWritingTo: installed)
            try handle.write(contentsOf: Data([0]))
            try handle.close()
            #expect(await store.voiceActivityModels() == [legacy])
            #expect(await store.installedIDs().isEmpty)
        } else {
            #expect(await store.voiceActivityModels() == [installed])
        }
    }
}

private actor VADIssueLog {
    var issues: [String] = []
    func receive(_ event: StreamEvent) {
        if case let .issue(_, message) = event { issues.append(message) }
    }
}

@Test(.enabled(if: vad63 != nil && vad62GGML != nil && playback != nil && whisperModels != nil,
    "Set the VAD, Whisper and archival playback fixture paths"))
func bothVADBackendsRetainKeyWordsInTheSameArchivalClip() async throws {
    let assets = try #require(whisperModels)
    let model = whisperFixture(assets, .small)
    let recognizer = WhisperRecognition()
    _ = try await recognizer.prepare(model: model, metal: true)
    let audio = try readPCM(#require(playback))
    for (name, candidate) in [("6.2-GGML", vad62GGML), ("6.3-ONNX", vad63)] {
        let events = VADTranscriptLog()
        var options = SessionOptions()
        options.sourceLanguage = .en
        let pipeline = StreamingTranscription(source: .system, sessionID: UUID(), options: options,
            engine: recognizer, vadURL: try #require(candidate), notify: { await events.receive($0) })
        await pipeline.consume(AsyncStream { stream in
            for start in stride(from: 0, to: audio.count, by: 1_600) {
                stream.yield(AudioChunk(start: Double(start) / 16_000,
                    samples: Array(audio[start..<min(start + 1_600, audio.count)])))
            }
            stream.finish()
        })
        let segments = await events.segments
        let original = segments.map(\.original).joined(separator: " ").lowercased()
        print("VADPLAYBACK \(name) captions=\(segments.count) \(original)")
        for phrase in ["my fellow americans", "what your country can do for you", "you can do for your country"] {
            #expect(original.contains(phrase))
        }
        #expect(await events.issues.isEmpty)
    }
    await recognizer.release()
}

private actor VADTranscriptLog {
    var segments: [TranscriptSegment] = []
    var issues: [String] = []

    func receive(_ event: StreamEvent) {
        switch event {
        case let .finalized(_, _, incoming): segments += incoming
        case let .issue(_, message): issues.append(message)
        default: break
        }
    }
}

@Test(.enabled(if: vad63 != nil && ProcessInfo.processInfo.environment["LOCALCAPTION_TEST_VAD_STRESS"] == "1",
    "Set LOCALCAPTION_TEST_VAD_STRESS=1 to process 30 minutes per source"))
func twoSileroStreamsProcessThirtyMinutesEach() async throws {
    let model = try #require(vad63)
    let sources = [try speech("en"), try speech("ru")]
    let clock = ContinuousClock.now
    try await withThrowingTaskGroup(of: Int.self) { group in
        for pcm in sources {
            group.addTask {
                let detector = try SileroDetector(url: model)
                let frames = stride(from: 0, to: pcm.count - 1_599, by: 1_600)
                    .map { Array(pcm[$0..<($0 + 1_600)]) }
                var detected = 0
                for index in 0..<18_000 {
                    let score = try detector.probability(frames[index % frames.count], history: [], quiet: false)
                    if score > 0.38 { detected += 1 }
                }
                return detected
            }
        }
        let scores = try await group.reduce(into: [Int]()) { $0.append($1) }
        #expect(scores.count == 2)
        #expect(scores.allSatisfy { $0 > 9_000 })
        print("VADSTRESS 36,000 caption frames across two streams in \(clock.duration(to: .now)), voiced=\(scores.sorted())")
    }
}

private func speech(_ language: String) throws -> [Float] {
    try readPCM(#require(Bundle.module.url(forResource: language, withExtension: "wav")))
}

private func readPCM(_ url: URL) throws -> [Float] {
    let audio = try AVAudioFile(forReading: url)
    #expect(audio.processingFormat.sampleRate == 16_000)
    #expect(audio.processingFormat.channelCount == 1)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: audio.processingFormat,
                                             frameCapacity: AVAudioFrameCount(audio.length)))
    try audio.read(into: buffer)
    return Array(UnsafeBufferPointer(start: try #require(buffer.floatChannelData?[0]), count: Int(buffer.frameLength)))
}

@Test(.enabled(if: vad63 != nil && vad62ONNX != nil && vad62GGML != nil,
    "Set the Silero 6.2 GGML, 6.2 ONNX, and 6.3 ONNX fixture paths"))
func compareSileroVersionsOnTheSameAudio() throws {
    let english = try speech("en")
    let russian = try speech("ru")
    var seed: UInt32 = 40
    let noise: [Float] = (0..<english.count).map { _ in
        seed = 1_664_525 &* seed &+ 1_013_904_223
        return (Float(seed) / Float(UInt32.max) * 2 - 1) * 0.05
    }
    let music: [Float] = (0..<64_000).map { index in
        let t = Double(index) * 2 * .pi / 16_000
        return Float(sin(t * 261.63) + sin(t * 329.63) + sin(t * 392)) * 0.07
    }
    let pause = [Float](repeating: 0, count: 12_000)
    var fixtures: [VADFixture] = [
        VADFixture("english", english),
        VADFixture("russian", russian),
        VADFixture("slow-english", Array(english.prefix(24_000)) + pause + Array(english.dropFirst(24_000))),
        VADFixture("slow-russian", Array(russian.prefix(25_600)) + pause + Array(russian.dropFirst(25_600))),
        VADFixture("short-english", Array(english.prefix(8_000))),
        VADFixture("quiet-english", english.map { $0 * 0.04 }),
        VADFixture("continuous", Array(repeating: english + russian, count: 3).flatMap { $0 }),
        VADFixture("music", music, containsSpeech: false),
        VADFixture("noise", noise, containsSpeech: false),
        VADFixture("noisy-english", zip(english, noise).map(+)),
        VADFixture("silence", [Float](repeating: 0, count: 64_000), containsSpeech: false)
    ]
    if let playback { fixtures.append(VADFixture("archival-playback", try readPCM(playback))) }
    if let microphone {
        for word in ["yes", "no", "stop"] {
            let audio = try readPCM(microphone.appendingPathComponent("\(word).wav"))
            fixtures.append(VADFixture("microphone-\(word)", audio))
        }
    }
    for (name, location) in [("6.2-GGML", vad62GGML), ("6.2-ONNX", vad62ONNX), ("6.3-ONNX", vad63)] {
        let detector = try SileroDetector(url: #require(location))
        var timings: [Double] = []
        for fixture in fixtures {
            detector.reset()
            let result = try fixture.measure(detector: detector, timings: &timings)
            print("VADCASE \(name) \(fixture.name) \(result)")
        }
        let sorted = timings.sorted()
        print("VADSPEED \(name) frames=\(sorted.count) meanMs=\(timings.reduce(0, +) / Double(timings.count)) p95Ms=\(sorted[Int(Double(sorted.count - 1) * 0.95)])")
    }
}

private struct VADFixture {
    let name: String
    let audio: [Float]
    let envelope: Range<Int>

    init(_ name: String, _ body: [Float], containsSpeech: Bool = true) {
        self.name = name
        let padding = [Float](repeating: 0, count: 16_000)
        audio = padding + body + padding
        envelope = 16_000..<(16_000 + (containsSpeech ? body.count : 0))
    }

    func measure(detector: SileroDetector, timings: inout [Double]) throws -> String {
        var preRoll: [Float] = []
        var detections: [Range<Int>] = []
        var silence = 6
        for start in stride(from: 0, to: audio.count, by: 1_600) {
            let frame = start..<min(start + 1_600, audio.count)
            let slice = Array(audio[frame])
            let quiet = sqrt(slice.reduce(Float.zero) { $0 + $1 * $1 } / Float(slice.count)) < 0.00025
            let startTime = ContinuousClock.now
            let score = try detector.probability(slice, history: preRoll.suffix(4_800), quiet: quiet,
                                                 flush: frame.upperBound == audio.count)
            let time = startTime.duration(to: .now).components
            timings.append(Double(time.seconds) * 1_000 + Double(time.attoseconds) / 1e15)
            if score >= (silence >= 6 ? 0.38 : 0.30) {
                detections.append(frame)
                silence = 0
            } else if silence < 6 {
                silence += 1
                if silence == 6 { preRoll.removeAll(keepingCapacity: true) }
            }
            preRoll.append(contentsOf: slice)
            if preRoll.count > 5_120 { preRoll.removeFirst(preRoll.count - 5_120) }
        }
        var groupedFrames: [Int] = []
        var end = -16_000
        for frame in detections {
            if frame.lowerBound - end >= 9_600 { groupedFrames.append(0) }
            groupedFrames[groupedFrames.count - 1] += 1
            end = frame.upperBound
        }
        let coverage = detections.reduce(0) { $0 + $1.clamped(to: envelope).count }
        let outside = detections.reduce(0) { $0 + $1.count } - coverage
        let on = detections.first.map { $0.upperBound - envelope.lowerBound }
        let off = detections.last.map { $0.upperBound - envelope.upperBound }
        return "segments=\(groupedFrames.filter { $0 >= 2 }.count) onset=\(milliseconds(on)) offset=\(milliseconds(off)) envelopeMiss=\(milliseconds(envelope.count - coverage)) outside=\(milliseconds(outside))"
    }

    private func milliseconds(_ count: Int?) -> String {
        count.map { String(format: "%.0f", Double($0) / 16) } ?? "—"
    }
}
