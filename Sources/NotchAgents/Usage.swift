import Foundation

/// Claude Code config directories. A GUI app doesn't inherit the shell's CLAUDE_CONFIG_DIR, so besides
/// ~/.claude (and any ~/.claude-* sibling) we learn directories from hook payloads and remember them.
enum ClaudeDirs {
    private static let key = "claudeConfigDirs"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var learned = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])

    static var all: [URL] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var paths: Set<String> = [home.appendingPathComponent(".claude").path]
        for name in (try? fm.contentsOfDirectory(atPath: home.path)) ?? [] where name.hasPrefix(".claude") {
            paths.insert(home.appendingPathComponent(name).path)
        }
        if let env = LaunchEnvironment.claudeConfigDir, !env.isEmpty { paths.insert(env) }
        lock.lock(); paths.formUnion(learned); lock.unlock()
        return paths.sorted().map { URL(fileURLWithPath: $0) }
            .filter { fm.fileExists(atPath: $0.appendingPathComponent("projects").path) }
    }

    static var projectRoots: [URL] { all.map { $0.appendingPathComponent("projects") } }

    /// `<config>/projects/<project>/<session>.jsonl` → remembers `<config>`.
    static func learn(transcript: String?) {
        guard let t = transcript, let r = t.range(of: "/projects/", options: .backwards) else { return }
        learn(dir: String(t[..<r.lowerBound]))
    }

    static func learn(dir: String?) {
        guard let d = dir, !d.isEmpty else { return }
        let path = (d as NSString).standardizingPath
        lock.lock(); defer { lock.unlock() }
        guard learned.insert(path).inserted else { return }
        UserDefaults.standard.set(Array(learned), forKey: key)
    }

    /// True when any Claude config has the NotchAgents hook registered.
    static var hooksInstalled: Bool {
        all.contains { dir in
            let s = (try? String(contentsOf: dir.appendingPathComponent("settings.json"), encoding: .utf8)) ?? ""
            return s.contains("notch-hook.sh")
        }
    }
}

/// API list prices in $/MTok: input, output, cache read. Cache writes bill at 1.25× input for the
/// 5-minute TTL and 2× for the 1-hour TTL. Subscription plans don't bill per token, so for them this is
/// the API-equivalent value of the usage, which is what Claude Code's own cost readout shows too.
enum Pricing {
    private static let table: [(key: String, input: Double, output: Double, read: Double)] = [
        ("fable-5-1", 10, 50, 0.25), ("mythos-5-1", 10, 50, 0.25), ("fable-5", 10, 50, 1), ("mythos-5", 10, 50, 1),
        ("opus-5-5", 4, 20, 0.20), ("opus-5", 5, 25, 0.50),
        ("opus-4-8", 5, 25, 0.50), ("opus-4-7", 5, 25, 0.50), ("opus-4-6", 5, 25, 0.50), ("opus-4-5", 5, 25, 0.50),
        ("opus-4-1", 15, 75, 1.50), ("opus-4", 15, 75, 1.50), ("3-opus", 15, 75, 1.50),
        ("sonnet-5-5", 2, 10, 0.20), ("sonnet-5", 2, 10, 0.20),
        ("sonnet-4-6", 3, 15, 0.30), ("sonnet-4-5", 3, 15, 0.30), ("sonnet-4", 3, 15, 0.30), ("3-7-sonnet", 3, 15, 0.30), ("3-5-sonnet", 3, 15, 0.30),
        ("haiku-5-5", 0.10, 0.50, 0.01), ("haiku-4-5", 1, 5, 0.10), ("3-5-haiku", 0.80, 4, 0.08), ("3-haiku", 0.25, 1.25, 0.03),
    ].sorted { $0.key.count > $1.key.count }

    static func cost(model: String, usage u: [String: Any]) -> Double? {
        guard let p = table.first(where: { model.contains($0.key) }) else { return nil }
        func n(_ k: String, _ d: [String: Any]) -> Double { (d[k] as? NSNumber)?.doubleValue ?? 0 }
        let written = n("cache_creation_input_tokens", u)
        var w1h = 0.0, w5m = written
        if let cc = u["cache_creation"] as? [String: Any] { w1h = n("ephemeral_1h_input_tokens", cc); w5m = n("ephemeral_5m_input_tokens", cc) }
        let dollars = n("input_tokens", u) * p.input + w5m * p.input * 1.25 + w1h * p.input * 2
            + n("cache_read_input_tokens", u) * p.read + n("output_tokens", u) * p.output
        return dollars / 1e6 * (u["speed"] as? String == "fast" ? 2 : 1)
    }
}

/// Incremental per-transcript spend, so "Today" counts what was spent today (not the lifetime of every
/// session touched today) and live sessions count before Claude writes a cost summary. Claude writes a
/// message's usage once per content block, so entries are de-duplicated by message id.
/// Only touched from the store's serial io queue.
final class UsageLedger: @unchecked Sendable {
    private struct File {
        var offset: UInt64 = 0; var seen = Set<String>(); var byDay: [Int: Double] = [:]; var cost = 0.0; var output = 0
        /// Written by the desktop app's Claude Code (`"entrypoint":"claude-desktop"`), not the CLI.
        var desktop: Bool?
    }
    private var files: [String: File] = [:]
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()

    private static func day(_ d: Date) -> Int {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return (c.year ?? 0) * 10000 + (c.month ?? 0) * 100 + (c.day ?? 0)
    }

    private func update(_ path: String) {
        var f = files[path] ?? File()
        guard let h = FileHandle(forReadingAtPath: path) else { return }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        if size < f.offset { f = File() }  // rewritten
        guard size > f.offset else { files[path] = f; return }
        // Read in bounded chunks: a first pass over a transcript of hundreds of megabytes would
        // otherwise hold all of it in memory at once.
        while f.offset < size {
            try? h.seek(toOffset: f.offset)
            let data = h.readData(ofLength: Int(min(size - f.offset, UInt64(Self.chunk))))
            guard let lastNL = data.lastIndex(of: 0x0A) else {
                // A single line longer than a chunk (a huge tool result): skip past it.
                if data.count == Self.chunk { f.offset += UInt64(data.count); continue }
                break
            }
            f.offset += UInt64(lastNL - data.startIndex + 1)
            scan(data[..<lastNL], into: &f)
        }
        files[path] = f
    }
    private static let chunk = 8 << 20

    private func scan(_ data: Data, into f: inout File) {
        for line in Self.lines(in: data, containing: "\"usage\":{") {
            guard let o = AgentStore.json(line), let m = o["message"] as? [String: Any], let u = m["usage"] as? [String: Any],
                  let model = m["model"] as? String else { continue }
            if f.desktop == nil, let e = o["entrypoint"] as? String { f.desktop = e == "claude-desktop" }
            let id = (m["id"] as? String) ?? (o["requestId"] as? String) ?? (o["uuid"] as? String) ?? UUID().uuidString
            guard f.seen.insert(id).inserted else { continue }
            f.output += (u["output_tokens"] as? NSNumber)?.intValue ?? 0
            guard let c = Pricing.cost(model: model, usage: u) else { continue }
            let when = (o["timestamp"] as? String).flatMap { iso.date(from: $0) } ?? Date()
            f.cost += c
            f.byDay[Self.day(when), default: 0] += c
        }
    }

    /// The lines of `data` that contain `needle`, found with a byte search. Transcripts run to hundreds of
    /// megabytes, almost all tool output, so decoding and splitting every line would dominate the cost.
    static func lines(in data: Data, containing needle: String) -> [Substring] {
        let n = Array(needle.utf8)
        var out: [Substring] = []
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            guard let base = buf.baseAddress, buf.count >= n.count else { return }
            var from = 0
            while from < buf.count, let hit = memmem(base + from, buf.count - from, n, n.count) {
                let at = base.distance(to: hit)
                var start = at, end = at
                while start > 0, buf[start - 1] != 0x0A { start -= 1 }
                while end < buf.count, buf[end] != 0x0A { end += 1 }
                out.append(Substring(String(decoding: UnsafeRawBufferPointer(rebasing: buf[start..<end]), as: UTF8.self)))
                from = end + 1
            }
        }
        return out
    }

    /// Spend and output tokens of one session, including its subagents.
    func session(_ transcript: String) -> (cost: Double, output: Int)? {
        let subdir = (transcript as NSString).deletingPathExtension + "/subagents"
        let subs = ((try? FileManager.default.contentsOfDirectory(atPath: subdir)) ?? [])
            .filter { $0.hasSuffix(".jsonl") }.map { subdir + "/" + $0 }
        var cost = 0.0, output = 0, any = false
        for p in [transcript] + subs {
            update(p)
            if let f = files[p] { cost += f.cost; output += f.output; any = any || !f.seen.isEmpty }
        }
        return any ? (cost, output) : nil
    }

    /// Transcripts written today, from the last full listing.
    private var todayFiles: [String] = []
    private var listed: (day: Int, at: Date)?

    /// Spend across every Claude config, counting only messages sent today, split between the
    /// desktop app's sessions and the CLI's (they're often different accounts).
    func today() -> [AgentKind: Double] {
        let key = Self.day(Date())
        // Listing every project folder is the expensive part, so it happens once a minute (and at
        // midnight); in between only the transcripts already known to be from today are re-read.
        if listed?.day != key || Date().timeIntervalSince(listed?.at ?? .distantPast) > 60 {
            todayFiles = listToday()
            listed = (key, Date())
        }
        var out: [AgentKind: Double] = [:]
        for p in todayFiles {
            update(p)
            if let f = files[p], let c = f.byDay[key] { out[f.desktop == true ? .claudeApp : .claudeCLI, default: 0] += c }
        }
        return out
    }

    private func listToday() -> [String] {
        let fm = FileManager.default
        let start = Calendar.current.startOfDay(for: Date())
        func fresh(_ u: URL) -> Bool { AgentStore.mtime(u) >= start }
        var paths: [String] = []
        for root in ClaudeDirs.projectRoots {
            // Appending to a transcript doesn't touch its directory's mtime, so every project is listed.
            for proj in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
                for item in (try? fm.contentsOfDirectory(at: proj, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
                    if item.pathExtension == "jsonl" { if fresh(item) { paths.append(item.path) } }
                    else {
                        let sub = item.appendingPathComponent("subagents")
                        paths += ((try? fm.contentsOfDirectory(at: sub, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
                            .filter { $0.pathExtension == "jsonl" && fresh($0) }.map(\.path)
                    }
                }
            }
        }
        return paths
    }
}
