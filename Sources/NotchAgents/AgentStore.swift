import AppKit
import SwiftUI

enum AgentKind: String, CaseIterable, Identifiable {
    case claudeCLI, claudeApp, codex
    /// Detected from their process alone (no hooks or logs we read): live, folder and run time.
    case opencode, cursor, gemini, copilot, amp, aider
    var id: String { rawValue }

    var title: String {
        switch self {
        case .claudeCLI: "Claude CLI"
        case .claudeApp: "Claude App"
        case .codex: "Codex"
        case .opencode: "OpenCode"
        case .cursor: "Cursor Agent"
        case .gemini: "Gemini CLI"
        case .copilot: "Copilot CLI"
        case .amp: "Amp"
        case .aider: "Aider"
        }
    }

    var isClaude: Bool { self == .claudeCLI || self == .claudeApp }
    /// Turn-by-turn status and tool activity (Claude via hooks, Codex via its rollout logs,
    /// OpenCode via its database).
    var hasLiveStatus: Bool { isClaude || self == .codex || self == .opencode }
    /// Context-window usage and a transcript file to reveal.
    var tracksContext: Bool { isClaude || self == .codex }
    /// Whether it's running comes from the process scan (status, if any, is layered on top).
    var isProcessOnly: Bool { !isClaude && self != .codex }
    /// Featured on the getting-started cards.
    var isCore: Bool { isClaude || self == .codex }

    var accent: Color { gradient[1] }

    /// Desktop app bundle ids, most specific first.
    var bundleIDs: [String] {
        switch self {
        case .claudeCLI: []
        case .claudeApp: ["com.anthropic.claudefordesktop"]
        case .codex: ["com.openai.codex"]
        default: []
        }
    }

    /// Terminal command that starts the agent, when it has one.
    var command: String? {
        switch self {
        case .claudeCLI: "claude"
        case .claudeApp: nil
        case .codex: "codex"
        case .opencode: "opencode"
        case .cursor: "cursor-agent"
        case .gemini: "gemini"
        case .copilot: "copilot"
        case .amp: "amp"
        case .aider: "aider"
        }
    }
}

enum AgentStatus: Equatable {
    case offline, idle, thinking, tool, waiting

    var label: String {
        switch self {
        case .offline: "Offline"
        case .idle: "Idle"
        case .thinking: "Thinking"
        case .tool: "Running tool"
        case .waiting: "Needs you"
        }
    }
    var isBusy: Bool { self == .thinking || self == .tool }
}

/// Compact time-until label for resets: "45m", "3h", "6d".
enum RelativeTime {
    static func short(_ t: TimeInterval) -> String {
        // Nearest unit, so 2 days 23 hours reads "3d", not "2d".
        return t >= 86400 ? "\(Int((t / 86400).rounded()))d" : t >= 3600 ? "\(Int((t / 3600).rounded()))h" : "\(max(1, Int((t / 60).rounded())))m"
    }
}

struct LogEntry: Identifiable, Equatable {
    let id = UUID()
    let tool: String
    let detail: String?
    let date: Date
    var done = false
}

/// Transient banner the island shows on its own (task finished, agent asking something).
struct IslandAlert: Identifiable, Equatable {
    enum Style { case done, question }
    let id = UUID()
    let kind: AgentKind
    let style: Style
    let title: String
    let message: String
    static func == (l: Self, r: Self) -> Bool { l.id == r.id }
}

struct DiffLine: Identifiable {
    let id = UUID()
    let text: String
    let added: Bool
}

struct PendingQuestion: Identifiable {
    struct Option: Hashable { let label: String; let detail: String }
    struct Item { let header: String; let question: String; let options: [Option]; let multi: Bool }
    var id = UUID()
    let kind: AgentKind
    var session = ""
    let items: [Item]
    /// Sends the answers (question text -> chosen label(s)) back to Claude. nil until Claude's
    /// permission request arrives; before that, picking an option just jumps to the terminal.
    let answer: (([String: String]?) -> Void)?

    static func items(_ input: [String: Any]) -> [Item] {
        ((input["questions"] as? [[String: Any]]) ?? []).map { q in
            Item(header: q["header"] as? String ?? "",
                 question: q["question"] as? String ?? "",
                 options: ((q["options"] as? [[String: Any]]) ?? []).map {
                     Option(label: $0["label"] as? String ?? "", detail: $0["description"] as? String ?? "")
                 },
                 multi: q["multiSelect"] as? Bool ?? false)
        }
    }

    /// The notch can only answer questions that offer options to pick from.
    static func answerable(_ items: [Item]) -> Bool {
        !items.isEmpty && items.allSatisfy { !$0.options.isEmpty }
    }
}

struct PendingPermission: Identifiable {
    let id = UUID()
    let tool: String
    let summary: String
    var diff: [DiffLine] = []
    let respond: (Bool?) -> Void  // nil = no decision, fall back to Claude's own prompt
}

struct Agent: Identifiable {
    let kind: AgentKind
    var id: AgentKind { kind }
    var live = false
    var status: AgentStatus = .offline
    var tool: String?
    var detail: String?
    var model: String?
    var tokens = 0
    var contextUsed = 0
    var contextWindow = 200_000
    var cost: Double?
    var limit5h: Double?
    var limitWeek: Double?
    var pid: Int32?
    var cwd: String?
    var transcript: String?
    var lastEvent = Date.distantPast
    var pending: PendingPermission?
    var log: [LogEntry] = []
    var turnStart: Date?
    var lastTurn: TimeInterval?
    var sessionStart: Date?
    var reset5h: Date?
    var resetWeek: Date?

    mutating func addLog(_ tool: String, _ detail: String?, at date: Date = Date()) {
        if let i = log.indices.first, !log[i].done { log[i].done = true }
        log.insert(LogEntry(tool: tool, detail: detail, date: date), at: 0)
        if log.count > 4 { log.removeLast(log.count - 4) }
    }

    mutating func finishLog() {
        if !log.isEmpty { log[0].done = true }
    }

    var contextFraction: Double {
        contextWindow > 0 ? min(1, Double(contextUsed) / Double(contextWindow)) : 0
    }
}

@MainActor
final class AgentStore: ObservableObject {
    @Published private(set) var agents: [AgentKind: Agent] =
        Dictionary(uniqueKeysWithValues: AgentKind.allCases.map { ($0, Agent(kind: $0)) })

    @Published private(set) var armedStop: AgentKind?
    /// Combined spend of all Claude Code sessions active today.
    /// Today's spend per Claude agent (CLI and desktop app separately).
    @Published private(set) var claudeToday: [AgentKind: Double] = [:]
    @Published var soundsOn = SFX.enabled {
        didSet { UserDefaults.standard.set(soundsOn, forKey: "sounds"); SFX.enabled = soundsOn }
    }
    @Published private(set) var alert: IslandAlert?
    /// A multiple-choice question from Claude (AskUserQuestion), answerable right in the notch.
    @Published private(set) var question: PendingQuestion?
    /// nil until the hook server reports; false when its port couldn't be bound.
    @Published private(set) var serverOK: Bool?
    /// Whether any Claude config has the NotchAgents hook registered.
    @Published private(set) var hooksInstalled = true

    /// Installs the Claude Code hooks from the app bundle (for DMG installs, where ./build.sh never ran).
    func installHooks() {
        io.async { [weak self] in
            HookInstaller.install()
            let installed = ClaudeDirs.hooksInstalled || HookInstaller.anyInstalled
            Task { @MainActor in self?.hooksInstalled = installed }
        }
    }
    /// Set once the first hook event arrives: hooks are installed *and* working.
    @Published private(set) var hooksActive = false
    private var lastCostScan = Date.distantPast
    private var lastHookCheck = Date.distantPast
    private let server = HookServer()
    private var timer: Timer?
    /// Transcript sizes at the last poll, so unchanged transcripts aren't re-parsed every tick.
    private var transcriptSizes: [String: UInt64] = [:]
    private var hookSeen: Set<AgentKind> = []
    /// Claude processes reported by the hook script, and when each kind last sent an event. Keeps an
    /// agent live when the process scan misses it, so one missed scan can't wipe its state.
    private var hookPIDs: [AgentKind: Set<Int32>] = [:]
    private var lastHook: [AgentKind: Date] = [:]
    private let ledger = UsageLedger()
    /// Latest status-line payload per transcript: Claude Code's own cost and context numbers.
    private struct SessionStatus { var cost: Double?; var contextPct: Double?; var contextSize: Int?; var model: String? }
    private var statusByTranscript: [String: SessionStatus] = [:]
    /// Open turns per Claude session (several CLI sessions can run at once). An agent is working
    /// only while one of its sessions has an open turn.
    private struct Turn { var start: Date; var last: Date; var transcript: String? }
    private var turns: [AgentKind: [String: Turn]] = [:]
    private var codexFile: URL?
    private var codexOffset: UInt64 = 0
    private var codexWritten: Date?
    /// Codex's state according to its log (idle, thinking, tool), whether or not it's shown as running.
    private var codexPhase: AgentStatus = .idle
    /// Hosts like Open Design chain Codex turns back to back (one completes, the next starts a second
    /// later), so "finished" is only announced once Codex has stayed idle for a moment.
    private var codexDone: DispatchWorkItem?
    private var codexChainStart: Date?
    private let io = DispatchQueue(label: "notch.io", qos: .utility)

    var ordered: [Agent] { AgentKind.allCases.compactMap { agents[$0] } }
    /// Agents worth listing: only the ones running now.
    var listed: [Agent] { ordered.filter(\.live) }
    var liveAgents: [Agent] { ordered.filter(\.live) }
    var pending: Agent? { ordered.first { $0.pending != nil } }

    /// Layout previews only (`--render-preview`): replaces state without starting any scanning.
    func preview(_ list: [Agent], today: Double?, alert: IslandAlert? = nil, question: PendingQuestion? = nil) {
        agents = Dictionary(uniqueKeysWithValues: AgentKind.allCases.map { ($0, Agent(kind: $0)) })
        for a in list { agents[a.kind] = a }
        claudeToday = today.map { [.claudeCLI: $0] } ?? [:]
        self.alert = alert
        self.question = question
    }

    func start() {
        server.onRequest = { [weak self] req, reply in self?.handleHook(req, reply: reply) }
        server.onState = { [weak self] ok in self?.serverOK = ok }
        // NOTCHAGENTS_PORT runs a second copy beside the installed one (development); hooks always use 47823.
        server.start(port: ProcessInfo.processInfo.environment["NOTCHAGENTS_PORT"].flatMap(UInt16.init) ?? 47823)
        SFX.prewarm()
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    // MARK: - Hooks (Claude Code)

    private func handleHook(_ req: HookServer.Request, reply: @escaping (Data?) -> Void) {
        guard HookServer.isValid(req.token) else { reply(nil); return }
        ClaudeDirs.learn(dir: req.headers["x-notch-config"])
        ClaudeDirs.learn(transcript: req.body["transcript_path"] as? String)
        if req.query["type"] == "status" { applyStatus(req.body); reply(nil); return }
        // Diagnostics (`curl -H "X-Notch-Token: …" 127.0.0.1:47823/?type=state`): what the app believes.
        if req.query["type"] == "state" {
            let list: [[String: Any]] = ordered.map { a in
                ["kind": a.kind.rawValue, "live": a.live, "status": "\(a.status)", "pid": a.pid.map(Int.init) as Any,
                 "tool": a.tool as Any, "cwd": a.cwd as Any, "model": a.model as Any, "transcript": a.transcript as Any,
                 "limit5h": a.limit5h as Any, "limitWeek": a.limitWeek as Any, "cost": a.cost as Any, "tokens": a.tokens,
                 "lastEvent": a.lastEvent == .distantPast ? NSNull() : Int(-a.lastEvent.timeIntervalSinceNow) as Any]
            }
            reply(try? JSONSerialization.data(withJSONObject: ["agents": list, "hooksActive": hooksActive, "alert": alert.map { "\($0.title): \($0.message)" } as Any], options: [.prettyPrinted]))
            return
        }
        let kind: AgentKind = req.query["src"] == "app" ? .claudeApp : .claudeCLI
        let b = req.body
        let event = b["hook_event_name"] as? String ?? ""
        hookSeen.insert(kind)
        hooksActive = true
        hooksInstalled = true
        lastHook[kind] = Date()
        if let p = req.query["pid"], let pid = Int32(p) {
            if event == "SessionEnd" { hookPIDs[kind]?.remove(pid); lastHook[kind] = nil } else { hookPIDs[kind, default: []].insert(pid) }
        }
        var a = agents[kind]!
        let sid = b["session_id"] as? String ?? "default"
        let now = Date()
        switch event {
        case "UserPromptSubmit":
            turns[kind, default: [:]][sid] = Turn(start: now, last: now, transcript: b["transcript_path"] as? String)
        case "PreToolUse", "PostToolUse", "PermissionRequest", "Notification":
            if var t = turns[kind]?[sid] { t.last = now; turns[kind]![sid] = t }
            else if event != "Notification" {
                let path = b["transcript_path"] as? String
                turns[kind, default: [:]][sid] = Turn(start: Self.lastPromptDate(path) ?? now, last: now, transcript: path)
            }
        case "Stop", "SessionEnd": turns[kind]?[sid] = nil
        default: break
        }
        a.live = true
        a.lastEvent = Date()
        if a.sessionStart == nil { a.sessionStart = Date() }
        if let p = req.query["pid"], let pid = Int32(p) { a.pid = pid }
        if let cwd = b["cwd"] as? String { a.cwd = cwd }
        if let t = b["transcript_path"] as? String {
            if kind == .claudeApp { appSessions.insert(t) }
            if t != a.transcript { switchSession(&a, to: t) }
        }
        let toolName = b["tool_name"] as? String
        let input = b["tool_input"] as? [String: Any] ?? [:]

        switch event {
        case "SessionStart": a.status = .idle; a.tool = nil; a.sessionStart = Date(); a.log = []
        case "UserPromptSubmit": a.status = .thinking; a.tool = nil; a.detail = nil; a.turnStart = Date()
        case "PostToolUse", "SubagentStop": a.status = .thinking; a.tool = nil; a.detail = nil; a.finishLog()
        case "PreToolUse":
            a.status = .tool; a.tool = toolName; a.detail = Self.summarize(input)
            a.addLog(toolName ?? "Tool", a.detail)
            if toolName == "AskUserQuestion" {
                // Show the options straight away; the PermissionRequest that follows makes them answerable.
                a.status = .waiting
                let items = PendingQuestion.items(input)
                if PendingQuestion.answerable(items) {
                    if question?.session != sid || question?.answer == nil {
                        question = PendingQuestion(kind: kind, session: sid, items: items, answer: nil)
                    }
                    SFX.play(.attention)
                } else {
                    // No options to pick from in the notch: say so, and leave the answer to the terminal.
                    raise(IslandAlert(kind: kind, style: .question, title: "\(kind.title) asks a question",
                                      message: items.first.map(\.question).flatMap { $0.isEmpty ? nil : $0 } ?? "Answer it in the terminal"), for: 20)
                }
            }
        case "Notification":
            let msg = b["message"] as? String ?? ""
            switch Self.notificationKind(b) {
            case .idle:
                // Claude's reminder a minute after a turn ends ("Claude is waiting for your input"). Nothing
                // is being asked, and the turn already finished; just make sure it's closed.
                turns[kind]?[sid] = nil
            case .permission, .info:
                // Approvals arrive as PermissionRequest; auth and similar notices need nothing from you.
                break
            case .input:
                if a.pending == nil {
                    a.status = .waiting; a.detail = msg
                    raise(IslandAlert(kind: kind, style: .question, title: "\(kind.title) needs you",
                                      message: msg.isEmpty ? "Waiting for your input" : msg), for: 20)
                }
            }
        case "PermissionRequest" where toolName == "AskUserQuestion" && !PendingQuestion.answerable(PendingQuestion.items(input)):
            // Nothing to pick from in the notch (free-text question): leave it to the terminal.
            a.status = .waiting
            agents[kind] = a
            reply(nil)
            return
        case "PermissionRequest" where toolName == "AskUserQuestion":
            a.status = .waiting
            question?.answer?(nil)
            var answered = false
            let qid = UUID()
            let q = PendingQuestion(id: qid, kind: kind, session: sid, items: PendingQuestion.items(input)) { [weak self] answers in
                guard !answered else { return }
                answered = true
                if let answers {
                    var updated = input
                    updated["answers"] = answers
                    let out: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest",
                                                                     "decision": ["behavior": "allow", "updatedInput": updated]]]
                    reply(try? JSONSerialization.data(withJSONObject: out))
                } else {
                    reply(nil)  // answer in the terminal instead
                }
                Task { @MainActor in
                    guard let self else { return }
                    if self.question?.id == qid { self.question = nil }
                    if answers != nil { self.agents[kind]?.status = .thinking }
                }
            }
            question = q
            if alert?.kind == kind { alert = nil }
            agents[kind] = a
            DispatchQueue.main.asyncAfter(deadline: .now() + 100) { [weak self] in
                guard let self, self.question?.id == q.id else { return }
                q.answer?(nil)
            }
            return
        case "PermissionRequest":
            a.status = .waiting
            a.tool = toolName
            a.detail = Self.summarize(input)
            a.pending?.respond(nil)
            var answered = false
            SFX.play(.permission)
            let pending = PendingPermission(tool: toolName ?? "Tool", summary: Self.summarize(input) ?? "", diff: Self.diff(input)) { [weak self] allow in
                guard !answered else { return }
                answered = true
                guard let allow else { reply(nil); Task { @MainActor in self?.clearPending(kind, allowed: nil) }; return }
                let decision: [String: Any] = allow
                    ? ["behavior": "allow"]
                    : ["behavior": "deny", "message": "Denied from the notch."]
                let out: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
                reply(try? JSONSerialization.data(withJSONObject: out))
                Task { @MainActor in self?.clearPending(kind, allowed: allow) }
            }
            a.pending = pending
            agents[kind] = a
            // Fall back to the terminal prompt before the hook's own timeout.
            DispatchQueue.main.asyncAfter(deadline: .now() + 100) { [weak self] in
                guard let self, self.agents[kind]?.pending?.id == pending.id else { return }
                pending.respond(nil)
            }
            return
        case "Stop":
            let wasBusy = a.status.isBusy
            a.lastTurn = a.turnStart.map { Date().timeIntervalSince($0) }
            a.status = .idle; a.tool = nil; a.detail = nil; a.turnStart = nil; a.finishLog()
            if wasBusy {
                let bits = [Self.duration(a.lastTurn).map { "Done in \($0)" } ?? "Done", a.cwd.map { ($0 as NSString).lastPathComponent }]
                raise(IslandAlert(kind: kind, style: .done, title: "\(kind.title) finished",
                                  message: bits.compactMap { $0 }.joined(separator: "  ·  ")), for: 6)
            }
        case "SessionEnd": a.status = .offline; a.live = false
        default: break
        }
        if event != "PermissionRequest", event != "Notification", a.pending != nil, event == "PostToolUse" || event == "Stop" {
            // The user answered in the terminal instead.
            a.pending?.respond(nil)
            a.pending = nil
        }
        if question?.kind == kind, question?.session == sid, event == "PostToolUse" || event == "Stop" || event == "UserPromptSubmit" || event == "SessionEnd" {
            // Answered in the terminal (or the turn moved on).
            question?.answer?(nil)
            question = nil
        }
        syncTurns(&a)
        if alert?.kind == kind, alert?.style == .question, a.status.isBusy { alert = nil }
        agents[kind] = a
        reply(nil)
        if let t = a.transcript { readTranscript(kind, path: t) }
    }

    private func clearPending(_ kind: AgentKind, allowed: Bool?) {
        guard var a = agents[kind] else { return }
        a.pending = nil
        a.status = allowed == true ? .tool : (allowed == false ? .thinking : .waiting)
        agents[kind] = a
    }

    /// Answer the notch question; nil hands it back to the terminal.
    func answer(_ answers: [String: String]?) {
        guard let q = question else { return }
        if let f = q.answer { f(answers) } else { focus(q.kind) }
        SFX.play(answers != nil && q.answer != nil ? .submit : .tap)
        question = nil
    }

    func decide(_ kind: AgentKind, allow: Bool) {
        guard let p = agents[kind]?.pending else { return }
        SFX.play(allow ? .allow : .deny)
        p.respond(allow)
    }

    func raise(_ alert: IslandAlert, for seconds: Double) {
        self.alert = alert
        if alert.style == .done { BotMood.celebrate(alert.kind) }
        SFX.play(alert.style == .done ? .done : .attention)
        expire(alert.id, after: seconds)
    }

    /// Banners stay up while the pointer rests on them, then leave a beat after it moves off.
    var alertHeld = false
    private func expire(_ id: UUID, after seconds: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.alert?.id == id else { return }
            if self.alertHeld { self.expire(id, after: 1.5) } else { self.alert = nil }
        }
    }

    func dismissAlert() { alert = nil }

    static func duration(_ t: TimeInterval?) -> String? {
        guard let t, t >= 86400 else { return durationUnderDay(t) }
        let s = Int(t)
        return "\(s / 86400)d \(s % 86400 / 3600)h"
    }

    private static func durationUnderDay(_ t: TimeInterval?) -> String? {
        guard let t, t >= 1 else { return nil }
        let s = Int(t)
        return s >= 3600 ? "\(s / 3600)h \(s % 3600 / 60)m" : s >= 60 ? "\(s / 60)m \(s % 60)s" : "\(s)s"
    }

    /// Up to six -/+ lines previewing an Edit/Write/Bash permission request.
    static func diff(_ input: [String: Any]) -> [DiffLine] {
        func lines(_ s: String?, _ added: Bool, _ max: Int) -> [DiffLine] {
            (s ?? "").split(separator: "\n", omittingEmptySubsequences: false).prefix(max)
                .map { DiffLine(text: String($0.prefix(90)), added: added) }
        }
        if let old = input["old_string"] as? String, let new = input["new_string"] as? String {
            return lines(old, false, 3) + lines(new, true, 3)
        }
        if let content = input["content"] as? String { return lines(content, true, 6) }
        if let cmd = input["command"] as? String { return lines(cmd, true, 4) }
        return []
    }

    nonisolated static func summarize(_ input: [String: Any]) -> String? {
        for key in ["command", "file_path", "path", "pattern", "url", "query", "description", "prompt"] {
            if let v = input[key] as? String, !v.isEmpty {
                let s = key.hasSuffix("path") ? (v as NSString).lastPathComponent : v
                return String(s.replacingOccurrences(of: "\n", with: " ").prefix(80))
            }
        }
        return nil
    }

    /// Claude Code's status-line payload: its own session cost and context-window numbers (exact,
    /// unlike anything derived from the transcript), plus plan usage, which is per account so both
    /// Claude agents share it.
    private func applyStatus(_ b: [String: Any]) {
        if let path = b["transcript_path"] as? String {
            let cw = b["context_window"] as? [String: Any]
            statusByTranscript[path] = SessionStatus(
                cost: ((b["cost"] as? [String: Any])?["total_cost_usd"] as? NSNumber)?.doubleValue,
                contextPct: (cw?["used_percentage"] as? NSNumber)?.doubleValue,
                contextSize: (cw?["context_window_size"] as? NSNumber)?.intValue,
                model: (b["model"] as? [String: Any])?["id"] as? String)
            for k in [AgentKind.claudeCLI, .claudeApp] where agents[k]?.transcript == path { readTranscript(k, path: path) }
        }
        guard let rl = b["rate_limits"] as? [String: Any],
              let path = b["transcript_path"] as? String else { return }
        func pct(_ w: Any?) -> Double? { ((w as? [String: Any])?["used_percentage"] as? NSNumber)?.doubleValue }
        func reset(_ w: Any?) -> Date? {
            let v = (w as? [String: Any])?["resets_at"]
            if let n = v as? NSNumber { return Date(timeIntervalSince1970: n.doubleValue > 1e12 ? n.doubleValue / 1000 : n.doubleValue) }
            if let s = v as? String {
                let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
            }
            return nil
        }
        claudeLimits[path] = ClaudeLimits(fiveHour: pct(rl["five_hour"]), week: pct(rl["seven_day"]),
                                          reset5h: reset(rl["five_hour"]), resetWeek: reset(rl["seven_day"]), at: Date())
        for k in [AgentKind.claudeCLI, .claudeApp] { if var a = agents[k] { applyLimits(&a); agents[k] = a } }
    }

    private struct ClaudeLimits { var fiveHour, week: Double?; var reset5h, resetWeek: Date?; var at: Date }
    /// Plan limits per session (transcript path), as reported by that session's status line.
    /// Limits belong to an account, and sessions can be on different ones: each config folder has its own
    /// login, and the desktop app runs Claude Code with its own login token even when it shares a config
    /// folder with the CLI. So the App only shows limits its own session reported, and the CLI falls back
    /// to the newest report from another CLI session in the same config folder.
    private var claudeLimits: [String: ClaudeLimits] = [:]
    /// Transcripts that belong to Claude App sessions.
    private var appSessions: Set<String> = []
    private func applyLimits(_ a: inout Agent) {
        guard a.kind.isClaude else { return }
        var l = a.transcript.flatMap { claudeLimits[$0] }
        if l == nil, a.kind == .claudeCLI, let root = a.transcript.flatMap(Self.configRoot) {
            l = claudeLimits.filter { !appSessions.contains($0.key) && Self.configRoot($0.key) == root }
                .values.max { $0.at < $1.at }
        }
        a.limit5h = l?.fiveHour; a.limitWeek = l?.week; a.reset5h = l?.reset5h; a.resetWeek = l?.resetWeek
    }
    /// `/Users/me/.claude-work/projects/<project>/<session>.jsonl` → `/Users/me/.claude-work`.
    static func configRoot(_ transcript: String) -> String? {
        transcript.range(of: "/projects/", options: .backwards).map { String(transcript[..<$0.lowerBound]) }
    }

    /// Agent-level status/timer follow the open session turns.
    private enum NotificationKind { case idle, permission, input, info }

    /// What a Claude Code Notification hook means. Newer versions send `notification_type`; older ones
    /// only a message, so fall back to its wording.
    private static func notificationKind(_ b: [String: Any]) -> NotificationKind {
        switch b["notification_type"] as? String {
        case "idle_prompt": return .idle
        case "permission_prompt": return .permission
        case "elicitation_dialog": return .input
        case .some: return .info
        case nil: break
        }
        let msg = (b["message"] as? String ?? "").lowercased()
        if msg.contains("waiting for your input") || msg.contains("is idle") { return .idle }
        if msg.contains("permission") { return .permission }
        return .input
    }

    private func syncTurns(_ a: inout Agent) {
        let open = turns[a.kind] ?? [:]
        if open.isEmpty {
            if a.status.isBusy { a.status = .idle; a.tool = nil; a.detail = nil; a.finishLog() }
            // "Waiting" only lasts while something is actually asked: an approval, a question, or an open turn.
            if a.status == .waiting, a.pending == nil, question?.kind != a.kind { a.status = .idle; a.detail = nil }
            a.turnStart = nil
        } else {
            if a.status == .idle || a.status == .offline { a.status = .thinking }
            a.turnStart = open.values.map(\.start).min()
        }
    }

    /// Close turns whose transcript shows they ended (finished, or interrupted with Esc — which
    /// fires no Stop hook), or that have gone silent for a long time.
    private func reconcileTurns() {
        for (kind, open) in turns where !open.isEmpty {
            let quiet = open.filter { Date().timeIntervalSince($0.value.last) > 4 }
            guard !quiet.isEmpty else { continue }
            io.async { [weak self] in
                var ended: [String] = []
                for (sid, t) in quiet {
                    let stale = Date().timeIntervalSince(t.last) > 1800
                    if stale || t.transcript.map(Self.turnEnded) == true { ended.append(sid) }
                }
                guard !ended.isEmpty else { return }
                Task { @MainActor in
                    guard let self, var a = self.agents[kind] else { return }
                    for sid in ended { self.turns[kind]?[sid] = nil }
                    self.syncTurns(&a)
                    self.agents[kind] = a
                }
            }
        }
    }

    /// Verdict per transcript at a given size, so an unchanged transcript isn't re-parsed every tick.
    /// Only touched from the serial `io` queue.
    nonisolated(unsafe) private static var endedCache: [String: (size: UInt64, ended: Bool)] = [:]

    /// True when the newest conversational entry closes the turn.
    nonisolated static func turnEnded(_ path: String) -> Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64) ?? 0
        if let c = endedCache[path], c.size == size { return c.ended }
        let ended = parseTurnEnded(path)
        endedCache[path] = (size, ended)
        return ended
    }

    private nonisolated static func parseTurnEnded(_ path: String) -> Bool {
        guard let lines = tailLines(path, bytes: 128 * 1024) else { return false }
        for line in lines.reversed() {
            guard let o = json(line), let type = o["type"] as? String, type == "user" || type == "assistant",
                  let m = o["message"] as? [String: Any] else { continue }
            if type == "assistant" {
                guard let r = m["stop_reason"] as? String else { continue }
                return r == "end_turn" || r == "stop_sequence" || r == "max_tokens"
            }
            let text = (m["content"] as? String) ?? ((m["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined() ?? "")
            if text.contains("Request interrupted by user") { return true }
            if o["isMeta"] as? Bool == true { continue }
            return false
        }
        return false
    }

    // MARK: - Polling

    private func tick() {
        io.async { [weak self] in
            let procs = ProcessScanner.scan()
            Task { @MainActor in self?.apply(procs) }
        }
        pollCodex()
        pollOpenCode()
        reconcileTurns()
        if Date().timeIntervalSince(lastCostScan) > 10 { lastCostScan = Date(); scanClaudeToday() }
        if Date().timeIntervalSince(lastHookCheck) > 30 {
            lastHookCheck = Date()
            io.async { [weak self] in
                let installed = ClaudeDirs.hooksInstalled || HookInstaller.anyInstalled
                Task { @MainActor in self?.hooksInstalled = installed || self?.hooksActive == true }
            }
        }
        // Only re-parse a transcript that grew; hooks and status updates read it directly when they arrive.
        for kind in [AgentKind.claudeCLI, .claudeApp] {
            guard let t = agents[kind]?.transcript else { continue }
            let size = (try? FileManager.default.attributesOfItem(atPath: t)[.size] as? UInt64) ?? 0
            if transcriptSizes[t] != size { transcriptSizes[t] = size; readTranscript(kind, path: t) }
        }
    }

    private func apply(_ p: ProcessScanner.Result) {
        for kind in [AgentKind.claudeCLI, .claudeApp] {
            var a = agents[kind]!
            let pids = kind == .claudeCLI ? p.claudeCLI : p.claudeApp
            let wasLive = a.live
            // The scan can miss a session (unusual installs, IDE hosts), so hook evidence also counts:
            // a pid the hook reported that is still running, a recent event, or an open approval/question.
            let hooked = (hookPIDs[kind] ?? []).filter { kill($0, 0) == 0 }
            hookPIDs[kind] = hooked
            let recent = lastHook[kind].map { Date().timeIntervalSince($0) < 15 } ?? false
            a.live = !pids.isEmpty || !hooked.isEmpty || recent || a.pending != nil || question?.kind == kind
            if a.live {
                if let pid = a.pid, pids.contains(pid) || hooked.contains(pid) {} else { a.pid = pids.max() ?? hooked.max() ?? a.pid }
                if !wasLive || a.status == .offline { a.status = .idle }
                if !hookSeen.contains(kind) { fallbackActivity(&a, transcripts: pids.compactMap { p.transcripts[$0] }) }
            } else {
                a.pending?.respond(nil)
                turns[kind] = nil
                a = Agent(kind: kind, model: a.model, cost: a.cost)
                applyLimits(&a)
            }
            agents[kind] = a
        }
        var c = agents[.codex]!
        // A Codex hosted by another app (ChatGPT, Open Design, editors) keeps its app-server around
        // between runs, so it counts while a turn is open or for a few minutes after its log last changed.
        let since = codexWritten.map { Date().timeIntervalSince($0) } ?? .infinity
        // A turn whose log went quiet for 10 minutes ended without saying so (crash, killed host).
        if codexPhase.isBusy, since > 600 { codexPhase = .idle }
        let active = codexPhase.isBusy ? since < 600 : since < 300
        let host = p.codex ?? (active ? p.codexServers.min() : nil)
        c.live = host != nil
        c.pid = host
        if !c.live { c.status = .offline; c.tool = nil; c.detail = nil; c.turnStart = nil } else { c.status = codexPhase }
        agents[.codex] = c
        for kind in AgentKind.allCases where kind.isProcessOnly {
            var a = agents[kind]!
            if let pid = p.others[kind] {
                if !a.live || a.pid != pid {
                    a = Agent(kind: kind, live: true, status: .idle, pid: pid)
                    a.cwd = ProcessScanner.cwd(of: pid)
                    a.sessionStart = ProcessScanner.startTime(of: pid)
                    if kind == .opencode { openCodeStamp = nil; _ = applyOpenCode(openCode, to: &a) }
                }
            } else if a.live {
                a = Agent(kind: kind)
            }
            agents[kind] = a
        }
    }

    // MARK: - OpenCode database

    private var openCode: OpenCodeSnapshot?
    private var openCodeStamp: Date?

    /// Re-reads OpenCode's database while it runs, only when the database has changed.
    private func pollOpenCode() {
        guard let a = agents[.opencode], a.live else { openCode = nil; return }
        let cwd = a.cwd, last = openCodeStamp
        io.async { [weak self] in
            let stamp = OpenCodeReader.stamp()
            guard stamp != last else { return }
            let snap = OpenCodeReader.read(cwd: cwd)
            Task { @MainActor in
                guard let self, var a = self.agents[.opencode], a.live else { return }
                self.openCodeStamp = stamp
                self.openCode = snap
                let finished = self.applyOpenCode(snap, to: &a)
                self.agents[.opencode] = a
                if finished {
                    // Announce only if no follow-up turn starts straight away (hosts chain turns).
                    let bits = [Self.duration(a.lastTurn).map { "Done in \($0)" } ?? "Done", a.cwd.map { ($0 as NSString).lastPathComponent }]
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                        guard let self, let o = self.agents[.opencode], o.live, !o.status.isBusy else { return }
                        self.raise(IslandAlert(kind: .opencode, style: .done, title: "OpenCode finished",
                                               message: bits.compactMap { $0 }.joined(separator: "  ·  ")), for: 6)
                    }
                }
            }
        }
    }

    /// Layers the database's view onto the process-detected agent. True when a turn just finished.
    private func applyOpenCode(_ s: OpenCodeSnapshot?, to a: inout Agent) -> Bool {
        guard let s else { return false }
        let wasBusy = a.status.isBusy
        a.status = s.status; a.tool = s.tool; a.detail = s.detail
        if let m = s.model { a.model = m }
        if let c = s.cwd { a.cwd = c }
        a.cost = s.cost; a.tokens = s.tokens
        if s.status.isBusy { a.turnStart = s.turnStart ?? a.turnStart ?? Date() }
        else if wasBusy, let start = a.turnStart { a.lastTurn = Date().timeIntervalSince(start); a.turnStart = nil }
        else { a.turnStart = nil }
        // Rebuild the log only when it changed, so rows keep their identity (and don't re-animate).
        let current = a.log.map { OpenCodeSnapshot.Step(tool: $0.tool, detail: $0.detail, date: $0.date, done: $0.done) }
        if current != s.steps {
            a.log = s.steps.map { LogEntry(tool: $0.tool, detail: $0.detail, date: $0.date, done: $0.done) }
        }
        return wasBusy && !s.status.isBusy && a.lastTurn != nil
    }

    /// A different session of the same agent: its numbers come from its own transcript, never the last one's.
    private func switchSession(_ a: inout Agent, to path: String) {
        a.transcript = path
        a.cost = nil; a.tokens = 0; a.contextUsed = 0
        transcriptSizes[path] = nil                      // read it on the next tick even if unchanged
        applyLimits(&a)
    }

    /// Without hooks, infer activity from the newest transcript's freshness.
    /// Before any hook has arrived for this agent: status from its own sessions' transcripts.
    private func fallbackActivity(_ a: inout Agent, transcripts: [URL]) {
        guard let newest = transcripts.max(by: { Self.mtime($0) < Self.mtime($1) }) else { a.status = .idle; return }
        if a.kind == .claudeApp { appSessions.insert(newest.path) }
        if a.transcript != newest.path { switchSession(&a, to: newest.path) }
        let age = Date().timeIntervalSince(Self.mtime(newest))
        a.status = age < 6 ? .thinking : .idle
    }

    /// Timestamp of the last real user prompt (not a tool result) in a Claude transcript's tail.
    static func lastPromptDate(_ path: String?) -> Date? {
        guard let path, let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        let end = (try? fh.seekToEnd()) ?? 0
        try? fh.seek(toOffset: end > 512_000 ? end - 512_000 : 0)
        guard let data = try? fh.readToEnd(), let text = String(data: data, encoding: .utf8) else { return nil }
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for line in text.split(separator: "\n").reversed() where line.contains("\"type\":\"user\"") {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  o["type"] as? String == "user", o["isMeta"] as? Bool != true,
                  let msg = o["message"] as? [String: Any] else { continue }
            let isPrompt: Bool
            if msg["content"] is String { isPrompt = true }
            else if let parts = msg["content"] as? [[String: Any]] { isPrompt = !parts.contains { $0["type"] as? String == "tool_result" } }
            else { isPrompt = false }
            if isPrompt, let ts = o["timestamp"] as? String, let d = iso.date(from: ts) { return d }
        }
        return nil
    }

    // MARK: - Claude transcripts

    /// Today's Claude spend: every message sent since local midnight, across all sessions and configs.
    private func scanClaudeToday() {
        io.async { [weak self] in
            guard let self else { return }
            let total = self.ledger.today()
            Task { @MainActor in self.claudeToday = total }
        }
    }

    private func readTranscript(_ kind: AgentKind, path: String) {
        let status = statusByTranscript[path]
        io.async { [weak self] in
            guard let self, let lines = Self.tailLines(path, bytes: 256 * 1024) else { return }
            // Context = the newest main-thread request's prompt size (sidechains are subagents).
            var model: String?, used: Int?
            for line in lines.reversed() where line.contains("\"usage\"") {
                guard let o = Self.json(line), o["isSidechain"] as? Bool != true,
                      let m = o["message"] as? [String: Any], let u = m["usage"] as? [String: Any] else { continue }
                model = m["model"] as? String
                used = (u["input_tokens"] as? Int ?? 0) + (u["cache_read_input_tokens"] as? Int ?? 0)
                    + (u["cache_creation_input_tokens"] as? Int ?? 0) + (u["output_tokens"] as? Int ?? 0)
                break
            }
            let session = self.ledger.session(path)
            Task { @MainActor in
                guard var a = self.agents[kind], a.transcript == nil || a.transcript == path else { return }
                if let m = status?.model ?? model, !m.hasPrefix("<") { a.model = m }
                let size = status?.contextSize ?? Self.contextWindow(a.model ?? "", used: used ?? 0)
                a.contextWindow = size
                if let pct = status?.contextPct { a.contextUsed = Int(pct / 100 * Double(size)) } else if let used { a.contextUsed = used }
                // Claude Code's own figure when the status line reports it; else priced from the transcript.
                a.cost = status?.cost ?? session?.cost
                if let s = session { a.tokens = s.output }
                self.agents[kind] = a
            }
        }
    }

    /// Context window when the status line hasn't said: current-generation models run with 1M.
    nonisolated static func contextWindow(_ model: String, used: Int) -> Int {
        let big = ["[1m]", "-1m", "fable", "mythos", "opus-5", "sonnet-5", "haiku-5", "opus-4-6", "opus-4-7", "opus-4-8", "sonnet-4-6"]
        return used > 200_000 || big.contains(where: model.contains) ? 1_000_000 : 200_000
    }

    // MARK: - Codex rollout logs

    private var codexListed = Date.distantPast

    private func pollCodex() {
        // Finding the newest log walks several folders; in between, only the current log is checked.
        if let file = codexFile, Date().timeIntervalSince(codexListed) < 6 {
            io.async { [weak self] in
                // Not `mtime(_:)`: a URL caches its resource values, so the stored URL would never change.
                let written = (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date) ?? .distantPast
                Task { @MainActor in
                    guard let self, written > (self.codexWritten ?? .distantPast) else { return }
                    self.codexWritten = written
                    self.readCodex(file)
                }
            }
            return
        }
        codexListed = Date()
        io.async { [weak self] in
            let env = LaunchEnvironment.codexHome.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            let home = env ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
            // Hosts like Open Design move a session's log to archived_sessions/ while it is still in use,
            // so both folders count. Guardian/subagent logs show Codex is busy but aren't the session.
            let recent = (Self.recentFiles(in: home.appendingPathComponent("sessions"), ext: "jsonl", depth: 4)
                + Self.recentFiles(in: home.appendingPathComponent("archived_sessions"), ext: "jsonl", depth: 0))
                .sorted { Self.mtime($0) > Self.mtime($1) }
            guard let written = recent.first.map(Self.mtime) else { return }
            let main = recent.prefix(8).first { !Self.isCodexSubagent($0) }
            Task { @MainActor in
                self?.codexWritten = written
                if let main { self?.readCodex(main) }
            }
        }
    }

    private func readCodex(_ url: URL) {
        // A different session's log: its own events decide its state, not the previous log's.
        if url != codexFile { codexFile = url; codexOffset = 0; codexPhase = .idle }
        let offset = codexOffset
        io.async { [weak self] in
            guard let h = try? FileHandle(forReadingFrom: url) else { return }
            defer { try? h.close() }
            let size = (try? h.seekToEnd()) ?? 0
            guard size > offset else { return }
            // On first read only parse the tail; status is derived from the latest events.
            let start = offset == 0 && size > 2_000_000 ? size - 2_000_000 : offset
            try? h.seek(toOffset: start)
            let data = h.readDataToEndOfFile()
            guard let lastNL = data.lastIndex(of: 0x0A) else { return }
            let text = String(decoding: data[..<lastNL], as: UTF8.self)
            let consumed = start + UInt64(lastNL - data.startIndex + 1)
            var updates: [[String: Any]] = []
            for line in text.split(separator: "\n") {
                if let o = Self.json(Substring(line)) { updates.append(o) }
            }
            Task { @MainActor in
                guard let self else { return }
                self.codexOffset = consumed
                var a = self.agents[.codex]!
                // Track the turn even while Codex isn't shown as running yet: a hosted app-server only
                // counts once its log moves, and those first events are the ones that say it's working.
                a.status = self.codexPhase
                var finished = false
                for o in updates where Self.applyCodex(o, to: &a) { finished = true }
                self.codexPhase = a.status == .offline ? .idle : a.status
                if !a.live { a.status = .offline }
                self.agents[.codex] = a
                // The log's own turn state, not the shown status (offline while the process isn't visible).
                if self.codexPhase.isBusy {
                    self.codexDone?.cancel(); self.codexDone = nil
                    if self.codexChainStart == nil { self.codexChainStart = a.turnStart }
                } else if finished {
                    self.codexDone?.cancel()
                    let start = self.codexChainStart, end = Date(), single = a.lastTurn
                    let work = DispatchWorkItem { [weak self] in
                        guard let self, !self.codexPhase.isBusy, let c = self.agents[.codex] else { return }
                        self.codexDone = nil; self.codexChainStart = nil
                        let took = start.map { end.timeIntervalSince($0) } ?? single
                        let bits = [Self.duration(took).map { "Done in \($0)" } ?? "Done", c.cwd.map { ($0 as NSString).lastPathComponent }]
                        self.raise(IslandAlert(kind: .codex, style: .done, title: "Codex finished",
                                               message: bits.compactMap { $0 }.joined(separator: "  ·  ")), for: 6)
                    }
                    self.codexDone = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
                } else if self.codexDone == nil {
                    self.codexChainStart = nil
                }
            }
        }
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Returns true when this event completed a live turn just now.
    @discardableResult
    private static func applyCodex(_ o: [String: Any], to a: inout Agent) -> Bool {
        guard let p = o["payload"] as? [String: Any] else { return false }
        if o["type"] as? String == "turn_context" {
            if let m = p["model"] as? String { a.model = m }
            if let cwd = p["cwd"] as? String { a.cwd = cwd }
            return false
        }
        // Most events carry their kind in payload.type; session_meta only has the outer type.
        guard let t = (p["type"] as? String) ?? (o["type"] as? String) else { return false }
        let when = (o["timestamp"] as? String).flatMap { iso.date(from: $0) } ?? Date()
        let fresh = Date().timeIntervalSince(when) < 15
        a.lastEvent = Date()
        switch t {
        case "session_meta":
            a.cwd = p["cwd"] as? String
            a.sessionStart = when; a.log = []
        case "turn_context", "thread_settings_applied":
            if let m = p["model"] as? String { a.model = m }
        case "task_started":
            a.status = .thinking
            a.tool = nil; a.turnStart = when
        case "task_complete", "turn_aborted":
            // Only a turn that ran to completion is "finished"; Esc/interrupts end it quietly.
            let completed = t == "task_complete" && fresh && a.status.isBusy
            a.lastTurn = a.turnStart.map { when.timeIntervalSince($0) }
            a.status = .idle
            a.turnStart = nil; a.finishLog()
            a.tool = nil; a.detail = nil
            return completed
        case "function_call", "custom_tool_call", "local_shell_call", "web_search_call":
            if a.status != .idle { a.status = .tool }
            a.tool = p["name"] as? String ?? t.replacingOccurrences(of: "_call", with: "")
            if let args = p["arguments"] as? String, let j = json(Substring(args)) {
                a.detail = summarize(j) ?? (j["cmd"] as? [String])?.joined(separator: " ")
            } else { a.detail = nil }
            a.addLog(a.tool ?? "tool", a.detail, at: when)
        case "function_call_output", "custom_tool_call_output":
            if a.status == .tool { a.status = .thinking }
            a.finishLog()
        case "token_count":
            if let info = p["info"] as? [String: Any] {
                if let tot = info["total_token_usage"] as? [String: Any] { a.tokens = tot["output_tokens"] as? Int ?? a.tokens }
                if let last = info["last_token_usage"] as? [String: Any] { a.contextUsed = last["input_tokens"] as? Int ?? 0 }
                if let w = info["model_context_window"] as? Int { a.contextWindow = w }
            }
            if let rl = p["rate_limits"] as? [String: Any] {
                let pri = rl["primary"] as? [String: Any], sec = rl["secondary"] as? [String: Any]
                a.limit5h = pri?["used_percent"] as? Double
                a.limitWeek = sec?["used_percent"] as? Double
                a.reset5h = (pri?["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
                a.resetWeek = (sec?["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
            }
        default: break
        }
        return false
    }

    // MARK: - Controls

    func focus(_ kind: AgentKind) {
        for b in kind.bundleIDs + (kind == .codex ? ["com.openai.chat"] : []) {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: b).first {
                app.activate(); return
            }
        }
        if let pid = agents[kind]?.pid, let app = ProcessScanner.owningApp(of: pid) { app.activate() }
    }

    func appURL(_ kind: AgentKind) -> URL? {
        kind.bundleIDs.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
    }

    func launch(_ kind: AgentKind) {
        guard let url = appURL(kind) else { return }
        SFX.play(.tap)
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    func armStop(_ kind: AgentKind) {
        armedStop = kind
        SFX.play(.arm)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            if self?.armedStop == kind { self?.armedStop = nil }
        }
    }

    func interrupt(_ kind: AgentKind) {
        armedStop = nil
        guard kind != .codex, let pid = agents[kind]?.pid else { return }
        // The pid may be stale (session ended, pid reused): only signal a process that is still Claude.
        guard ProcessScanner.isClaude(pid) else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        SFX.play(.stop)
        kill(pid, SIGINT)
    }

    func openTranscript(_ kind: AgentKind) {
        if let t = agents[kind]?.transcript { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: t)]) }
        else if kind == .codex, let f = codexFile { NSWorkspace.shared.activateFileViewerSelecting([f]) }
    }

    // MARK: - File helpers

    nonisolated static func json(_ s: Substring) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any]
    }

    nonisolated static func mtime(_ u: URL) -> Date {
        (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    nonisolated static func tailLines(_ path: String, bytes: UInt64) -> [Substring]? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > bytes ? size - bytes : 0)
        let text = String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
        var lines = text.split(separator: "\n")
        if size > bytes, !lines.isEmpty { lines.removeFirst() }
        return lines
    }

    /// Newest file by walking only the most recent directory at each level (fast for date-sharded trees).
    /// Files in `root` and its most recently changed subfolders (up to `depth` levels), newest first.
    nonisolated static func recentFiles(in root: URL, ext: String, depth: Int) -> [URL] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey]) else { return [] }
        // Each modification time is read once; sorting would otherwise look it up on every comparison.
        let dated = items.map { (url: $0, date: mtime($0)) }
        var out = dated.filter { $0.url.pathExtension == ext }.sorted { $0.date > $1.date }.prefix(8).map(\.url)
        if depth > 0 {
            let dirs = dated.filter { (try? $0.url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            for d in dirs.sorted(by: { $0.date > $1.date }).prefix(3) { out += recentFiles(in: d.url, ext: ext, depth: depth - 1) }
        }
        return out
    }

    /// A Codex rollout written by a subagent (guardian reviews and the like), from its session_meta line.
    nonisolated static func isCodexSubagent(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        let head = String(decoding: h.readData(ofLength: 8192), as: UTF8.self)
        guard let r = head.range(of: "\"source\"") else { return false }
        let after = head[r.upperBound...].prefix(40).filter { !$0.isWhitespace }
        return after.hasPrefix(":{\"subagent\"")
    }

    nonisolated static func newestFile(in root: URL, ext: String, depth: Int) -> URL? {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey]) else { return nil }
        let files = items.filter { $0.pathExtension == ext }
        let dirs = items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        var best = files.max { mtime($0) < mtime($1) }
        if depth > 0 {
            for d in dirs.sorted(by: { mtime($0) > mtime($1) }).prefix(3) {
                if let f = newestFile(in: d, ext: ext, depth: depth - 1), best == nil || mtime(f) > mtime(best!) { best = f }
            }
        }
        return best
    }
}

enum ProcessScanner {
    struct Result { var claudeCLI: [Int32] = []; var claudeApp: [Int32] = []; var codex: Int32?; var codexServers: [Int32] = []; var transcripts: [Int32: URL] = [:]; var others: [AgentKind: Int32] = [:] }

    /// Process-detected agents: executable names (native installs, or the script an npm/pip install
    /// runs under a runtime) and package markers found in the command line.
    private static let signatures: [(kind: AgentKind, names: Set<String>, markers: [String])] = [
        (.opencode, ["opencode"], ["opencode-ai/", "/opencode/bin/"]),
        (.cursor, ["cursor-agent"], ["cursor-agent/"]),
        (.gemini, ["gemini"], ["@google/gemini-cli"]),
        (.copilot, ["copilot"], ["@github/copilot/"]),
        (.amp, ["amp"], ["@sourcegraph/amp"]),
        (.aider, ["aider"], ["/bin/aider", "-m aider"]),
    ]

    /// Every process's parent, executable path and whether it has a terminal, read from the kernel.
    /// (Spawning `ps` twice per scan cost more CPU than the rest of the app put together.)
    static func table() -> (parent: [Int32: Int32], comm: [Int32: String], tty: [Int32: Bool]) {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return ([:], [:], [:]) }
        size += size / 8                                      // room for processes started in between
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return ([:], [:], [:]) }
        procs.removeLast(procs.count - size / MemoryLayout<kinfo_proc>.stride)

        var parent: [Int32: Int32] = [:], comm: [Int32: String] = [:], tty: [Int32: Bool] = [:]
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        for p in procs {
            let pid = p.kp_proc.p_pid
            parent[pid] = p.kp_eproc.e_ppid
            tty[pid] = p.kp_eproc.e_tdev != -1
            if proc_pidpath(pid, &path, UInt32(path.count)) > 0 {
                comm[pid] = String(cString: path)
            } else {
                comm[pid] = withUnsafeBytes(of: p.kp_proc.p_comm) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            }
        }
        return (parent, comm, tty)
    }

    /// A process's command line (arguments joined by spaces, like `ps -o args`), or nil if not readable.
    static func args(of pid: Int32) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return nil }
        // Layout: argc, the executable path, padding NULs, then argv[0..<argc] (environment follows; never read).
        let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = 4
        while i < size, buf[i] != 0 { i += 1 }
        while i < size, buf[i] == 0 { i += 1 }
        var words: [String] = []
        while words.count < argc, i < size {
            let start = i
            while i < size, buf[i] != 0 { i += 1 }
            words.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

    /// Background helper modes of the claude binary that are not agent sessions.
    private static let helperFlags = ["--chrome-native-host", "native-host", "mcp serve", "--mcp"]
    /// Script runtimes an npm-installed CLI runs under (`comm` is the runtime, not "claude").
    private static let runtimes: Set<String> = ["node", "bun", "deno"]

    private static func base(_ c: String) -> String { (c as NSString).lastPathComponent }
    /// Arguments of short-lived commands (version checks, logins, upgrades), never a session.
    private static let oneShot: Set<String> = ["--version", "-v", "-V", "version", "--help", "-h", "help",
                                               "auth", "login", "logout", "models", "upgrade", "update", "stats"]

    private static func isRuntime(_ c: String) -> Bool {
        let b = base(c)
        return runtimes.contains(b) || b.lowercased().hasPrefix("python")
    }

    /// The process-detected agent a process is, if any.
    private static func signature(comm c: String, args: String?) -> AgentKind? {
        let b = base(c)
        for sig in signatures where sig.names.contains(b) { return sig.kind }
        guard isRuntime(c), let a = args else { return nil }
        let words = a.split(separator: " ")
        let script = words.count > 1 ? base(String(words[1])) : ""
        return signatures.first { sig in sig.names.contains(script) || sig.markers.contains(where: a.contains) }?.kind
    }

    /// Native installs show as `claude` (or the versioned binary); npm installs as `node …/claude`.
    private static func isClaude(comm c: String, args: String?) -> Bool {
        if base(c) == "claude" || c.contains("/claude-code/") || c.contains("/.local/share/claude/versions/") { return true }
        guard runtimes.contains(base(c)), let a = args else { return false }
        if a.contains("@anthropic-ai/claude-code") { return true }
        // `node /path/to/bin/claude …`: the script is the first argument after the runtime.
        let words = a.split(separator: " ")
        return words.count > 1 && base(String(words[1])) == "claude"
    }

    /// Whether `pid` is still a Claude process (guards signals against reused pids).
    static func isClaude(_ pid: Int32) -> Bool {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return false }
        return isClaude(comm: String(cString: path), args: args(of: pid))
    }

    static func scan() -> Result {
        let (parent, comm, tty) = table()
        resumed = resumed.filter { parent[$0.key] != nil }
        // Full command lines only for the processes that could be agents.
        let names = signatures.reduce(into: Set<String>()) { $0.formUnion($1.names) }
        let wanted = comm.filter { let b = base($0.value)
            return b == "claude" || b.lowercased() == "codex" || isRuntime($0.value) || names.contains(b) || $0.value.contains("claude")
        }.map(\.key)
        var args: [Int32: String] = [:]
        for pid in wanted { args[pid] = Self.args(of: pid) }
        let claude = Set(wanted.filter { isClaude(comm: comm[$0] ?? "", args: args[$0]) })
        func ancestors(_ pid: Int32) -> [String] {
            var out: [String] = [], cur = parent[pid] ?? 1
            for _ in 0..<16 where cur > 1 { out.append(comm[cur] ?? ""); cur = parent[cur] ?? 1 }
            return out
        }
        func hasTTY(_ pid: Int32) -> Bool { tty[pid] ?? false }

        var r = Result()
        for pid in claude {
            let a = args[pid] ?? ""
            // Skip claude processes spawned by another claude (subagents/helpers) and helper modes.
            if let pp = parent[pid], claude.contains(pp) { continue }
            if helperFlags.contains(where: a.contains) { continue }
            // One-shot `claude -p` runs aren't sessions you can watch or answer.
            let words = a.split(separator: " ").map(String.init)
            if words.contains("-p") || words.contains("--print") { continue }
            let up = ancestors(pid)
            let c = comm[pid] ?? ""
            if c.contains("Application Support/Claude") || up.contains(where: { $0.contains("Claude.app") }) {
                r.claudeApp.append(pid)
            } else if hasTTY(pid) || up.contains(where: { $0.contains(".app/") }) {
                // A CLI session owns a terminal, or runs inside an editor (VS Code, Cursor, JetBrains…).
                r.claudeCLI.append(pid)
            }
        }
        for pid in r.claudeCLI + r.claudeApp {
            if let t = transcript(pid: pid, args: args[pid] ?? "") { r.transcripts[pid] = t }
        }
        for (pid, c) in comm where base(c).lowercased() == "codex" {
            if let pp = parent[pid], let pc = comm[pp], base(pc).lowercased() == "codex" { continue }
            let a = args[pid] ?? ""
            if a.contains("mcp-server") || a.contains(" mcp ") { continue }
            // The Codex app (and the app-server it hosts) and terminal sessions count outright. A TTY-less
            // `codex app-server` started by something else (ChatGPT, editors, design tools) idles most of the
            // time, so it only counts while its session log is being written (decided in `apply`).
            let inApp = c.contains("Codex.app") || ancestors(pid).contains { $0.contains("Codex.app") }
            if inApp || (hasTTY(pid) && !a.contains("app-server")) {
                r.codex = r.codex.map { min($0, pid) } ?? pid
            } else {
                r.codexServers.append(pid)
            }
        }
        var kinds: [Int32: AgentKind] = [:]
        for pid in wanted where !claude.contains(pid) {
            if let k = signature(comm: comm[pid] ?? "", args: args[pid]) { kinds[pid] = k }
        }
        for (pid, kind) in kinds {
            // Count each agent once: skip a wrapper's child of the same kind, and background servers.
            if let pp = parent[pid], kinds[pp] == kind { continue }
            let a = args[pid] ?? ""
            if a.contains(" serve") || a.contains(" server") || a.contains("--acp") || a.contains("language-server") { continue }
            // Apps that host agents (Open Design, editors) run one-shot commands like `opencode --version`
            // to probe them; only a process that has kept running for a few seconds is a session.
            let words = Set(a.split(separator: " ").dropFirst().map(String.init))
            if !words.isDisjoint(with: oneShot) { continue }
            if let start = startTime(of: pid), Date().timeIntervalSince(start) < 3 { continue }
            guard hasTTY(pid) || ancestors(pid).contains(where: { $0.contains(".app/") }) else { continue }
            r.others[kind] = r.others[kind].map { min($0, pid) } ?? pid
        }
        return r
    }

    /// The transcript a Claude process is writing: its `--resume`/`--session-id` file when given (the
    /// Claude app passes one), else the newest transcript in the project folder for its working directory.
    /// Transcripts found from a `--resume`/`--session-id` flag: fixed for the life of the process, and
    /// finding one means listing every project folder. Only touched from the store's io queue.
    nonisolated(unsafe) private static var resumed: [Int32: (args: String, url: URL)] = [:]

    private static func transcript(pid: Int32, args: String) -> URL? {
        // A fresh URL each time: URLs cache their modification date, and callers check freshness.
        if let r = resumed[pid], r.args == args, FileManager.default.fileExists(atPath: r.url.path) { return URL(fileURLWithPath: r.url.path) }
        let words = args.split(separator: " ").map(String.init)
        var sid: String?
        for (i, w) in words.enumerated() {
            for flag in ["--resume", "--session-id"] {
                if w.hasPrefix(flag + "=") { sid = String(w.dropFirst(flag.count + 1)) }
                else if w == flag, i + 1 < words.count, !words[i + 1].hasPrefix("-") { sid = words[i + 1] }
            }
        }
        let fm = FileManager.default
        if let sid {
            for root in ClaudeDirs.projectRoots {
                for proj in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] {
                    let f = root.appendingPathComponent(proj).appendingPathComponent(sid + ".jsonl")
                    if fm.fileExists(atPath: f.path) { resumed[pid] = (args, f); return f }
                }
            }
        }
        // Claude Code names a project folder after its path with every non-alphanumeric turned into "-".
        guard let cwd = cwd(of: pid) else { return nil }
        let name = String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
        return ClaudeDirs.projectRoots.compactMap { AgentStore.newestFile(in: $0.appendingPathComponent(name), ext: "jsonl", depth: 0) }
            .max { AgentStore.mtime($0) < AgentStore.mtime($1) }
    }

    /// Working directory of a process (its project folder).
    static func cwd(of pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        return path.isEmpty ? nil : path
    }

    static func startTime(of pid: Int32) -> Date? {
        var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let tv = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6)
    }

    /// Walk up the process tree to the GUI app hosting a CLI (Terminal, iTerm, Ghostty, VS Code…).
    static func owningApp(of pid: Int32) -> NSRunningApplication? {
        var cur = pid
        for _ in 0..<16 where cur > 1 {
            if let app = NSRunningApplication(processIdentifier: cur), app.activationPolicy == .regular { return app }
            var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, cur]
            guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return nil }
            cur = info.kp_eproc.e_ppid
        }
        return nil
    }
}
