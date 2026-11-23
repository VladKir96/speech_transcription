import AVFoundation
import AudioToolbox
import CaptionCore
import CoreAudio
import CoreGraphics
import ScreenCaptureKit

struct CaptureClock: Sendable {
    let hostStart = CMClockGetTime(CMClockGetHostTimeClock()).seconds
    var elapsed: Double { max(0, hostNow - hostStart) }
    private var hostNow: Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

    func offset(hostSeconds: Double?, duration: Double) -> Double {
        let now = hostNow
        let timestamp = hostSeconds.flatMap { $0.isFinite && abs($0 - now) < 15 ? $0 : nil } ?? now - duration
        return max(0, timestamp - hostStart)
    }
}

struct InputDevice: Identifiable, Equatable, Sendable {
    let object: AudioDeviceID
    let id: String
    let name: String
}

enum InputDevices {
    static func all() -> [InputDevice] {
        var devicesProperty = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &devicesProperty, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard !ids.isEmpty else { return [] }
        let status = ids.withUnsafeMutableBytes { bytes -> OSStatus in
            guard let base = bytes.baseAddress else { return kAudio_ParamError }
            return AudioObjectGetPropertyData(system, &devicesProperty, 0, nil, &size, base)
        }
        guard status == noErr else { return [] }
        return ids.compactMap { id in
            var input = address(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeInput)
            var bytes: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &input, 0, nil, &bytes) == noErr, bytes > 0,
                  let uid = property(id, selector: kAudioDevicePropertyDeviceUID),
                  let name = property(id, selector: kAudioObjectPropertyName) else { return nil }
            return InputDevice(object: id, id: uid, name: name)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func resolve(_ uid: String?) -> InputDevice? {
        let devices = all()
        if let uid { return devices.first { $0.id == uid } }
        var selected: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var property = address(kAudioHardwarePropertyDefaultInputDevice)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property,
                                         0, nil, &size, &selected) == noErr else { return nil }
        return devices.first { $0.object == selected }
    }

    private static func property(_ id: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var result: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout.size(ofValue: result))
        var property = address(selector)
        guard AudioObjectGetPropertyData(id, &property, 0, nil, &size, &result) == noErr else { return nil }
        return result?.takeRetainedValue() as String?
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
}

// Used only by the serial audio callback of one capture source.
final class PCMProducer: @unchecked Sendable {
    private let clock: CaptureClock
    private let output: AsyncStream<AudioChunk>.Continuation
    private let report: @Sendable (String) -> Void
    private let normalizer = PCMNormalizer()
    private var lastIssueAt = -10.0

    init(clock: CaptureClock, output: AsyncStream<AudioChunk>.Continuation,
         report: @escaping @Sendable (String) -> Void) {
        self.clock = clock
        self.output = output
        self.report = report
    }

    func issue(_ message: String, error: (any Error)? = nil) {
        let now = clock.elapsed
        if now - lastIssueAt > 3 {
            lastIssueAt = now
            if let error { CaptureDiagnostics.failure("Normalizing capture PCM", error, logger: CaptureDiagnostics.audio) }
            report(message)
        }
    }

    @discardableResult
    func write(_ input: AVAudioPCMBuffer, hostSeconds: Double?) -> Bool {
        let duration = Double(input.frameLength) / max(1, input.format.sampleRate)
        let start = clock.offset(hostSeconds: hostSeconds, duration: duration)
        do {
            guard let chunk = try normalizer.normalize(input, start: start) else { return false }
            if chunk.samples.count <= 3_200 { return publish(chunk) }
            for index in stride(from: 0, to: chunk.samples.count, by: 3_200) {
                let slice = chunk.samples[index..<min(index + 3_200, chunk.samples.count)]
                if !publish(AudioChunk(start: chunk.start + Double(index) / Double(AudioChunk.rate), samples: Array(slice))) {
                    return index > 0
                }
            }
            return true
        } catch {
            issue(error.localizedDescription, error: error)
            return false
        }
    }

    private func publish(_ chunk: AudioChunk) -> Bool {
        switch output.yield(chunk) {
        case .enqueued:
            return true
        case .dropped:
            issue("Processing is behind. Some input audio was skipped. Try Low Latency or a faster model.")
            return true
        case .terminated:
            return false
        @unknown default:
            return false
        }
    }
}

// ScreenCaptureKit delivers samples on this output's serial queue.
private final class ScreenOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let sampleQueue = DispatchQueue(label: "local.caption.system-audio", qos: .userInitiated)
    private let producer: PCMProducer
    private let failure: @Sendable (SystemAudioCaptureFailure) -> Void
    private var receivedSample = false
    private var forwardedPCM = false
    private let measurement: AudioProbeMeasurements?

    init(producer: PCMProducer, measurement: AudioProbeMeasurements?,
         failure: @escaping @Sendable (SystemAudioCaptureFailure) -> Void) {
        self.producer = producer
        self.measurement = measurement
        self.failure = failure
    }

    func checkForSamples() {
        if !receivedSample {
            let warning = SystemAudioCaptureFailure(.samples, kind: .noSamples)
            CaptureDiagnostics.audio.notice("\(warning.localizedDescription, privacy: .public)")
            producer.issue(warning.localizedDescription)
        } else if !forwardedPCM {
            CaptureDiagnostics.audio.warning("ScreenCaptureKit delivered audio but no normalized PCM has reached transcription.")
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        CaptureDiagnostics.failure("ScreenCaptureKit stream interrupted", error, logger: CaptureDiagnostics.audio)
        failure(SystemAudioCaptureFailure(.interruption, error: error))
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        if !receivedSample {
            receivedSample = true
            CaptureDiagnostics.audio.info("First ScreenCaptureKit audio buffer; frames=\(sample.numSamples)")
        }
        measurement?.received(frames: sample.numSamples)
        guard sample.isValid, CMSampleBufferDataIsReady(sample),
              let description = sample.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description) else { return }
        guard supportedPCM(asbd.pointee), let format = AVAudioFormat(streamDescription: asbd) else {
            producer.issue("System Audio returned an unsupported PCM format.")
            return
        }
        let count = sample.numSamples
        guard count > 0, count <= 48_000,
              let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { return }
        input.frameLength = AVAudioFrameCount(count)
        let result = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sample, at: 0, frameCount: Int32(count), into: input.mutableAudioBufferList)
        guard result == noErr else {
            CaptureDiagnostics.cleanup("Copying ScreenCaptureKit PCM", status: result)
            producer.issue("Could not read a System Audio buffer.")
            return
        }
        if producer.write(input, hostSeconds: sample.presentationTimeStamp.seconds), !forwardedPCM {
            forwardedPCM = true
            CaptureDiagnostics.audio.info("First System Audio PCM forwarded to transcription; sourceRate=\(format.sampleRate) channels=\(format.channelCount)")
        }
    }
}

@MainActor
final class SystemCapture: SystemAudioCapturing {
    private var stream: SCStream?
    private var output: ScreenOutput?
    private var picker: ScreenAudioPicker?
    private var sampleCheck: DispatchWorkItem?
    private var stopping: Task<Void, Never>?
    private var starting = false
    private let measurement: AudioProbeMeasurements?
    private var tap: (any SystemAudioCapturing)?

    init(measurement: AudioProbeMeasurements? = nil) { self.measurement = measurement }

    func start(selection: SystemAudioSelection, clock: CaptureClock, chunks: AsyncStream<AudioChunk>.Continuation,
               issue: @escaping @Sendable (String) -> Void,
               failure: @escaping @Sendable (SystemAudioCaptureFailure) -> Void) async throws {
        guard !starting, stream == nil, stopping == nil, tap == nil else {
            throw CaptionFailure("System Audio is already connected or still stopping. Try again.")
        }
        starting = true
        defer {
            starting = false
            if stream == nil { releasePicker() }
        }
        CaptureDiagnostics.systemAudioRequested(selection: selection.rawValue)

        if #available(macOS 14.2, *), selection == .automatic {
            let tap = CoreAudioTapCapture(measurement: measurement)
            self.tap = tap
            do {
                try await tap.start(selection: selection, clock: clock, chunks: chunks, issue: issue, failure: failure)
            } catch {
                await tap.stop()
                self.tap = nil
                throw error
            }
            return
        }

        let filter: SCContentFilter
        switch selection {
        case .automatic, .screenCaptureKit:
            filter = try await discoverDisplay()
        case .displayPicker:
            let picker = ScreenAudioPicker()
            self.picker = picker
            filter = try await attempt(.selection) { try await picker.chooseDisplay() }
            CaptureDiagnostics.audio.info("Created a ScreenCaptureKit filter from the selected display")
        }
        try Task.checkCancellation()

        CaptureDiagnostics.audio.info("Configuring ScreenCaptureKit stream for 48 kHz stereo audio")
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.showsCursor = false
        CaptureDiagnostics.audio.info("ScreenCaptureKit configuration: audio=true ownAudioExcluded=true rate=\(configuration.sampleRate) channels=\(configuration.channelCount)")

        let producer = PCMProducer(clock: clock, output: chunks, report: issue)
        let output = ScreenOutput(producer: producer, measurement: measurement, failure: failure)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        CaptureDiagnostics.audio.info("Initialized ScreenCaptureKit stream")
        try await attempt(.registration) {
            try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: output.sampleQueue)
        }
        CaptureDiagnostics.audio.info("Registered ScreenCaptureKit audio output")
        self.output = output
        self.stream = stream
        do {
            CaptureDiagnostics.audio.info("Calling SCStream.startCapture()")
            try await attempt(.startup) { try await stream.startCapture() }
            try Task.checkCancellation()
            CaptureDiagnostics.audio.info("ScreenCaptureKit audio started")
            let check = DispatchWorkItem { @Sendable [weak output] in output?.checkForSamples() }
            sampleCheck = check
            output.sampleQueue.asyncAfter(deadline: .now() + .seconds(5), execute: check)
        } catch {
            await stop()
            throw error
        }
    }

    private func discoverDisplay() async throws -> SCContentFilter {
        CaptureDiagnostics.audio.info("Calling SCShareableContent.current; ScreenCaptureKit handles authorization")
        let content = try await attempt(.discovery) { try await SCShareableContent.current }
        CaptureDiagnostics.audio.info("Discovered \(content.displays.count) shareable displays")
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
            let failure = SystemAudioCaptureFailure(.selection, kind: .sourceUnavailable)
            CaptureDiagnostics.failure("Selecting ScreenCaptureKit display", failure, logger: CaptureDiagnostics.audio)
            throw failure
        }
        CaptureDiagnostics.audio.info("Selected ScreenCaptureKit display; display=\(display.displayID)")
        let filter = SCContentFilter(display: display, excludingWindows: [])
        CaptureDiagnostics.audio.info("Created ScreenCaptureKit display filter; display=\(display.displayID)")
        return filter
    }

    private func attempt<Value>(_ stage: SystemAudioCaptureFailure.Stage,
                                _ operation: () async throws -> Value) async throws -> Value {
        do { return try await operation() }
        catch is CancellationError { throw CancellationError() }
        catch let failure as SystemAudioCaptureFailure { throw failure }
        catch {
            CaptureDiagnostics.failure(stage.rawValue, error, logger: CaptureDiagnostics.audio)
            throw SystemAudioCaptureFailure(stage, error: error)
        }
    }

    private func releasePicker() {
        picker?.stop()
        picker = nil
    }

    func stop() async {
        if let tap {
            await tap.stop()
            self.tap = nil
            return
        }
        if let stopping {
            await stopping.value
            return
        }
        sampleCheck?.cancel()
        sampleCheck = nil
        guard let stream, let output else {
            releasePicker()
            return
        }
        let task = Task {
            do { try await stream.stopCapture() }
            catch { CaptureDiagnostics.failure("Stopping ScreenCaptureKit", error, logger: CaptureDiagnostics.audio) }
            do { try stream.removeStreamOutput(output, type: .audio) }
            catch { CaptureDiagnostics.failure("Removing ScreenCaptureKit audio output", error, logger: CaptureDiagnostics.audio) }
        }
        stopping = task
        await task.value
        self.stream = nil
        self.output = nil
        stopping = nil
        releasePicker()
        CaptureDiagnostics.audio.debug("Released ScreenCaptureKit audio stream")
    }
}

private final class MicrophoneCallback: @unchecked Sendable {
    let unit: AudioUnit
    let buffer: AVAudioPCMBuffer
    let producer: PCMProducer

    init(unit: AudioUnit, buffer: AVAudioPCMBuffer, producer: PCMProducer) {
        self.unit = unit
        self.buffer = buffer
        self.producer = producer
    }

    func render(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, _ time: UnsafePointer<AudioTimeStamp>,
                _ frames: UInt32) -> OSStatus {
        guard frames <= buffer.frameCapacity else {
            producer.issue("The microphone returned more samples than its buffer can hold.")
            return kAudioUnitErr_TooManyFramesToProcess
        }
        guard frames > 0 else { return noErr }
        buffer.frameLength = frames
        let status = AudioUnitRender(unit, flags, time, 1, frames, buffer.mutableAudioBufferList)
        guard status == noErr else {
            producer.issue("Microphone input failed (Core Audio \(status)). Check the connection or select another device.")
            return status
        }
        let timestamp = time.pointee
        let seconds = timestamp.mFlags.contains(.hostTimeValid) ? AVAudioTime.seconds(forHostTime: timestamp.mHostTime) : nil
        producer.write(buffer, hostSeconds: seconds)
        return noErr
    }
}

// Core Audio invokes this C function on its own I/O thread.
nonisolated let microphoneRenderProc: AURenderCallback = { user, flags, time, _, frames, _ in
    guard frames > 0 else { return noErr }
    return Unmanaged<MicrophoneCallback>.fromOpaque(user).takeUnretainedValue().render(flags, time, frames)
}

func supportedPCM(_ format: AudioStreamBasicDescription) -> Bool {
    format.mFormatID == kAudioFormatLinearPCM && format.mChannelsPerFrame > 0 &&
        format.mChannelsPerFrame <= 64 && format.mBytesPerFrame > 0 &&
        (8_000...384_000).contains(format.mSampleRate)
}

@MainActor
final class MicrophoneCapture: MicrophoneCapturing {
    private var unit: AudioUnit?
    private var initialized = false
    private var attemptedStart = false
    private var callback: MicrophoneCallback?
    private(set) var device: InputDevice?

    func start(device: InputDevice, clock: CaptureClock, chunks: AsyncStream<AudioChunk>.Continuation,
               issue: @escaping @Sendable (String) -> Void) throws {
        guard self.device == nil else { throw CaptionFailure("The microphone is already recording.") }
        stop()
        guard unit == nil else { throw CaptionFailure("Could not release the previous microphone connection. Try again.") }
        var description = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                                    componentSubType: kAudioUnitSubType_HALOutput,
                                                    componentManufacturer: kAudioUnitManufacturer_Apple,
                                                    componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw CaptionFailure("The Core Audio microphone unit is unavailable.")
        }
        var instance: AudioUnit?
        try AudioComponentInstanceNew(component, &instance).checkedAudio("Opening microphone")
        guard let unit = instance else { throw CaptionFailure("Could not open the selected microphone.") }
        self.unit = unit
        CaptureDiagnostics.audio.info("Configuring Core Audio input; UID=\(device.id, privacy: .private(mask: .hash))")

        do {
            try set(unit, kAudioOutputUnitProperty_EnableIO, scope: kAudioUnitScope_Input, bus: 1, value: UInt32(1))
            try set(unit, kAudioOutputUnitProperty_EnableIO, scope: kAudioUnitScope_Output, bus: 0, value: UInt32(0))
            try set(unit, kAudioOutputUnitProperty_CurrentDevice, scope: kAudioUnitScope_Global, bus: 0, value: device.object)
            var native = AudioStreamBasicDescription()
            var bytes = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &native, &bytes)
                .checkedAudio("Reading microphone format")
            CaptureDiagnostics.audio.info("Microphone format; rate=\(native.mSampleRate) channels=\(native.mChannelsPerFrame)")
            guard supportedPCM(native),
                  let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: native.mSampleRate,
                                            channels: 1, interleaved: false),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_192) else {
                throw CaptionFailure("This microphone does not expose a usable input format.")
            }
            try set(unit, kAudioUnitProperty_StreamFormat, scope: kAudioUnitScope_Output, bus: 1,
                    value: format.streamDescription.pointee)
            try set(unit, kAudioUnitProperty_MaximumFramesPerSlice, scope: kAudioUnitScope_Global, bus: 0, value: UInt32(8_192))

            let producer = PCMProducer(clock: clock, output: chunks, report: issue)
            let callback = MicrophoneCallback(unit: unit, buffer: buffer, producer: producer)
            self.callback = callback
            let procedure = AURenderCallbackStruct(inputProc: microphoneRenderProc,
                inputProcRefCon: Unmanaged.passUnretained(callback).toOpaque())
            try set(unit, kAudioOutputUnitProperty_SetInputCallback, scope: kAudioUnitScope_Global, bus: 0, value: procedure)
            try AudioUnitInitialize(unit).checkedAudio("Initializing microphone")
            initialized = true
            attemptedStart = true
            try AudioOutputUnitStart(unit).checkedAudio("Starting microphone")
            self.device = device
            CaptureDiagnostics.audio.info("Core Audio microphone started")
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        guard let unit else { return }
        if attemptedStart {
            let status = AudioOutputUnitStop(unit)
            CaptureDiagnostics.cleanup("Stopping microphone I/O", status: status)
            if status == noErr { attemptedStart = false }
        }
        if initialized {
            let status = AudioUnitUninitialize(unit)
            CaptureDiagnostics.cleanup("Uninitializing microphone", status: status)
            if status == noErr {
                initialized = false
                attemptedStart = false
            }
        }
        let status = AudioComponentInstanceDispose(unit)
        CaptureDiagnostics.cleanup("Disposing microphone", status: status)
        device = nil
        // Keep the Swift callback alive until Core Audio has released its refCon.
        guard status == noErr else { return }
        self.unit = nil
        callback = nil
        initialized = false
        attemptedStart = false
        CaptureDiagnostics.audio.debug("Released Core Audio microphone")
    }

    private func set<T>(_ unit: AudioUnit, _ property: AudioUnitPropertyID, scope: AudioUnitScope,
                        bus: AudioUnitElement, value: T) throws {
        try withUnsafeBytes(of: value) { bytes in
            try AudioUnitSetProperty(unit, property, scope, bus, bytes.baseAddress, UInt32(bytes.count))
                .checkedAudio("Configuring microphone property \(property)")
        }
    }
}

private extension OSStatus {
    func checkedAudio(_ operation: String) throws {
        guard self != noErr else { return }
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(self), userInfo: [
            NSLocalizedDescriptionKey: "\(operation) failed (Core Audio \(self)). Check the device in Settings → Audio."
        ])
    }
}
