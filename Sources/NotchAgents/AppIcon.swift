import SwiftUI

/// The app icon: the notch comes alive. A big black notch hangs from the top of a plain white squircle
/// (the website's #F4F4F6 paper) and looks out with two glowing eyes, Claude orange and Codex blue, over a
/// thin rim-light edge. One bold shape that fills the body, so it still reads at 16 px. Drawn in a single
/// Canvas inside the standard 824 pt icon body of the 1024 pt canvas.
struct AppIconView: View {
    var body: some View {
        Canvas { ctx, _ in Self.draw(&ctx) }.frame(width: 1024, height: 1024)
    }

    private static func draw(_ ctx: inout GraphicsContext) {
        let orange = AgentKind.claudeCLI.gradient, blue = AgentKind.codex.gradient
        let bodyRect = CGRect(x: 100, y: 100, width: 824, height: 824)
        let squircle = Path(roundedRect: bodyRect, cornerRadius: 185, style: .continuous)
        let n = CGRect(x: 512 - 330, y: bodyRect.minY, width: 660, height: 590)
        let (t, b): (CGFloat, CGFloat) = (52, 210)
        let notch = NotchShape(topRadius: t, bottomRadius: b).path(in: n)
        let rim = GraphicsContext.Shading.linearGradient(Gradient(colors: [orange[0], Color(hex: 0xFF5C8A), Color(hex: 0x7FB8FF)]),
                                                         startPoint: CGPoint(x: n.minX, y: 0), endPoint: CGPoint(x: n.maxX, y: 0))
        // The lit bottom edge of the notch, as on the website's mark.
        var edge = Path()
        edge.move(to: CGPoint(x: n.minX + t, y: n.maxY - b))
        edge.addQuadCurve(to: CGPoint(x: n.minX + t + b, y: n.maxY), control: CGPoint(x: n.minX + t, y: n.maxY))
        edge.addLine(to: CGPoint(x: n.maxX - t - b, y: n.maxY))
        edge.addQuadCurve(to: CGPoint(x: n.maxX - t, y: n.maxY - b), control: CGPoint(x: n.maxX - t, y: n.maxY))

        // Drop shadow under the body.
        ctx.drawLayer { l in
            l.addFilter(.blur(radius: 16))
            l.translateBy(x: 0, y: 12)
            l.fill(squircle, with: .color(.black.opacity(0.22)))
        }

        ctx.drawLayer { c in
            c.clip(to: squircle)
            c.fill(squircle, with: .color(Color(hex: 0xF4F4F6)))
            c.fill(notch, with: .color(Color(hex: 0x0E0F13)))
            c.drawLayer { l in
                l.clip(to: notch)
                // Taper the rim in as it comes round the corners, instead of starting abruptly.
                l.drawLayer { e in
                    e.stroke(edge, with: rim, style: StrokeStyle(lineWidth: 14))
                    e.blendMode = .destinationIn
                    e.fill(Path(n), with: .linearGradient(Gradient(colors: [.clear, .black]),
                                                          startPoint: CGPoint(x: 0, y: n.maxY - b), endPoint: CGPoint(x: 0, y: n.maxY - b * 0.45)))
                }
                // The eyes: a soft glow inside the black, then a bright core.
                for (x, pal) in [(n.midX - 128, orange), (n.midX + 128, blue)] {
                    let eye = CGRect(x: x - 50, y: n.minY + 150, width: 100, height: 230)
                    l.drawLayer { g in
                        g.addFilter(.blur(radius: 34))
                        g.opacity = 0.75
                        g.fill(Path(roundedRect: eye.insetBy(dx: -18, dy: -18), cornerRadius: 70), with: .color(pal[1]))
                    }
                    l.fill(Path(roundedRect: eye, cornerRadius: 50),
                           with: .linearGradient(Gradient(colors: [pal[3], pal[0]]),
                                                 startPoint: CGPoint(x: 0, y: eye.minY), endPoint: CGPoint(x: 0, y: eye.maxY)))
                }
            }
            c.stroke(squircle, with: .color(.black.opacity(0.08)), lineWidth: 3)
        }
    }
}

/// Background of the DMG window (660 × 420 pt): plain website paper, the notch with both bots hanging
/// from the top, and a quiet arrow showing where to drag the app. Finder draws icon labels in black, so
/// the light paper keeps them readable. Finder places the icons at (170, 250) and (490, 250).
struct DMGBackgroundView: View {
    static let size = CGSize(width: 660, height: 420)

    var body: some View {
        let orange = AgentKind.claudeCLI.gradient
        let rim = LinearGradient(colors: [orange[0], Color(hex: 0xFF5C8A), Color(hex: 0x7FB8FF)], startPoint: .leading, endPoint: .trailing)
        let island = NotchShape(topRadius: 10, bottomRadius: 26)
        let ink = Color(hex: 0x0E0F13)

        ZStack(alignment: .top) {
            Color(hex: 0xF4F4F6)

            ZStack {
                island.fill(ink)
                island.stroke(rim, lineWidth: 3)
                    .mask(LinearGradient(colors: [.clear, .black], startPoint: UnitPoint(x: 0.5, y: 0.6), endPoint: .bottom))
                    .clipShape(island)
                HStack(spacing: 10) {
                    orb(.claudeCLI, size: 58)
                    orb(.codex, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("NotchAgents").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                        Text("Your agents, live in the notch").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                    }
                    .padding(.leading, 4)
                }
                .offset(y: 4)
            }
            .frame(width: 340, height: 92)
            .shadow(color: .black.opacity(0.18), radius: 16, y: 8)

            DragArc(head: false).stroke(ink.opacity(0.28), style: StrokeStyle(lineWidth: 3.5, lineCap: .round, dash: [1, 10]))
                .frame(width: Self.size.width, height: Self.size.height)
            DragArc(head: true).stroke(ink.opacity(0.28), style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
                .frame(width: Self.size.width, height: Self.size.height)

            Text("Drag NotchAgents into Applications")
                .font(.system(size: 13, weight: .medium)).foregroundStyle(ink.opacity(0.45))
                .offset(y: 368)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipped()
    }

    private func orb(_ kind: AgentKind, size: CGFloat) -> some View {
        Canvas { ctx, sz in OrbPainter(kind: kind, status: .idle, t: 0.5).draw(&ctx, sz) }
            .frame(width: size, height: size)
    }
}

/// Arc over the gap between the two Finder icons (`head: false`), or just its arrowhead.
private struct DragArc: Shape {
    let head: Bool
    func path(in r: CGRect) -> Path {
        var p = Path()
        let a = CGPoint(x: 250, y: 240), b = CGPoint(x: 408, y: 240)
        if head {
            p.move(to: CGPoint(x: b.x - 15, y: b.y - 14))
            p.addLine(to: b)
            p.addLine(to: CGPoint(x: b.x - 20, y: b.y + 1))
        } else {
            p.move(to: a)
            p.addQuadCurve(to: CGPoint(x: b.x - 4, y: b.y - 3), control: CGPoint(x: 329, y: 182))
        }
        return p
    }
}

enum AppIcon {
    @MainActor static func render(to path: String) {
        write(AppIconView(), scale: 1, to: path)
    }

    /// Writes `<dir>/background.png` and `background@2x.png` for the DMG window.
    @MainActor static func renderDMGBackground(to dir: String) {
        BotMood.celebrate(.claudeCLI, for: 60)
        write(DMGBackgroundView(), scale: 1, to: (dir as NSString).appendingPathComponent("background.png"))
        write(DMGBackgroundView(), scale: 2, to: (dir as NSString).appendingPathComponent("background@2x.png"))
    }

    @MainActor private static func write(_ view: some View, scale: CGFloat, to path: String) {
        let r = ImageRenderer(content: view)
        r.scale = scale
        guard let cg = r.cgImage else { fputs("render failed: \(path)\n", stderr); return }
        let rep = NSBitmapImageRep(cgImage: cg)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
