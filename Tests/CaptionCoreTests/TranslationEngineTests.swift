import Foundation
import Testing
@testable import CaptionCore

private let preparedNLLB = ProcessInfo.processInfo.environment["LOCALCAPTION_TEST_NLLB"]
    .map { URL(fileURLWithPath: $0, isDirectory: true) }
private let marianModels = ProcessInfo.processInfo.environment["LOCALCAPTION_TEST_MODELS"]
    .map { URL(fileURLWithPath: $0, isDirectory: true) }

@Suite(.serialized, .enabled(if: preparedNLLB != nil && marianModels != nil,
    "Set LOCALCAPTION_TEST_NLLB and LOCALCAPTION_TEST_MODELS to run both sets of actual weights"))
struct OfflineTranslationTests {
    @Test func bothEnginesTranslateTheSameFiveInputs() async throws {
        let nllb = try #require(preparedNLLB)
        let marian = try #require(marianModels)
        let engine = TranslationEngineManager()
        let samples = [
            ("en", "ru", "Hello, how are you doing today?"),
            ("en", "ru", "We need to optimize the inference pipeline to reduce latency."),
            ("en", "ru", "Although the current implementation works correctly, we should consider improving its performance before deploying it."),
            ("en", "ru", "I think we should discuss this tomorrow."),
            ("ru", "en", "Давайте обсудим архитектуру системы и возможные способы оптимизации.")
        ]
        for model in TranslationModel.allCases {
            for (index, sample) in samples.enumerated() {
                let (source, target, text) = sample
                let folder = model == .nllb ? nllb : marian.appendingPathComponent("opus-\(source)-\(target)")
                let clock = ContinuousClock()
                let first = clock.now
                let output = try await engine.translate(text, using: model, source: source, target: target, modelFolder: folder)
                let firstTime = first.duration(to: clock.now)
                let begin = clock.now
                let warmed = try await engine.translate(text, using: model, source: source, target: target, modelFolder: folder)
                print("COMPARE \(model.rawValue) sample=\(index + 1) first=\(firstTime) warm=\(begin.duration(to: clock.now)) \(output)")
                #expect(warmed == output)
                #expect(output != text)
                #expect(!output.isEmpty)
                #expect(!output.contains("eng_Latn") && !output.contains("rus_Cyrl") && !output.contains("</s>"))
                #expect(output.last.map { ".!?".contains($0) } == true)
                let cyrillic = output.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
                #expect(cyrillic == (target == "ru"))
            }
        }
        await engine.release()
    }

    @Test func validatedImportAndQueuedSwitchPreserveTextAndProvenance() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let models = try ModelStore(directory: root)
        let nllb = try #require(preparedNLLB)
        let marian = try #require(marianModels)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("opus-en-ru"),
            withDestinationURL: marian.appendingPathComponent("opus-en-ru"))
        #expect(await models.installedIDs().contains(TranslationModel.nllb.id) == false)
        try await models.importModel(TranslationModel.nllb.id, from: nllb) { _ in }
        #expect(await models.installedIDs().contains(TranslationModel.nllb.id))
        let installed = try await models.verifiedTranslationModel(TranslationModel.nllb.id)
        let repository = try CaptionRepository(location: root.appendingPathComponent("switch.sqlite3"))
        let session = CaptionSession(title: "Offline switch", options: SessionOptions())
        try await repository.create(session)
        let engine = TranslationEngineManager()
        let queue = TranslationQueue(repository: repository, session: session, models: models, engine: engine,
                                     update: { _ in }, issue: { _ in })
        let first = request(session, at: 0, using: .nllb, source: .system)
        let second = request(session, at: 2, using: .marian, source: .microphone)
        try await repository.insert([first, second])
        try await queue.finish(timeout: .seconds(15))
        let results = try await repository.segments(session.id)
        #expect(results.map(\.id) == [first.id, second.id])
        #expect(results.map(\.source) == [.system, .microphone])
        #expect(results.map(\.translationStatus) == [.translated, .translated])
        #expect(results.map(\.translationModel) == [.nllb, .marian])
        #expect(results.first?.translationModelVersion == TranslationModel.nllb.version)
        let json = String(decoding: try TranscriptExport.render(session, segments: results, format: .json), as: UTF8.self)
        #expect(json.contains("\"translationModel\" : \"nllb-200-600m\""))
        let nllbText = try #require(results.first?.translation)
        for format in [ExportFormat.txt, .srt] {
            let exported = String(decoding: try TranscriptExport.render(session, segments: results, format: format), as: UTF8.self)
            #expect(exported.contains(nllbText))
            #expect(exported.contains(first.original))
        }

        let tokenizer = installed.appendingPathComponent("sentencepiece.bpe.model")
        let original = try FileHandle(forUpdating: tokenizer)
        let byte = try #require(original.read(upToCount: 1)?.first)
        try original.seek(toOffset: 0)
        try original.write(contentsOf: Data([byte ^ 0xFF]))
        try original.close()
        #expect(await models.installedIDs().contains(TranslationModel.nllb.id) == false)
        let broken = request(session, at: 4, using: .nllb, source: .system)
        try await repository.insert([broken])
        let failure = try #require(try await TranslationQueue.process(broken, session: session,
            repository: repository, models: models, engine: engine))
        #expect(failure.translationStatus == .failed)
        #expect(failure.translationError?.contains("SHA-256") == true)
        #expect(failure.original == broken.original)
        let retry = try #require(try await repository.retryTranslation(broken.id, session: session.id, model: .marian))
        let recovered = try #require(try await TranslationQueue.process(retry, session: session,
            repository: repository, models: models, engine: engine))
        #expect(recovered.translationStatus == .translated)
        #expect(recovered.translationModel == .marian)
        #expect(recovered.id == broken.id)
        try await models.importModel(TranslationModel.nllb.id, from: nllb) { _ in }
        #expect(await models.installedIDs().contains(TranslationModel.nllb.id))
        await engine.release()
        let descriptor = try #require(models.catalog.first { $0.id == TranslationModel.nllb.id })
        try await models.remove(descriptor)
        #expect(await models.installedIDs().contains(TranslationModel.nllb.id) == false)
        #expect(try await repository.segments(session.id).count == 3)
    }
}

@Test func backlogLimitKeepsOriginalTextAndRejectsStaleCompletion() async throws {
    let repository = try CaptionRepository(location: nil)
    let session = CaptionSession(title: "Backlog", options: SessionOptions())
    try await repository.create(session)
    let limit = CaptionRepository.maximumPendingTranslations
    let requests = (0...limit).map { request(session, at: Double($0 * 2), using: .nllb, source: .system) }
    let saved = try await repository.insert(requests)
    #expect(saved.map(\.original) == requests.map(\.original))
    #expect(saved.filter { $0.translationStatus == .pending }.count == limit)
    #expect(saved.last?.translationStatus == .failed)
    try await repository.completePendingTranslations(session.id, reason: "Timed out")
    let original = try #require(requests.first)
    _ = try await repository.retryTranslation(original.id, session: session.id, model: .marian)
    var stale = original
    stale.translation = "Stale"
    stale.translationStatus = .translated
    #expect(try await repository.updateTranslation(stale, matching: original) == false)
    let first = try await repository.pendingTranslations(session.id).first
    #expect(first?.translationModel == .marian)
    #expect(first?.translation == nil)
    #expect(try await repository.segments(session.id).count == limit + 1)
}

private func request(_ session: CaptionSession, at start: Double, using model: TranslationModel,
                     source: AudioSource) -> TranscriptSegment {
    var segment = TranscriptSegment(sessionID: session.id, source: source, start: start, end: start + 1,
        original: "I think we should discuss this tomorrow.", language: "en", finalized: true, translationStatus: .pending)
    segment.translationModel = model
    segment.translationModelVersion = model.version
    return segment
}
