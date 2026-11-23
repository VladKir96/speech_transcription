import AVFoundation
import CaptionCore
import CoreAudio
import Foundation

// All callbacks for one tap use its serial IO queue.
private final class TapInput: @unchecked Sendable {
    private let format: AVAudioFormat
    private let producer: PCMProducer
    private let measurement: AudioProbeMeasurements?
    private var receivedSample = false
    private var forwardedPCM = false

    init(format: AVAudioFormat, producer: PCMProducer, measurement: AudioProbeMeasurements?) {
        self.format = format
        self.producer = producer
        self.measurement = measurement
    }

    func receive(_ input: UnsafePointer<AudioBufferList>, time: UnsafePointer<AudioTimeStamp>) {
        guard input.pointee.mNumberBuffers > 0, input.pointee.mBuffers.mDataByteSize > 0 else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input),
              buffer.frameLength > 0 else {
            producer.issue(SystemAudioCaptureFailure(.processing, kind: .processing).localizedDescription)
            return
        }

        if !receivedSample {
            receivedSample = true
            CaptureDiagnostics.audio.info("First Core Audio tap buffer; frames=\(buffer.frameLength) rate=\(self.format.sampleRate) channels=\(self.format.channelCount)")
        }
        measurement?.received(frames: Int(buffer.frameLength))
        let timestamp = time.pointee
        let hostSeconds = timestamp.mFlags.contains(.hostTimeValid) ? AVAudioTime.seconds(forHostTime: timestamp.mHostTime) : nil
        if producer.write(buffer, hostSeconds: hostSeconds), !forwardedPCM {
            forwardedPCM = true
            CaptureDiagnostics.audio.info("First Core Audio tap PCM forwarded to the System Audio pipeline")
        }
    }

    func checkForSamples() {
        if !receivedSample {
            let warning = SystemAudioCaptureFailure(.samples, kind: .noSamples)
            CaptureDiagnostics.audio.notice("\(warning.localizedDescription, privacy: .public)")
            producer.issue(warning.localizedDescription)
        } else if !forwardedPCM {
            CaptureDiagnostics.audio.warning("Core Audio delivered buffers without normalized PCM")
        }
    }
}

@available(macOS 14.2, *)
@MainActor
final class CoreAudioTapCapture: SystemAudioCapturing {
    private let measurement: AudioProbeMeasurements?
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    private var running = false
    private var sampleCheck: DispatchWorkItem?

    init(measurement: AudioProbeMeasurements?) { self.measurement = measurement }

    func start(selection: SystemAudioSelection, clock: CaptureClock, chunks: AsyncStream<AudioChunk>.Continuation,
               issue: @escaping @Sendable (String) -> Void,
               failure: @escaping @Sendable (SystemAudioCaptureFailure) -> Void) async throws {
        guard tapID == kAudioObjectUnknown else {
            throw CaptionFailure("The Core Audio tap is already connected.")
        }
        try Task.checkCancellation()
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: currentProcessObjects())
        description.name = "LocalCaption System Audio"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        try check(AudioHardwareCreateProcessTap(description, &tapID), "Creating process tap", stage: .initialization)
        CaptureDiagnostics.audio.info("Created a private Core Audio process tap; system audio authorization is handled by macOS")
        var formatDescription = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var formatAddress = address(kAudioTapPropertyFormat)
        try check(AudioObjectGetPropertyData(tapID, &formatAddress, 0, nil, &formatSize, &formatDescription),
                  "Reading process tap format", stage: .initialization)
        guard supportedPCM(formatDescription),
              let format = AVAudioFormat(streamDescription: &formatDescription) else {
            throw SystemAudioCaptureFailure(.initialization, kind: .configuration,
                                            underlying: CaptionFailure("Core Audio returned an unsupported tap format."))
        }

        let config: [String: Any] = [
            kAudioAggregateDeviceNameKey: "LocalCaption System Audio",
            kAudioAggregateDeviceUIDKey: "local.caption.tap.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true
            ]]
        ]
        try check(AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregateID),
                  "Creating private aggregate device", stage: .initialization)
        CaptureDiagnostics.audio.info("Created Core Audio tap device; rate=\(format.sampleRate) channels=\(format.channelCount)")

        let producer = PCMProducer(clock: clock, output: chunks, report: issue)
        let receiver = TapInput(format: format, producer: producer, measurement: measurement)
        let queue = DispatchQueue(label: "local.caption.core-audio-tap", qos: .userInitiated)
        try check(AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregateID, queue) { @Sendable _, input, time, _, _ in
            receiver.receive(input, time: time)
        }, "Registering Core Audio tap input", stage: .registration)
        guard let ioProc else { throw SystemAudioCaptureFailure(.registration, kind: .initialization) }
        CaptureDiagnostics.audio.info("Starting Core Audio System Audio input")
        try check(AudioDeviceStart(aggregateID, ioProc), "Starting Core Audio tap", stage: .startup)
        running = true
        try Task.checkCancellation()
        CaptureDiagnostics.audio.info("Core Audio tap started; waiting for actual samples")
        let check = DispatchWorkItem { @Sendable [weak receiver] in receiver?.checkForSamples() }
        sampleCheck = check
        queue.asyncAfter(deadline: .now() + .seconds(5), execute: check)
    }

    func stop() async {
        sampleCheck?.cancel()
        sampleCheck = nil
        if let ioProc {
            if running { CaptureDiagnostics.cleanup("Stopping Core Audio tap", status: AudioDeviceStop(aggregateID, ioProc)) }
            CaptureDiagnostics.cleanup("Removing Core Audio tap callback", status: AudioDeviceDestroyIOProcID(aggregateID, ioProc))
        }
        ioProc = nil
        running = false
        if aggregateID != kAudioObjectUnknown {
            CaptureDiagnostics.cleanup("Destroying private Core Audio tap device", status: AudioHardwareDestroyAggregateDevice(aggregateID))
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            CaptureDiagnostics.cleanup("Destroying Core Audio process tap", status: AudioHardwareDestroyProcessTap(tapID))
            tapID = kAudioObjectUnknown
            CaptureDiagnostics.audio.info("Released Core Audio tap")
        }
    }

    private func check(_ status: OSStatus, _ operation: String, stage: SystemAudioCaptureFailure.Stage) throws {
        guard status != noErr else { return }
        let error = NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
            NSLocalizedDescriptionKey: "\(operation) returned Core Audio status \(status)."
        ])
        CaptureDiagnostics.failure(operation, error, logger: CaptureDiagnostics.audio)
        throw SystemAudioCaptureFailure(stage, kind: stage == .startup ? .stream : .initialization, underlying: error)
    }

    private func currentProcessObjects() -> [AudioObjectID] {
        var address = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = ProcessInfo.processInfo.processIdentifier
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafePointer(to: &pid) { qualifier in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<pid_t>.size), qualifier, &size, &objectID)
        }
        if status == noErr, objectID != kAudioObjectUnknown { return [objectID] }
        CaptureDiagnostics.audio.debug("No Core Audio process object for LocalCaption; status=\(status)")
        return []
    }

    private func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }
}
