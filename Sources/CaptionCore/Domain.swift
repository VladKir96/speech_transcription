import Foundation

public enum AudioSource: String, CaseIterable, Codable, Identifiable, Sendable {
    case system, microphone
    public var id: String { rawValue }
    public var title: String { self == .system ? "System Audio" : "Microphone" }
    public var icon: String { self == .system ? "speaker.wave.2" : "mic" }
}

public enum SpeechLanguage: String, CaseIterable, Codable, Identifiable, Sendable {
    case auto, en, ru
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .auto: "Auto Detect"
        case .en: "English"
        case .ru: "Russian"
        }
    }
}

public enum RecognitionProfile: String, CaseIterable, Codable, Identifiable, Sendable {
    case lowLatency, highAccuracy
    public var id: String { rawValue }
    public var title: String { self == .lowLatency ? "Low Latency" : "High Accuracy" }
    var firstPartial: Double { self == .lowLatency ? 1.05 : 2.0 }
    var partialInterval: Double { self == .lowLatency ? 0.75 : 1.5 }
    var endSilence: Double { self == .lowLatency ? 0.55 : 0.85 }
    var maxPhrase: Double { self == .lowLatency ? 10 : 18 }
    var finalBeam: Int { self == .lowLatency ? 1 : 4 }
}

public enum WhisperModel: String, CaseIterable, Codable, Identifiable, Sendable {
    case small, turbo
    public var id: String { rawValue }
    public var q8ID: String { "\(rawValue)-q8" }
    public var title: String { self == .small ? "Whisper Small (Q8)" : "Whisper Large-v3 Turbo (Q8)" }
}

public enum TranslationModel: String, CaseIterable, Codable, Identifiable, Sendable {
    case marian = "marian-opus"
    case nllb = "nllb-200-600m"
    public var id: String { rawValue }
    public var title: String { self == .marian ? "MarianMT (Fast)" : "NLLB-200 (Multilingual)" }
    public var version: String? { self == .nllb ? "b3bbac6-ct2-4.6.3-int8" : nil }
    public var detail: String {
        self == .marian ? "Lightweight offline translation optimized for low latency."
            : "Multilingual offline translation model with broader language support."
    }
    public func installation(from: String, to: String) -> String? {
        guard from != to, Self.nllbToken(for: from) != nil, Self.nllbToken(for: to) != nil else { return nil }
        return self == .marian ? "opus-\(from)-\(to)" : rawValue
    }

    public static func nllbToken(for language: String) -> String? {
        ["en": "eng_Latn", "ru": "rus_Cyrl"][language]
    }
}

public enum SessionPhase: String, Codable, Sendable {
    case idle, preparing, recording, paused, stopping, completed, error, interrupted
    public var title: String { rawValue.capitalized }
    public func allows(_ next: Self) -> Bool {
        switch (self, next) {
        case (.idle, .preparing), (.completed, .preparing), (.error, .preparing), (.interrupted, .preparing),
             (.preparing, .recording), (.preparing, .paused), (.preparing, .error),
             (.preparing, .completed), (.preparing, .idle), (.preparing, .interrupted),
             (.recording, .paused), (.recording, .stopping), (.paused, .preparing),
             (.paused, .stopping), (.stopping, .completed), (.stopping, .error): true
        default: false
        }
    }
}

public enum TranslationStatus: String, Codable, Sendable {
    case disabled, pending, translating, translated, sameLanguage, unsupported, failed
}

public enum CaptionDisplay: String, Codable, CaseIterable, Identifiable, Sendable {
    case original, translated, both
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .original: "Original"
        case .translated: "Translation"
        case .both: "Original and Translation"
        }
    }
}

public enum ExportFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case txt, json, srt
    public var id: String { rawValue }
    public var title: String { rawValue.uppercased() }
}

public enum SystemAudioSelection: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic, screenCaptureKit, displayPicker
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .automatic: "Automatic"
        case .screenCaptureKit: "ScreenCaptureKit"
        case .displayPicker: "macOS display picker"
        }
    }
}

public enum TranslationStrategy: String, Codable, CaseIterable, Identifiable, Sendable {
    case fast, balanced, contextAware

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .fast: "Fast"
        case .balanced: "Balanced"
        case .contextAware: "Context-Aware"
        }
    }
    public var pause: Double {
        switch self {
        case .fast: 0.9
        case .balanced: 1.8
        case .contextAware: 2.8
        }
    }
}

public struct SessionOptions: Codable, Sendable {
    public var profile: RecognitionProfile = .lowLatency
    public var sources: Set<AudioSource> = Set(AudioSource.allCases)
    public var model: WhisperModel = .small
    public var translationModel: TranslationModel = .marian
    public var sourceLanguage: SpeechLanguage = .auto
    public var targetLanguage: SpeechLanguage = .ru
    public var translate = false
    public var enableVAD = true
    public var useMetal = true
    public var systemAudioSelection: SystemAudioSelection?
    public var microphoneUID: String?
    public var translationStrategy: TranslationStrategy?
    public var phraseCompletionPause: Double?
    public var effectivePhrasePause: Double {
        let preset = (translationStrategy ?? .balanced).pause
        guard let pause = phraseCompletionPause, pause.isFinite else { return preset }
        return min(4, max(0.5, pause))
    }
    public init() {}
}

public struct CaptionSession: Codable, Identifiable, Sendable, Hashable {
    public let id: UUID
    public var title: String
    public let createdAt: Date
    public let startedAt: Date
    public var endedAt: Date?
    public var duration: Double
    public var status: SessionPhase
    public let options: SessionOptions

    public init(id: UUID = UUID(), title: String, date: Date = .now, options: SessionOptions, createdAt: Date? = nil) {
        self.id = id
        self.title = title
        self.createdAt = createdAt ?? date
        startedAt = date
        duration = 0
        status = .preparing
        self.options = options
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

public struct TranscriptSegment: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public let sessionID: UUID
    public let source: AudioSource
    public let start: Double
    public let end: Double
    public let original: String
    public let language: String
    public let finalized: Bool
    public let createdAt: Date
    public var translation: String?
    public var translationStatus: TranslationStatus
    public var translationError: String?
    public var translationModel: TranslationModel?
    public var translationModelVersion: String?
    public var speakerID: UUID?
    public var speakerName: String?
    public var speakerColor: Int?
    public var speakerStatus: SpeakerStatus?
    public var speakerConfidence: Double?

    public var speakerLabel: String? {
        switch speakerStatus {
        case .assigned: speakerName
        case .unknown: "Unknown Speaker"
        case .mixed: "Mixed Speakers"
        case .overlapping: "Overlapping Speakers"
        case nil: nil
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, sessionID, source, start, end, original, language, finalized, createdAt
        case translation, translationStatus, translationError, translationModel, translationModelVersion
        case speakerID = "speaker_id", speakerName = "speaker_name", speakerColor = "speaker_color"
        case speakerStatus = "speaker_status", speakerConfidence = "speaker_confidence"
    }

    public init(id: UUID = UUID(), sessionID: UUID, source: AudioSource, start: Double, end: Double,
                original: String, language: String, finalized: Bool, createdAt: Date = .now,
                translationStatus: TranslationStatus = .disabled) {
        self.id = id
        self.sessionID = sessionID
        self.source = source
        self.start = start
        self.end = end
        self.original = original
        self.language = language
        self.finalized = finalized
        self.createdAt = createdAt
        self.translationStatus = translationStatus
    }
}

public struct CaptionFailure: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum CaptionTime {
    public static func milliseconds(_ seconds: Double) -> Int64 {
        guard seconds.isFinite else { return 0 }
        return Int64(max(0, min(seconds * 1_000, Double(Int64.max / 2))).rounded())
    }

    public static func clock(_ seconds: Double, srt: Bool = false) -> String {
        let ms = milliseconds(seconds)
        let whole = ms / 1_000
        let time = String(format: "%02lld:%02lld:%02lld", whole / 3_600, whole / 60 % 60, whole % 60)
        return srt ? time + String(format: ",%03lld", ms % 1_000) : time
    }
}
