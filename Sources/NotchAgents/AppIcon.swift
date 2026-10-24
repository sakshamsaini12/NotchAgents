import SwiftUI

/// The app icon is the product itself: the island hanging from the top of a dark screen, with the
/// agents inside it and the multi-hue rim light the island shows while they work. Everything sits
/// inside the standard 824 pt icon body of the 1024 pt canvas.
struct AppIconView: View {
    private static let body = CGSize(width: 824, height: 824)
    private static let island = CGSize(width: 560, height: 420)

    var body: some View {
        let squircle = RoundedRectangle(cornerRadius: 185, style: .continuous)
        let orange = AgentKind.claudeCLI.gradient, blue = AgentKind.codex.gradient
        let hues = [orange[0], Color(hex: 0xFF5C8A), Color(hex: 0x9B6BFF), blue[0], orange[0]]
        let islandShape = NotchShape(topRadius: 0, bottomRadius: 150)

        ZStack {
            // Drop shadow under the icon body.
            squircle.fill(.black.opacity(0.4)).frame(width: Self.body.width, height: Self.body.height).blur(radius: 14).offset(y: 10)

            ZStack(alignment: .top) {
                // The screen: near-black glass with soft wallpaper light rising from below.
                LinearGradient(colors: [Color(hex: 0x17151E), Color(hex: 0x0A090E)], startPoint: .top, endPoint: .bottom)
                Ellipse().fill(Color(hex: 0x6A3BFF).opacity(0.5)).frame(width: 560, height: 320).blur(radius: 120).offset(x: -260, y: 660)
                Ellipse().fill(Color(hex: 0xFF5C8A).opacity(0.35)).frame(width: 520, height: 300).blur(radius: 120).offset(x: 260, y: 680)
                // The island's dot-matrix texture, lit from below and fading out towards the top.
                Canvas { ctx, sz in
                    let step: CGFloat = 26
                    for y in stride(from: step / 2, to: sz.height, by: step) {
                        for x in stride(from: step / 2, to: sz.width, by: step) {
                            ctx.fill(Path(ellipseIn: CGRect(x: x - 3, y: y - 3, width: 6, height: 6)), with: .color(.white))
                        }
                    }
                }
                .opacity(0.09)
                .mask(LinearGradient(colors: [.clear, .black], startPoint: UnitPoint(x: 0.5, y: 0.35), endPoint: .bottom))
                // Light the island spills onto the screen beneath it.
                Ellipse().fill(orange[0].opacity(0.3)).frame(width: 520, height: 200).blur(radius: 70).offset(y: 430)

                // The island, flush with the top edge.
                ZStack {
                    islandShape.fill(.black)
                    // Rim light: wide soft bloom plus a crisp edge, fading out towards the top like the app's.
                    ZStack {
                        islandShape.stroke(AngularGradient(colors: hues, center: .center, angle: .degrees(200)), lineWidth: 40).blur(radius: 26)
                        islandShape.stroke(AngularGradient(colors: hues, center: .center, angle: .degrees(200)), lineWidth: 8)
                    }
                    .mask(LinearGradient(stops: [.init(color: .clear, location: 0.05), .init(color: .black, location: 0.6)],
                                         startPoint: .top, endPoint: .bottom))
                    .clipShape(islandShape)

                    VStack(spacing: 46) {
                        HStack(alignment: .center, spacing: 30) {
                            orb(.claudeCLI, size: 210, t: 1)
                            orb(.codex, size: 160, t: 4.2)
                        }
                        // Usage meter, like the island's footer.
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.12))
                            Capsule().fill(LinearGradient(colors: [orange[0], Color(hex: 0xFF5C8A), blue[0]], startPoint: .leading, endPoint: .trailing))
                                .frame(width: 250)
                                .shadow(color: orange[0].opacity(0.8), radius: 14)
                        }
                        .frame(width: 340, height: 22)
                    }
                    .offset(y: 4)
                }
                .frame(width: Self.island.width, height: Self.island.height)
                .shadow(color: orange[1].opacity(0.45), radius: 50, y: 24)
            }
            .frame(width: Self.body.width, height: Self.body.height)
            .clipShape(squircle)
            .overlay(squircle.strokeBorder(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.04)],
                                                          startPoint: .top, endPoint: .bottom), lineWidth: 3))
        }
        .frame(width: 1024, height: 1024)
    }

    private func orb(_ kind: AgentKind, size: CGFloat, t: Double) -> some View {
        Canvas { ctx, sz in OrbPainter(kind: kind, status: .idle, t: t).draw(&ctx, sz) }
            .frame(width: size, height: size)
    }
}

enum AppIcon {
    @MainActor static func render(to path: String) {
        let r = ImageRenderer(content: AppIconView())
        r.scale = 1
        guard let cg = r.cgImage else { fputs("icon render failed\n", stderr); return }
        let rep = NSBitmapImageRep(cgImage: cg)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
