import CInference
import Foundation
import OSLog

public struct RecognitionPiece: Sendable {
    public let text: String
    public let start: Double
    public let end: Double
    public let noSpeech: Float

    public init(text: String, start: Double, end: Double, noSpeech: Float = 0) {
        self.text = text
        self.start = start
        self.end = end
        self.noSpeech = noSpeech
    }
}

public struct RecognitionResult: Sendable {
    public let language: String
    public let pieces: [RecognitionPiece]
    public init(language: String, pieces: [RecognitionPiece]) {
        self.language = language
        self.pieces = pieces
    }
}

public protocol SpeechRecognitionEngine: Sendable {
    func recognize(_ samples: [Float], language: SpeechLanguage, prompt: String?,
                   final: Bool, profile: RecognitionProfile) async throws -> RecognitionResult
}

private func nativeError(_ message: UnsafeMutablePointer<CChar>?, default fallback: String) -> CaptionFailure {
    guard let message else { return CaptionFailure(fallback) }
    defer { lc_string_free(message) }
    return CaptionFailure(String(cString: message))
}

private final class WhisperHandle: @unchecked Sendable {
    let pointer: OpaquePointer
    init(_ pointer: OpaquePointer) { self.pointer = pointer }
    deinit { lc_whisper_close(pointer) }
}

public actor WhisperRecognition: SpeechRecognitionEngine {
    private var handle: WhisperHandle?
    private var url: URL?
    private var requestedMetal = false
    private var activeMetal = false
    private let logger = Logger(subsystem: "local.caption", category: "recognition")

    public init() {}

    public func prepare(model: URL, metal: Bool) throws -> Bool {
        if url == model, requestedMetal == metal, handle != nil {
            logger.debug("Reusing the loaded Whisper model")
            return activeMetal
        }
        handle = nil
        var error: UnsafeMutablePointer<CChar>?
        logger.info("Initializing Whisper; model=\(model.path, privacy: .private) requestedMetal=\(metal)")
        let gpu = metal && lc_whisper_has_metal()
        if metal && !gpu { logger.warning("The ggml Metal backend could not initialize. Trying CPU inference.") }
        var pointer = lc_whisper_open(model.path, gpu, &error)
        var loadedGPU = gpu
        if pointer == nil && gpu {
            let failure = nativeError(error, default: "The native Metal initializer returned no context.")
            logger.warning("Whisper Metal initialization failed. Trying CPU inference. \(failure.message, privacy: .private)")
            error = nil
            pointer = lc_whisper_open(model.path, false, &error)
            loadedGPU = false
        }
        guard let pointer else { throw nativeError(error, default: "Could not load the Whisper model.") }
        handle = WhisperHandle(pointer)
        url = model
        requestedMetal = metal
        activeMetal = loadedGPU
        logger.info("Whisper context ready; Metal=\(loadedGPU)")
        return activeMetal
    }

    public func release() { handle = nil }

    public func recognize(_ samples: [Float], language: SpeechLanguage, prompt: String?,
                          final: Bool, profile: RecognitionProfile) throws -> RecognitionResult {
        guard let engine = handle?.pointer else { throw CaptionFailure("Load a Whisper model before recording.") }
        guard samples.count >= 1_600, samples.count <= 480_000 else {
            return RecognitionResult(language: language.rawValue, pieces: [])
        }
        var error: UnsafeMutablePointer<CChar>?
        let beam = final ? profile.finalBeam : 1
        let threads = Int32(max(1, min(4, ProcessInfo.processInfo.activeProcessorCount / 2)))
        let succeeded = samples.withUnsafeBufferPointer { pcm in
            language.rawValue.withCString { code in
                if let prompt {
                    return prompt.withCString {
                        lc_whisper_run(engine, pcm.baseAddress, Int32(pcm.count), code, $0, threads, Int32(beam), !final, &error)
                    }
                }
                return lc_whisper_run(engine, pcm.baseAddress, Int32(pcm.count), code, nil, threads, Int32(beam), !final, &error)
            }
        }
        guard succeeded else { throw nativeError(error, default: "Whisper inference failed.") }
        let detected = lc_whisper_language(engine).map { String(cString: $0) } ?? language.rawValue
        let pieces = (0..<lc_whisper_count(engine)).compactMap { i -> RecognitionPiece? in
            guard let text = lc_whisper_text(engine, i) else { return nil }
            let string = String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !string.isEmpty else { return nil }
            return RecognitionPiece(text: string, start: lc_whisper_start(engine, i),
                                    end: lc_whisper_end(engine, i), noSpeech: lc_whisper_no_speech(engine, i))
        }
        return RecognitionResult(language: detected, pieces: pieces)
    }
}

// Owned by an individual streaming pipeline actor.
final class SileroDetector: @unchecked Sendable {
    let pointer: OpaquePointer

    init?(url: URL) {
        guard let pointer = lc_vad_open(url.path) else { return nil }
        self.pointer = pointer
    }

    func probability(_ samples: [Float]) -> Float? {
        let p = samples.withUnsafeBufferPointer {
            lc_vad_probability(pointer, $0.baseAddress, Int32($0.count))
        }
        return p.isFinite && p >= 0 ? p : nil
    }

    deinit { lc_vad_close(pointer) }
}

public protocol TranslationEngine: Sendable {
    func translate(_ text: String, using model: TranslationModel,
                   source: String, target: String, modelFolder: URL) async throws -> String
}

private final class MarianHandle: @unchecked Sendable {
    let pointer: OpaquePointer

    init(folder: URL) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard let pointer = lc_translator_open(folder.path, &error) else {
            throw nativeError(error, default: "Could not load the local Marian model.")
        }
        self.pointer = pointer
    }

    func translate(_ text: String) throws -> String {
        var error: UnsafeMutablePointer<CChar>?
        guard let result = lc_translate(pointer, text, &error) else {
            throw nativeError(error, default: "Local translation could not complete.")
        }
        defer { lc_string_free(result) }
        return String(cString: result)
    }

    deinit { lc_translator_close(pointer) }
}

public actor MarianTranslation {
    private var models: [URL: MarianHandle] = [:]

    public init() {}

    public func translate(_ text: String, modelFolder: URL) throws -> String {
        let handle = try models[modelFolder] ?? MarianHandle(folder: modelFolder)
        models[modelFolder] = handle
        return try handle.translate(text)
    }

    public func release() { models.removeAll() }
}

private final class NLLBHandle: @unchecked Sendable {
    let pointer: OpaquePointer

    init(folder: URL) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard let pointer = lc_nllb_open(folder.path, 2, &error) else {
            throw nativeError(error, default: "Could not load the local NLLB model.")
        }
        self.pointer = pointer
    }

    func translate(_ text: String, source: String, target: String, flag: OpaquePointer) throws -> String {
        var error: UnsafeMutablePointer<CChar>?
        guard let result = lc_nllb_translate(pointer, text, source, target, 15_000, flag, &error) else {
            throw nativeError(error, default: "NLLB translation did not complete.")
        }
        defer { lc_string_free(result) }
        return String(cString: result)
    }

    deinit { lc_nllb_close(pointer) }
}

private final class TranslationCancellation: @unchecked Sendable {
    // The flag is immutable on the Swift side. Native reads and writes use a C++ atomic.
    let flag: OpaquePointer

    init() throws {
        guard let flag = lc_cancel_flag_open() else { throw CaptionFailure("Could not allocate translation state.") }
        self.flag = flag
    }

    func cancel() { lc_cancel_flag_set(flag) }
    deinit { lc_cancel_flag_close(flag) }
}

public actor TranslationEngineManager: TranslationEngine {
    private var marian: [URL: MarianHandle] = [:]
    private var nllb: (folder: URL, handle: NLLBHandle)?

    public init() {}

    public func translate(_ text: String, using model: TranslationModel,
                          source: String, target: String, modelFolder: URL) async throws -> String {
        guard model.installation(from: source, to: target) != nil,
              !text.contains("\0"),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CaptionFailure("Translation needs non-empty text and a supported language pair.")
        }
        try Task.checkCancellation()
        let cancellation = try TranslationCancellation()
        return try await withTaskCancellationHandler {
            // Native inference stays on this actor. Switching happens only between requests.
            let result = try perform(text, using: model, source: source, target: target,
                                     modelFolder: modelFolder, cancellation: cancellation)
            try Task.checkCancellation()
            guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CaptionFailure("The translation model returned empty text.")
            }
            return result
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func perform(_ text: String, using model: TranslationModel, source: String, target: String,
                         modelFolder: URL, cancellation: TranslationCancellation) throws -> String {
        switch model {
        case .marian:
            nllb = nil
            let handle = try marian[modelFolder] ?? MarianHandle(folder: modelFolder)
            marian[modelFolder] = handle
            return try handle.translate(text)
        case .nllb:
            marian.removeAll()
            if nllb?.folder != modelFolder {
                nllb = nil
                nllb = (modelFolder, try NLLBHandle(folder: modelFolder))
            }
            guard let handle = nllb?.handle,
                  let sourceToken = TranslationModel.nllbToken(for: source),
                  let targetToken = TranslationModel.nllbToken(for: target) else {
                throw CaptionFailure("NLLB does not support this language pair.")
            }
            try Task.checkCancellation()
            return try handle.translate(text, source: sourceToken, target: targetToken, flag: cancellation.flag)
        }
    }

    public func release() {
        marian.removeAll()
        nllb = nil
    }
}
