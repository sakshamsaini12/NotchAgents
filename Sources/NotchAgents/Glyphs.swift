import SwiftUI

extension AgentKind {
    /// Four-stop palette: light, core, deep, highlight. Feeds the mesh tiles, rings and island tint.
    var gradient: [Color] {
        // Claude: two oranges (deep for the CLI, warm tangerine for the app). Codex: blue.
        switch self {
        case .claudeCLI: [Color(hex: 0xFF9A4D), Color(hex: 0xE8641C), Color(hex: 0x9E3209), Color(hex: 0xFFD9B8)]
        case .claudeApp: [Color(hex: 0xFFC27A), Color(hex: 0xF49530), Color(hex: 0xB5560F), Color(hex: 0xFFEBCF)]
        case .codex: [Color(hex: 0x7FD0FF), Color(hex: 0x4A5CFF), Color(hex: 0x2A2FC0), Color(hex: 0x9BF0FF)]
        // Process-detected agents: each its own hue, clear of Claude's orange and Codex's blue.
        case .opencode: [Color(hex: 0xF2F4F7), Color(hex: 0xB0BAC6), Color(hex: 0x56616E), Color(hex: 0xFFFFFF)]
        case .cursor: [Color(hex: 0xC9C2FF), Color(hex: 0x8C7CFF), Color(hex: 0x4B3BC4), Color(hex: 0xEDE9FF)]
        case .gemini: [Color(hex: 0xF29BD8), Color(hex: 0xB86BF0), Color(hex: 0x6A35B8), Color(hex: 0xFFD6F3)]
        case .copilot: [Color(hex: 0xE2F57A), Color(hex: 0xB4D82E), Color(hex: 0x6C8A10), Color(hex: 0xF6FFC8)]
        case .amp: [Color(hex: 0xFF8A8A), Color(hex: 0xF0453F), Color(hex: 0x9E1C18), Color(hex: 0xFFD3D1)]
        case .aider: [Color(hex: 0x9BF59B), Color(hex: 0x3FCF5A), Color(hex: 0x1D7A2E), Color(hex: 0xD8FFD8)]
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

let amber = Color(hex: 0xF5B53F)
let amberPalette = [Color(hex: 0xF7C25A), Color(hex: 0xEE8F2E), Color(hex: 0xC8551F), Color(hex: 0xFFE3A3)]

/// Animated 3×3 mesh-gradient field. Interior control points drift on slow sine paths.
struct MeshField: View {
    let palette: [Color]
    var speed: Double = 0.4
    var amplitude: Float = 0.08
    var paused = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: paused)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate * speed
            let s = { (k: Double) in Float(sin(t + k)) * amplitude }
            let p = palette
            MeshGradient(
                width: 3, height: 3,
                points: [
                    [0, 0], [0.5 + s(0), 0], [1, 0],
                    [0, 0.5 + s(1.3)], [0.5 + s(2.1), 0.5 + s(3.4)], [1, 0.5 + s(4.2)],
                    [0, 1], [0.5 + s(5.1), 1], [1, 1],
                ],
                colors: [p[3], p[0], p[1],
                         p[0], p[1], p[2],
                         p[1], p[2], p[2]],
                smoothsColors: true
            )
        }
    }
}

/// Deep, mostly-black version of a palette for mesh backgrounds: colour lives in the shadows.
func darkMesh(_ p: [Color], strength: Double = 1) -> [Color] {
    let k = 1 - 0.55 * strength
    return [p[0].mix(with: .black, by: min(1, 0.78 + 0.2 * (1 - strength))),  // top-left glow
            p[1].mix(with: .black, by: min(1, 0.6 * k + 0.4)),                 // edges
            p[2].mix(with: .black, by: min(1, 0.35 * k + 0.3)),                // core
            Color(white: 0.015)]                                               // corners
        .enumerated().map { $0.element }
        .reorderedForMesh()
}

private extension Array where Element == Color {
    /// MeshField maps [light, mid, deep, highlight]; place black in the corners and depth in the centre.
    func reorderedForMesh() -> [Color] { [self[1], self[2], self[3], self[0]] }
}

/// Agent icon: a near-black squircle holding a slow, dark mesh gradient; the agent's colour lives
/// Agent character: a glossy orb with two pill eyes. Orange for Claude, blue for Codex.
/// The eyes carry the state — scanning while a tool runs, drifting up while thinking,
/// wide and bouncing when it needs you, closed when asleep — with a blink every few seconds.
struct AgentGlyph: View {
    let kind: AgentKind
    let status: AgentStatus
    var size: CGFloat = 18

    var body: some View {
        // Idle orbs only drift slowly, so a low frame rate looks the same and costs a fraction;
        // the canvas renders off the main thread.
        let fps: Double = !(status.isBusy || status == .waiting) ? 12 : size < 30 ? 30 : 60
        TimelineView(.animation(minimumInterval: 1 / fps, paused: status == .offline)) { tl in
            Canvas(rendersAsynchronously: true) { ctx, sz in
                OrbPainter(kind: kind, status: status, t: tl.date.timeIntervalSinceReferenceDate).draw(&ctx, sz)
            }
        }
        .frame(width: size, height: size)
        // Coloured glow beneath, drawn outside the canvas so it never clips to a square.
        .shadow(color: kind.gradient[0].opacity(status.isBusy || status == .waiting ? 0.75 : 0.35), radius: size * 0.16, y: size * 0.12)
        .overlay { if status == .waiting { Ripple(size: size) } }
        .saturation(status == .offline ? 0.35 : 1)
        .opacity(status == .offline ? 0.6 : 1)
        .animation(.smooth(duration: 0.6), value: status)
    }
}

/// Shared, non-observed state the orbs read every frame: where the pointer is, and short-lived
/// moods (celebrating a finished task, reacting to a click).
enum BotMood {
    static var pointer: CGPoint?
    static var origin: CGPoint = .zero
    static var liveOrder: [AgentKind] = []
    static var happyUntil: [AgentKind: Date] = [:]
    static var pokedAt: [AgentKind: Date] = [:]
    /// Current tool per agent, so the eyes can act it out.
    static var tools: [AgentKind: String] = [:]

    static func celebrate(_ k: AgentKind, for s: Double = 3.5) { happyUntil[k] = Date().addingTimeInterval(s) }
    static func poke(_ k: AgentKind) { pokedAt[k] = Date() }
}

struct OrbPainter {
    let kind: AgentKind
    let status: AgentStatus
    let t: Double

    /// Each agent gets its own clock offset so they never blink in sync.
    private var seed: Double { Double(AgentKind.allCases.firstIndex(of: kind) ?? 0) * 1.7 }

    func draw(_ ctx: inout GraphicsContext, _ sz: CGSize) {
        let p = kind.gradient
        let busy = status.isBusy, waiting = status == .waiting
        let lt = t + seed

        // Float + gentle squash; quicker and springier when something is happening.
        let bobSpeed = waiting ? 6.0 : busy ? 3.2 : 1.4
        let now = Date()
        let happy = (BotMood.happyUntil[kind] ?? .distantPast) > now
        let pokeAge = now.timeIntervalSince(BotMood.pokedAt[kind] ?? .distantPast)
        var bob = sin(lt * bobSpeed) * (waiting ? 0.06 : busy ? 0.035 : 0.02)
        var squash = 1 + sin(lt * bobSpeed * 2) * (waiting ? 0.04 : 0.018)
        var breathe = 1.0
        switch status {
        case .thinking:                     // slow, deep breathing
            bob = sin(lt * 1.6) * 0.025; squash = 1; breathe = 1 + 0.035 * sin(lt * 2.2)
        case .tool:                         // busy little hops with a typing squash
            bob = -abs(sin(lt * 4.5)) * 0.03; squash = 1 + 0.035 * sin(lt * 9)
        default: break
        }
        if happy { bob -= abs(sin(lt * 7)) * 0.08 }                                    // celebratory hops
        if pokeAge < 0.9 { squash += 0.2 * exp(-pokeAge * 5) * cos(pokeAge * 26) }     // jelly wobble
        // Shrink a touch while busy so the orbiting particles fit inside the frame.
        let r = min(sz.width, sz.height) * (busy ? 0.39 : 0.44) * breathe
        let c = CGPoint(x: sz.width / 2, y: sz.height / 2 + bob * sz.height)
        let orbiters = particles(c: c, r: r, lt: lt)
        for o in orbiters where o.depth < 0 { ctx.fill(o.path, with: .color(o.color)) }
        let body = CGRect(x: c.x - r * squash, y: c.y - r / squash, width: 2 * r * squash, height: 2 * r / squash)
        let orb = Path(ellipseIn: body)

        // Soft, frosted sphere: saturated core, misty pale rim, light pooling at the bottom.
        ctx.fill(orb, with: .radialGradient(
            Gradient(colors: [p[1], p[1], p[0]]),
            center: CGPoint(x: c.x, y: c.y - r * 0.1), startRadius: 0, endRadius: r * 1.05))
        var inner = ctx
        inner.clip(to: orb)
        inner.fill(orb, with: .radialGradient(
            Gradient(stops: [.init(color: .white.opacity(0), location: 0.62), .init(color: .white.opacity(0.5), location: 1)]),
            center: c, startRadius: 0, endRadius: r))
        inner.fill(orb, with: .radialGradient(
            Gradient(colors: [p[3].opacity(0.95), p[0].opacity(0.5), p[0].opacity(0)]),
            center: CGPoint(x: c.x, y: body.maxY + r * 0.05), startRadius: 0, endRadius: r * 0.85))
        if status == .thinking {
            // Light swirling slowly inside the orb.
            var swirl = inner
            swirl.addFilter(.blur(radius: r * 0.3))
            let a = lt * 1.8
            let sc = CGPoint(x: c.x + cos(a) * r * 0.42, y: c.y + sin(a) * r * 0.42)
            swirl.fill(Path(ellipseIn: CGRect(x: sc.x - r * 0.45, y: sc.y - r * 0.45, width: r * 0.9, height: r * 0.9)),
                       with: .color(p[3].opacity(0.55)))
        }
        // Faint, wide sheen on top rather than a hard highlight.
        inner.addFilter(.blur(radius: r * 0.2))
        inner.fill(Path(ellipseIn: CGRect(x: c.x - r * 0.55, y: body.minY + r * 0.05, width: r * 1.1, height: r * 0.5)),
                   with: .color(.white.opacity(0.22)))

        drawEyes(&ctx, c: c, r: r, lt: lt, joyful: happy || pokeAge < 0.9)
        for o in orbiters where o.depth >= 0 { ctx.fill(o.path, with: .color(o.color)) }
    }

    /// Particles on a tilted orbit, split into behind/in-front by depth for a 3D pass around the orb.
    /// Thinking: three soft thought-motes drifting slowly. Working: a bright comet with a trail.
    private func particles(c: CGPoint, r: CGFloat, lt: Double) -> [(path: Path, color: Color, depth: Double)] {
        let p = kind.gradient
        // A Saturn-style ring sitting low on the orb, so the front pass runs beneath the face.
        let tilt = -0.22, R = r * 1.18, oc = CGPoint(x: c.x, y: c.y + r * 0.42)
        func at(_ a: Double) -> (CGPoint, Double) {
            let px = cos(a) * R, py = sin(a) * R * 0.3
            return (CGPoint(x: oc.x + px * cos(tilt) - py * sin(tilt), y: oc.y + px * sin(tilt) + py * cos(tilt)), sin(a))
        }
        func dot(_ pt: CGPoint, _ d: CGFloat) -> Path { Path(ellipseIn: CGRect(x: pt.x - d / 2, y: pt.y - d / 2, width: d, height: d)) }
        switch status {
        case .thinking:
            return (0..<3).map { k in
                let (pt, depth) = at(lt * 1.3 + Double(k) * 2 * .pi / 3)
                let d = r * 0.2 * (0.75 + 0.25 * depth)
                return (dot(pt, d), p[3].mix(with: .white, by: 0.4).opacity(0.55 + 0.45 * (depth + 1) / 2), depth)
            }
        case .tool:
            return (0..<11).map { k in
                let (pt, depth) = at(lt * 5 - Double(k) * 0.14)
                let fade = 1 - Double(k) / 11
                let d = r * (k == 0 ? 0.24 : 0.17 * fade) * (0.8 + 0.2 * depth)
                let col = (k == 0 ? Color.white : p[0].mix(with: p[3], by: fade))
                return (dot(pt, d), col.opacity((0.35 + 0.65 * fade) * (0.6 + 0.4 * (depth + 1) / 2)), depth)
            }
        default: return []
        }
    }

    private func drawEyes(_ ctx: inout GraphicsContext, c: CGPoint, r: CGFloat, lt: Double, joyful: Bool) {
        let eye = Color.white.opacity(0.92)
        let gap = r * 0.3
        let base = CGPoint(x: c.x, y: c.y - r * 0.06)

        if status == .offline {
            // Asleep: two gentle downward arcs.
            for side in [-1.0, 1.0] {
                var arc = Path()
                let x = base.x + side * gap
                arc.move(to: CGPoint(x: x - r * 0.12, y: base.y))
                arc.addQuadCurve(to: CGPoint(x: x + r * 0.12, y: base.y), control: CGPoint(x: x, y: base.y + r * 0.12))
                ctx.stroke(arc, with: .color(eye.opacity(0.85)), style: StrokeStyle(lineWidth: max(1, r * 0.09), lineCap: .round))
            }
            return
        }

        if joyful {
            // Happy squint: two upturned arcs.
            for side in [-1.0, 1.0] {
                var arc = Path()
                let x = base.x + side * gap
                arc.move(to: CGPoint(x: x - r * 0.13, y: base.y + r * 0.05))
                arc.addQuadCurve(to: CGPoint(x: x + r * 0.13, y: base.y + r * 0.05), control: CGPoint(x: x, y: base.y - r * 0.15))
                ctx.stroke(arc, with: .color(eye), style: StrokeStyle(lineWidth: max(1.1, r * 0.11), lineCap: .round))
            }
            return
        }

        // Gaze, as a fraction of the radius.
        var gx = 0.0, gy = 0.0
        switch status {
        case .tool:                                                               // act out the tool
            let tool = (BotMood.tools[kind] ?? "").lowercased()
            if ["edit", "write", "patch", "notebook"].contains(where: tool.contains) {
                gx = sin(lt * 7) * 0.05; gy = 0.13                                // typing: eyes down
            } else if ["bash", "exec", "shell", "command"].contains(where: tool.contains) {
                gx = 0.1; gy = 0.1 + sin(lt * 11) * 0.02                          // watching output
            } else if ["task", "agent"].contains(where: tool.contains) {
                gx = sin(lt * 1.7) * 0.16; gy = cos(lt * 1.3) * 0.08              // keeping an eye on helpers
            } else {
                gx = sin(lt * 4.2) * 0.16                                         // reading / searching
            }
        case .thinking: gx = cos(lt * 0.8) * 0.12; gy = -0.14 + sin(lt * 0.8) * 0.04   // pondering, gaze up
        case .waiting: gy = 0.02                                                  // looking at you
        default:                                                                  // idle glances
            let phase = (lt / 4).truncatingRemainder(dividingBy: 3)
            gx = phase < 1 ? 0 : phase < 2 ? 0.1 : -0.08
            // With company, now and then look over at the neighbour.
            let order = BotMood.liveOrder
            if order.count > 1, let i = order.firstIndex(of: kind), (lt / 5).truncatingRemainder(dividingBy: 2) < 0.8 {
                gx = i == 0 ? 0.15 : -0.15
            }
        }
        // Follow the pointer when it's near the notch (except while reading).
        if !status.isBusy, let p = BotMood.pointer {
            let dx = p.x - BotMood.origin.x, dy = BotMood.origin.y - p.y
            if hypot(dx, dy) < 520 {
                gx = max(-1, min(1, dx / 320)) * 0.17
                gy = max(-0.4, min(1, dy / 220)) * 0.14
            }
        }

        // Blink: ~0.14s every 3.6s.
        let bt = (lt + seed).truncatingRemainder(dividingBy: 3.6)
        let blink = bt < 0.14 ? 1 - sin(bt / 0.14 * .pi) * 0.9 : 1.0

        var w = r * 0.15
        var h = r * (status == .waiting ? 0.44 : 0.36) * blink
        if status == .thinking { h *= 0.72 }                 // half-lidded, lost in thought
        if status == .tool { h *= 0.85; w *= 1.1 }          // focused
        let round = kind == .claudeApp   // the desktop app gets round eyes, the CLIs pill eyes
        for side in [-1.0, 1.0] {
            let x = base.x + side * gap + gx * r
            let y = base.y + gy * r
            let rect = round
                ? CGRect(x: x - w * 0.75, y: y - min(h, w * 1.5) / 2, width: w * 1.5, height: min(h, w * 1.5))
                : CGRect(x: x - w / 2, y: y - h / 2, width: w, height: h)
            ctx.fill(Path(roundedRect: rect, cornerRadius: min(rect.width, rect.height) / 2), with: .color(eye))
        }
    }
}

private struct LightSweep: View {
    let size: CGFloat
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { tl in
            let p = CGFloat((tl.date.timeIntervalSinceReferenceDate * 0.7).truncatingRemainder(dividingBy: 1))
            LinearGradient(colors: [.clear, .white.opacity(0.12), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: size * 0.5, height: size * 2)
                .rotationEffect(.degrees(25))
                .offset(x: -size * 1.1 + p * size * 2.2)
        }
    }
}

private struct Ripple: View {
    let size: CGFloat
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(0..<2, id: \.self) { k in
                    let p = CGFloat((t * 0.8 + Double(k) * 0.5).truncatingRemainder(dividingBy: 1))
                    Circle()
                        .stroke(amber.opacity(0.7 * (1 - p)), lineWidth: 1)
                        .frame(width: size * (1 + 0.5 * p), height: size * (1 + 0.5 * p))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// The white mark at the centre of a tile.
private struct MarkCanvas: View {
    let kind: AgentKind
    let status: AgentStatus

    var body: some View {
        TimelineView(.animation(minimumInterval: status.isBusy ? 1 / 60 : 1 / 20, paused: status == .offline)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let e: Double = status == .tool ? 1 : status == .thinking ? 0.8 : 0.1
            Canvas { ctx, sz in
                let c = CGPoint(x: sz.width / 2, y: sz.height / 2)
                let R = min(sz.width, sz.height) * 0.56 * (1 + 0.05 * e * sin(t * 3.2))
                switch kind {
                case .claudeCLI: Self.terminal(ctx, c, R, t, e)
                case .claudeApp: Self.star(ctx, c, R, t, e)
                case .codex: Self.hex(ctx, c, R, t, e)
                default: Self.terminal(ctx, c, R, t, e)
                }
            }
        }
    }

    static func terminal(_ ctx: GraphicsContext, _ c: CGPoint, _ R: CGFloat, _ t: Double, _ e: Double) {
        let lw = max(1.5, R * 0.14)
        var chev = Path()
        chev.move(to: CGPoint(x: c.x - R * 0.38, y: c.y - R * 0.26))
        chev.addLine(to: CGPoint(x: c.x - R * 0.1, y: c.y))
        chev.addLine(to: CGPoint(x: c.x - R * 0.38, y: c.y + R * 0.26))
        ctx.stroke(chev, with: .color(.white), style: StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round))
        let blink = e > 0.5 ? (sin(t * .pi * 2) > -0.2 ? 1.0 : 0.15) : 1
        var line = Path()
        line.move(to: CGPoint(x: c.x + R * 0.06, y: c.y + R * 0.26))
        line.addLine(to: CGPoint(x: c.x + R * 0.4, y: c.y + R * 0.26))
        ctx.stroke(line, with: .color(.white.opacity(blink)), style: StrokeStyle(lineWidth: lw, lineCap: .round))
    }

    static func star(_ ctx: GraphicsContext, _ c: CGPoint, _ R: CGFloat, _ t: Double, _ e: Double) {
        let rot = t * (0.1 + 0.7 * e)
        var p = Path()
        for i in 0..<12 {
            let a = Double(i) / 12 * .pi * 2 + rot
            let len = R * (i.isMultiple(of: 2) ? 0.5 : 0.36)
            p.move(to: CGPoint(x: c.x + cos(a) * R * 0.08, y: c.y + sin(a) * R * 0.08))
            p.addLine(to: CGPoint(x: c.x + cos(a) * len, y: c.y + sin(a) * len))
        }
        ctx.stroke(p, with: .color(.white), style: StrokeStyle(lineWidth: max(1.2, R * 0.11), lineCap: .round))
    }

    static func hex(_ ctx: GraphicsContext, _ c: CGPoint, _ R: CGFloat, _ t: Double, _ e: Double) {
        let rot = t * 0.6 * e
        var hex = Path()
        for i in 0..<6 {
            let a = Double(i) / 6 * .pi * 2 + rot - .pi / 2
            let pt = CGPoint(x: c.x + cos(a) * R * 0.42, y: c.y + sin(a) * R * 0.42)
            i == 0 ? hex.move(to: pt) : hex.addLine(to: pt)
        }
        hex.closeSubpath()
        ctx.stroke(hex, with: .color(.white), style: StrokeStyle(lineWidth: max(1.5, R * 0.12), lineJoin: .round))
        let d = R * (0.1 + 0.03 * e * sin(t * 4))
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - d, y: c.y - d, width: d * 2, height: d * 2)), with: .color(.white))
    }
}

/// Gradient ring showing context-window fill.
struct ContextRing: View {
    let fraction: Double
    let colors: [Color]
    var lineWidth: CGFloat = 2.5

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.07), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, fraction))
                .stroke(AngularGradient(colors: colors + [colors[0]], center: .center,
                                        startAngle: .degrees(0), endAngle: .degrees(360 * max(fraction, 0.01))),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: colors[1].opacity(0.5), radius: 3)
        }
        .animation(.smooth(duration: 0.8), value: fraction)
    }
}

/// Live waveform for the compact island.
struct ActivityBars: View {
    let colors: [Color]
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            Canvas { ctx, sz in
                let n = 5
                let bw = sz.width / CGFloat(n * 2 - 1)
                let shading = GraphicsContext.Shading.linearGradient(Gradient(colors: colors.count > 1 ? colors : colors + colors),
                                                                     startPoint: .zero, endPoint: CGPoint(x: sz.width, y: 0))
                var path = Path()
                for i in 0..<n {
                    let center = 1 - abs(Double(i) - 2) / 3
                    let v = 0.25 + 0.75 * center * (sin(t * (4.5 + Double(i) * 1.1) + Double(i) * 1.9) + 1) / 2
                    let bh = max(bw, sz.height * v)
                    path.addRoundedRect(in: CGRect(x: CGFloat(i) * bw * 2, y: (sz.height - bh) / 2, width: bw, height: bh),
                                        cornerSize: CGSize(width: bw / 2, height: bw / 2))
                }
                ctx.fill(path, with: shading)
            }
        }
    }
}

/// Rotating multi-hue light along the island's edge while agents work — the island's own
/// version of the Siri edge glow. Clipped by the island, so it reads as an inner rim light.
struct IntelligenceGlow<S: Shape>: View {
    let shape: S
    let colors: [Color]
    var intensity: Double = 1
    var topFade: CGFloat = 0.3

    var body: some View {
        // Ambient and slow-moving: 30 fps is plenty, and drawingGroup rasterises the blurred conic
        // strokes on the GPU instead of the CPU every frame.
        TimelineView(.animation(minimumInterval: 1 / 30, paused: colors.isEmpty)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let stops = colors.isEmpty ? [Color.clear] : colors + [colors[0]]
            let g = AngularGradient(colors: stops, center: .center, angle: .degrees((t * 70).truncatingRemainder(dividingBy: 360)))
            ZStack {
                shape.stroke(g, lineWidth: 4).blur(radius: 5).opacity(0.45)
                shape.stroke(g, lineWidth: 1.2).opacity(0.9)
            }
            .drawingGroup()
            .opacity(intensity)
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: topFade)],
                                 startPoint: .top, endPoint: .bottom))
        }
        .allowsHitTesting(false)
    }
}

/// Text with a light sweep passing through it while active.
struct ShimmerText: View {
    let text: String
    let color: Color
    let active: Bool
    var mono = false
    var size: CGFloat = 11

    var body: some View {
        let label = Text(text)
            .font(.system(size: size, weight: .medium, design: mono ? .monospaced : .default))
        label
            .foregroundStyle(color.opacity(active ? 0.6 : 0.85))
            .lineLimit(1).truncationMode(.middle)
            .overlay {
                if active {
                    TimelineView(.animation(minimumInterval: 1 / 30)) { tl in
                        let p = CGFloat((tl.date.timeIntervalSinceReferenceDate * 0.55).truncatingRemainder(dividingBy: 1))
                        GeometryReader { g in
                            LinearGradient(colors: [.clear, .white.opacity(0.95), .clear], startPoint: .leading, endPoint: .trailing)
                                .frame(width: max(40, g.size.width * 0.35))
                                .offset(x: -g.size.width * 0.35 + p * g.size.width * 1.7)
                        }
                    }
                    .mask(label.lineLimit(1).truncationMode(.middle))
                    .allowsHitTesting(false)
                }
            }
    }
}
