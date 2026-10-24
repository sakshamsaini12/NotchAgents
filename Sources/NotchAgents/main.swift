import AppKit
import Combine
import SwiftUI

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class FirstMouseHostingView<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    // Always show the arrow over the island, never the I-beam of whatever app is underneath.
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
    override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }
    override func mouseMoved(with event: NSEvent) { NSCursor.arrow.set(); super.mouseMoved(with: event) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self && $0.userInfo?["arrow"] != nil }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.cursorUpdate, .mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: ["arrow": true]))
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = AgentStore()
    private let model = IslandModel()
    private var panel: NotchPanel!
    private var monitors: [Any] = []
    private var hoverWork: DispatchWorkItem?
    private var alertSub: AnyCancellable?
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ note: Notification) {
        // One island at a time: a second copy would fight over the notch and the hook port.
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0 != .current }) {
            NSApp.terminate(nil); return
        }
        panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .init(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.ignoresMouseEvents = true
        panel.acceptsMouseMovedEvents = true
        let host = FirstMouseHostingView(rootView: IslandView(store: store, model: model))
        host.sizingOptions = []
        panel.contentView = host
        layout()
        panel.orderFrontRegardless()

        store.start()
        menuBar = MenuBarController(store: store)

        // Mouse moves arrive at up to the display's refresh rate (120 Hz on ProMotion); hit-testing at
        // most once per frame of the slower 60 Hz is indistinguishable and halves the work.
        var lastTrack = Date.distantPast
        let track: (NSEvent) -> Void = { [weak self] _ in
            let now = Date()
            guard now.timeIntervalSince(lastTrack) >= 1.0 / 60 else { return }
            lastTrack = now
            self?.trackMouse()
        }
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: track) as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { e in track(e); return e } as Any)
        // ⌘Y / ⌘N answer a pending permission while the island is open (the panel is key only then).
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self else { return e }
            // A notch question: 1–9 pick an option of the current item (toggle, for multi-select), Return
            // moves on or submits, Escape hands the question back to the agent's own window.
            if let q = self.store.question, e.modifierFlags.intersection([.command, .control, .option]).isEmpty {
                if let n = Int(e.charactersIgnoringModifiers ?? ""), n >= 1, n <= 9 {
                    self.model.pick(n - 1, in: q, store: self.store); return nil
                }
                switch e.keyCode {
                case 36, 76: self.model.advance(q, store: self.store); return nil   // Return, Enter
                case 53: self.store.answer(nil); return nil                            // Escape
                default: break
                }
            }
            guard e.modifierFlags.contains(.command), let kind = self.store.pending?.kind else { return e }
            switch e.charactersIgnoringModifiers?.lowercased() {
            case "y": self.store.decide(kind, allow: true); return nil
            case "n": self.store.decide(kind, allow: false); return nil
            default: return e
            }
        } as Any)
        alertSub = store.$alert.removeDuplicates().sink { a in
            if a != nil { NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now) }
        }
        // Polling fallback: global monitors can miss moves (synthetic events, some full-screen apps).
        // A still pointer only needs an occasional check (the island can change size under it).
        var lastPoint: CGPoint?, idleTicks = 0
        Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                let p = NSEvent.mouseLocation
                idleTicks = p == lastPoint ? idleTicks + 1 : 0
                lastPoint = p
                if idleTicks % 10 == 0 { self?.trackMouse() }
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.layout() }
        }
    }

    private var screen: NSScreen {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func layout() {
        let s = screen
        let f = s.frame
        if s.safeAreaInsets.top > 0, let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea {
            model.notch = CGSize(width: f.width - l.width - r.width, height: s.safeAreaInsets.top)
        } else {
            let menuBar = f.maxY - s.visibleFrame.maxY
            model.notch = CGSize(width: 185, height: max(24, menuBar))
        }
        let w = IslandModel.maxSize.width + 120, h = IslandModel.maxSize.height + 60
        panel.setFrame(NSRect(x: f.midX - w / 2, y: f.maxY - h, width: w, height: h), display: true)
    }

    private static let pinOpen = ProcessInfo.processInfo.environment["NOTCH_PIN_OPEN"] != nil
    private static let debug = ProcessInfo.processInfo.environment["NOTCH_DEBUG"] != nil

    /// Hit-test against the island's current shape so the rest of the panel stays click-through.
    private func trackMouse() {
        let p = NSEvent.mouseLocation
        BotMood.pointer = p
        BotMood.origin = CGPoint(x: screen.frame.midX, y: screen.frame.maxY - model.notch.height / 2)
        let live = store.liveAgents
        BotMood.liveOrder = live.map(\.kind)
        for a in live { BotMood.tools[a.kind] = a.tool ?? "" }
        let f = screen.frame
        // Far below the island with nothing to undo: the hit test can't come out differently.
        if !Self.pinOpen, p.y < f.maxY - IslandModel.maxSize.height - 40, !model.hovering, hoverWork == nil,
           panel.ignoresMouseEvents, !panel.isKeyWindow, !store.alertHeld { return }
        let current = model.size(store)
        if Self.pinOpen {
            if !model.hovering { model.hovering = true; DispatchQueue.main.async { self.model.revealed = true } }
            panel.ignoresMouseEvents = false; return
        }
        let pad: CGFloat = model.hovering ? 10 : 0
        // When idle/compact, a slightly wider band under the notch triggers expansion.
        let w = current.width + pad * 2 + (model.hovering ? 0 : 16)
        let h = current.height + pad + (model.hovering ? 0 : 4)
        let rect = NSRect(x: f.midX - w / 2, y: f.maxY - h, width: w, height: h)
        let inside = rect.contains(p)
        panel.ignoresMouseEvents = !inside
        if inside { NSCursor.arrow.set() }
        store.alertHeld = inside
        // Take key status while the pointer is over the island: mouse-moved/cursor events go to the key
        // window, so this is what stops the app underneath from forcing its I-beam (and lets ⌘Y/⌘N work).
        // The panel is non-activating, so the frontmost app stays active and gets focus back on exit.
        let wantsKey = inside
        if wantsKey && !panel.isKeyWindow { panel.makeKey() } else if !wantsKey && panel.isKeyWindow { panel.resignKey() }
        guard inside != model.hovering else { hoverWork?.cancel(); hoverWork = nil; return }
        guard hoverWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hoverWork = nil
            self.model.hovering = inside
            if Self.debug { FileHandle.standardError.write("hover \(inside) \(NSEvent.mouseLocation) \(rect) \(Date().timeIntervalSince1970)\n".data(using: .utf8)!) }
            self.model.holdBanner = inside && self.store.alert != nil
            if inside {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { if self.model.hovering { self.model.revealed = true } }
            } else {
                self.model.revealed = false
                self.model.selected = nil
            }
            if inside && !self.model.holdBanner { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
            self.trackMouse()
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (inside ? 0.08 : 0.3), execute: work)
    }
}

let app = NSApplication.shared
/// NotchAgents is often started from a terminal that is itself running an agent (installing with
/// build.sh from inside Claude Code or Codex, development), and every app it later opens would inherit
/// that session's variables: Claude.app started with `CLAUDE_CONFIG_DIR` reads another folder and its
/// sessions seem to vanish, `CODEX_HOME` does the same to Codex, and API keys would leak into other apps.
/// Keep the values NotchAgents itself needs, then drop every agent variable that wasn't set for the
/// whole login session (`launchctl setenv`, which apps opened from the Dock see anyway).
enum LaunchEnvironment {
    static let claudeConfigDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
    static let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]

    private static let prefixes = ["CLAUDE", "ANTHROPIC_", "CODEX_", "OPENAI_", "OPENCODE"]

    static func scrub() {
        _ = (claudeConfigDir, codexHome)
        for key in ProcessInfo.processInfo.environment.keys where prefixes.contains(where: key.hasPrefix) && !loginWide(key) {
            unsetenv(key)
        }
    }

    private static func loginWide(_ key: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["getenv", key]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return !out.allSatisfy { $0 == 0x0A }
    }
}
LaunchEnvironment.scrub()

// `NotchAgents --scan` prints which agent processes are detected (diagnostics).
if CommandLine.arguments.contains("--scan") { print(ProcessScanner.scan()); exit(0) }
// `NotchAgents --usage` prints the Claude config dirs found and today's spend (diagnostics).
if CommandLine.arguments.contains("--usage") {
    print("config dirs:", ClaudeDirs.all.map(\.path))
    print("hooks installed:", ClaudeDirs.hooksInstalled)
    let today = UsageLedger().today()
    print("today:", today.isEmpty ? "none" : today.map { "\($0.key.title) " + String(format: "$%.2f", $0.value) }.sorted().joined(separator: ", "))
    exit(0)
}
if CommandLine.arguments.contains("--sounds") { MainActor.assumeIsolated { SFX.audition() }; exit(0) }
if let i = CommandLine.arguments.firstIndex(of: "--render-preview"), i + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated { IslandPreview.render(to: CommandLine.arguments[i + 1]) }
    exit(0)
}
// `NotchAgents --render-icon out.png` draws the app icon (used by build.sh) and exits.
if let i = CommandLine.arguments.firstIndex(of: "--render-icon"), i + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated { AppIcon.render(to: CommandLine.arguments[i + 1]) }
    exit(0)
}
// `NotchAgents --render-dmg-background <dir>` draws the DMG window background (used by make_dmg.sh) and exits.
if let i = CommandLine.arguments.firstIndex(of: "--render-dmg-background"), i + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated { AppIcon.renderDMGBackground(to: CommandLine.arguments[i + 1]) }
    exit(0)
}
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
