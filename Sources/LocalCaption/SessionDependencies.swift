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

@MainActor
struct SessionDependencies {
    init() { prepareRecognition = Self.prepareSpeechModel }

    var system: any SystemAudioCapturing = SystemCapture()
    var microphone: any MicrophoneCapturing = MicrophoneCapture()
    var microphoneAuthorization: () -> AVAuthorizationStatus = { AVCaptureDevice.authorizationStatus(for: .audio) }
    var requestMicrophone: () async -> Bool = { await AVCaptureDevice.requestAccess(for: .audio) }
    var inputs: () -> [InputDevice] = { InputDevices.all() }
    var input: (String?) -> InputDevice? = { InputDevices.resolve($0) }
    var prepareRecognition: @MainActor (ModelStore, SessionOptions, WhisperRecognition) async throws -> Bool

    private static func prepareSpeechModel(_ store: ModelStore, _ options: SessionOptions,
                                           _ recognizer: WhisperRecognition) async throws -> Bool {
        let path = try await store.verifiedSpeechModel(options.model.id)
        CaptureDiagnostics.session.info("Speech model verified; model=\(options.model.id, privacy: .public)")
        try Task.checkCancellation()
        return try await recognizer.prepare(model: path, metal: options.useMetal)
    }
}
