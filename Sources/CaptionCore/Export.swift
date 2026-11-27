import Foundation

public enum TranscriptExport {
    public static func write(_ session: CaptionSession, segments: [TranscriptSegment],
                             format: ExportFormat, display: CaptionDisplay, includeSpeakerNames: Bool = true,
                             to url: URL) async throws {
        let task = Task.detached(priority: .utility) {
            let data = try render(session, segments: segments, format: format, display: display,
                                  includeSpeakerNames: includeSpeakerNames)
            try data.write(to: url, options: .atomic)
        }
        try await task.value
    }

    public static func render(_ session: CaptionSession, segments: [TranscriptSegment],
                              format: ExportFormat, display: CaptionDisplay = .both,
                              includeSpeakerNames: Bool = true) throws -> Data {
        let ordered = segments.filter(\.finalized).sorted {
            ($0.start, $0.end, $0.source.rawValue, $0.id.uuidString) <
                ($1.start, $1.end, $1.source.rawValue, $1.id.uuidString)
        }
        switch format {
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            return try encoder.encode(JSONExport(session: session, segments: ordered))
        case .txt:
            let heading = "\(session.title)\n\(session.startedAt.formatted(.iso8601))"
            let transcript = ordered.compactMap { segment -> String? in
                let lines = lines(segment, display: display)
                guard !lines.isEmpty else { return nil }
                let span = "\(CaptionTime.clock(segment.start)) – \(CaptionTime.clock(segment.end))"
                let speaker = segment.speakerLabel.map { " [\($0)]" } ?? ""
                return "[\(span)] \(segment.source.title) (\(segment.language))\(speaker)\n" + lines.joined(separator: "\n")
            }
            return Data(([heading] + transcript).joined(separator: "\n\n").appending("\n").utf8)
        case .srt:
            return Data(srt(ordered, display: display, includeSpeakerNames: includeSpeakerNames).utf8)
        }
    }

    private struct JSONExport: Encodable {
        let schemaVersion = 1
        let session: CaptionSession
        let segments: [TranscriptSegment]
    }

    private static func lines(_ segment: TranscriptSegment, display: CaptionDisplay) -> [String] {
        let translation = segment.translation ?? (segment.translationStatus == .sameLanguage ? segment.original : nil)
        switch display {
        case .original: return [segment.original]
        case .translated: return translation.map { [$0] } ?? []
        case .both:
            return [segment.original] + (segment.translation.map { [$0] } ?? [])
        }
    }

    private struct Event {
        let time: Int64
        let index: Int
        let begin: Bool
    }

    private static func srt(_ segments: [TranscriptSegment], display: CaptionDisplay, includeSpeakerNames: Bool) -> String {
        var events: [Event] = []
        var captions: [Int: String] = [:]
        for (index, segment) in segments.enumerated() {
            let text = lines(segment, display: display).map(srtText).filter { !$0.isEmpty }
            guard !text.isEmpty else { continue }
            let start = CaptionTime.milliseconds(segment.start)
            let end = max(start + 1, CaptionTime.milliseconds(segment.end))
            let speaker = includeSpeakerNames ? segment.speakerLabel.map { srtText($0) + ": " } : nil
            captions[index] = "\(segment.source.title) · " + (speaker ?? "") + text.joined(separator: "\n")
            events.append(Event(time: start, index: index, begin: true))
            events.append(Event(time: end, index: index, begin: false))
        }
        events.sort { $0.time < $1.time }
        var active: Set<Int> = []
        var cues: [String] = []
        var cursor = 0
        var last = events.first?.time ?? 0
        while cursor < events.count {
            let now = events[cursor].time
            if now > last, !active.isEmpty {
                let start = CaptionTime.clock(Double(last) / 1_000, srt: true)
                let end = CaptionTime.clock(Double(now) / 1_000, srt: true)
                let text = active.sorted().compactMap { captions[$0] }.joined(separator: "\n")
                cues.append("\(cues.count + 1)\n\(start) --> \(end)\n\(text)\n")
            }
            while cursor < events.count, events[cursor].time == now {
                let event = events[cursor]
                if event.begin { active.insert(event.index) } else { active.remove(event.index) }
                cursor += 1
            }
            last = now
        }
        return cues.joined(separator: "\n")
    }

    private static func srtText(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .replacingOccurrences(of: "-->", with: "→")
            .replacingOccurrences(of: "<", with: "‹")
            .replacingOccurrences(of: ">", with: "›")
    }
}
