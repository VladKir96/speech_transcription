import CSQLite
import Darwin
import Foundation

public actor CaptionRepository {
    public static let maximumPendingTranslations = 64
    private let connection: SQLiteConnection
    private let fileLock: RepositoryLock?
    public nonisolated let location: URL?

    public init(location: URL?, exclusive: Bool = false) throws {
        self.location = location
        if let location {
            try FileManager.default.createDirectory(at: location.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
        }
        fileLock = try (exclusive ? location : nil).map {
            try RepositoryLock($0.appendingPathExtension("lock"))
        }
        connection = try SQLiteConnection(location?.path ?? ":memory:")
        try connection.migrate()
    }

    @discardableResult
    public func recoverInterruptedSessions() throws -> Int {
        try connection.transaction {
            try connection.execute("""
                UPDATE segments SET translation_status = 'failed',
                   translation_error = 'LocalCaption closed before translation finished.'
                WHERE translation_status IN ('pending','translating')
                """)
            try connection.execute("""
                UPDATE sessions SET status = 'interrupted',
                   duration = max(duration, coalesce((SELECT max(end) FROM segments WHERE session_id = sessions.id), 0)),
                   ended = started + max(duration, coalesce((SELECT max(end) FROM segments WHERE session_id = sessions.id), 0))
                WHERE status IN ('preparing','recording','paused','stopping')
                """)
            return connection.changed
        }
    }

    public func create(_ session: CaptionSession) throws {
        let options = try JSONEncoder().encode(session.options)
        try connection.execute("""
            INSERT INTO sessions (id, title, created, started, ended, duration, status, options)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, [
                .text(session.id.uuidString), .text(session.title), .date(session.createdAt), .date(session.startedAt),
                .date(session.endedAt), .number(session.duration), .text(session.status.rawValue), .blob(options)
            ])
    }

    public func update(_ session: CaptionSession) throws {
        try connection.execute("""
            UPDATE sessions SET title = ?, ended = ?, duration = ?, status = ? WHERE id = ?
            """, [.text(session.title), .date(session.endedAt), .number(session.duration),
                  .text(session.status.rawValue), .text(session.id.uuidString)])
    }

    public func rename(_ id: UUID, title: String) throws {
        try connection.execute("UPDATE sessions SET title = ? WHERE id = ?", [.text(title), .text(id.uuidString)])
    }

    public func delete(_ id: UUID) throws {
        try connection.execute("DELETE FROM sessions WHERE id = ?", [.text(id.uuidString)])
    }

    public func deleteHistory(keeping activeSession: UUID?) throws {
        try connection.transaction {
            let inactive = "status NOT IN ('preparing','recording','paused','stopping')"
            if let activeSession {
                try connection.execute("DELETE FROM sessions WHERE \(inactive) AND id != ?", [.text(activeSession.uuidString)])
            } else {
                try connection.execute("DELETE FROM sessions WHERE \(inactive)")
            }
        }
    }

    @discardableResult
    public func insert(_ segments: [TranscriptSegment]) throws -> [TranscriptSegment] {
        guard !segments.isEmpty else { return [] }
        return try connection.transaction {
            var capacity: [UUID: Int] = [:]
            var saved: [TranscriptSegment] = []
            for var segment in segments where segment.finalized {
                if segment.translationStatus == .pending {
                    let available = try capacity[segment.sessionID] ?? availableTranslationSlots(segment.sessionID)
                    capacity[segment.sessionID] = available
                    if available == 0 {
                        segment.translationStatus = .failed
                        segment.translationError = "The translation queue is full. Retry this caption when it catches up."
                    }
                }
                try connection.execute("""
                    INSERT INTO segments (id, session_id, source, start, end, original, language, created,
                                          translation, translation_status, translation_error, searchable,
                                          translation_model, translation_model_version)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO NOTHING
                    """, [
                        .text(segment.id.uuidString), .text(segment.sessionID.uuidString), .text(segment.source.rawValue),
                        .number(segment.start), .number(segment.end), .text(segment.original), .text(segment.language),
                        .date(segment.createdAt), .optional(segment.translation), .text(segment.translationStatus.rawValue),
                        .optional(segment.translationError), .text(Self.searchText(segment.original, segment.translation)),
                        .optional(segment.translationModel?.rawValue), .optional(segment.translationModelVersion)
                    ])
                if connection.changed == 1 {
                    if segment.translationStatus == .pending { capacity[segment.sessionID, default: 0] -= 1 }
                    saved.append(segment)
                }
            }
            return saved
        }
    }

    private func availableTranslationSlots(_ session: UUID) throws -> Int {
        let pending = try connection.query("""
            SELECT count(*) FROM segments WHERE session_id = ? AND translation_status = 'pending'
            """, [.text(session.uuidString)]) { Int($0.number(0)) }.first ?? 0
        return max(0, Self.maximumPendingTranslations - pending)
    }

    @discardableResult
    public func updateTranslation(_ segment: TranscriptSegment, matching request: TranscriptSegment? = nil) throws -> Bool {
        var values: [SQLiteValue] = [
            .optional(segment.translation), .text(segment.translationStatus.rawValue), .optional(segment.translationError),
            .text(Self.searchText(segment.original, segment.translation)), .optional(segment.translationModel?.rawValue),
            .optional(segment.translationModelVersion), .text(segment.id.uuidString), .text(segment.sessionID.uuidString)
        ]
        var condition = ""
        if let request {
            condition = "AND translation_status = 'pending' AND translation_model IS ?"
            values.append(.optional(request.translationModel?.rawValue))
        }
        try connection.execute("""
            UPDATE segments SET translation = ?, translation_status = ?, translation_error = ?, searchable = ?,
                                translation_model = ?, translation_model_version = ?
            WHERE id = ? AND session_id = ? \(condition)
            """, values)
        if request == nil, connection.changed != 1 {
            throw CaptionFailure("The segment could not be found when saving its translation.")
        }
        return connection.changed == 1
    }

    public func retryTranslation(_ id: UUID, session: UUID, model: TranslationModel) throws -> TranscriptSegment? {
        try connection.transaction {
            guard try availableTranslationSlots(session) > 0 else {
                throw CaptionFailure("The translation queue is full. Wait for it to catch up before retrying.")
            }
            let keys: [SQLiteValue] = [.text(id.uuidString), .text(session.uuidString)]
            try connection.execute("""
                UPDATE segments SET translation_status = 'pending', translation_error = NULL,
                                    translation_model = ?, translation_model_version = ?
                WHERE id = ? AND session_id = ? AND translation_status = 'failed'
                """, [.text(model.rawValue), .optional(model.version)] + keys)
            guard connection.changed == 1 else { return nil }
            return try connection.query("""
                SELECT \(Self.segmentColumns) FROM segments WHERE id = ? AND session_id = ?
                """, keys, readSegment).first
        }
    }

    public func pendingTranslations(_ id: UUID, limit: Int = 1) throws -> [TranscriptSegment] {
        try connection.query("""
            SELECT \(Self.segmentColumns) FROM segments
            WHERE session_id = ? AND translation_status = 'pending'
            ORDER BY start, end, id LIMIT ?
            """, [.text(id.uuidString), .number(Double(limit))], readSegment)
    }

    public func completePendingTranslations(_ id: UUID, reason: String) throws {
        try connection.execute("""
            UPDATE segments SET translation_status = 'failed', translation_error = ?
            WHERE session_id = ? AND translation_status = 'pending'
            """, [.text(reason), .text(id.uuidString)])
    }

    public func sessions(limit: Int = 100, offset: Int = 0) throws -> [CaptionSession] {
        try connection.query("""
            SELECT \(Self.sessionColumns) FROM sessions ORDER BY started DESC, id LIMIT ? OFFSET ?
            """, [.number(Double(limit)), .number(Double(offset))], readSession)
    }

    public func session(_ id: UUID) throws -> CaptionSession? {
        try connection.query("SELECT \(Self.sessionColumns) FROM sessions WHERE id = ?",
                             [.text(id.uuidString)], readSession).first
    }

    public func segments(_ id: UUID, source: AudioSource? = nil, search: String = "",
                         limit: Int = -1, offset: Int = 0, newestFirst: Bool = false,
                         before: TranscriptSegment? = nil) throws -> [TranscriptSegment] {
        var filters = ["session_id = ?"]
        var values: [SQLiteValue] = [.text(id.uuidString)]
        if let source {
            filters.append("source = ?")
            values.append(.text(source.rawValue))
        }
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !term.isEmpty {
            filters.append("instr(searchable, ?) > 0")
            values.append(.text(Self.searchText(term, nil)))
        }
        if let before {
            filters.append("(start, end, id) < (?, ?, ?)")
            values += [.number(before.start), .number(before.end), .text(before.id.uuidString)]
        }
        values += [.number(Double(limit)), .number(Double(offset))]
        let order = newestFirst ? "start DESC, end DESC, id DESC" : "start, end, id"
        return try connection.query("""
            SELECT \(Self.segmentColumns) FROM segments WHERE \(filters.joined(separator: " AND "))
            ORDER BY \(order) LIMIT ? OFFSET ?
            """, values, readSegment)
    }

    private static let sessionColumns = "id, title, created, started, ended, duration, status, options"
    private static let segmentColumns = """
        id, session_id, source, start, end, original, language, created, translation, translation_status, translation_error,
        translation_model, translation_model_version
        """

    private static func searchText(_ original: String, _ translation: String?) -> String {
        [original, translation].compactMap { $0 }.joined(separator: "\n")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private func readSession(_ row: SQLiteRow) throws -> CaptionSession {
        guard let id = UUID(uuidString: row.text(0)), let status = SessionPhase(rawValue: row.text(6)) else {
            throw CaptionFailure("A saved session contains invalid metadata.")
        }
        let options = try JSONDecoder().decode(SessionOptions.self, from: row.data(7))
        let started = Date(timeIntervalSince1970: row.number(3))
        var session = CaptionSession(id: id, title: row.text(1), date: started, options: options,
                                     createdAt: Date(timeIntervalSince1970: row.number(2)))
        session.endedAt = row.isNull(4) ? nil : Date(timeIntervalSince1970: row.number(4))
        session.duration = row.number(5)
        session.status = status
        return session
    }

    private func readSegment(_ row: SQLiteRow) throws -> TranscriptSegment {
        guard let id = UUID(uuidString: row.text(0)), let sessionID = UUID(uuidString: row.text(1)),
              let source = AudioSource(rawValue: row.text(2)),
              let translation = TranslationStatus(rawValue: row.text(9)) else {
            throw CaptionFailure("A transcript segment contains invalid metadata.")
        }
        var result = TranscriptSegment(id: id, sessionID: sessionID, source: source, start: row.number(3),
                                       end: row.number(4), original: row.text(5), language: row.text(6),
                                       finalized: true, createdAt: Date(timeIntervalSince1970: row.number(7)),
                                       translationStatus: translation)
        result.translation = row.optional(8)
        result.translationError = row.optional(10)
        result.translationModel = row.optional(11).flatMap(TranslationModel.init(rawValue:))
        result.translationModelVersion = row.optional(12)
        return result
    }
}

private final class RepositoryLock: Sendable {
    let descriptor: Int32

    init(_ file: URL) throws {
        let descriptor = file.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        }
        guard descriptor >= 0 else {
            throw CaptionFailure("Could not open the transcript lock. Check access to the application data folder.")
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw CaptionFailure("Another LocalCaption instance is already using this transcript library.")
        }
        self.descriptor = descriptor
    }

    deinit { close(descriptor) }
}

private enum SQLiteValue {
    case null, text(String), number(Double), blob(Data)
    static func optional(_ string: String?) -> Self { string.map(Self.text) ?? .null }
    static func date(_ date: Date?) -> Self { date.map { .number($0.timeIntervalSince1970) } ?? .null }
}

private struct SQLiteRow {
    let statement: OpaquePointer
    func isNull(_ index: Int32) -> Bool { sqlite3_column_type(statement, index) == SQLITE_NULL }
    func number(_ index: Int32) -> Double { sqlite3_column_double(statement, index) }
    func optional(_ index: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, index) else { return nil }
        let bytes = UnsafeBufferPointer(start: value, count: Int(sqlite3_column_bytes(statement, index)))
        return String(decoding: bytes, as: UTF8.self)
    }
    func text(_ index: Int32) -> String { optional(index) ?? "" }
    func data(_ index: Int32) -> Data {
        guard let blob = sqlite3_column_blob(statement, index) else { return Data() }
        return Data(bytes: blob, count: Int(sqlite3_column_bytes(statement, index)))
    }
}

// Owned by a single CaptionRepository actor.
private final class SQLiteConnection: @unchecked Sendable {
    private let handle: OpaquePointer
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(_ path: String) throws {
        var database: OpaquePointer?
        let status = sqlite3_open_v2(path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK, let database else {
            let reason = database.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            sqlite3_close(database)
            throw CaptionFailure("Could not open the local database. \(reason)")
        }
        handle = database
        sqlite3_busy_timeout(handle, 2_000)
        try script("PRAGMA foreign_keys = ON; PRAGMA journal_mode = WAL; PRAGMA synchronous = FULL;")
    }

    deinit { sqlite3_close(handle) }
    var changed: Int { Int(sqlite3_changes(handle)) }

    func migrate() throws {
        let version = try query("PRAGMA user_version", [], { Int($0.number(0)) }).first ?? 0
        guard version <= 2 else { throw CaptionFailure("This database was created by a newer version of LocalCaption.") }
        if version == 0 {
            try transaction {
                try script("""
                    CREATE TABLE sessions (
                        id TEXT PRIMARY KEY, title TEXT NOT NULL, created REAL NOT NULL, started REAL NOT NULL,
                        ended REAL, duration REAL NOT NULL CHECK(duration >= 0), status TEXT NOT NULL,
                        options BLOB NOT NULL
                    );
                    CREATE INDEX sessions_chronological ON sessions(started DESC, id);
                    CREATE TABLE segments (
                        id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                        source TEXT NOT NULL, start REAL NOT NULL CHECK(start >= 0), end REAL NOT NULL CHECK(end >= start),
                        original TEXT NOT NULL, language TEXT NOT NULL, created REAL NOT NULL,
                        translation TEXT, translation_status TEXT NOT NULL, translation_error TEXT, searchable TEXT NOT NULL
                    );
                    CREATE INDEX segments_chronological ON segments(session_id, start, end, id);
                    CREATE INDEX segments_by_source ON segments(session_id, source, start, end, id);
                    CREATE INDEX segments_pending ON segments(session_id, start, end, id)
                        WHERE translation_status = 'pending';
                    PRAGMA user_version = 1;
                    """)
            }
        }
        if version <= 1 {
            try transaction {
                try script("""
                    ALTER TABLE segments ADD COLUMN translation_model TEXT;
                    ALTER TABLE segments ADD COLUMN translation_model_version TEXT;
                    PRAGMA user_version = 2;
                    """)
            }
        }
    }

    func transaction<T>(_ block: () throws -> T) throws -> T {
        try script("BEGIN IMMEDIATE;")
        do {
            let result = try block()
            try script("COMMIT;")
            return result
        } catch {
            try? script("ROLLBACK;")
            throw error
        }
    }

    func execute(_ sql: String, _ values: [SQLiteValue] = []) throws {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }

    func query<T>(_ sql: String, _ values: [SQLiteValue], _ read: (SQLiteRow) throws -> T) throws -> [T] {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        var results: [T] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            results.append(try read(SQLiteRow(statement: statement)))
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw failure() }
        return results
    }

    private func script(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }

    private func prepare(_ sql: String, _ values: [SQLiteValue]) throws -> OpaquePointer {
        var output: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &output, nil) == SQLITE_OK, let output else { throw failure() }
        do {
            for (offset, value) in values.enumerated() {
                let index = Int32(offset + 1)
                let status: Int32
                switch value {
                case .null: status = sqlite3_bind_null(output, index)
                case .number(let number): status = sqlite3_bind_double(output, index, number)
                case .text(let text):
                    status = text.withCString {
                        sqlite3_bind_text(output, index, $0, Int32(text.utf8.count), transient)
                    }
                case .blob(let data):
                    status = data.withUnsafeBytes {
                        sqlite3_bind_blob(output, index, $0.baseAddress, Int32($0.count), transient)
                    }
                }
                guard status == SQLITE_OK else { throw failure() }
            }
            return output
        } catch {
            sqlite3_finalize(output)
            throw error
        }
    }

    private func failure() -> CaptionFailure {
        CaptionFailure("Local database error. \(String(cString: sqlite3_errmsg(handle))). Check available disk space and the data folder.")
    }
}
