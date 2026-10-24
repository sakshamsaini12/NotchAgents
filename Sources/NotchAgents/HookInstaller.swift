import Foundation

/// Installs the Claude Code hooks from inside the app, for people who got NotchAgents from the DMG
/// instead of running ./build.sh. Mirrors hooks/install_hooks.py: settings are only rewritten when
/// something changes, backed up first, written atomically, and existing hooks and status lines are kept.
enum HookInstaller {
    private static let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                                 "Notification", "PermissionRequest", "Stop", "SubagentStop", "SessionEnd"]
    private static let toolEvents: Set<String> = ["PreToolUse", "PostToolUse", "PermissionRequest"]

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    private static var dir: URL { home.appendingPathComponent(".notchagents") }

    /// Shell-quoted like Python's shlex.quote, since Claude Code runs the command through a shell.
    private static func quote(_ s: String) -> String {
        s.allSatisfy({ $0.isLetter || $0.isNumber || "@%+=:,./-_".contains($0) }) ? s
            : "'" + s.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    /// Copies the hook scripts out of the app bundle and registers them. Returns false if nothing could be installed.
    @discardableResult
    static func install() -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        for name in ["notch-hook", "notch-status"] {
            guard let src = Bundle.main.url(forResource: name, withExtension: "sh") else { return false }
            let dst = dir.appendingPathComponent("\(name).sh")
            try? fm.removeItem(at: dst)
            guard (try? fm.copyItem(at: src, to: dst)) != nil else { return false }
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dst.path)
        }
        let hookPath = dir.appendingPathComponent("notch-hook.sh").path
        let statusPath = dir.appendingPathComponent("notch-status.sh").path
        let hook = quote(hookPath), status = quote(statusPath)

        var ok = false
        for settings in settingsFiles() {
            guard var data = load(settings) else { continue }
            let before = canonical(data)
            var hooks = data["hooks"] as? [String: Any] ?? [:]
            for ev in events {
                var groups = hooks[ev] as? [[String: Any]] ?? []
                var present = false
                for i in groups.indices {
                    guard var hs = groups[i]["hooks"] as? [[String: Any]] else { continue }
                    for j in hs.indices where [hook, hookPath].contains(hs[j]["command"] as? String) {
                        hs[j]["command"] = hook; present = true
                    }
                    groups[i]["hooks"] = hs
                }
                if !present {
                    var entry: [String: Any] = ["hooks": [["type": "command", "command": hook,
                                                           "timeout": ev == "PermissionRequest" ? 120 : 5]]]
                    if toolEvents.contains(ev) { entry["matcher"] = "*" }
                    groups.append(entry)
                }
                hooks[ev] = groups
            }
            data["hooks"] = hooks
            // Never replace a status line the user already has.
            let current = (data["statusLine"] as? [String: Any])?["command"] as? String
            if data["statusLine"] == nil || [status, statusPath].contains(current) {
                data["statusLine"] = ["type": "command", "command": status]
            }
            if canonical(data) == before || write(data, to: settings) { ok = true }
        }
        return ok
    }

    /// Brings already-installed hook scripts up to date with the ones in this app bundle, so an update to
    /// the app also updates what the hooks report. Settings files are left alone; nothing is installed
    /// where there were no scripts before.
    static func refreshScripts() {
        let fm = FileManager.default
        for name in ["notch-hook", "notch-status"] {
            let dst = dir.appendingPathComponent("\(name).sh")
            guard fm.fileExists(atPath: dst.path), let src = Bundle.main.url(forResource: name, withExtension: "sh"),
                  let new = try? Data(contentsOf: src), (try? Data(contentsOf: dst)) != new else { continue }
            // Written in place of the old file in one step, so a hook running right now never sees half a script.
            let tmp = dir.appendingPathComponent(".\(name).sh.new")
            guard (try? new.write(to: tmp)) != nil else { continue }
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tmp.path)
            if rename(tmp.path, dst.path) != 0 { try? fm.removeItem(at: tmp) }
        }
    }

    /// True when any Claude settings file, including a fresh ~/.claude with no projects yet, has the hook.
    static var anyInstalled: Bool {
        settingsFiles(create: false).contains { ((try? String(contentsOf: $0, encoding: .utf8)) ?? "").contains("notch-hook.sh") }
    }

    /// ~/.claude (its settings.json is created if Claude Code is installed but has none yet) plus every
    /// other Claude config folder that already has settings.
    private static func settingsFiles(create: Bool = true) -> [URL] {
        let fm = FileManager.default
        let main = home.appendingPathComponent(".claude")
        var dirs = Set([main.path])
        for name in (try? fm.contentsOfDirectory(atPath: home.path)) ?? [] where name.hasPrefix(".claude") {
            dirs.insert(home.appendingPathComponent(name).path)
        }
        dirs.formUnion(ClaudeDirs.all.map(\.path))
        let mainSettings = main.appendingPathComponent("settings.json")
        if create, fm.fileExists(atPath: main.path), !fm.fileExists(atPath: mainSettings.path) {
            fm.createFile(atPath: mainSettings.path, contents: Data("{}\n".utf8))
        }
        return dirs.sorted().map { URL(fileURLWithPath: $0).appendingPathComponent("settings.json") }
            .filter { fm.fileExists(atPath: $0.path) }
    }

    private static func load(_ url: URL) -> [String: Any]? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    private static func canonical(_ obj: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
    }

    private static func write(_ obj: [String: Any], to url: URL) -> Bool {
        let fm = FileManager.default
        guard var out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .withoutEscapingSlashes]) else { return false }
        out.append(0x0A)
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        let backup = url.path + ".notchagents-backup-\(f.string(from: Date()))-\(getpid())"
        guard (try? fm.copyItem(atPath: url.path, toPath: backup)) != nil else { return false }
        let mode = (try? fm.attributesOfItem(atPath: url.path)[.posixPermissions]) as? NSNumber
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".settings.\(UUID().uuidString).json")
        guard (try? out.write(to: tmp)) != nil else { return false }
        if let mode { try? fm.setAttributes([.posixPermissions: mode], ofItemAtPath: tmp.path) }
        return rename(tmp.path, url.path) == 0
    }
}
