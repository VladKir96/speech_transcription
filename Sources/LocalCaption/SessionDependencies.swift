import AVFoundation
import CaptionCore
import CoreGraphics

@MainActor
protocol SystemAudioCapturing: Sendable {
    func start(selection: SystemAudioSelection, clock: CaptureClock, chunks: AsyncStream<AudioChunk>.Continuation,
               issue: @escaping @Sendable (String) -> Void,
               failure: @escaping @Sendable (SystemAudioCaptureFailure) -> Void) async throws
    func stop() async
}

@MainActor
protocol MicrophoneCapturing: Sendable {
    var device: InputDevice? { get }
    func start(device: InputDevice, clock: CaptureClock, chunks: AsyncStream<AudioChunk>.Continuation,
               issue: @escaping @Sendable (String) -> Void) throws
    func stop()
}

struct PreparedSpeech {
    let metal: Bool
    var compatibilityNotice: String? = nil
}

@MainActor
struct SessionDependencies {
    init() { prepareRecognition = Self.prepareSpeechModel }

    var system: any SystemAudioCapturing = SystemCapture()
    var microphone: any MicrophoneCapturing = MicrophoneCapture()
    var microphoneAuthorization: () -> AVAuthorizationStatus = { AVCaptureDevice.authorizationStatus(for: .audio) }
    var requestMicrophone: () async -> Bool = { await AVCaptureDevice.requestAccess(for: .audio) }
    var inputs: () -> [InputDevice] = { InputDevices.all() }
    var input: (String?) -> InputDevice? = { InputDevices.resolve($0) }
    var prepareRecognition: @MainActor (ModelStore, SessionOptions, WhisperRecognition) async throws -> PreparedSpeech

    private static func prepareSpeechModel(_ store: ModelStore, _ options: SessionOptions,
                                           _ recognizer: WhisperRecognition) async throws -> PreparedSpeech {
        let prefersQ5 = ProcessInfo.processInfo.environment["LOCALCAPTION_WHISPER_QUANTIZATION"] == "q5"
        let speech = try await store.speechModel(options.model, preferLegacy: prefersQ5)
        CaptureDiagnostics.session.info("Speech model verified; model=\(speech.model.id, privacy: .public)")
        try Task.checkCancellation()
        let metal = try await recognizer.prepare(model: speech.url, metal: options.useMetal)
        let warning = !prefersQ5 && speech.model.id != options.model.q8ID
            ? "\(options.model.title) is unavailable. Install or repair it in Settings → Models."
            : nil
        return PreparedSpeech(metal: metal, compatibilityNotice: warning)
    }
}
