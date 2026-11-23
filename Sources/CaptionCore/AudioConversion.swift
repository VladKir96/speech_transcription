import AVFoundation
import Foundation

// One instance per serial capture callback. Each call consumes its buffer synchronously.
public final class PCMNormalizer {
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                       channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private var lastFormat: AVAudioFormat?
    private var expectedOffset: Double?
    private var nextOffset: Double?

    public init() {}

    public func normalize(_ input: AVAudioPCMBuffer, start: Double) throws -> AudioChunk? {
        let format = input.format
        guard start.isFinite, start >= 0, input.frameLength > 0,
              format.sampleRate >= 8_000, format.sampleRate <= 384_000,
              format.channelCount > 0, Double(input.frameLength) <= format.sampleRate else {
            throw CaptionFailure("The capture device produced an unsupported audio format.")
        }

        let duration = Double(input.frameLength) / format.sampleRate
        if lastFormat != format || expectedOffset.map({ abs($0 - start) > 0.12 }) == true {
            lastFormat = format
            converter = format != target ? AVAudioConverter(from: format, to: target) : nil
            converter?.primeMethod = .none
            converter?.downmix = true
            nextOffset = start
        }
        expectedOffset = start + duration

        let samples: [Float]
        if format == target {
            samples = Self.samples(in: input)
        } else {
            let capacity = AVAudioFrameCount(ceil(duration * 16_000) + 256)
            guard let converter, let buffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
                throw CaptionFailure("Could not convert the device audio to 16 kHz mono PCM.")
            }

            let source = ConversionInput(input)
            var output: [Float] = []
            repeat {
                let remainingBeforeConversion = source.remaining
                var error: NSError?
                let status = converter.convert(to: buffer, error: &error) { requested, state in
                    source.provide(requested, to: state)
                }
                if status == .error || source.failed
                    || (source.remaining > 0 && buffer.frameLength == 0 && source.remaining == remainingBeforeConversion) {
                    converter.reset()
                    nextOffset = nil
                    throw CaptionFailure(error?.localizedDescription ?? "Audio conversion failed.")
                }
                output.append(contentsOf: Self.samples(in: buffer))
            } while source.remaining > 0
            samples = output
        }

        guard !samples.isEmpty else { return nil }
        let chunk = AudioChunk(start: nextOffset ?? start, samples: samples)
        nextOffset = chunk.end
        return chunk
    }

    private static func samples(in buffer: AVAudioPCMBuffer) -> [Float] {
        guard buffer.frameLength > 0, let channel = buffer.floatChannelData?[0] else { return [] }
        return UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
            .map { $0.isFinite ? min(1, max(-1, $0)) : 0 }
    }
}

// The converter pulls slices synchronously. Returning more than requested can drop trailing frames.
private final class ConversionInput: @unchecked Sendable {
    private let input: AVAudioPCMBuffer
    private var scratch: AVAudioPCMBuffer?
    private var offset: AVAudioFrameCount = 0
    private(set) var failed = false
    var remaining: AVAudioFrameCount { input.frameLength - offset }

    init(_ input: AVAudioPCMBuffer) { self.input = input }

    func provide(_ requested: AVAudioPacketCount,
                 to state: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioPCMBuffer? {
        let count = min(remaining, requested)
        guard count > 0 else {
            state.pointee = .noDataNow
            return nil
        }

        if offset == 0, count == input.frameLength {
            offset = count
            state.pointee = .haveData
            return input
        }

        if (scratch?.frameCapacity ?? 0) < count {
            scratch = AVAudioPCMBuffer(pcmFormat: input.format, frameCapacity: count)
        }
        guard let scratch else {
            failed = true
            state.pointee = .noDataNow
            return nil
        }
        scratch.frameLength = count
        let stride = Int(input.format.streamDescription.pointee.mBytesPerFrame)
        let inputBuffers = UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList)
        let outputBuffers = UnsafeMutableAudioBufferListPointer(scratch.mutableAudioBufferList)
        for (input, output) in zip(inputBuffers, outputBuffers) {
            guard let source = input.mData, let destination = output.mData else {
                failed = true
                state.pointee = .noDataNow
                return nil
            }
            destination.copyMemory(from: source.advanced(by: Int(offset) * stride), byteCount: Int(count) * stride)
        }
        offset += count
        state.pointee = .haveData
        return scratch
    }
}
