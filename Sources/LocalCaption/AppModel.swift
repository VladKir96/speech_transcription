import AppKit
import AVFoundation
import CaptionCore
import Foundation
import Observation
import UniformTypeIdentifiers

enum Theme: String, Codable, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum LaunchView: String, Codable, CaseIterable, Identifiable {
    case live, history
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum SessionNaming: String, Codable, CaseIterable, Identifiable {
    case dated, custom
    var id: String { rawValue }
    var title: String { self == .dated ? "Date and time" : "Custom title" }
}

struct CaptionSettings: Codable {
    var options = SessionOptions()
    var appearance: Theme = .system
    var launchView: LaunchView = .live
    var titleMode: SessionNaming = .dated
    var sessionTitle = "Session"
    var autoSave = true
    var autoExport = false
    var exportFolder: URL?
    var exportFormat: ExportFormat = .txt
    var exportDisplay: CaptionDisplay = .both
    var showOriginal = true
    var showTranslation = true
    var overlay = false
    var overlaySources = Set(AudioSource.allCases)
    var overlayFontSize = 25.0
    var overlayOpacity = 0.85
    var overlayDisplay: CaptionDisplay = .both
    var overlayLines = 4
    var microphoneShortcut: MicrophoneShortcut?
    var diarization: DiarizationOptions?
    var exportSpeakerNames: Bool?
}

enum SignalStatus: Equatable {
    case ready, disabled, starting, capturing, paused, unavailable(String)
    var title: String {
        switch self {
        case .ready: "Ready"
        case .disabled: "Off"
        case .starting: "Connecting"
        case .capturing: "Capturing"
        case .paused: "Paused"
        case .unavailable: "Unavailable"
        }
    }
    var issue: String? {
        if case let .unavailable(reason) = self { reason } else { nil }
    }
}

struct TranscriptLane {
    var status = SignalStatus.ready
    var level = 0.0
    var latest: [TranscriptSegment] = []
    var partial: TranscriptSegment?
    var pendingPhrase: TranscriptSegment?
    var speakerDrafts: [TranscriptSegment] = []
    var issue: String?
    var total = 0
}

private struct CaptureFeed {
    let id: UUID
    let continuation: AsyncStream<AudioChunk>.Continuation
    let consumer: Task<Void, Never>
}

@MainActor
@Observable final class AppModel {
    static let defaultFolder: URL = {
        let identifier = Bundle.main.bundleIdentifier ?? "local.caption.macos"
        let folder = identifier == "local.caption.macos" ? "LocalCaption" : identifier
        return URL.applicationSupportDirectory.appendingPathComponent(folder, isDirectory: true)
    }()
    let dataFolder: URL
    var settings: CaptionSettings {
        didSet {
            if let data = try? JSONEncoder().encode(settings) {
                defaults?.set(data, forKey: "LocalCaption.settings.1")
            }
        }
    }
    private(set) var session: CaptionSession?
    private(set) var phase: SessionPhase = .idle
    private(set) var busy = false
    private(set) var elapsed = 0.0
    private(set) var lanes: [AudioSource: TranscriptLane] = [.system: TranscriptLane(), .microphone: TranscriptLane()]
    private(set) var devices: [InputDevice] = []
    private(set) var microphonePermission = AVAuthorizationStatus.notDetermined
    private(set) var microphoneRequested = false
    var microphoneShortcutIssue: String?
    private(set) var systemAudioAccess: SystemAudioAccess = .unchecked
    private(set) var hardware: String?
    private(set) var installed = Set<String>()
    private(set) var downloadProgress: [String: Double] = [:]
    private(set) var modelErrors: [String: String] = [:]
    private(set) var historyRevision = 0
    private(set) var repository: CaptionRepository?
    private(set) var modelStore: ModelStore?
    private(set) var unsaved: [TranscriptSegment] = []
    private(set) var diarizationRequested = false
    private(set) var diarizationStatus = DiarizationStatus.disabled
    private(set) var diarizationIssue: String?
    private var speakerNames: [UUID: String] = [:]
    var preferencesTab: PreferencesTab = .general
    var notice: String?
    var exportSuccess: String?

    @ObservationIgnored private var liveRepository: CaptionRepository?
    @ObservationIgnored private var translationQueue: TranslationQueue?
    @ObservationIgnored private let recognizer = WhisperRecognition()
    @ObservationIgnored private let translator = TranslationEngineManager()
    private var manualTranslation: Task<TranscriptSegment?, Never>?
    @ObservationIgnored private var clock: CaptureClock?
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let dependencies: SessionDependencies
    @ObservationIgnored private var preparation: Task<Void, Never>?
    @ObservationIgnored private var operationWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var feeds: [AudioSource: CaptureFeed] = [:]
    @ObservationIgnored private var heartbeat: Task<Void, Never>?
    @ObservationIgnored private var downloads: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var micRetryAt = 0.0
    @ObservationIgnored private var microphoneOperation: Task<Void, Never>?
    @ObservationIgnored private var microphoneEpoch = 0
    @ObservationIgnored private var microphoneRevision = 0
    @ObservationIgnored private var microphonePrompt = false
    @ObservationIgnored private var pushToTalkHeld = false
    private var ready = false
    private var terminating = false
    private var updateReserved = false
    private var preparingUpdateExit = false
    @ObservationIgnored private var initializing = false
    @ObservationIgnored private var pausedForStorage = false
    @ObservationIgnored private var diarization: DiarizationSession?
    @ObservationIgnored private var diarizationRevision = 0

    init(dataFolder: URL = AppModel.defaultFolder, defaults: UserDefaults? = .standard,
         dependencies: SessionDependencies = SessionDependencies()) {
        self.dataFolder = dataFolder
        self.defaults = defaults
        self.dependencies = dependencies
        let stored = defaults?.data(forKey: "LocalCaption.settings.1")
        settings = stored.flatMap { try? JSONDecoder().decode(CaptionSettings.self, from: $0) } ?? CaptionSettings()
        updateReadyLanes()
    }

    var sessionActive: Bool { [.preparing, .recording, .paused, .stopping].contains(phase) }
    var recording: Bool { phase == .recording }
    var canStart: Bool { !terminating && !updateReserved && !busy && !sessionActive && ready }
    var canOfferUpdate: Bool { !terminating && !busy && !sessionActive && unsaved.isEmpty }
    var canStop: Bool { phase == .preparing || (!busy && (phase == .recording || phase == .paused)) }
    var sessionTitle: String { session?.title ?? "New session" }
    var activeCount: Int { lanes.values.filter { $0.status == .capturing }.count }
    var modelCatalog: [ModelDescriptor] { modelStore?.catalog ?? [] }
    var translationRetryActive: Bool { manualTranslation != nil }
    var diarizationOptions: DiarizationOptions {
        get { settings.diarization ?? DiarizationOptions() }
        set { settings.diarization = newValue }
    }
    var speakerModelsInstalled: Bool { installed.contains("speaker-segmentation") && installed.contains("speaker-embedding") }

    func toggleDiarization() {
        if sessionActive {
            diarizationRequested.toggle()
            if diarizationRequested { startDiarization() }
            else { suspendDiarization() }
        } else {
            diarizationOptions.enabledByDefault.toggle()
        }
    }

    private func startDiarization() {
        guard diarizationRequested, recording, let session, session.options.sources.contains(.system) else { return }
        guard let feed = feeds[.system], let clock, let modelStore, let diarization else {
            diarizationStatus = .unavailable
            diarizationIssue = "Speaker Diarization requires an active System Audio source."
            return
        }
        diarizationRevision += 1
        let revision = diarizationRevision
        let sessionID = session.id
        let feedID = feed.id
        diarizationStatus = .loading
        diarizationIssue = nil
        diarization.begin(models: modelStore, settings: diarizationOptions, after: clock.elapsed) { [weak self] event in
            await self?.receiveDiarization(event, sessionID: sessionID, feedID: feedID, revision: revision)
        }
    }

    private func suspendDiarization() {
        diarizationRevision += 1
        diarization?.stop(at: clock?.elapsed ?? elapsed)
        diarizationStatus = .disabled
        diarizationIssue = nil
    }

    private func receiveDiarization(_ event: DiarizationEvent, sessionID: UUID, feedID: UUID, revision: Int) async {
        guard session?.id == sessionID, feeds[.system]?.id == feedID, diarizationRevision == revision else { return }
        switch event {
        case let .status(status, issue):
            diarizationStatus = status
            diarizationIssue = issue
            if status == .unavailable, speakerModelsInstalled { await refreshModels() }
        case .timelineUpdated:
            guard let diarization, let liveRepository else { return }
            if let draft = lanes[.system]?.partial { lanes[.system]?.partial = diarization.refresh(draft) }
            if let draft = lanes[.system]?.pendingPhrase { lanes[.system]?.pendingPhrase = diarization.refresh(draft) }
            let unknown = lanes[.system]?.latest.filter { $0.speakerStatus == .unknown && elapsed - $0.end <= 50 } ?? []
            var changed = false
            for segment in unknown {
                let updated = diarization.refresh(segment)
                guard let status = updated.speakerStatus, status != .unknown else { continue }
                do {
                    let saved = try await liveRepository.updateSpeaker(updated)
                    guard diarizationRevision == revision, session?.id == sessionID else { break }
                    if let index = unsaved.firstIndex(where: { $0.id == updated.id }) {
                        var caption = unsaved[index]
                        applySpeaker(updated, to: &caption)
                        unsaved[index] = caption
                    }
                    guard saved, let index = lanes[.system]?.latest.firstIndex(where: { $0.id == updated.id }),
                          var caption = lanes[.system]?.latest[index] else { continue }
                    applySpeaker(updated, to: &caption)
                    lanes[.system]?.latest[index] = caption
                    changed = true
                } catch {
                    CaptureDiagnostics.failure("Saving a speaker label", error)
                    diarizationIssue = "A speaker label could not be saved."
                    break
                }
            }
            if changed { historyRevision += 1 }
        }
    }

    private func applySpeaker(_ from: TranscriptSegment, to caption: inout TranscriptSegment) {
        caption.speakerID = from.speakerID
        caption.speakerName = from.speakerID.flatMap { speakerNames[$0] } ?? from.speakerName
        caption.speakerColor = from.speakerColor
        caption.speakerStatus = from.speakerStatus
        caption.speakerConfidence = from.speakerConfidence
    }

    func renameSpeaker(on segment: TranscriptSegment, to name: String) async {
        let store = session?.id == segment.sessionID ? liveRepository : repository
        guard let store, let id = segment.speakerID else { return }
        let normalized = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        do {
            try await store.renameSpeaker(id, session: segment.sessionID, name: normalized)
            if session?.id == segment.sessionID {
                speakerNames[id] = normalized
            }
            historyRevision += 1
        } catch {
            notice = error.localizedDescription
        }
    }

    func translationInstallation(_ model: TranslationModel) -> String? {
        let target = (sessionActive ? session?.options : nil)?.targetLanguage ?? settings.options.targetLanguage
        return model.installation(from: target == .en ? "ru" : "en", to: target.rawValue)
    }

    func initialize() async {
        guard !ready, !initializing else { return }
        initializing = true
        defer { initializing = false }
        do {
            let root = dataFolder
            modelStore = try ModelStore(directory: root.appendingPathComponent("Models", isDirectory: true))
            let store = try await Task.detached(priority: .utility) {
                let repository = try CaptionRepository(location: root.appendingPathComponent("Transcripts.sqlite3"), exclusive: true)
                try await repository.recoverInterruptedSessions()
                return repository
            }.value
            repository = store
            historyRevision += 1
        } catch {
            CaptureDiagnostics.failure("Initializing the transcript library", error)
            notice = error.localizedDescription
        }
        ready = true
        refreshDevicesAndPermissions()
        await refreshModels()
    }

    func refreshDevicesAndPermissions() {
        devices = dependencies.inputs()
        microphonePermission = dependencies.microphoneAuthorization()
    }

    func requestMicrophone() async {
        _ = await dependencies.requestMicrophone()
        refreshDevicesAndPermissions()
    }

    func toggleMicrophone() {
        let unavailable = lanes[.microphone]?.status.issue != nil
        setMicrophoneEnabled(!microphoneRequested || unavailable)
    }

    func beginPushToTalk() {
        guard recording, !pushToTalkHeld else { return }
        pushToTalkHeld = true
        setMicrophoneEnabled(true)
    }

    func endPushToTalk() {
        guard pushToTalkHeld else { return }
        pushToTalkHeld = false
        setMicrophoneEnabled(false)
    }

    @discardableResult
    func setMicrophoneEnabled(_ enabled: Bool) -> Task<Void, Never>? {
        guard recording, !terminating else { return nil }
        microphoneRequested = enabled
        microphonePrompt = enabled
        microphoneRevision += 1
        micRetryAt = 0
        if !enabled {
            dependencies.microphone.stop()
            lanes[.microphone]?.status = .disabled
            lanes[.microphone]?.issue = nil
            lanes[.microphone]?.level = 0
        }
        return scheduleMicrophoneUpdate()
    }

    func microphoneDeviceChanged() {
        guard recording, microphoneRequested else { return }
        microphoneRevision += 1
        micRetryAt = 0
        scheduleMicrophoneUpdate()
    }

    func refreshModels() async {
        if let modelStore {
            installed = await modelStore.installedIDs()
            if diarizationStatus == .unavailable && speakerModelsInstalled {
                startDiarization()
            }
        }
    }

    func install(_ model: ModelDescriptor, from folder: URL? = nil) {
        guard downloads[model.id] == nil, let modelStore else { return }
        modelErrors[model.id] = nil
        downloadProgress[model.id] = 0
        downloads[model.id] = Task { [weak self] in
            guard let self else { return }
            defer {
                downloads[model.id] = nil
                downloadProgress[model.id] = nil
            }
            do {
                let progress: @Sendable (Double) -> Void = { [weak self] progress in
                    Task { @MainActor in
                        guard let self, let previous = self.downloadProgress[model.id], self.downloads[model.id] != nil,
                              progress == 1 || progress - previous >= 0.01 else { return }
                        self.downloadProgress[model.id] = progress
                    }
                }
                if let folder { try await modelStore.importModel(model.id, from: folder, progress: progress) }
                else { try await modelStore.install(model, progress: progress) }
            } catch {
                if !Task.isCancelled { modelErrors[model.id] = error.localizedDescription }
            }
            await refreshModels()
        }
    }

    func cancelInstall(_ model: ModelDescriptor) { downloads[model.id]?.cancel() }

    func remove(_ model: ModelDescriptor) async {
        guard !busy, !sessionActive, !translationRetryActive, downloads[model.id] == nil, let modelStore else { return }
        busy = true
        defer { finishOperation() }
        await recognizer.release()
        await translator.release()
        do {
            try await modelStore.remove(model)
            modelErrors[model.id] = nil
            await refreshModels()
        } catch {
            modelErrors[model.id] = error.localizedDescription
        }
    }

    func updateReadyLanes() {
        guard !sessionActive else { return }
        for source in AudioSource.allCases {
            lanes[source]?.status = settings.options.sources.contains(source) ? .ready : .disabled
        }
    }

    func start() async {
        CaptureDiagnostics.session.info("Start Session requested; state=\(self.phase.rawValue, privacy: .public) busy=\(self.busy)")
        guard canStart else { return }
        guard unsaved.isEmpty else {
            notice = "Retry saving the previous session or export its remaining transcript before starting another."
            return
        }
        let previousPhase = phase
        guard transition(.preparing) else { return }
        busy = true
        let task = Task { await prepareSession(previousPhase: previousPhase) }
        preparation = task
        await task.value
    }

    func cancelPreparation() { preparation?.cancel() }

    private func prepareSession(previousPhase: SessionPhase) async {
        defer {
            preparation = nil
            finishOperation()
        }
        notice = nil
        exportSuccess = nil
        var created = false
        var warnings: [String] = []
        do {
            try Task.checkCancellation()
            guard let modelStore else { throw CaptionFailure("The model catalog could not be loaded.") }
            let preferences = settings
            let options = preferences.options
            guard !options.sources.isEmpty else { throw CaptionFailure("Enable at least one audio source in Settings → Audio.") }
            CaptureDiagnostics.session.info("Configuration ready; system=\(options.sources.contains(.system)) microphone=\(options.sources.contains(.microphone)) VAD=\(options.enableVAD) translation=\(options.translate)")

            let store: CaptionRepository
            if preferences.autoSave {
                guard let repository else { throw CaptionFailure("The transcript database is unavailable. Check the data folder.") }
                store = repository
            } else {
                store = try CaptionRepository(location: nil)
            }
            CaptureDiagnostics.session.info("Verifying speech model; model=\(options.model.id, privacy: .public)")
            let speech = try await dependencies.prepareRecognition(modelStore, options, recognizer)
            try Task.checkCancellation()
            hardware = speech.metal ? "Metal" : "CPU"
            if options.useMetal && !speech.metal { warnings.append("Metal is unavailable. Whisper is running on the CPU.") }
            if let compatibilityNotice = speech.compatibilityNotice { warnings.append(compatibilityNotice) }

            let defaultName = "Session · \(Date.now.formatted(date: .abbreviated, time: .shortened))"
            let custom = preferences.sessionTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = preferences.titleMode == .custom && !custom.isEmpty ? custom : defaultName
            let candidate = CaptionSession(title: title, options: options)
            let newClock = CaptureClock()
            CaptureDiagnostics.session.info("Creating the transcript session; diskStorage=\(preferences.autoSave)")
            try await store.create(candidate)
            created = true
            clock = newClock
            session = candidate
            diarization = options.sources.contains(.system) ? DiarizationSession() : nil
            diarizationRequested = diarizationOptions.enabledByDefault
            speakerNames = [:]
            liveRepository = store
            elapsed = 0
            micRetryAt = 0
            microphoneRequested = options.sources.contains(.microphone)
                && preferences.microphoneShortcut?.mode != .pushToTalk
            pausedForStorage = false
            for source in AudioSource.allCases {
                let requested = source == .microphone ? microphoneRequested : options.sources.contains(source)
                lanes[source] = TranscriptLane(status: requested ? .starting : .disabled)
            }
            try Task.checkCancellation()
            if options.translate {
                let target = options.targetLanguage.rawValue
                let source = options.sourceLanguage == .auto ? (target == "en" ? "ru" : "en") : options.sourceLanguage.rawValue
                if let model = options.translationModel.installation(from: source, to: target),
                   await modelStore.path(model) == nil {
                    CaptureDiagnostics.session.warning("Optional translation model unavailable; model=\(model, privacy: .public)")
                    warnings.append("Install the selected translation model in Settings → Models. Transcription can continue.")
                }
                translationQueue = TranslationQueue(repository: store, session: candidate, models: modelStore,
                    engine: translator, update: { [weak self] segment in await self?.applyTranslation(segment) },
                    issue: { [weak self] message in await self?.reportTranslation(message, session: candidate.id) })
                CaptureDiagnostics.session.debug("Translation queue ready; model loading is deferred")
            }
            await connectSources(candidate, clock: newClock)
            try Task.checkCancellation()
            guard canRecord(current: candidate) else {
                throw CaptionFailure("Could not start the enabled sources. Check the source messages below.")
            }
            try await writeState(status: .recording)
            await discardFailedSystem()
            try Task.checkCancellation()
            guard canRecord(current: candidate) else { throw CaptionFailure("The enabled audio sources disconnected during startup.") }
            _ = transition(.recording)
            startDiarization()
            if !warnings.isEmpty { notice = warnings.joined(separator: " ") }
            startHeartbeat()
        } catch {
            let cancelled = error is CancellationError || Task.isCancelled
            if cancelled { CaptureDiagnostics.session.info("Session preparation cancelled") }
            else { CaptureDiagnostics.failure("Starting the session", error) }
            if created {
                elapsed = clock?.elapsed ?? elapsed
                await stopFeeds()
                _ = transition(cancelled ? .interrupted : .error)
                await closeSession()
            } else {
                _ = transition(cancelled ? previousPhase : .error)
            }
            await recognizer.release()
            hardware = nil
            if !cancelled { notice = error.localizedDescription }
        }
    }

    func pause() async {
        guard !terminating, !busy, phase == .recording, transition(.paused) else { return }
        busy = true
        defer { finishOperation() }
        heartbeat?.cancel()
        heartbeat = nil
        elapsed = clock?.elapsed ?? elapsed
        await stopFeeds()
        for source in AudioSource.allCases where lanes[source]?.status == .capturing {
            lanes[source]?.status = .paused
        }
        await persistState()
    }

    func resume() async {
        guard !terminating, !busy, phase == .paused, let session, let clock, transition(.preparing) else { return }
        busy = true
        let task = Task { await prepareResume(session: session, clock: clock) }
        preparation = task
        await task.value
    }

    private func prepareResume(session: CaptionSession, clock: CaptureClock) async {
        defer {
            preparation = nil
            finishOperation()
        }
        await retrySaving()
        guard unsaved.isEmpty, !Task.isCancelled else {
            _ = transition(.paused)
            return
        }
        micRetryAt = 0
        await connectSources(session, clock: clock)
        do {
            try Task.checkCancellation()
            guard canRecord(current: session) else { throw CaptionFailure("No audio source could resume. Check the source messages below.") }
            try await writeState(status: .recording)
            await discardFailedSystem()
            try Task.checkCancellation()
            guard canRecord(current: session) else { throw CaptionFailure("The enabled audio sources disconnected while resuming.") }
            _ = transition(.recording)
            startDiarization()
            startHeartbeat()
        } catch {
            await stopFeeds()
            for source in AudioSource.allCases where lanes[source]?.status == .capturing {
                lanes[source]?.status = .paused
            }
            _ = transition(.paused)
            await persistState()
            if !Task.isCancelled {
                CaptureDiagnostics.failure("Resuming the session", error)
                notice = error.localizedDescription
            }
        }
    }

    func stop() async {
        if phase == .preparing, let preparation {
            preparation.cancel()
            await preparation.value
        }
        guard !busy, phase == .recording || phase == .paused, transition(.stopping) else { return }
        busy = true
        defer { finishOperation() }
        heartbeat?.cancel()
        heartbeat = nil
        elapsed = clock?.elapsed ?? elapsed
        await stopFeeds()
        await retrySaving()
        _ = transition(unsaved.isEmpty ? .completed : .error)
        await closeSession()
        if settings.autoExport, let folder = settings.exportFolder, let session {
            let timestamp = session.startedAt.formatted(.iso8601).replacingOccurrences(of: ":", with: "-")
            let url = folder.appendingPathComponent("LocalCaption-\(timestamp)-\(session.id.uuidString.prefix(8)).\(settings.exportFormat.rawValue)")
            await export(session, from: liveRepository, to: url, format: settings.exportFormat, display: settings.exportDisplay,
                         includeSpeakerNames: settings.exportSpeakerNames ?? true)
        }
    }

    private func closeSession() async {
        do {
            try await translationQueue?.finish()
        } catch {
            CaptureDiagnostics.failure("Finishing queued translations", error)
            notice = error.localizedDescription
        }
        translationQueue = nil
        if let session, let store = liveRepository {
            for source in AudioSource.allCases {
                do {
                    let latest = try await store.segments(session.id, source: source, limit: 240, newestFirst: true)
                    let recovered = unsaved.filter { $0.source == source }
                    lanes[source]?.latest = Array((latest + recovered).sorted(by: Self.newestCaptionFirst).prefix(240))
                } catch {
                    CaptureDiagnostics.failure("Reloading finalized captions", error)
                }
                lanes[source]?.partial = nil
                lanes[source]?.pendingPhrase = nil
                lanes[source]?.speakerDrafts = []
                lanes[source]?.level = 0
                if lanes[source]?.status.issue == nil {
                    lanes[source]?.status = session.options.sources.contains(source) ? .ready : .disabled
                }
            }
        }
        if var current = session {
            current.endedAt = current.startedAt.addingTimeInterval(elapsed)
            session = current
        }
        await persistState()
        diarization = nil
        diarizationRequested = false
        historyRevision += 1
        Task { await translator.release() }
    }

    private func transition(_ next: SessionPhase) -> Bool {
        guard phase.allows(next) else {
            CaptureDiagnostics.session.error("Rejected state change \(self.phase.rawValue, privacy: .public) → \(next.rawValue, privacy: .public)")
            return false
        }
        CaptureDiagnostics.session.info("State \(self.phase.rawValue, privacy: .public) → \(next.rawValue, privacy: .public)")
        phase = next
        return true
    }

    private func finishOperation() {
        busy = false
        let waiters = operationWaiters
        operationWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func waitForOperation() async {
        while busy {
            await withCheckedContinuation { operationWaiters.append($0) }
        }
    }

    private func voiceActivityModels(_ options: SessionOptions) async -> [URL] {
        guard options.enableVAD, let modelStore else { return [] }
        let legacy = ProcessInfo.processInfo.environment["LOCALCAPTION_VAD_VERSION"] == "6.2"
        return await modelStore.voiceActivityModels(preferLegacy: legacy)
    }

    private func connectSources(_ current: CaptionSession, clock: CaptureClock) async {
        let vadModels = await voiceActivityModels(current.options)
        CaptureDiagnostics.session.info("Preparing capture; verified Silero models=\(vadModels.count)")
        guard !Task.isCancelled else { return }
        async let systemStarted: Void = connectSystem(current, clock: clock, vadModels: vadModels)
        async let microphoneStarted: Void = connectMicrophone(current, clock: clock, vadModels: vadModels, request: true)
        _ = await (systemStarted, microphoneStarted)
        refreshDevicesAndPermissions()
    }

    private func canRecord(current: CaptionSession) -> Bool {
        activeCount > 0 || (!microphoneRequested && current.options.sources.contains(.microphone))
    }

    private func connectSystem(_ current: CaptionSession, clock: CaptureClock, vadModels: [URL]) async {
        let source = AudioSource.system
        guard current.options.sources.contains(source), feeds[source] == nil, !Task.isCancelled else { return }
        CaptureDiagnostics.session.info("Preparing System Audio pipeline")
        systemAudioAccess = .unchecked
        lanes[source]?.status = .starting
        let feed = makeFeed(source, session: current, vadModels: vadModels)
        do {
            try await dependencies.system.start(selection: current.options.systemAudioSelection ?? .automatic,
                clock: clock, chunks: feed.continuation,
                issue: { [weak self] message in
                    Task { @MainActor in self?.captureIssue(message, source: source, id: feed.id) }
                },
                failure: { [weak self] error in
                    Task { @MainActor in await self?.systemStopped(error, id: feed.id) }
                })
            if feeds[source]?.id == feed.id, lanes[source]?.status == .starting {
                lanes[source]?.status = .capturing
                systemAudioAccess = .verified
            } else {
                await dependencies.system.stop()
                await finishFeed(source)
            }
        } catch {
            CaptureDiagnostics.failure("Starting System Audio", error)
            if (error as? SystemAudioCaptureFailure)?.kind == .authorization { systemAudioAccess = .declined }
            await dependencies.system.stop()
            await finishFeed(source, id: feed.id)
            lanes[source]?.status = .unavailable(error.localizedDescription)
        }
    }

    private func connectMicrophone(_ current: CaptionSession, clock: CaptureClock,
                                   vadModels: [URL], request: Bool) async {
        let source = AudioSource.microphone
        guard microphoneRequested, feeds[source] == nil, !Task.isCancelled else { return }
        let revision = microphoneRevision
        lanes[source]?.status = .starting
        CaptureDiagnostics.session.info("Checking microphone authorization; status=\(self.dependencies.microphoneAuthorization().rawValue)")
        if request, dependencies.microphoneAuthorization() == .notDetermined {
            _ = await dependencies.requestMicrophone()
        }
        guard !Task.isCancelled, microphoneRequested, revision == microphoneRevision,
              session?.id == current.id else { return }
        guard dependencies.microphoneAuthorization() == .authorized else {
            CaptureDiagnostics.session.warning("Microphone permission is unavailable")
            lanes[source]?.status = .unavailable("Allow LocalCaption in System Settings → Privacy & Security → Microphone.")
            return
        }
        guard let selected = dependencies.input(settings.options.microphoneUID) else {
            CaptureDiagnostics.session.warning("The selected microphone is unavailable")
            lanes[source]?.status = .unavailable("The selected microphone is disconnected. Reconnect it or choose an available input in Settings.")
            return
        }

        let feed = makeFeed(source, session: current, vadModels: vadModels)
        do {
            try dependencies.microphone.start(device: selected, clock: clock, chunks: feed.continuation) { [weak self] message in
                Task { @MainActor in self?.captureIssue(message, source: source, id: feed.id) }
            }
            lanes[source]?.status = .capturing
        } catch {
            CaptureDiagnostics.failure("Starting the microphone", error)
            dependencies.microphone.stop()
            await finishFeed(source, id: feed.id)
            if revision == microphoneRevision, !Task.isCancelled {
                lanes[source]?.status = .unavailable(error.localizedDescription)
            }
        }
    }

    private func makeFeed(_ source: AudioSource, session: CaptionSession, vadModels: [URL]) -> CaptureFeed {
        lanes[source]?.issue = nil
        CaptureDiagnostics.session.debug("Preparing transcription pipeline; source=\(source.rawValue, privacy: .public)")
        let pair = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .bufferingNewest(96))
        let pipeline = StreamingTranscription(source: source, sessionID: session.id, options: session.options,
            engine: recognizer, vadURL: vadModels.first, fallbackVADURL: vadModels.dropFirst().first,
            diarization: source == .system ? diarization : nil) { [weak self] event in
                await self?.receive(event, sessionID: session.id)
            }
        let feed = CaptureFeed(id: UUID(), continuation: pair.continuation,
                               consumer: Task { await pipeline.consume(pair.stream) })
        feeds[source] = feed
        return feed
    }

    private func finishFeed(_ source: AudioSource, id: UUID? = nil) async {
        guard let feed = feeds[source], id == nil || id == feed.id else { return }
        feed.continuation.finish()
        await feed.consumer.value
        if feeds[source]?.id == feed.id {
            feeds[source] = nil
            lanes[source]?.level = 0
        }
    }

    private func stopFeeds() async {
        suspendDiarization()
        microphoneEpoch += 1
        microphoneRevision += 1
        microphoneOperation?.cancel()
        microphoneOperation = nil
        microphonePrompt = false
        if pushToTalkHeld {
            pushToTalkHeld = false
            microphoneRequested = false
            lanes[.microphone]?.status = .disabled
        }
        dependencies.microphone.stop()
        async let stopped: Void = dependencies.system.stop()
        async let micDrained: Void = finishFeed(.microphone)
        await stopped
        await finishFeed(.system)
        await micDrained
        await diarization?.waitForShutdown()
    }

    private func discardFailedSystem() async {
        guard lanes[.system]?.status.issue != nil, let feed = feeds[.system] else { return }
        await dependencies.system.stop()
        await finishFeed(.system, id: feed.id)
    }

    private func systemStopped(_ error: SystemAudioCaptureFailure, id: UUID) async {
        guard feeds[.system]?.id == id, phase == .preparing || phase == .recording else { return }
        CaptureDiagnostics.session.warning("System Audio stopped unexpectedly")
        if error.kind == .authorization { systemAudioAccess = .declined }
        lanes[.system]?.status = .unavailable(error.localizedDescription)
        // During startup the owner of startCapture handles the same stream after it returns.
        guard phase == .recording else { return }
        suspendDiarization()
        await dependencies.system.stop()
        await finishFeed(.system, id: id)
        await waitForOperation()
        if phase == .recording, activeCount == 0, feeds[.system] == nil { await pause() }
    }

    private func captureIssue(_ message: String, source: AudioSource, id: UUID) {
        guard feeds[source]?.id == id else { return }
        lanes[source]?.issue = message
    }

    private static func newestCaptionFirst(_ lhs: TranscriptSegment, _ rhs: TranscriptSegment) -> Bool {
        (lhs.start, lhs.end, lhs.id.uuidString) > (rhs.start, rhs.end, rhs.id.uuidString)
    }

    private func receive(_ event: StreamEvent, sessionID: UUID) async {
        guard session?.id == sessionID else { return }
        switch event {
        case let .activity(source, level):
            lanes[source]?.level = level
        case let .issue(source, message):
            lanes[source]?.issue = message
        case let .partial(source, segment):
            lanes[source]?.partial = segment
        case let .pendingPhrase(source, segment):
            lanes[source]?.pendingPhrase = segment
        case let .speakerDrafts(source, segments):
            lanes[source]?.speakerDrafts = segments
        case let .finalized(source, phraseID, captured):
            if lanes[source]?.partial?.id == phraseID { lanes[source]?.partial = nil }
            if lanes[source]?.pendingPhrase?.id == phraseID { lanes[source]?.pendingPhrase = nil }
            guard !captured.isEmpty else { return }
            let engine = settings.options.translationModel
            let segments = captured.map { item in
                var finalized = item.speakerStatus == .unknown && source == .system
                    ? diarization?.refresh(item) ?? item : item
                if finalized.translationStatus == .pending {
                    finalized.translationModel = engine
                    finalized.translationModelVersion = engine.version
                }
                return finalized
            }
            lanes[source]?.latest.insert(contentsOf: segments.sorted(by: Self.newestCaptionFirst), at: 0)
            if let count = lanes[source]?.latest.count, count > 240 {
                lanes[source]?.latest.removeLast(count - 240)
            }
            lanes[source]?.total += segments.count
            do {
                guard let liveRepository else { throw CaptionFailure("The current session database is unavailable.") }
                let saved = try await liveRepository.insert(segments)
                for result in saved where result.translationStatus == .failed { applyTranslation(result) }
                if saved.contains(where: { $0.translationStatus == .pending }) {
                    await translationQueue?.kick()
                }
            } catch {
                unsaved.append(contentsOf: segments)
                notice = "\(error.localizedDescription) Recent text is held in memory. Use Retry Save or export it."
                if !pausedForStorage {
                    pausedForStorage = true
                    Task { await self.pauseAfterStorageError(sessionID: sessionID) }
                }
            }
        }
    }

    private func pauseAfterStorageError(sessionID: UUID) async {
        await waitForOperation()
        if session?.id == sessionID { await pause() }
    }

    func retrySaving() async {
        guard !unsaved.isEmpty, let liveRepository else { return }
        let batch = unsaved
        do {
            let saved = try await liveRepository.insert(batch)
            for result in saved where result.translationStatus == .failed { applyTranslation(result) }
            let ids = Set(batch.map(\.id))
            unsaved.removeAll { ids.contains($0.id) }
            pausedForStorage = false
            if let session, !sessionActive {
                try await liveRepository.completePendingTranslations(session.id, reason: "Translation was pending when transcript storage failed.")
            } else {
                await translationQueue?.kick()
            }
            if unsaved.isEmpty { notice = nil }
        } catch {
            notice = error.localizedDescription
        }
    }

    private func applyTranslation(_ segment: TranscriptSegment) {
        guard session?.id == segment.sessionID,
              let index = lanes[segment.source]?.latest.firstIndex(where: { $0.id == segment.id }) else { return }
        lanes[segment.source]?.latest[index].translation = segment.translation
        lanes[segment.source]?.latest[index].translationStatus = segment.translationStatus
        lanes[segment.source]?.latest[index].translationError = segment.translationError
        lanes[segment.source]?.latest[index].translationModel = segment.translationModel
        lanes[segment.source]?.latest[index].translationModelVersion = segment.translationModelVersion
    }

    func currentTranslation(for segment: TranscriptSegment) -> TranscriptSegment {
        guard session?.id == segment.sessionID else { return segment }
        var caption = lanes[segment.source]?.latest.first { $0.id == segment.id } ?? segment
        if let speaker = caption.speakerID, let name = speakerNames[speaker] { caption.speakerName = name }
        return caption
    }

    func canUseTranslation(_ engine: TranslationModel, for segment: TranscriptSegment) -> Bool {
        // A failed translation has an identifiable source, and the app exposes two target languages.
        let target = segment.language == "en" ? "ru" : "en"
        guard let id = engine.installation(from: segment.language, to: target) else { return false }
        return installed.contains(id)
    }

    func retryTranslation(_ segment: TranscriptSegment, using engine: TranslationModel) async -> TranscriptSegment? {
        guard manualTranslation == nil, !busy, !terminating, let modelStore else { return nil }
        let store = session?.id == segment.sessionID ? liveRepository : repository
        guard let store else { return nil }
        let task = Task {
            await performTranslationRetry(segment, using: engine, repository: store, models: modelStore)
        }
        manualTranslation = task
        defer { manualTranslation = nil }
        return await task.value
    }

    private func performTranslationRetry(_ segment: TranscriptSegment, using engine: TranslationModel,
                                         repository: CaptionRepository, models: ModelStore) async -> TranscriptSegment? {
        do {
            guard let storedSession = try await repository.session(segment.sessionID),
                  engine.installation(from: segment.language, to: storedSession.options.targetLanguage.rawValue) != nil,
                  let request = try await repository.retryTranslation(segment.id, session: segment.sessionID, model: engine)
            else { return nil }
            applyTranslation(request)
            if let translationQueue, session?.id == request.sessionID, sessionActive {
                await translationQueue.kick()
                return request
            }
            var result = request
            do {
                guard let translated = try await TranslationQueue.process(request, session: storedSession,
                    repository: repository, models: models, engine: translator) else { return nil }
                result = translated
            } catch is CancellationError {
                result.translationStatus = .failed
                result.translationError = "Translation retry was canceled."
                guard try await repository.updateTranslation(result, matching: request) else { return nil }
            }
            applyTranslation(result)
            return result
        } catch {
            notice = error.localizedDescription
            return nil
        }
    }

    private func reportTranslation(_ message: String, session id: UUID) {
        guard session?.id == id else { return }
        notice = message
    }

    private func writeState(status: SessionPhase? = nil) async throws {
        guard var current = session, let liveRepository else { return }
        current.status = status ?? phase
        current.duration = elapsed
        session = current
        try await liveRepository.update(current)
    }

    private func persistState() async {
        do { try await writeState() }
        catch {
            CaptureDiagnostics.failure("Updating session state in SQLite", error)
            notice = error.localizedDescription
        }
    }

    private func startHeartbeat() {
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) }
                catch { return }
                guard let self, self.phase == .recording, let clock = self.clock else { return }
                self.elapsed = clock.elapsed
                tick += 1
                if tick.isMultiple(of: 4) { await self.checkMicrophone(clock: clock) }
                if tick.isMultiple(of: 60), self.phase == .recording { await self.persistState() }
            }
        }
    }

    func checkMicrophone(clock: CaptureClock) async {
        guard !busy, recording, microphoneRequested, let session else { return }
        await scheduleMicrophoneUpdate(current: session, clock: clock)?.value
    }

    @discardableResult
    private func scheduleMicrophoneUpdate(current: CaptionSession? = nil, clock: CaptureClock? = nil) -> Task<Void, Never>? {
        if let microphoneOperation { return microphoneOperation }
        guard let current = current ?? session, let clock = clock ?? self.clock else { return nil }
        let epoch = microphoneEpoch
        let task = Task {
            defer { if epoch == microphoneEpoch { microphoneOperation = nil } }
            var revision: Int
            repeat {
                revision = microphoneRevision
                await reconcileMicrophone(current, clock: clock, revision: revision)
            } while !Task.isCancelled && revision != microphoneRevision
        }
        microphoneOperation = task
        return task
    }

    private func reconcileMicrophone(_ current: CaptionSession, clock: CaptureClock, revision: Int) async {
        guard recording, session?.id == current.id, !Task.isCancelled else { return }
        let selected = dependencies.input(settings.options.microphoneUID)
        let old = dependencies.microphone.device
        if !microphoneRequested || old != selected || old == nil {
            dependencies.microphone.stop()
            await finishFeed(.microphone)
        }
        guard recording, microphoneRequested, revision == microphoneRevision, !Task.isCancelled else { return }
        if old != nil, old != selected {
            lanes[.microphone]?.status = .unavailable("Microphone disconnected or the default input changed.")
        }
        let prompt = microphonePrompt
        microphonePrompt = false
        guard dependencies.microphone.device == nil,
              prompt || (selected != nil && clock.elapsed >= micRetryAt && dependencies.microphoneAuthorization() == .authorized) else { return }
        micRetryAt = clock.elapsed + 5
        let vadModels = await voiceActivityModels(current.options)
        if !Task.isCancelled, revision == microphoneRevision, recording {
            await connectMicrophone(current, clock: clock, vadModels: vadModels, request: prompt)
            refreshDevicesAndPermissions()
        }
    }

    func older(_ source: AudioSource, before: TranscriptSegment) async throws -> [TranscriptSegment] {
        guard let session, let liveRepository else { return [] }
        return try await liveRepository.segments(session.id, source: source, limit: 160,
                                                 newestFirst: true, before: before)
    }

    func exportCurrent(format: ExportFormat, display: CaptionDisplay, includeSpeakerNames: Bool = true) async {
        guard let session else { return }
        await presentExport(session, from: liveRepository, format: format, display: display,
                            includeSpeakerNames: includeSpeakerNames)
    }

    func exportHistory(_ session: CaptionSession, format: ExportFormat, display: CaptionDisplay,
                       includeSpeakerNames: Bool = true) async {
        await presentExport(session, from: repository, format: format, display: display, includeSpeakerNames: includeSpeakerNames)
    }

    func chooseExportFolder() async {
        let dialog = NSOpenPanel()
        dialog.canChooseDirectories = true
        dialog.canChooseFiles = false
        dialog.canCreateDirectories = true
        dialog.prompt = "Choose"
        if await dialog.begin() == .OK { settings.exportFolder = dialog.url }
    }

    private func presentExport(_ session: CaptionSession, from repository: CaptionRepository?,
                               format: ExportFormat, display: CaptionDisplay, includeSpeakerNames: Bool) async {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [UTType(filenameExtension: format.rawValue) ?? .plainText]
        let safe = session.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = safe + "." + format.rawValue
        guard await panel.begin() == .OK, let url = panel.url else { return }
        await export(session, from: repository, to: url, format: format, display: display, includeSpeakerNames: includeSpeakerNames)
    }

    private func export(_ session: CaptionSession, from repository: CaptionRepository?, to url: URL,
                        format: ExportFormat, display: CaptionDisplay, includeSpeakerNames: Bool) async {
        do {
            guard let repository else { throw CaptionFailure("There is no database available to export from.") }
            let recovered = unsaved.filter { $0.sessionID == session.id }.map(currentTranslation(for:))
            let stored: [TranscriptSegment]
            do {
                stored = try await repository.segments(session.id)
            } catch {
                guard !recovered.isEmpty else { throw error }
                let filename = url.deletingPathExtension().appendingPathExtension("recovery.\(format.rawValue)")
                try await TranscriptExport.write(session, segments: recovered, format: format, display: display,
                                                 includeSpeakerNames: includeSpeakerNames, to: filename)
                throw CaptionFailure("The database could not be read. Unsaved transcript was exported to \(filename.lastPathComponent).")
            }
            let ids = Set(stored.map(\.id))
            try await TranscriptExport.write(session, segments: stored + recovered.filter { !ids.contains($0.id) },
                                             format: format, display: display, includeSpeakerNames: includeSpeakerNames, to: url)
            exportSuccess = "Exported \(url.lastPathComponent)"
        } catch {
            notice = "Export failed. \(error.localizedDescription)"
        }
    }

    func reflectRename(_ id: UUID, title: String) {
        if session?.id == id { session?.title = title }
    }

    func reflectDelete(_ id: UUID) {
        guard session?.id == id, !sessionActive else { return }
        session = nil
        liveRepository = nil
        elapsed = 0
        for source in AudioSource.allCases { lanes[source] = TranscriptLane() }
        updateReadyLanes()
    }

    func deleteSavedHistory() async throws {
        guard let repository, !busy, sessionActive || unsaved.isEmpty else { return }
        let protected = sessionActive ? session?.id : nil
        let displayed = liveRepository === repository ? session?.id : nil
        busy = true
        defer { finishOperation() }
        try await repository.deleteHistory(keeping: protected)
        if let displayed, displayed != protected { reflectDelete(displayed) }
        historyRevision += 1
    }

    func openDataFolder() {
        do {
            try FileManager.default.createDirectory(at: dataFolder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(dataFolder)
        } catch {
            notice = error.localizedDescription
        }
    }

    func reserveUpdate() -> Bool {
        if updateReserved && !sessionActive && unsaved.isEmpty { return true }
        guard canOfferUpdate else { return false }
        updateReserved = true
        return true
    }

    func prepareForUpdate() async -> Bool {
        guard updateReserved, !sessionActive, unsaved.isEmpty else { return false }
        preparingUpdateExit = true
        return await canTerminate()
    }

    func endUpdate() {
        updateReserved = false
        if preparingUpdateExit {
            preparingUpdateExit = false
            terminating = false
        }
    }

    func canTerminate() async -> Bool {
        terminating = true
        manualTranslation?.cancel()
        _ = await manualTranslation?.value
        cancelPreparation()
        await waitForOperation()
        if sessionActive { await stop() }
        await retrySaving()
        guard unsaved.isEmpty else {
            terminating = false
            return false
        }

        // ggml's process-exit cleanup expects all Metal inference contexts to be freed.
        CaptureDiagnostics.session.info("Releasing inference contexts before application termination")
        await recognizer.release()
        await translator.release()
        CaptureDiagnostics.session.info("Inference contexts released; application can terminate")
        return true
    }
}
