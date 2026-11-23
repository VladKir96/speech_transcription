import Foundation
import Testing
import CaptionCore

@Test(arguments: [
    (0.5, 0.5, false), (0.5, 1.8, true), (1.0, 1.8, true),
    (2.0, 1.8, false), (2.0, 2.8, true), (3.0, 1.8, false), (3.0, 4.0, true)
])
func phrasePauseControlsEnglishTranslationUnits(gap: Double, pause: Double, joins: Bool) async {
    // A 0.5-second pause remains within the default STT window. Longer gaps exercise the
    // distinct phrase aggregation path after the short recognizer window has closed.
    let script = gap == 0.5 && joins ? ["I think we should consider another approach."]
        : ["I think we should…", "consider another approach."]
    let result = await recognizeBursts(gap: gap, pause: pause, script: script)
    #expect(result.finalized.count == (joins ? 1 : 2))
    #expect(result.finalized.first?.original == (joins ? "I think we should consider another approach." : script[0]))
    #expect(result.finalized.allSatisfy { $0.translationStatus == .pending })
    #expect(result.pending.first?.id == result.finalized.first?.id)
    #expect(Set(result.finalized.map(\.id)).count == result.finalized.count)
}

@Test func completeSentencesStaySeparateAndRussianFragmentsKeepContext() async {
    let english = await recognizeBursts(gap: 0.7, pause: 2.8,
        script: ["Thank you for joining.", "Next question is about funding."])
    #expect(english.finalized.count == 2)
    let russian = await recognizeBursts(gap: 1, pause: 1.8, language: "ru", source: .microphone,
        script: ["Я думаю, что нам следует…", "рассмотреть другой вариант."])
    #expect(russian.finalized.map(\.original) == ["Я думаю, что нам следует рассмотреть другой вариант."])
    #expect(russian.finalized.allSatisfy { $0.source == .microphone })
    #expect(russian.pending.first?.id == russian.finalized.first?.id)
}

@Test func continuousAndRapidSpeechRespectThePhraseDurationAndFlushOnStop() async {
    let result = await recognizeBursts(gap: 0, pause: 4, burst: 11,
        script: ["We begin a longer thought", "and continue sharing ideas", "and finish the last thought."])
    #expect(result.finalized.count >= 2)
    #expect(result.finalized.allSatisfy { $0.end - $0.start <= 15 })
    #expect(result.finalized.last?.original.contains("finish the last thought") == true)
    let quiet = await recognizeBursts(gap: 3, pause: 1.8, burst: 0, script: [])
    #expect(quiet.finalized.isEmpty)
}

@Test func translationPresetsProvideDistinctPausesAndClampStoredOverrides() {
    var options = SessionOptions()
    #expect(options.effectivePhrasePause == 1.8)
    options.translationStrategy = .fast
    #expect(options.effectivePhrasePause == 0.9)
    options.translationStrategy = .contextAware
    #expect(options.effectivePhrasePause == 2.8)
    options.phraseCompletionPause = 100
    #expect(options.effectivePhrasePause == 4)
    options.phraseCompletionPause = 0
    #expect(options.effectivePhrasePause == 0.5)
}

private actor ScriptedSpeech: SpeechRecognitionEngine {
    let language: String
    var script: ArraySlice<String>

    init(language: String, script: [String]) {
        self.language = language
        self.script = script[...]
    }

    func recognize(_ samples: [Float], language: SpeechLanguage, prompt: String?, final: Bool,
                   profile: RecognitionProfile) async throws -> RecognitionResult {
        let text = final ? script.popFirst() : script.first
        let duration = Double(samples.count) / Double(AudioChunk.rate)
        let pieces = text.map { [RecognitionPiece(text: $0, start: 0.25, end: min(duration, 0.85))] } ?? []
        return RecognitionResult(language: self.language, pieces: pieces)
    }
}

private actor PhraseEvents {
    var pending: [TranscriptSegment] = []
    var finalized: [TranscriptSegment] = []

    func record(_ event: StreamEvent) {
        if case let .pendingPhrase(_, phrase?) = event { pending.append(phrase) }
        if case let .finalized(_, _, segments) = event { finalized.append(contentsOf: segments) }
    }

    func results() -> (pending: [TranscriptSegment], finalized: [TranscriptSegment]) { (pending, finalized) }
}

private func recognizeBursts(gap: Double, pause: Double, burst: Double = 1.2, language: String = "en",
                             source: AudioSource = .system, script: [String]) async
                             -> (pending: [TranscriptSegment], finalized: [TranscriptSegment]) {
    var options = SessionOptions()
    options.enableVAD = false
    options.translate = true
    options.targetLanguage = language == "en" ? .ru : .en
    options.phraseCompletionPause = pause
    let reports = PhraseEvents()
    let actor = StreamingTranscription(source: source, sessionID: UUID(), options: options,
        engine: ScriptedSpeech(language: language, script: script), vadURL: nil, notify: { await reports.record($0) })
    let audio = AsyncStream<AudioChunk>.makeStream()
    var frame = 0
    for (voiced, length) in [(true, burst), (false, gap), (true, burst)] {
        for _ in 0..<Int((length * 10).rounded()) {
            audio.continuation.yield(AudioChunk(start: Double(frame) / 10,
                samples: Array(repeating: voiced ? 0.1 : 0, count: 1_600)))
            frame += 1
        }
    }
    audio.continuation.finish()
    await actor.consume(audio.stream)
    return await reports.results()
}
