import AVFoundation
import Darwin
import Foundation
import Testing
@testable import CaptionCore

@Test func speakerAggregationKeepsPacedSpeechTogetherAndSeparatesChanges() {
    let session = UUID()
    let firstSpeaker = SessionSpeaker(id: UUID(), number: 1)
    let secondSpeaker = SessionSpeaker(id: UUID(), number: 2)
    func caption(_ start: Double, _ text: String, _ speaker: SessionSpeaker) -> TranscriptSegment {
        var segment = TranscriptSegment(sessionID: session, source: .system, start: start, end: start + 0.5,
                                        original: text, language: "en", finalized: true)
        SpeakerAttribution(speaker: speaker, status: .assigned, confidence: 0.8).apply(to: &segment)
        return segment
    }
    var aggregation = PhraseAggregation(pause: 1.8, strategy: .balanced)
    #expect(aggregation.accept(caption(0, "I think we should", firstSpeaker)) == nil)
    #expect(aggregation.accept(caption(1, "consider another approach", firstSpeaker)) == nil)
    let completed = aggregation.accept(caption(1.6, "use different data", secondSpeaker))
    #expect(completed?.original == "I think we should consider another approach")
    #expect(completed?.speakerID == firstSpeaker.id)
    #expect(aggregation.finish()?.speakerID == secondSpeaker.id)
}

@Test func timelineDistinguishesUncertainMixedAndOverlappingSpeech() {
    let a = SessionSpeaker(id: UUID(), number: 1)
    let b = SessionSpeaker(id: UUID(), number: 2)
    var timeline = SpeakerTimeline()
    timeline.replace(start: 0, end: 4, with: [
        SpeakerInterval(start: 0, end: 1, speaker: a, overlap: false, confidence: 0.8),
        SpeakerInterval(start: 1, end: 2, speaker: b, overlap: false, confidence: 0.9),
        SpeakerInterval(start: 2, end: 3, speaker: nil, overlap: true, confidence: 0.8)
    ])
    #expect(timeline.attribution(start: 0.1, end: 0.9).speaker == a)
    #expect(timeline.attribution(start: 0.3, end: 1.7).status == .mixed)
    #expect(timeline.attribution(start: 1.6, end: 2.4).status == .overlapping)
    #expect(timeline.attribution(start: 3.1, end: 3.9).status == .unknown)
}

@Test func speakerMetadataSurvivesRenameReopenAndExport() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("captions.sqlite3")
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let store = try CaptionRepository(location: file)
    var session = CaptionSession(title: "Interview", options: SessionOptions())
    session.status = .completed
    let another = CaptionSession(title: "Different session", options: SessionOptions())
    try await store.create(session)
    try await store.create(another)
    let speaker = SessionSpeaker(id: UUID(), number: 1)
    var caption = TranscriptSegment(sessionID: session.id, source: .system, start: 1, end: 2,
                                   original: "We can continue.", language: "en", finalized: true)
    SpeakerAttribution.unknown.apply(to: &caption)
    let original = caption.id
    let unassigned = TranscriptSegment(sessionID: session.id, source: .microphone, start: 0, end: 1,
                                     original: "Hello.", language: "en", finalized: true)
    try await store.insert([caption, unassigned])
    SpeakerAttribution(speaker: speaker, status: .assigned, confidence: 0.87).apply(to: &caption)
    #expect(try await store.updateSpeaker(caption))
    #expect(try await !store.updateSpeaker(caption))
    try await store.renameSpeaker(speaker.id, session: session.id, name: "  Interviewer  ")
    await #expect(throws: CaptionFailure.self) {
        try await store.renameSpeaker(speaker.id, session: another.id, name: "Wrong session")
    }
    let reopened = try CaptionRepository(location: file)
    let saved = try await reopened.segments(session.id)
    #expect(saved.count == 2)
    #expect(saved.first?.speakerStatus == nil)
    #expect(saved.last?.id == original)
    #expect(saved.last?.speakerName == "Interviewer")
    #expect(saved.last?.speakerID == speaker.id)
    #expect(saved.last?.original == caption.original)
    #expect(saved.last?.speakerConfidence == 0.87)
    let json = String(decoding: try TranscriptExport.render(session, segments: saved, format: .json), as: UTF8.self)
    let txt = String(decoding: try TranscriptExport.render(session, segments: saved, format: .txt), as: UTF8.self)
    let srt = String(decoding: try TranscriptExport.render(session, segments: saved, format: .srt), as: UTF8.self)
    let anonymous = String(decoding: try TranscriptExport.render(session, segments: saved, format: .srt,
                                                                includeSpeakerNames: false), as: UTF8.self)
    #expect(json.contains("\"speaker_name\" : \"Interviewer\""))
    #expect(json.contains("\"speaker_id\""))
    #expect(txt.contains("[Interviewer]"))
    #expect(srt.contains("Interviewer: We can continue."))
    #expect(!anonymous.contains("Interviewer"))
    try await reopened.deleteHistory(keeping: nil)
    await #expect(throws: CaptionFailure.self) {
        try await reopened.renameSpeaker(speaker.id, session: session.id, name: "Deleted")
    }
    #expect(try await reopened.segments(session.id).isEmpty)
}

private let speakerModels = ProcessInfo.processInfo.environment["LOCALCAPTION_TEST_SPEAKER_MODELS"]
    .map { URL(fileURLWithPath: $0) }
private let speakerFixture = ProcessInfo.processInfo.environment["LOCALCAPTION_TEST_SPEAKER_FIXTURE"]
    .map { URL(fileURLWithPath: $0) }

private actor DiarizationEvents {
    var status = DiarizationStatus.disabled
    var windows = 0
    var firstUpdate: ContinuousClock.Instant?
    var inference = Duration.zero
    var lagEvents = 0
    func record(_ event: DiarizationEvent) {
        switch event {
        case let .status(value, _):
            status = value
            if value == .behind { lagEvents += 1 }
        case let .timelineUpdated(inferenceTime):
            windows += 1
            inference += inferenceTime
            if firstUpdate == nil { firstUpdate = .now }
        }
    }

    func waitForWindow(after count: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while windows == count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(windows > count)
    }
}

private struct ReferenceTurn: Decodable {
    let speaker: String
    let start: Double
    let end: Double
}

private func samples(_ path: URL) throws -> [Float] {
    let audio = try AVAudioFile(forReading: path)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length)))
    #expect(audio.processingFormat.sampleRate == 16_000)
    try audio.read(into: buffer)
    let channel = try #require(buffer.floatChannelData?[0])
    return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
}

@Suite(.serialized, .enabled(if: speakerModels != nil && speakerFixture != nil, "Set speaker model and annotated fixture paths"))
struct RealDiarizationTests {
    @Test(arguments: DiarizationMode.allCases)
    func rollingDiarizationUsesRealModels(_ mode: DiarizationMode) async throws {
        let store = try ModelStore(directory: #require(speakerModels))
        let folder = try #require(speakerFixture)
        let audio = try samples(folder.appendingPathComponent("speakers.wav"))
        let reference = try JSONDecoder().decode([ReferenceTurn].self,
            from: Data(contentsOf: folder.appendingPathComponent("speakers.json")))
        let speaker = DiarizationSession()
        let events = DiarizationEvents()
        let identity = UUID()
        func interval(_ start: Double, _ end: Double, source: AudioSource = .system) -> TranscriptSegment {
            TranscriptSegment(sessionID: identity, source: source, start: start, end: end,
                              original: "", language: "en", finalized: true)
        }
        #expect(speaker.refresh(interval(1, 2)).speakerStatus == nil)
        var settings = DiarizationOptions()
        settings.mode = mode
        let loadStart = ContinuousClock.now
        speaker.begin(models: store, settings: settings, after: 0.25) { await events.record($0) }
        defer { speaker.stop(at: 140) }
        for _ in 0..<200 {
            if await events.status != .disabled { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(await events.status == .active)
        let load = loadStart.duration(to: .now)
        let feedStart = ContinuousClock.now
        for start in stride(from: 0, to: audio.count, by: 1_600) {
            let delivered = start + 1_600 - 4_800
            let expectsWindow = delivered >= mode.warmup && (delivered - mode.warmup) % mode.hop == 0
            let count = expectsWindow ? await events.windows : 0
            speaker.offer(AudioChunk(start: Double(start) / 16_000,
                                    samples: Array(audio[start..<min(audio.count, start + 1_600)])))
            if expectsWindow { try await events.waitForWindow(after: count) }
            else { try await Task.sleep(for: .milliseconds(4)) }
        }
        try await Task.sleep(for: .milliseconds(200))
        let first = await events.firstUpdate.map { feedStart.duration(to: $0) }
        let windows = await events.windows
        #expect(windows > 18)
        #expect(speaker.refresh(interval(0, 0.2)).speakerStatus == nil)
        #expect(speaker.refresh(interval(1, 2, source: .microphone)).speakerStatus == nil)
        let truthAndPrediction = (2..<310).compactMap { index -> (String?, UUID?)? in
            let time = Double(index) * 0.2
            let referenceIDs = Set(reference.filter { $0.start < time && $0.end > time }.map(\.speaker))
            guard referenceIDs.count <= 1,
                  !reference.contains(where: { min(abs(time - $0.start), abs(time - $0.end)) <= 0.25 }) else { return nil }
            return (referenceIDs.first, speaker.refresh(interval(time - 0.1, time + 0.1)).speakerID)
        }
        let names = Array(Set(reference.map(\.speaker))).sorted()
        let predicted = Set(truthAndPrediction.compactMap(\.1))
        let counts = Dictionary(grouping: truthAndPrediction.compactMap { reference, prediction in
            reference.flatMap { name in prediction.map { (name, $0) } }
        }, by: \.0)
        func best(_ available: Set<UUID>, index: Int) -> Int {
            guard index < names.count else { return 0 }
            let candidates = counts[names[index], default: []]
            return max(best(available, index: index + 1), available.map { id in
                candidates.filter { $0.1 == id }.count + best(available.subtracting([id]), index: index + 1)
            }.max() ?? 0)
        }
        let referenceFrames = truthAndPrediction.filter { $0.0 != nil }.count
        let missed = truthAndPrediction.filter { $0.0 != nil && $0.1 == nil }.count
        let falseAlarm = truthAndPrediction.filter { $0.0 == nil && $0.1 != nil }.count
        let confused = referenceFrames - missed - best(predicted, index: 0)
        let overlap = speaker.refresh(interval(21.5, 22.7)).speakerStatus
        let early = speaker.refresh(interval(0.9, 2.2))
        let late = speaker.refresh(interval(51.5, 53))
        let inference = await events.inference
        print("SPEAKER \(mode.rawValue) windows=\(windows) load=\(load) first=\(String(describing: first)) native=\(inference) referenceFrames=\(referenceFrames) missed=\(missed) false=\(falseAlarm) confused=\(confused) speakers=\(predicted.count) overlap=\(String(describing: overlap)) early=\(early.speakerLabel ?? "-") returned=\(late.speakerLabel ?? "-")")
        #expect(predicted.count >= 2)
        #expect(missed + confused < referenceFrames / 2)
        #expect(early.speakerID != nil)
        #expect(early.speakerID == late.speakerID)
        speaker.stop(at: Double(audio.count) / 16_000)
        await speaker.waitForShutdown()
        speaker.offer(AudioChunk(start: 65, samples: Array(audio.prefix(16_000))))
        #expect(speaker.refresh(interval(65, 66)).speakerStatus == nil)
        #expect(speaker.refresh(interval(51.5, 53)).speakerID == early.speakerID)
        let resumed = DiarizationEvents()
        speaker.begin(models: store, settings: settings, after: 370) { await resumed.record($0) }
        for _ in 0..<200 {
            if await resumed.status != .disabled { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(await resumed.status == .active)
        for start in stride(from: 0, to: 96_000, by: 1_600) {
            speaker.offer(AudioChunk(start: 370 + Double(start) / 16_000,
                                    samples: Array(audio[start..<(start + 1_600)])))
            try await Task.sleep(for: .milliseconds(12))
        }
        try await Task.sleep(for: .milliseconds(150))
        #expect(speaker.refresh(interval(370.9, 372.2)).speakerID == early.speakerID)
        speaker.stop(at: 376)
        await speaker.waitForShutdown()
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["LOCALCAPTION_SPEAKER_STRESS"] == "1",
               "Set LOCALCAPTION_SPEAKER_STRESS=1 to analyze six minutes of audio"))
func speakerProfilesRemainStableInExtendedStream() async throws {
    let store = try ModelStore(directory: #require(speakerModels))
    let audio = try samples(#require(speakerFixture).appendingPathComponent("speakers.wav"))
    let session = DiarizationSession()
    let events = DiarizationEvents()
    let captionSession = UUID()
    let startClock = ContinuousClock.now
    let duration = audio.count / AudioChunk.rate
    defer { session.stop(at: Double(6 * duration)) }
    session.begin(models: store, settings: DiarizationOptions(), after: 0) { await events.record($0) }
    for _ in 0..<200 {
        if await events.status != .disabled { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    try #require(await events.status == .active)
    var known: UUID?
    for cycle in 0..<6 {
        let offset = cycle * duration
        for second in 0..<duration {
            let count = await events.windows
            for part in 0..<4 {
                let position = second * 16_000 + part * 4_000
                session.offer(AudioChunk(start: Double(offset + second) + Double(part) / 4,
                    samples: Array(audio[position..<(position + 4_000)])))
            }
            if offset + second >= 1 {
                try await events.waitForWindow(after: count)
            }
            if second == 4 {
                let anchor = TranscriptSegment(sessionID: captionSession, source: .system, start: Double(offset) + 0.9,
                    end: Double(offset) + 2.2, original: "", language: "en", finalized: true)
                let id = try #require(session.refresh(anchor).speakerID)
                if let known { #expect(id == known) } else { known = id }
            }
        }
    }
    let analysis = await events.inference
    let windows = await events.windows
    #expect(await events.lagEvents == 0)
    print("SPEAKER STRESS audioSeconds=\(6 * duration) windows=\(windows) native=\(analysis) elapsed=\(startClock.duration(to: .now))")
    session.stop(at: Double(6 * duration))
    await session.waitForShutdown()
}

private let benchmarkMode = ProcessInfo.processInfo.environment["LOCALCAPTION_SPEAKER_BENCHMARK"]

@Test(.enabled(if: ProcessInfo.processInfo.environment["LOCALCAPTION_TEST_SPEAKER_DOWNLOAD"] == "1",
               "Set LOCALCAPTION_TEST_SPEAKER_DOWNLOAD=1 to test both pinned downloads"))
func bothSpeakerModelsDownloadAndOpen() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try ModelStore(directory: directory)
    for model in store.catalog where model.kind == .diarization {
        try await store.install(model) { _ in }
    }
    let paths = try #require(try await store.diarizationModels())
    let engine = try NativeSpeakerAnalysis(segmentation: paths.segmentation, embedding: paths.embedding)
    let silence = try engine.analyze([Float](repeating: 0, count: 32_000), start: 1)
    #expect(silence.frames.isEmpty && silence.observations.isEmpty)
}

private actor TimedWhisper: SpeechRecognitionEngine {
    let native = WhisperRecognition()
    private(set) var timings: [Double] = []

    func recognize(_ samples: [Float], language: SpeechLanguage, prompt: String?,
                   final: Bool, profile: RecognitionProfile) async throws -> RecognitionResult {
        let start = ContinuousClock.now
        let result = try await native.recognize(samples, language: language, prompt: prompt, final: final, profile: profile)
        timings.append(seconds(start.duration(to: .now)))
        return result
    }
}

private actor TimedCaptions {
    var captions: [TranscriptSegment] = []
    var draftCounts: [Int] = []
    var translationTasks: [Task<Double?, Never>] = []
    let translator = MarianTranslation()
    let folder: URL
    init(folder: URL) { self.folder = folder }

    func record(_ event: StreamEvent) async {
        switch event {
        case let .speakerDrafts(_, drafts): draftCounts.append(drafts.count)
        case let .finalized(_, _, segments):
            captions += segments
            for segment in segments where segment.language == "en" {
                let translator = translator
                let folder = folder
                translationTasks.append(Task {
                    let start = ContinuousClock.now
                    guard (try? await translator.translate(segment.original, modelFolder: folder)) != nil else { return nil }
                    return seconds(start.duration(to: .now))
                })
            }
        default: break
        }
    }

    func translations() async -> [Double] {
        var times: [Double] = []
        for task in translationTasks {
            if let time = await task.value { times.append(time) }
        }
        return times
    }
}

private func seconds(_ duration: Duration) -> Double {
    let parts = duration.components
    return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
}

private func cpuSeconds(_ usage: rusage) -> Double {
    Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
        + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
}

@Test(.enabled(if: benchmarkMode != nil, "Set LOCALCAPTION_SPEAKER_BENCHMARK to off, realTime or highAccuracy"))
func pacedSpeakerPipelineBenchmark() async throws {
    let raw = try #require(benchmarkMode)
    let modelsPath = try #require(ProcessInfo.processInfo.environment["LOCALCAPTION_TEST_MODELS"])
    let models = URL(fileURLWithPath: modelsPath)
    let audio = Array(try samples(#require(speakerFixture).appendingPathComponent("speakers.wav")).prefix(224_000))
    let whisper = TimedWhisper()
    let native = whisper.native
    try #require(try await native.prepare(model: whisperFixture(models, .small), metal: true))
    let captures = TimedCaptions(folder: models.appendingPathComponent("opus-en-ru"))
    _ = try await captures.translator.translate("This is an offline test.", modelFolder: models.appendingPathComponent("opus-en-ru"))
    let diarization = DiarizationSession()
    defer { diarization.stop(at: Double(audio.count) / 16_000) }
    let timing = DiarizationEvents()
    let session = UUID()
    let vad = ProcessInfo.processInfo.environment["LOCALCAPTION_TEST_VAD63"].map { URL(fileURLWithPath: $0) }
    let mode = DiarizationMode(rawValue: raw)
    let started = ContinuousClock.now
    var initialUsage = rusage()
    getrusage(RUSAGE_SELF, &initialUsage)
    if let mode {
        let catalog = try ModelStore(directory: #require(speakerModels))
        var options = DiarizationOptions()
        options.mode = mode
        diarization.begin(models: catalog, settings: options, after: 0) { await timing.record($0) }
        for _ in 0..<200 {
            if await timing.status != .disabled { break }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    let captureStart = ContinuousClock.now
    var options = SessionOptions()
    options.translate = true
    options.sourceLanguage = .en
    let feed = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .bufferingNewest(96))
    let pipeline = StreamingTranscription(source: .system, sessionID: session, options: options,
        engine: whisper, vadURL: vad, diarization: diarization) { await captures.record($0) }
    let consumer = Task { await pipeline.consume(feed.stream) }
    for start in stride(from: 0, to: audio.count, by: 1_600) {
        try await ContinuousClock().sleep(until: captureStart.advanced(by: .milliseconds(Int64(start + 1_600) / 16)))
        feed.continuation.yield(AudioChunk(start: Double(start) / 16_000,
                                         samples: Array(audio[start..<(start + 1_600)])))
    }
    feed.continuation.finish()
    await consumer.value
    let captions = await captures.captions
    let calls = await whisper.timings
    let translations = await captures.translations()
    let windows = await timing.windows
    let achieved = await timing.firstUpdate.map { seconds(captureStart.duration(to: $0)) }
    let inference = await timing.inference
    diarization.stop(at: Double(audio.count) / 16_000)
    await diarization.waitForShutdown()
    var finalUsage = rusage()
    getrusage(RUSAGE_SELF, &finalUsage)
    let elapsed = seconds(started.duration(to: .now))
    let mean: ([Double]) -> Double = { $0.reduce(0, +) / Double(max(1, $0.count)) }
    let drafts = await captures.draftCounts.max() ?? 0
    print("SPEAKER PERF \(raw) elapsed=\(elapsed) cpu=\((cpuSeconds(finalUsage) - cpuSeconds(initialUsage)) / elapsed * 100) rss=\(finalUsage.ru_maxrss) whisperCalls=\(calls.count) whisperMean=\(mean(calls)) translationCalls=\(translations.count) translationMean=\(mean(translations)) firstTimeline=\(String(describing: achieved)) native=\(inference) windows=\(windows) captions=\(captions.count) assigned=\(captions.filter { $0.speakerID != nil }.count) drafts=\(drafts)")
    #expect(!calls.isEmpty)
    #expect(!translations.isEmpty)
    #expect(!captions.isEmpty)
    #expect(Set(captions.map(\.id)).count == captions.count)
    if mode == nil {
        #expect(windows == 0 && drafts == 0)
        #expect(captions.allSatisfy { $0.speakerStatus == nil })
    } else {
        #expect(windows > 0)
        #expect(captions.contains { $0.speakerID != nil })
    }
    await native.release()
}
