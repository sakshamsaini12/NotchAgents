import SwiftUI

/// A MacBook Pro drawn in code, with the real island at the top of its screen: the README images
/// (`--render-preview`). `full` shows the whole laptop; `closeUp` crops to the top of the screen so the
/// island stays legible at small sizes.
struct MacBookMock: View {
    enum Framing { case full, closeUp }

    @ObservedObject var store: AgentStore
    @ObservedObject var model: IslandModel
    let island: CGSize
    let framing: Framing

    static let screen = CGSize(width: 1240, height: 775)
    private static let bezel: CGFloat = 14
    private static var lid: CGSize { CGSize(width: screen.width + bezel * 2, height: screen.height + bezel * 2 + 4) }

    var body: some View {
        switch framing {
        case .full:
            ZStack(alignment: .top) {
                Studio()
                laptop.padding(.top, 90)
            }
            .frame(width: Self.lid.width + 300, height: Self.lid.height + 220)
        case .closeUp:
            let height = max(island.height, 90) + 190
            ZStack(alignment: .top) {
                Studio()
                // Pinned to the top: the lid is taller than this frame and would otherwise be centred.
                lidView.padding(.top, 56).frame(width: 1040, height: height, alignment: .top)
                // Fade the lower edge into the studio so the crop reads as a close-up, not a cut.
                LinearGradient(colors: [.clear, Studio.base], startPoint: UnitPoint(x: 0.5, y: 0.55), endPoint: .bottom)
            }
            .frame(width: 1040, height: height)
            .clipped()
        }
    }

    private var laptop: some View {
        VStack(spacing: 0) {
            lidView
            Base(width: Self.lid.width + 110)
        }
        .background(alignment: .bottom) {
            // Contact shadow on the "table".
            Ellipse().fill(.black.opacity(0.55)).frame(width: Self.lid.width + 60, height: 34).blur(radius: 22).offset(y: 18)
        }
    }

    private var lidView: some View {
        let outer = RoundedRectangle(cornerRadius: 30, style: .continuous)
        return ZStack {
            outer.fill(LinearGradient(colors: [Color(hex: 0xC9CBCF), Color(hex: 0x8E9196)], startPoint: .top, endPoint: .bottom))
            outer.inset(by: 1.5).fill(Color(hex: 0x050506))
            // Faint glass reflection across the bezel.
            outer.inset(by: 1.5).fill(LinearGradient(colors: [.white.opacity(0.07), .clear], startPoint: .topLeading, endPoint: UnitPoint(x: 0.45, y: 0.4)))
            screenView
                .frame(width: Self.screen.width, height: Self.screen.height)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .offset(y: -2)
        }
        .frame(width: Self.lid.width, height: Self.lid.height)
    }

    private var screenView: some View {
        ZStack(alignment: .top) {
            Wallpaper()
            Desktop().padding(.top, model.notch.height)
            MenuBar(height: model.notch.height)
            IslandView(store: store, model: model)
                .frame(width: island.width, height: island.height)
        }
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Pieces

/// Dark graphite backdrop with a soft spotlight behind the laptop.
private struct Studio: View {
    static let base = Color(hex: 0x0D0D10)
    var body: some View {
        ZStack {
            Self.base
            RadialGradient(colors: [Color(hex: 0x2A2A31), Self.base], center: UnitPoint(x: 0.5, y: 0.32), startRadius: 0, endRadius: 900)
        }
    }
}

/// macOS-style abstract wallpaper: deep violet with warm and cool light blooms.
private struct Wallpaper: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0x1B1530), Color(hex: 0x0B0A14)], startPoint: .top, endPoint: .bottom)
            Ellipse().fill(Color(hex: 0x7B3FE4).opacity(0.55)).frame(width: 900, height: 520).blur(radius: 120).offset(x: -380, y: 260)
            Ellipse().fill(Color(hex: 0xFF6A3D).opacity(0.45)).frame(width: 760, height: 460).blur(radius: 130).offset(x: 420, y: 300)
            Ellipse().fill(Color(hex: 0x2F7BFF).opacity(0.35)).frame(width: 700, height: 380).blur(radius: 120).offset(x: 80, y: -160)
            Ellipse().fill(Color(hex: 0xFF3D8B).opacity(0.25)).frame(width: 520, height: 300).blur(radius: 110).offset(x: -60, y: 420)
        }
    }
}

private struct MenuBar: View {
    let height: CGFloat
    var body: some View {
        HStack(spacing: 18) {
            Image(systemName: "apple.logo").font(.system(size: 14, weight: .medium))
            Text("Terminal").font(.system(size: 13, weight: .bold))
            ForEach(["Shell", "Edit", "View", "Window", "Help"], id: \.self) { Text($0).font(.system(size: 13)) }
            Spacer()
            Image(systemName: "sparkles").font(.system(size: 13))
            Image(systemName: "battery.75percent").font(.system(size: 15))
            Image(systemName: "wifi").font(.system(size: 13, weight: .semibold))
            Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .semibold))
            Image(systemName: "switch.2").font(.system(size: 13))
            Text("Sat 24 Oct  9:41").font(.system(size: 13, weight: .medium))
        }
        .foregroundStyle(.white.opacity(0.92))
        .padding(.horizontal, 18)
        .frame(height: height)
        .background(.black.opacity(0.22))
    }
}

/// Two windows on the desktop for context: a terminal running Claude Code and an editor.
private struct Desktop: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            Window(title: "ForecastView.swift — weather-app", width: 600, height: 400) { Editor() }
                .offset(x: 600, y: 300)
            Window(title: "weather-app — claude", width: 530, height: 380) { Terminal() }
                .offset(x: 46, y: 350)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct Window<Content: View>: View {
    let title: String
    let width: CGFloat, height: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(spacing: 0) {
            ZStack {
                HStack(spacing: 8) {
                    ForEach([0xFF5F57, 0xFEBC2E, 0x28C840] as [UInt32], id: \.self) { Circle().fill(Color(hex: $0)).frame(width: 12, height: 12) }
                    Spacer()
                }
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.55))
            }
            .padding(.horizontal, 14)
            .frame(height: 34)
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: width, height: height)
        .background(shape.fill(Color(hex: 0x18171C).opacity(0.94)))
        .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .clipShape(shape)
        .shadow(color: .black.opacity(0.5), radius: 30, y: 18)
    }
}

private struct Terminal: View {
    var body: some View {
        let orange = Color(hex: 0xE8875B), dim = Color.white.opacity(0.45), text = Color.white.opacity(0.85)
        VStack(alignment: .leading, spacing: 7) {
            Text("✻ Welcome to Claude Code").foregroundStyle(orange)
            Text("  cwd: ~/Developer/weather-app").foregroundStyle(dim)
            Text(" ")
            Text("> show units on the forecast and keep digits aligned").foregroundStyle(text)
            Text(" ")
            line("Read", "WeatherService.swift", orange, text)
            line("Edit", "ForecastView.swift", orange, text)
            Text("  ⎿  Updated with 2 additions and 1 removal").foregroundStyle(dim)
            line("Bash", "swift test --parallel", orange, text)
            Text("  ⎿  Running 42 tests…").foregroundStyle(dim)
        }
        .font(.system(size: 12.5, design: .monospaced))
        .padding(16)
    }

    private func line(_ tool: String, _ arg: String, _ accent: Color, _ text: Color) -> some View {
        (Text("⏺ ").foregroundColor(accent) + Text(tool).bold().foregroundColor(text) + Text("(\(arg))").foregroundColor(text.opacity(0.7)))
    }
}

private struct Editor: View {
    var body: some View {
        let kw = Color(hex: 0xFC5FA3), type = Color(hex: 0x5DD8FF), str = Color(hex: 0xFC6A5D), plain = Color.white.opacity(0.85), com = Color.white.opacity(0.38)
        let lines: [[(String, Color)]] = [
            [("struct ", kw), ("ForecastView", type), (": ", plain), ("View", type), (" {", plain)],
            [("    let ", kw), ("days", plain), (": [", plain), ("Day", type), ("]", plain)],
            [("", plain)],
            [("    var ", kw), ("body", plain), (": ", plain), ("some ", kw), ("View", type), (" {", plain)],
            [("        // One row per day, digits aligned", com)],
            [("        List", type), ("(days) { day ", plain), ("in", kw)],
            [("            HStack", type), (" {", plain)],
            [("                Text", type), ("(day.name)", plain)],
            [("                Spacer", type), ("()", plain)],
            [("                Text", type), ("(day.high, format: .measurement(width: .narrow))", plain)],
            [("                    .monospacedDigit()", plain)],
            [("            }", plain)],
            [("        }", plain)],
            [("        .navigationTitle(", plain), ("\"Forecast\"", str), (")", plain)],
        ]
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .trailing, spacing: 6) {
                ForEach(1...lines.count, id: \.self) { Text("\($0)").foregroundStyle(.white.opacity(0.22)) }
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(lines.indices, id: \.self) { i in
                    lines[i].reduce(Text("")) { $0 + Text($1.0).foregroundColor($1.1) }
                }
            }
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(16)
    }
}

/// The aluminium base seen edge-on, with the thumb cut-out under the hinge.
private struct Base: View {
    let width: CGFloat
    var body: some View {
        ZStack(alignment: .top) {
            UnevenRoundedRectangle(topLeadingRadius: 4, bottomLeadingRadius: 18, bottomTrailingRadius: 18, topTrailingRadius: 4, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0xE4E5E8), Color(hex: 0xB4B6BA), Color(hex: 0x7C7F84)], startPoint: .top, endPoint: .bottom))
                .frame(width: width, height: 22)
            UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0x8A8D92), Color(hex: 0xB9BBBF)], startPoint: .top, endPoint: .bottom))
                .frame(width: 170, height: 9)
            Rectangle().fill(.white.opacity(0.7)).frame(width: width - 20, height: 1).offset(y: 0.5)
        }
    }
}
