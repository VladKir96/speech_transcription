import AudioToolbox
import AVFoundation
import CaptionCore
import Foundation
import ScreenCaptureKit
import Testing
@testable import LocalCaption

@Test func halCallbackRunsOnAForeignQueueWithoutMainActorIsolation() async {
    let status = await withCheckedContinuation { continuation in
        DispatchQueue(label: "test.hal-io").async {
            var flags = AudioUnitRenderActionFlags()
            var timestamp = AudioTimeStamp()
            var unusedContext: UInt8 = 0
            let result = withUnsafeMutablePointer(to: &unusedContext) { pointer in
                microphoneRenderProc(UnsafeMutableRawPointer(pointer), &flags, &timestamp, 1, 0, nil)
            }
            continuation.resume(returning: result)
        }
    }
    #expect(status == noErr)
}

@Test func probeDistinguishesMissingBuffersSilenceAndAudioEnergy() {
    let measurement = AudioProbeMeasurements()
    #expect(measurement.snapshot().buffers == 0)

    measurement.received(frames: 12)
    measurement.normalized([0, 0, 0, 0])
    let silence = measurement.snapshot()
    #expect(silence.buffers == 1)
    #expect(silence.nativeFrames == 12)
    #expect(silence.normalizedFrames == 4)
    #expect(silence.rms == 0)

    measurement.received(frames: 6)
    measurement.normalized([0.5, -0.25])
    let playback = measurement.snapshot()
    #expect(playback.buffers == 2)
    #expect(playback.nativeFrames == 18)
    #expect(playback.normalizedFrames == 6)
    #expect(playback.peak == 0.5)
    #expect(abs(playback.rms - sqrt(0.3125 / 6)) < 0.000001)
}

@Test func microphoneShortcutAndPhrasePauseRoundTripWhileOldSettingsLoad() throws {
    let original = CaptionSettings()
    let legacy = try JSONDecoder().decode(CaptionSettings.self, from: JSONEncoder().encode(original))
    #expect(legacy.microphoneShortcut == nil)
    #expect(legacy.options.effectivePhrasePause == 1.8)

    var set = original
    set.microphoneShortcut = MicrophoneShortcut(mode: .pushToTalk, key: .m, modifiers: .controlOption)
    set.options.translationStrategy = .contextAware
    set.options.phraseCompletionPause = 3.1
    let decoded = try JSONDecoder().decode(CaptionSettings.self, from: JSONEncoder().encode(set))
    #expect(decoded.microphoneShortcut == set.microphoneShortcut)
    #expect(decoded.options.translationStrategy == .contextAware)
    #expect(decoded.options.effectivePhrasePause == 3.1)
}

@Test @MainActor func selectedTranslationEngineIsRestoredFromPreferences() throws {
    let domain = "local.caption.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: domain))
    defer { defaults.removePersistentDomain(forName: domain) }
    let initial = AppModel(defaults: defaults)
    #expect(initial.settings.options.translationModel == .marian)
    initial.settings.options.translationModel = .nllb
    let reopenedDefaults = try #require(UserDefaults(suiteName: domain))
    let reopened = AppModel(defaults: reopenedDefaults)
    #expect(reopened.settings.options.translationModel == .nllb)
}

@Test @MainActor func whisperSelectionRestoresTheArchitectureFromExistingPreferences() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let domain = "local.caption.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: domain))
    defer { defaults.removePersistentDomain(forName: domain) }
    let initial = AppModel(dataFolder: folder, defaults: defaults)
    initial.settings.options.model = .turbo
    let reopened = AppModel(dataFolder: folder, defaults: try #require(UserDefaults(suiteName: domain)))
    #expect(reopened.settings.options.model == .turbo)
    #expect(reopened.settings.options.model.id == "turbo")
    #expect(reopened.settings.options.model.q8ID == "turbo-q8")
}

@Suite @MainActor
struct SessionStartupTests {
    @Test(arguments: [Set([AudioSource.microphone]), [.system], Set(AudioSource.allCases)])
    func startStopPauseResumeAndTenRestarts(_ sources: Set<AudioSource>) async throws {
        let rig = try await Rig(sources: sources)
        await rig.model.start()
        #expect(rig.model.phase == .recording)
        #expect(rig.system.running == sources.contains(.system))
        #expect((rig.microphone.device != nil) == sources.contains(.microphone))
        await rig.model.pause()
        #expect(rig.model.phase == .paused)
        rig.expectStopped()
        await rig.model.resume()
        #expect(rig.model.phase == .recording)
        await rig.model.stop()
        #expect(rig.model.phase == .completed)
        for _ in 0..<10 {
            await rig.model.start()
            #expect(rig.model.phase == .recording)
            await rig.model.stop()
            rig.expectStopped()
        }
        #expect(rig.system.starts == (sources.contains(.system) ? 12 : 0))
        #expect(rig.microphone.starts == (sources.contains(.microphone) ? 12 : 0))
    }

    @Test func bothSourcesDisabledIsRecoverable() async throws {
        let rig = try await Rig(sources: [])
        await rig.model.start()
        #expect(rig.model.phase == .error)
        #expect(rig.model.notice?.contains("Enable at least one") == true)
        #expect(rig.model.canStart)
        rig.expectStopped()
    }

    @Test func permissionDeniedCanRetryAfterAuthorization() async throws {
        let rig = try await Rig(sources: [.microphone])
        rig.permissions.microphone = .denied
        await rig.model.start()
        #expect(rig.model.phase == .error)
        #expect(rig.model.lanes[.microphone]?.status.issue?.contains("System Settings") == true)
        #expect(rig.permissions.requests == 0)
        rig.expectStopped()
        rig.permissions.microphone = .authorized
        await rig.model.start()
        #expect(rig.model.phase == .recording)
        await rig.model.stop()
        rig.expectStopped()
    }

    @Test func screenPermissionFailureKeepsMicrophoneRunning() async throws {
        let rig = try await Rig()
        rig.system.failure = SystemAudioCaptureFailure(.discovery, error: screenError(.userDeclined))
        await rig.model.start()
        #expect(rig.model.phase == .recording)
        #expect(rig.model.lanes[.system]?.status.issue?.contains("declined ScreenCaptureKit access") == true)
        #expect(rig.model.systemAudioAccess == .declined)
        #expect(rig.model.lanes[.microphone]?.status == .capturing)
        await rig.model.stop()
        rig.expectStopped()
    }

    @Test func screenDiscoveryFailureDoesNotBecomePermissionDenial() async throws {
        let rig = try await Rig(sources: [.system])
        rig.system.failure = SystemAudioCaptureFailure(.discovery, error: screenError(.internalError))
        await rig.model.start()
        #expect(rig.model.phase == .error)
        #expect(rig.model.canStart)
        #expect(rig.model.systemAudioAccess == .unchecked)
        #expect(rig.model.lanes[.system]?.status.issue?.contains("Finding shareable displays failed") == true)
        #expect(rig.model.lanes[.system]?.status.issue?.contains("System Settings") == false)
        rig.expectStopped()
    }

    @Test func screenAudioCanRetryAfterDeclineAndClearsTheStalePermissionStatus() async throws {
        let rig = try await Rig(sources: [.system])
        rig.system.failure = SystemAudioCaptureFailure(.discovery, error: screenError(.userDeclined))
        await rig.model.start()
        #expect(rig.model.systemAudioAccess == .declined)
        rig.system.failure = nil
        await rig.model.start()
        #expect(rig.model.systemAudioAccess == .verified)
        #expect(rig.model.lanes[.system]?.status == .capturing)
        #expect(rig.system.selections == [.automatic, .automatic])
        await rig.model.stop()
        rig.expectStopped()
    }

    @Test func thePickerIsUsedOnlyWhenSelected() async throws {
        let rig = try await Rig(sources: [.system])
        rig.model.settings.options.systemAudioSelection = .displayPicker
        rig.system.failure = SystemAudioCaptureFailure(.selection, kind: .selectionCancelled)
        await rig.model.start()
        #expect(rig.model.systemAudioAccess == .unchecked)
        #expect(rig.model.lanes[.system]?.status.issue?.contains("selection was canceled") == true)
        rig.system.failure = nil
        await rig.model.start()
        #expect(rig.model.systemAudioAccess == .verified)
        #expect(rig.system.selections == [.displayPicker, .displayPicker])
        await rig.model.stop()
        rig.expectStopped()
    }

    @Test func explicitScreenCaptureKitSelectionReachesTheSystemAudioPipeline() async throws {
        let rig = try await Rig(sources: [.system])
        rig.model.settings.options.systemAudioSelection = .screenCaptureKit
        await rig.model.start()
        #expect(rig.model.phase == .recording)
        #expect(rig.system.selections == [.screenCaptureKit])
        await rig.model.stop()
        rig.expectStopped()
    }

    @Test func noMicrophoneAndInvalidFormatAreActionable() async throws {
        let rig = try await Rig(sources: [.microphone])
        rig.permissions.input = nil
        await rig.model.start()
        #expect(rig.model.lanes[.microphone]?.status.issue?.contains("disconnected") == true)
        #expect(rig.model.phase == .error)
        rig.permissions.input = Rig.device
        rig.microphone.failure = "This microphone does not expose a usable input format."
        await rig.model.start()
        #expect(rig.model.phase == .error)
        #expect(rig.model.lanes[.microphone]?.status.issue?.contains("usable input format") == true)
        rig.expectStopped()
    }

    @Test func partiallyStartedCaptureIsRolledBackWithoutStoppingOtherSource() async throws {
        let rig = try await Rig()
        rig.system.failsAfterStarting = true
        await rig.model.start()
        #expect(rig.model.phase == .recording)
        #expect(!rig.system.running)
        #expect(rig.system.releases == 1)
        #expect(rig.microphone.device != nil)
        await rig.model.stop()
        rig.expectStopped()
    }

    @Test func missingTranslationIsOptional() async throws {
        let rig = try await Rig(sources: [.system])
        rig.model.settings.options.translate = true
        await rig.model.start()
        #expect(rig.model.phase == .recording)
        #expect(rig.model.notice?.contains("translation model") == true)
        await rig.model.stop()
    }

    @Test(arguments: ["missing", "invalid", "corrupted"])
    func badModelBlocksCaptureAndAllowsRetry(_ mode: String) async throws {
        let rig = try await Rig(verifyModel: true)
        if mode != "missing" {
            let store = try #require(rig.model.modelStore)
            let model = try #require(store.catalog.first { $0.id == WhisperModel.small.q8ID })
            let asset = try #require(model.assets.first)
            let folder = store.directory.appendingPathComponent(model.id)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent(asset.name)
            try Data("invalid".utf8).write(to: file)
            if mode == "corrupted" {
                let handle = try FileHandle(forWritingTo: file)
                try handle.truncate(atOffset: UInt64(asset.bytes))
                try handle.close()
            }
        }
        await rig.model.start()
        #expect(rig.model.phase == .error)
        #expect(rig.model.notice?.contains(mode == "corrupted" ? "SHA-256" : "Whisper Small") == true)
        #expect(rig.model.canStart && rig.system.starts == 0 && rig.microphone.starts == 0)
    }

    @Test func databaseFailureBlocksCapture() async throws {
        let rig = try await Rig(brokenDatabase: true)
        await rig.model.start()
        #expect(rig.model.phase == .error)
        #expect(rig.model.notice?.contains("database is unavailable") == true)
        #expect(rig.system.starts == 0 && rig.microphone.starts == 0)
    }

    @Test func repeatedStartAndStopDuringPreparationLeaveNoCapture() async throws {
        let rig = try await Rig()
        let gate = StartGate()
        rig.system.gate = gate
        let starting = Task { await rig.model.start() }
        await gate.waitUntilEntered()
        #expect(rig.model.phase == .preparing)
        await rig.model.start()
        #expect(rig.system.starts == 1)
        await rig.model.stop()
        await starting.value
        #expect(rig.model.phase == .interrupted)
        rig.expectStopped()
        rig.system.gate = nil
        await rig.model.start()
        #expect(rig.model.phase == .recording)
        await rig.model.stop()
    }

    @Test func closingWindowCancelsPreparationAndTerminationStopsRecording() async throws {
        let rig = try await Rig(sources: [.system])
        let gate = StartGate()
        rig.system.gate = gate
        let starting = Task { await rig.model.start() }
        await gate.waitUntilEntered()
        rig.model.cancelPreparation()
        await starting.value
        #expect(rig.model.phase == .interrupted)
        rig.expectStopped()
        rig.system.gate = nil
        await rig.model.start()
        #expect(await rig.model.canTerminate())
        #expect(!rig.model.canStart)
        #expect(rig.model.phase == .completed)
        rig.expectStopped()
    }

    @Test func micDisconnectAndSystemInterruptionAreIndependent() async throws {
        let rig = try await Rig()
        await rig.model.start()
        rig.permissions.input = nil
        await rig.model.checkMicrophone(clock: CaptureClock())
        #expect(rig.model.lanes[.microphone]?.status.issue?.contains("disconnected") == true)
        #expect(rig.model.lanes[.system]?.status == .capturing)
        rig.permissions.input = Rig.device
        await rig.model.checkMicrophone(clock: CaptureClock())
        #expect(rig.model.lanes[.microphone]?.status == .capturing)
        let released = rig.system.releaseEvents.stream
        rig.system.interrupt()
        var releases = released.makeAsyncIterator()
        #expect(await releases.next() == true)
        #expect(rig.model.lanes[.system]?.status.issue?.contains("Display disconnected.") == true)
        #expect(rig.model.lanes[.microphone]?.status == .capturing)
        await rig.model.stop()
        rig.expectStopped()
    }

    @Test func runtimeMicrophoneCanStartMutedAndToggleWithoutRestartingSystemAudio() async throws {
        let rig = try await Rig(sources: [.system])
        await rig.model.start()
        let session = rig.model.session?.id
        for _ in 0..<4 {
            await rig.model.setMicrophoneEnabled(true)?.value
            #expect(rig.microphone.device == Rig.device)
            #expect(rig.model.lanes[.microphone]?.status == .capturing)
            let off = rig.model.setMicrophoneEnabled(false)
            #expect(rig.microphone.device == nil)
            #expect(rig.model.lanes[.microphone]?.status == .disabled)
            await off?.value
        }
        #expect(rig.model.session?.id == session)
        #expect(rig.system.starts == 1)
        #expect(rig.system.running)
        await rig.model.pause()
        await rig.model.resume()
        #expect(rig.microphone.device == nil)
        #expect(rig.model.phase == .recording)
        await rig.model.stop()
        rig.expectStopped()
    }

    @Test func pushToTalkReleaseAndPauseLeaveMicrophoneOffInAMicrophoneOnlySession() async throws {
        let rig = try await Rig(sources: [.microphone])
        rig.model.settings.microphoneShortcut = MicrophoneShortcut(mode: .pushToTalk)
        await rig.model.start()
        #expect(rig.model.phase == .recording)
        #expect(rig.microphone.device == nil)
        rig.model.beginPushToTalk()
        await rig.model.checkMicrophone(clock: CaptureClock())
        #expect(rig.microphone.device == Rig.device)
        rig.model.endPushToTalk()
        #expect(rig.microphone.device == nil)
        rig.model.beginPushToTalk()
        await rig.model.checkMicrophone(clock: CaptureClock())
        await rig.model.pause()
        await rig.model.resume()
        #expect(rig.model.phase == .recording)
        #expect(rig.microphone.device == nil)
        #expect(rig.model.lanes[.microphone]?.status == .disabled)
        await rig.model.stop()
    }

    @Test func switchingTheInputDuringCaptureAndDeletingHistoryKeepTheSessionRunning() async throws {
        let rig = try await Rig()
        let repository = try #require(rig.model.repository)
        var saved = CaptionSession(title: "Previous", options: SessionOptions())
        saved.status = .completed
        try await repository.create(saved)
        await rig.model.start()
        let current = try #require(rig.model.session?.id)
        let alternate = InputDevice(object: 43, id: "alternate", name: "Alternate microphone")
        rig.permissions.input = alternate
        rig.model.settings.options.microphoneUID = alternate.id
        rig.model.microphoneDeviceChanged()
        await rig.model.checkMicrophone(clock: CaptureClock())
        #expect(rig.microphone.device == alternate)
        try await rig.model.deleteSavedHistory()
        #expect(try await repository.sessions().map(\.id) == [current])
        #expect(rig.model.phase == .recording)
        #expect(rig.system.running)
        #expect(rig.system.starts == 1)
        await rig.model.stop()
    }
}

@MainActor
private final class Rig {
    static let device = InputDevice(object: 42, id: "test-input", name: "Test microphone")
    let root: URL
    let model: AppModel
    let permissions = Permissions()
    let system = SystemSpy()
    let microphone = MicrophoneSpy()

    init(sources: Set<AudioSource> = Set(AudioSource.allCases), verifyModel: Bool = false,
         brokenDatabase: Bool = false) async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        if brokenDatabase { try Data().write(to: root) }
        var dependencies = SessionDependencies()
        dependencies.system = system
        dependencies.microphone = microphone
        let permissions = permissions
        dependencies.microphoneAuthorization = { permissions.microphone }
        dependencies.requestMicrophone = { permissions.requests += 1; return false }
        dependencies.inputs = { permissions.input.map { [$0] } ?? [] }
        dependencies.input = { _ in permissions.input }
        if !verifyModel { dependencies.prepareRecognition = { _, _, _ in PreparedSpeech(metal: true) } }
        model = AppModel(dataFolder: root, defaults: nil, dependencies: dependencies)
        model.settings.options.sources = sources
        model.settings.options.enableVAD = false
        await model.initialize()
    }

    func expectStopped() {
        #expect(!system.running)
        #expect(microphone.device == nil)
    }

    deinit { try? FileManager.default.removeItem(at: root) }
}

@MainActor
private final class Permissions {
    var microphone = AVAuthorizationStatus.authorized
    var input: InputDevice? = Rig.device
    var requests = 0
}

@MainActor
private final class StartGate {
    private let entered = AsyncStream<Void>.makeStream()
    private let wait = AsyncStream<Void>.makeStream()

    func waitUntilEntered() async {
        var events = entered.stream.makeAsyncIterator()
        _ = await events.next()
    }

    func enter() async {
        entered.continuation.yield(())
        var pending = wait.stream.makeAsyncIterator()
        _ = await pending.next()
    }
}

@MainActor
private final class SystemSpy: SystemAudioCapturing {
    var starts = 0
    var selections: [SystemAudioSelection] = []
    var releases = 0
    var running = false
    var failure: (any Error)?
    var failsAfterStarting = false
    var gate: StartGate?
    var onFailure: (@Sendable (SystemAudioCaptureFailure) -> Void)?
    let releaseEvents = AsyncStream<Bool>.makeStream()

    func start(selection: SystemAudioSelection, clock: CaptureClock, chunks: AsyncStream<AudioChunk>.Continuation,
               issue: @escaping @Sendable (String) -> Void,
               failure: @escaping @Sendable (SystemAudioCaptureFailure) -> Void) async throws {
        starts += 1
        selections.append(selection)
        if let error = self.failure { throw error }
        #expect(!running)
        onFailure = failure
        running = true
        if let gate { await gate.enter() }
        try Task.checkCancellation()
        if failsAfterStarting { throw CaptionFailure("System Audio failed after starting.") }
    }

    func stop() async {
        if running {
            releases += 1
            running = false
            onFailure = nil
            releaseEvents.continuation.yield(true)
        }
    }

    func interrupt() { onFailure?(SystemAudioCaptureFailure(.interruption, kind: .stream, underlying: CaptionFailure("Display disconnected."))) }
}

@MainActor
private final class MicrophoneSpy: MicrophoneCapturing {
    var device: InputDevice?
    var starts = 0
    var failure: String?

    func start(device: InputDevice, clock: CaptureClock, chunks: AsyncStream<AudioChunk>.Continuation,
               issue: @escaping @Sendable (String) -> Void) throws {
        starts += 1
        if let failure { throw CaptionFailure(failure) }
        #expect(self.device == nil)
        self.device = device
    }

    func stop() { device = nil }
}


private func screenError(_ code: SCStreamError.Code) -> NSError {
    NSError(domain: SCStreamErrorDomain, code: code.rawValue, userInfo: [
        NSLocalizedDescriptionKey: "Native ScreenCaptureKit error \(code.rawValue)"
    ])
}

@Test(arguments: [
    (SCStreamError.Code.userDeclined, SystemAudioCaptureFailure.Kind.authorization),
    (.noDisplayList, .sourceUnavailable), (.noCaptureSource, .sourceUnavailable),
    (.invalidParameter, .configuration), (.missingEntitlements, .configuration),
    (.internalError, .stream), (.failedToStartAudioCapture, .stream)
])
func onlyScreenCaptureKitAuthorizationErrorsArePermissionDenials(
    _ entry: (SCStreamError.Code, SystemAudioCaptureFailure.Kind)
) {
    let (code, expected) = entry
    let failure = SystemAudioCaptureFailure(.startup, error: screenError(code))
    #expect(failure.kind == expected)
    #expect((failure.underlying as? NSError)?.code == code.rawValue)
    if expected != .authorization {
        #expect(failure.errorDescription?.contains("Native ScreenCaptureKit error") == true)
        #expect(failure.errorDescription?.contains("Recording Settings") == false)
    }
    let unrelated = NSError(domain: NSOSStatusErrorDomain, code: code.rawValue)
    #expect(SystemAudioCaptureFailure(.discovery, error: unrelated).kind == .stream)
}
