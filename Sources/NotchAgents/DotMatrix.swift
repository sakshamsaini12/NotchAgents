import SwiftUI

/// 5×7 dot-matrix font. Narrow glyphs (":", ".", " ") keep numbers tight.
enum DotFont {
    struct Glyph { let rows: [[Bool]]; var width: Int { rows[0].count } }

    static func glyph(_ c: Character) -> Glyph { cache[c] ?? cache[" "]! }

    private static let cache: [Character: Glyph] = source.mapValues { rows in
        Glyph(rows: rows.map { $0.map { $0 == "#" } })
    }

    private static let source: [Character: [String]] = [
        "0": [".###.", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."],
        "1": ["..#..", ".##..", "..#..", "..#..", "..#..", "..#..", ".###."],
        "2": [".###.", "#...#", "....#", "...#.", "..#..", ".#...", "#####"],
        "3": ["#####", "...#.", "..#..", "...#.", "....#", "#...#", ".###."],
        "4": ["...#.", "..##.", ".#.#.", "#..#.", "#####", "...#.", "...#."],
        "5": ["#####", "#....", "####.", "....#", "....#", "#...#", ".###."],
        "6": ["..##.", ".#...", "#....", "####.", "#...#", "#...#", ".###."],
        "7": ["#####", "....#", "...#.", "..#..", ".#...", ".#...", ".#..."],
        "8": [".###.", "#...#", "#...#", ".###.", "#...#", "#...#", ".###."],
        "9": [".###.", "#...#", "#...#", ".####", "....#", "...#.", ".##.."],
        "%": ["##...", "##..#", "...#.", "..#..", ".#...", "#..##", "...##"],
        "$": ["..#..", ".####", "#.#..", ".###.", "..#.#", "####.", "..#.."],
        "K": ["#...#", "#..#.", "#.#..", "##...", "#.#..", "#..#.", "#...#"],
        "M": ["#...#", "##.##", "#.#.#", "#.#.#", "#...#", "#...#", "#...#"],
        "h": ["#....", "#....", "#.##.", "##..#", "#...#", "#...#", "#...#"],
        "m": [".....", ".....", "##.#.", "#.#.#", "#.#.#", "#...#", "#...#"],
        "s": [".....", ".....", ".####", "#....", ".###.", "....#", "####."],
        "d": ["....#", "....#", ".##.#", "#..##", "#...#", "#...#", ".####"],
        ":": [".", ".", "#", ".", "#", ".", "."],
        ".": [".", ".", ".", ".", ".", ".", "#"],
        "-": ["...", "...", "...", "###", "...", "...", "..."],
        "—": ["...", "...", "...", "###", "...", "...", "..."],
        " ": ["..", "..", "..", "..", "..", "..", ".."],
    ]
}

/// Text drawn as a dot matrix, lit with a vertical gradient. Unlit dots can be ghosted in
/// like an LED panel.
struct DotText: View {
    let text: String
    var pitch: CGFloat = 2
    var colors: [Color] = [.white]
    var ghost: Double = 0

    var body: some View {
        let glyphs = text.map(DotFont.glyph)
        let cols = glyphs.reduce(0) { $0 + $1.width } + max(0, glyphs.count - 1)
        Canvas { ctx, size in
            var lit = Path(), off = Path()
            let d = pitch * 0.76, inset = (pitch - d) / 2
            var x = 0
            for g in glyphs {
                for r in 0..<7 {
                    for c in 0..<g.width {
                        let rect = CGRect(x: CGFloat(x + c) * pitch + inset, y: CGFloat(r) * pitch + inset, width: d, height: d)
                        if g.rows[r][c] { lit.addEllipse(in: rect) } else if ghost > 0 { off.addEllipse(in: rect) }
                    }
                }
                x += g.width + 1
            }
            if ghost > 0 { ctx.fill(off, with: .color(.white.opacity(ghost))) }
            ctx.fill(lit, with: .linearGradient(Gradient(colors: colors.count > 1 ? colors : colors + colors),
                                                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
        }
        .frame(width: CGFloat(cols) * pitch, height: 7 * pitch)
        .animation(nil, value: text)
    }
}

/// Uniform grid of dots, used as a mask so a gradient shows through as an LED field.
struct DotGrid: View {
    var pitch: CGFloat = 7
    var dot: CGFloat = 1.6

    var body: some View {
        Canvas { ctx, size in
            var p = Path()
            var y = pitch / 2
            while y < size.height {
                var x = pitch / 2
                while x < size.width {
                    p.addEllipse(in: CGRect(x: x - dot / 2, y: y - dot / 2, width: dot, height: dot))
                    x += pitch
                }
                y += pitch
            }
            ctx.fill(p, with: .color(.white))
        }
    }
}

/// Dot-matrix equalizer for a working agent: columns rise and fall on layered sines.
struct DotEqualizer: View {
    var colors: [Color]
    var columns = 4, rows = 4
    var pitch: CGFloat = 2.6

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                var lit = Path(), off = Path()
                let d = pitch * 0.72, inset = (pitch - d) / 2
                for c in 0..<columns {
                    let k = Double(c)
                    let level = (0.55 + 0.3 * sin(t * 5.1 + k * 1.7) + 0.15 * sin(t * 8.3 + k * 2.9)) * Double(rows)
                    for r in 0..<rows {
                        let rect = CGRect(x: CGFloat(c) * pitch + inset, y: CGFloat(rows - 1 - r) * pitch + inset, width: d, height: d)
                        if Double(r) < level.rounded() { lit.addEllipse(in: rect) } else { off.addEllipse(in: rect) }
                    }
                }
                ctx.fill(off, with: .color(.white.opacity(0.1)))
                ctx.fill(lit, with: .linearGradient(Gradient(colors: colors), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            }
        }
        .frame(width: CGFloat(columns) * pitch, height: CGFloat(rows) * pitch)
    }
}

/// Ring of eight dots with a fading comet tail — a "working" indicator that doesn't read as audio.
struct DotSpinner: View {
    let color: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { tl in
            let head = Int(tl.date.timeIntervalSinceReferenceDate * 10) % 8
            Canvas { ctx, size in
                let r = min(size.width, size.height) / 2, d = r * 0.42
                for i in 0..<8 {
                    let a = Double(i) / 8 * 2 * .pi - .pi / 2
                    let age = (head - i + 8) % 8
                    let p = CGPoint(x: size.width / 2 + cos(a) * (r - d / 2), y: size.height / 2 + sin(a) * (r - d / 2))
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d)),
                             with: .color(age == 0 ? .white : color.opacity(max(0.12, 1 - Double(age) * 0.22))))
                }
            }
        }
    }
}

/// Three dots rising and brightening in turn — the "in progress" mark for a running step.
struct DotWave: View {
    let color: Color
    var dot: CGFloat = 3.2

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            HStack(spacing: dot * 0.7) {
                ForEach(0..<3, id: \.self) { i in
                    let k = max(0, sin(t * 6 - Double(i) * 0.9))
                    Circle()
                        .fill(color.mix(with: .white, by: 0.35 * k))
                        .frame(width: dot, height: dot)
                        .opacity(0.35 + 0.65 * k)
                        .offset(y: -dot * 0.6 * k)
                }
            }
            .frame(height: dot * 2.2, alignment: .bottom)
        }
    }
}
