import AppKit
import SwiftUI

/// Menu bar item (next to Control Center) that opens a small frosted-glass panel with every agent
/// and the plan usage at a glance.
@MainActor
final class MenuBarController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()

    init(store: AgentStore) {
        super.init()
        popover.behavior = .transient
        popover.animates = true
        popover.appearance = NSAppearance(named: .vibrantDark)
        popover.contentViewController = NSHostingController(rootView: MenuBarView(store: store))
        if let b = item.button {
            b.image = Self.orbIcon
            b.toolTip = "NotchAgents"
            b.target = self
            b.action = #selector(toggle)
        }
    }

    @objc private func toggle() {
        guard let b = item.button else { return }
        if popover.isShown { popover.performClose(nil) } else {
            popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    /// Template orb with two eyes, so it tints like the system icons.
    private static let orbIcon: NSImage = {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { r in
            let orb = NSBezierPath(ovalIn: r.insetBy(dx: 2, dy: 2))
            for x in [6.6, 10.2] { orb.append(NSBezierPath(roundedRect: NSRect(x: x, y: 7.4, width: 1.6, height: 3.6), xRadius: 0.8, yRadius: 0.8)) }
            orb.windingRule = .evenOdd
            NSColor.black.setFill(); orb.fill()
            return true
        }
        img.isTemplate = true
        return img
    }()
}

struct MenuBarView: View {
    @ObservedObject var store: AgentStore

    var body: some View {
        let codex = store.agents[.codex]
        VStack(alignment: .leading, spacing: 14) {
            Text("Agents").font(.system(size: 13, weight: .semibold))
            if store.liveAgents.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("No agents running").font(.system(size: 12, weight: .medium))
                    Text("Start Claude Code, Codex or OpenCode and it shows up here.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(spacing: 10) {
                ForEach(store.listed) { a in row(a) }
            }
            if [AgentKind.claudeCLI, .claudeApp, .codex].contains(where: { store.agents[$0]?.limit5h != nil || store.agents[$0]?.limitWeek != nil }) {
                Divider().opacity(0.5)
                Text("Usage").font(.system(size: 13, weight: .semibold))
                // CLI and App can be signed in to different accounts, so each shows its own limits.
                let claudes = [AgentKind.claudeCLI, .claudeApp].compactMap { store.agents[$0] }.filter { $0.limit5h != nil || $0.limitWeek != nil }
                ForEach(claudes) { c in usage(claudes.count > 1 ? c.kind.title : "Claude", c) }
                if let c = codex, c.limit5h != nil || c.limitWeek != nil { usage("Codex", c) }
            }
            Divider().opacity(0.5)
            HookStatus(store: store)
            if !store.hooksInstalled, Bundle.main.url(forResource: "notch-hook", withExtension: "sh") != nil {
                Button("Install Claude Code hooks") { store.installHooks() }.controlSize(.small)
            }
            Toggle("Sound effects", isOn: $store.soundsOn)
                .toggleStyle(.switch).controlSize(.mini).font(.system(size: 11))
            HStack {
                Text("Hover the notch for details").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.controlSize(.small)
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    private func row(_ a: Agent) -> some View {
        HStack(spacing: 10) {
            AgentGlyph(kind: a.kind, status: a.status, size: 26)
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(a.kind.title).font(.system(size: 12, weight: .medium))
                Text(a.live ? (a.tool.map { "\(a.status.label) · \($0)" } ?? a.status.label) : "Not running")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if a.live, a.contextUsed > 0 {
                Text("\(Int(a.contextFraction * 100))% ctx")
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .opacity(a.live ? 1 : 0.55)
    }

    private func usage(_ name: String, _ a: Agent) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(name).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            if let h = a.limit5h { bar("5-hour", h, a.reset5h, a.kind.gradient) }
            if let w = a.limitWeek { bar("Weekly", w, a.resetWeek, a.kind.gradient) }
        }
    }

    private func bar(_ label: String, _ pct: Double, _ reset: Date?, _ pal: [Color]) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 11)).frame(width: 46, alignment: .leading)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.1))
                    Capsule().fill(LinearGradient(colors: [pal[0], pal[1]], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(4, g.size.width * min(1, pct / 100)))
                }
            }
            .frame(height: 5)
            Text("\(Int(pct.rounded()))%").font(.system(size: 11).monospacedDigit()).frame(width: 34, alignment: .trailing)
            if let r = reset, r > Date() {
                Text(RelativeTime.short(r.timeIntervalSinceNow)).font(.system(size: 10).monospacedDigit()).foregroundStyle(.tertiary).frame(width: 34, alignment: .trailing)
            }
        }
    }
}
