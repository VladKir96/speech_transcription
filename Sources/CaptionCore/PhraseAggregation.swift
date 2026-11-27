import Foundation

struct PhraseAggregation {
    static let maximumDuration = 15.0

    let pause: Double
    let strategy: TranslationStrategy
    private(set) var pending: TranscriptSegment?

    mutating func refreshPending(using diarization: DiarizationSession) {
        if let pending, pending.speakerStatus == .unknown {
            self.pending = diarization.refresh(pending)
        }
    }

    mutating func accept(_ next: TranscriptSegment, respectSpeakers: Bool = true) -> TranscriptSegment? {
        guard let current = pending else {
            pending = next
            return nil
        }
        guard canJoin(current, next), !respectSpeakers || speakerCompatible(current, next) else {
            pending = next
            return current
        }
        let text = current.original.reversed().drop(while: { ".… ".contains($0) }).reversed()
        let joined = String(text) + " " + next.original
        var combined = TranscriptSegment(id: current.id, sessionID: current.sessionID, source: current.source,
            start: current.start, end: next.end, original: joined,
            language: current.language, finalized: true, createdAt: current.createdAt,
            translationStatus: current.translationStatus)
        if current.speakerStatus == next.speakerStatus, current.speakerID == next.speakerID {
            combined.speakerID = current.speakerID
            combined.speakerName = current.speakerName
            combined.speakerColor = current.speakerColor
            combined.speakerStatus = current.speakerStatus
            combined.speakerConfidence = zipConfidence(current.speakerConfidence, next.speakerConfidence)
        } else if current.speakerStatus == .overlapping || next.speakerStatus == .overlapping {
            combined.speakerStatus = .overlapping
        } else if current.speakerStatus == .mixed || next.speakerStatus == .mixed
                    || (current.speakerID != nil && next.speakerID != nil) {
            combined.speakerStatus = .mixed
        } else if current.speakerStatus != nil, next.speakerStatus != nil {
            combined.speakerStatus = .unknown
        }
        pending = combined
        return nil
    }

    private func speakerCompatible(_ first: TranscriptSegment, _ second: TranscriptSegment) -> Bool {
        if (first.speakerStatus == nil) != (second.speakerStatus == nil) { return false }
        if [first.speakerStatus, second.speakerStatus].contains(where: { $0 == .mixed || $0 == .overlapping }) {
            return false
        }
        if let a = first.speakerID, let b = second.speakerID { return a == b }
        return true
    }

    private func zipConfidence(_ first: Double?, _ second: Double?) -> Double? {
        guard let first, let second else { return nil }
        return min(first, second)
    }

    mutating func finish() -> TranscriptSegment? {
        defer { pending = nil }
        return pending
    }

    private func canJoin(_ current: TranscriptSegment, _ next: TranscriptSegment) -> Bool {
        let gap = max(0, next.start - current.end)
        guard current.source == next.source, current.sessionID == next.sessionID, current.language == next.language,
              gap < pause, next.end - current.start <= Self.maximumDuration else { return false }

        let end = current.original.trimmingCharacters(in: CharacterSet(charactersIn: "\"'”’»)]}"))
        let ending = end.last
        let continuation = next.original.first(where: \.isLetter)?.isLowercase == true
        let starter = startsNewThought(next)
        let softEnd = end.hasSuffix("…") || end.hasSuffix("...") || endsWithConnector(current)
        if softEnd { return !starter || continuation }
        if let ending, "!?。！？؟।".contains(ending) { return false }
        if ending == "." {
            // Whisper sometimes supplies a period at a recognition boundary inside a clause.
            return continuation && !starter && gap < min(pause, strategy == .fast ? 0.25 : 0.55)
        }
        // A new clause after a pause can be complete even when Whisper omitted its punctuation.
        return !starter || continuation || gap < (strategy == .contextAware ? 0.65 : 0.35)
    }

    private func endsWithConnector(_ segment: TranscriptSegment) -> Bool {
        let word = words(segment.original).last
        switch segment.language {
        case "en": return ["and", "or", "because", "if", "we", "should", "could", "would", "to", "the", "a", "of", "that"].contains(word ?? "")
        case "ru": return ["и", "или", "но", "что", "чтобы", "если", "в", "на", "с", "к", "для", "следует", "нужно", "бы", "мы", "нам"].contains(word ?? "")
        default: return false
        }
    }

    private func startsNewThought(_ segment: TranscriptSegment) -> Bool {
        let beginning = words(segment.original).prefix(2).joined(separator: " ")
        switch segment.language {
        case "en":
            return ["thank you", "good morning", "good evening", "next question", "now let", "okay so"].contains(beginning)
        case "ru":
            return ["доброе утро", "добрый вечер", "следующий вопрос", "а теперь", "всем спасибо"].contains(beginning)
        default: return false
        }
    }

    private func words(_ text: String) -> [Substring] {
        text.lowercased().split { !$0.isLetter }
    }
}
