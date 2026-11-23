import Foundation

public actor TranslationQueue {
    public typealias Update = @Sendable (TranscriptSegment) async -> Void
    public typealias Issue = @Sendable (String) async -> Void

    private let repository: CaptionRepository
    private let session: CaptionSession
    private let models: ModelStore
    private let engine: any TranslationEngine
    private let update: Update
    private let issue: Issue
    private var worker: Task<Void, Never>?
    private var requested = false
    private var closed = false

    public init(repository: CaptionRepository, session: CaptionSession, models: ModelStore,
                engine: any TranslationEngine, update: @escaping Update, issue: @escaping Issue) {
        self.repository = repository
        self.session = session
        self.models = models
        self.engine = engine
        self.update = update
        self.issue = issue
    }

    public func kick() {
        guard !closed else { return }
        requested = true
        guard worker == nil else { return }
        worker = Task { await drain() }
    }

    public func finish(timeout: Duration = .seconds(8)) async throws {
        kick()
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while worker != nil, !Task.isCancelled, clock.now < deadline {
            do { try await Task.sleep(for: .milliseconds(50)) }
            catch { break }
        }
        closed = true
        worker?.cancel()
        try await repository.completePendingTranslations(session.id,
            reason: "Translation did not finish before the session closed.")
    }

    private func drain() async {
        defer { worker = nil }
        while requested, !Task.isCancelled {
            requested = false
            do {
                while !Task.isCancelled, var segment = try await repository.pendingTranslations(session.id).first {
                    let request = segment
                    segment.translationStatus = .translating
                    await update(segment)
                    if let result = try await Self.process(request, session: session, repository: repository,
                                                           models: models, engine: engine) {
                        await update(result)
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                await issue(error.localizedDescription)
            }
        }
    }

    // The engine is captured when the finalized segment is stored. Legacy rows use their session's engine.
    public static func process(_ request: TranscriptSegment, session: CaptionSession, repository: CaptionRepository,
                               models: ModelStore, engine: any TranslationEngine) async throws -> TranscriptSegment? {
        try Task.checkCancellation()
        var result = request
        let model = request.translationModel ?? session.options.translationModel
        let target = session.options.targetLanguage.rawValue
        result.translationModel = model
        result.translationModelVersion = request.translationModelVersion ?? model.version
        do {
            guard let installation = model.installation(from: request.language, to: target) else {
                throw CaptionFailure("\(model.title) does not support this language pair.")
            }
            let folder = try await models.verifiedTranslationModel(installation)
            result.translation = try await engine.translate(request.original, using: model, source: request.language,
                                                            target: target, modelFolder: folder)
            result.translationStatus = .translated
            result.translationError = nil
        } catch {
            try Task.checkCancellation()
            result.translationStatus = .failed
            result.translation = nil
            result.translationError = "\(model.title) · \(error.localizedDescription)"
        }
        try Task.checkCancellation()
        guard try await repository.updateTranslation(result, matching: request) else { return nil }
        return result
    }
}
