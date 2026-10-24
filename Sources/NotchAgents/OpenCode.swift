import Foundation
import SQLite3

/// What OpenCode's own database says about its current session: OpenCode keeps sessions, messages
/// and tool calls in SQLite (`~/.local/share/opencode/opencode.db`), so its status, tool activity,
/// model and cost can be shown like Claude's and Codex's. Opened read-only; never written.
struct OpenCodeSnapshot: Equatable {
    struct Step: Equatable { var tool: String; var detail: String?; var date: Date; var done: Bool }

    var status: AgentStatus = .idle
    var tool: String?
    var detail: String?
    var model: String?
    var cwd: String?
    var cost: Double?
    var tokens = 0
    var turnStart: Date?
    /// Newest first, at most 4.
    var steps: [Step] = []
}

enum OpenCodeReader {
    /// A turn whose last write is older than this was abandoned (OpenCode quit mid-turn).
    private static let staleAfter: TimeInterval = 600

    /// `opencode.db`, or a channel's own `opencode-<channel>.db` (preview builds keep theirs apart):
    /// whichever was written last.
    static var database: URL {
        let env = ProcessInfo.processInfo.environment["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        let dir = (env ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share"))
            .appendingPathComponent("opencode")
        let dbs = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasPrefix("opencode") && $0.hasSuffix(".db") }
            .map { dir.appendingPathComponent($0) }
        return dbs.max { written($0.path) < written($1.path) } ?? dir.appendingPathComponent("opencode.db")
    }

    private static func written(_ db: String) -> Date {
        [db, db + "-wal"].compactMap { try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate] as? Date }.max() ?? .distantPast
    }

    /// Last-modified time of the database or its write-ahead log, whichever is newer: changes when OpenCode writes.
    static func stamp() -> Date? {
        let d = written(database.path)
        return d == .distantPast ? nil : d
    }

    /// The top-level session to show: one with a turn in progress (in a TUI, `opencode run`, or an app
    /// hosting OpenCode), else the newest in `cwd` (the running process's folder), else the newest.
    static func read(cwd: String?) -> OpenCodeSnapshot? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db); return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 200)

        guard let session = rows(db, """
            SELECT id, directory, model, cost, tokens_output, time_updated FROM session
            WHERE parent_id IS NULL AND time_archived IS NULL
            ORDER BY (time_updated > ?2 AND (
                SELECT json_extract(m.data, '$.role') = 'user' OR json_extract(m.data, '$.time.completed') IS NULL
                FROM message m WHERE m.session_id = session.id ORDER BY m.time_created DESC LIMIT 1)) DESC,
              (directory = ?1) DESC, time_updated DESC LIMIT 1
            """, [cwd ?? "", String(Int((Date().timeIntervalSince1970 - staleAfter) * 1000))]).first, let sid = session[0] else { return nil }

        var snap = OpenCodeSnapshot()
        snap.cwd = session[1]
        snap.model = session[2].flatMap(json).flatMap { $0["id"] as? String }
        snap.cost = session[3].flatMap(Double.init).flatMap { $0 > 0 ? $0 : nil }
        snap.tokens = session[4].flatMap { Int($0) } ?? 0
        let updated = date(session[5])

        let last = rows(db, "SELECT data FROM message WHERE session_id = ?1 ORDER BY time_created DESC LIMIT 1", [sid])
            .first?[0].flatMap(json)
        let prompt = rows(db, """
            SELECT time_created FROM message WHERE session_id = ?1 AND json_extract(data, '$.role') = 'user'
            ORDER BY time_created DESC LIMIT 1
            """, [sid]).first.flatMap { date($0[0]) }
        if let m = last?["modelID"] as? String { snap.model = m }

        // Busy while the newest message is a prompt awaiting its reply, or a reply still being written.
        let role = last?["role"] as? String
        let completed = (last?["time"] as? [String: Any])?["completed"] != nil
        let fresh = updated.map { Date().timeIntervalSince($0) < staleAfter } ?? false
        let busy = fresh && (role == "user" || (role == "assistant" && !completed))

        let parts = rows(db, "SELECT data, time_created FROM part WHERE session_id = ?1 ORDER BY time_created DESC LIMIT 16", [sid])
            .compactMap { r -> (part: [String: Any], date: Date)? in
                guard let p = r[0].flatMap(json), let d = date(r[1]) else { return nil }
                return (p, d)
            }
        for (p, d) in parts where p["type"] as? String == "tool" {
            let state = p["state"] as? [String: Any] ?? [:]
            let status = state["status"] as? String ?? ""
            let name = (p["tool"] as? String ?? "tool").capitalizedFirst
            snap.steps.append(.init(tool: name, detail: detail(state["input"] as? [String: Any] ?? [:]), date: d,
                                    done: status == "completed" || status == "error" || !busy))
            if snap.steps.count == 4 { break }
        }

        if busy {
            snap.turnStart = prompt
            if let newest = parts.first, newest.part["type"] as? String == "tool",
               let step = snap.steps.first, !step.done {
                snap.status = .tool; snap.tool = step.tool; snap.detail = step.detail
            } else {
                snap.status = .thinking
            }
        }
        return snap
    }

    /// OpenCode's tool inputs use camelCase (`filePath`); summarise them like Claude's.
    private static func detail(_ input: [String: Any]) -> String? {
        var mapped = input
        if let p = input["filePath"] { mapped["file_path"] = p }
        return AgentStore.summarize(mapped)
    }

    private static func json(_ s: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any]
    }

    /// OpenCode stores times as Unix milliseconds.
    private static func date(_ s: String?) -> Date? {
        s.flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) }
    }

    /// Runs a query with text parameters; every column comes back as text (nil for NULL).
    private static func rows(_ db: OpaquePointer?, _ sql: String, _ params: [String]) -> [[String?]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, p) in params.enumerated() { sqlite3_bind_text(stmt, Int32(i + 1), p, -1, transient) }
        var out: [[String?]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append((0..<sqlite3_column_count(stmt)).map { c in
                sqlite3_column_text(stmt, c).map { String(cString: $0) }
            })
        }
        return out
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
