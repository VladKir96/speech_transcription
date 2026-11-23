import Foundation
import Testing
@testable import CaptionCore

@Test func samplesStayOrderedAcrossCompaction() throws {
    var buffer = SampleBuffer()
    buffer.append((0..<10_000).map(Float.init))
    #expect(buffer.take(0) == nil)
    #expect(buffer.take(10_001) == nil)
    let taken = buffer.take(6_500)
    let first = try #require(taken)
    #expect(first.last == 6_499)
    buffer.append([10_000, 10_001])
    let remainder = buffer.take(3_502)
    #expect(remainder?.last == 10_001)
    #expect(buffer.count == 0)
    buffer.append([1, 2])
    buffer.reset()
    #expect(buffer.count == 0)
}

@Test func timestampsRoundWithoutInvalidSeconds() {
    #expect(CaptionTime.clock(59.9996, srt: true) == "00:01:00,000")
    #expect(CaptionTime.clock(7_201.234, srt: true) == "02:00:01,234")
    #expect(CaptionTime.clock(-1) == "00:00:00")
    #expect(CaptionTime.milliseconds(.infinity) == 0)
}

@Test func sessionTransitionsRejectInvalidOperations() {
    #expect(SessionPhase.idle.allows(.preparing))
    #expect(!SessionPhase.idle.allows(.recording))
    #expect(SessionPhase.recording.allows(.paused))
    #expect(SessionPhase.paused.allows(.preparing))
    #expect(SessionPhase.stopping.allows(.completed))
    #expect(!SessionPhase.stopping.allows(.recording))
    #expect(!SessionPhase.completed.allows(.paused))
}

@Test func overlapReconciliationPreservesLaterRepetition() {
    let pieces = [
        RecognitionPiece(text: "word", start: 0, end: 0.15),
        RecognitionPiece(text: "hello again", start: 0.16, end: 0.9),
        RecognitionPiece(text: "hello again", start: 1, end: 1.8),
        RecognitionPiece(text: "noise", start: 2, end: 5, noSpeech: 0.9)
    ]
    let output = TranscriptReconciler.pieces(pieces, duration: 2, overlap: 0.25, previous: "Say hello")
    #expect(output.map(\.text) == ["again", "hello again"])
    #expect(output.first?.start == 0.25)
}

@Test func sqliteRecoversAnInterruptedSessionAndKeepsFinalizedText() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("transcripts.sqlite3")
    let id = UUID()
    do {
        let repository = try CaptionRepository(location: url)
        let session = CaptionSession(id: id, title: "Original", date: Date(timeIntervalSince1970: 100), options: SessionOptions())
        try await repository.create(session)
        let final = makeSegment(id, text: "Привет, Москва!", status: .pending)
        let partial = TranscriptSegment(sessionID: id, source: .system, start: 1, end: 2, original: "tentative",
                                        language: "en", finalized: false)
        try await repository.insert([final, partial, final])
        #expect(try await repository.segments(id, search: "МОСКВА").count == 1)
        try await repository.rename(id, title: "Renamed")
    }
    let repository = try CaptionRepository(location: url)
    #expect(try await repository.recoverInterruptedSessions() == 1)
    #expect(try await repository.recoverInterruptedSessions() == 0)
    let restored = try #require(try await repository.session(id))
    #expect(restored.status == .interrupted)
    #expect(restored.title == "Renamed")
    #expect(restored.duration == 3)
    #expect(restored.endedAt == Date(timeIntervalSince1970: 103))
    let segments = try await repository.segments(id)
    #expect(segments.count == 1)
    #expect(segments.first?.translationStatus == .failed)
    try await repository.delete(id)
    #expect(try await repository.segments(id).isEmpty)
}

@Test func errorsRollBackSegmentBatch() async throws {
    let repository = try CaptionRepository(location: nil)
    let session = CaptionSession(title: "Rollback", options: SessionOptions())
    try await repository.create(session)
    let valid = makeSegment(session.id, text: "Saved")
    let invalid = makeSegment(UUID(), text: "Missing session")
    await #expect(throws: CaptionFailure.self) { try await repository.insert([valid, invalid]) }
    #expect(try await repository.segments(session.id).isEmpty)
}

@Test func deletingSavedHistoryKeepsActiveCaptionsAndCascadesAfterReopening() async throws {
    let location = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: location) }
    let database = location.appendingPathComponent("history.sqlite3")
    let repository = try CaptionRepository(location: database)
    var saved = CaptionSession(title: "Saved", options: SessionOptions())
    saved.status = .completed
    var active = CaptionSession(title: "Active", options: SessionOptions())
    active.status = .recording
    try await repository.create(saved)
    try await repository.create(active)
    var translated = TranscriptSegment(sessionID: saved.id, source: .system, start: 0, end: 1,
        original: "Hello", language: "en", finalized: true, translationStatus: .translated)
    translated.translation = "Привет"
    let current = TranscriptSegment(sessionID: active.id, source: .microphone, start: 0, end: 1,
        original: "Live", language: "en", finalized: true)
    try await repository.insert([translated, current])
    try await repository.deleteHistory(keeping: active.id)
    let reopened = try CaptionRepository(location: database)
    #expect(try await reopened.sessions().map(\.id) == [active.id])
    #expect(try await reopened.segments(saved.id).isEmpty)
    #expect(try await reopened.segments(active.id).map(\.id) == [current.id])
    active.status = .completed
    try await reopened.update(active)
    try await reopened.deleteHistory(keeping: nil)
    try await reopened.deleteHistory(keeping: nil)
    #expect(try await repository.sessions().isEmpty)
    #expect(try await repository.segments(active.id).isEmpty)
}

@Test func captionPagesStayNewestFirstWithStableTiesAndNewArrivals() async throws {
    let repository = try CaptionRepository(location: nil)
    let session = CaptionSession(title: "Order", options: SessionOptions())
    try await repository.create(session)
    let tags = try (1...4).map { index in
        let id = try #require(UUID(uuidString: "00000000-0000-0000-0000-00000000000\(index)"))
        let start = index <= 2 ? 0.0 : Double(index)
        return TranscriptSegment(id: id, sessionID: session.id, source: .system, start: start,
            end: start + 1, original: String(index), language: "en", finalized: true)
    }
    try await repository.insert(Array(tags.prefix(3)))
    let first = try await repository.segments(session.id, limit: 2, newestFirst: true)
    #expect(first.map(\.original) == ["3", "2"])
    try await repository.insert([tags[3]])
    let next = try await repository.segments(session.id, newestFirst: true, before: try #require(first.last))
    #expect(next.map(\.original) == ["1"])
    #expect(try await repository.segments(session.id).map(\.original) == ["1", "2", "3", "4"])
}

@Test func pendingTranslationOrderingUsesSessionTimeline() async throws {
    let repository = try CaptionRepository(location: nil)
    let session = CaptionSession(title: "Ordering", options: SessionOptions())
    try await repository.create(session)
    let later = makeSegment(session.id, text: "later", start: 5, end: 6, status: .pending)
    var earlier = makeSegment(session.id, source: .microphone, text: "earlier", status: .pending)
    try await repository.insert([later, earlier])
    #expect(try await repository.pendingTranslations(session.id, limit: 2).map(\.id) == [earlier.id, later.id])
    earlier.translation = "Раньше"
    earlier.translationStatus = .translated
    try await repository.updateTranslation(earlier)
    #expect(try await repository.pendingTranslations(session.id).map(\.id) == [later.id])
    #expect(try await repository.segments(session.id, search: "РАНЬШЕ").map(\.id) == [earlier.id])
}

@Test func exportSplitsOverlappingSubtitlesChronologically() throws {
    let session = CaptionSession(title: "Export", options: SessionOptions())
    let system = makeSegment(session.id, text: "Desktop", start: 1, end: 3)
    var mic = makeSegment(session.id, source: .microphone, text: "Microphone cue", start: 2, end: 4)
    mic.translation = "Перевод"
    mic.translationStatus = .translated
    let data = try TranscriptExport.render(session, segments: [mic, system], format: .srt)
    let srt = String(decoding: data, as: UTF8.self)
    #expect(srt.contains("1\n00:00:01,000 --> 00:00:02,000\nSystem Audio · Desktop"))
    #expect(srt.contains("2\n00:00:02,000 --> 00:00:03,000\nSystem Audio · Desktop\nMicrophone · Microphone cue\nПеревод"))
    #expect(srt.contains("3\n00:00:03,000 --> 00:00:04,000\nMicrophone · Microphone cue"))
    let json = try TranscriptExport.render(session, segments: [mic, system], format: .json)
    let object = try #require(JSONSerialization.jsonObject(with: json) as? [String: Any])
    #expect(object["schemaVersion"] as? Int == 1)
    #expect((object["segments"] as? [[String: Any]])?.first?["source"] as? String == "system")
    let txt = String(decoding: try TranscriptExport.render(session, segments: [mic, system], format: .txt), as: UTF8.self)
    #expect(txt.hasPrefix("Export\n"))
    #expect(txt.contains("Перевод"))
}

@Test func modelValidationRejectsTruncatedAndModifiedAssets() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("test")
    let asset = ModelDescriptor.Asset(name: "test", url: file,
        sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", bytes: 3)
    try Data("abc".utf8).write(to: file)
    try ModelStore.validate(file, asset: asset)
    try Data("ab".utf8).write(to: file)
    #expect(throws: CaptionFailure.self) { try ModelStore.validate(file, asset: asset) }
    try Data("abd".utf8).write(to: file)
    #expect(throws: CaptionFailure.self) { try ModelStore.validate(file, asset: asset) }
}

private func makeSegment(_ id: UUID, source: AudioSource = .system, text: String,
                         start: Double = 1, end: Double = 3, status: TranslationStatus = .disabled) -> TranscriptSegment {
    TranscriptSegment(sessionID: id, source: source, start: start, end: end, original: text, language: "en",
                      finalized: true, translationStatus: status)
}

@Test func exclusiveTranscriptLibraryRejectsASecondOwner() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("local.sqlite3")
    let repository = try CaptionRepository(location: file, exclusive: true)
    #expect(throws: CaptionFailure.self) { _ = try CaptionRepository(location: file, exclusive: true) }
    #expect(try await repository.sessions().isEmpty)
}
