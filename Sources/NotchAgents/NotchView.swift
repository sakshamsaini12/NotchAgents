import SwiftUI

/// The single black island. Top corners flare outward into the menu bar like the hardware notch;
/// bottom corners round off. Both radii are animatable so the shape morphs as one piece.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        let t = topRadius, b = min(bottomRadius, (r.height - t) / 2, (r.width - 2 * t) / 2)
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addCurve(to: CGPoint(x: r.minX + t, y: r.minY + t),
                   control1: CGPoint(x: r.minX + t * 0.62, y: r.minY), control2: CGPoint(x: r.minX + t, y: r.minY + t * 0.38))
        p.addLine(to: CGPoint(x: r.minX + t, y: r.maxY - b))
        p.addQuadCurve(to: CGPoint(x: r.minX + t + b, y: r.maxY), control: CGPoint(x: r.minX + t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t - b, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - t, y: r.maxY - b), control: CGPoint(x: r.maxX - t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t, y: r.minY + t))
        p.addCurve(to: CGPoint(x: r.maxX, y: r.minY),
                   control1: CGPoint(x: r.maxX - t, y: r.minY + t * 0.38), control2: CGPoint(x: r.maxX - t * 0.62, y: r.minY))
        p.closeSubpath()
        return p
    }
}

enum IslandMode: Equatable { case idle, compact, alert, question, expanded }

@MainActor
final class IslandModel: ObservableObject {
    @Published var hovering = false
    /// Flips true a beat after expansion starts so content can stagger in.
    @Published var revealed = false
    /// Agent featured in the expanded island; nil = pick the most relevant one.
    @Published var selected: AgentKind?
    @Published var notch = CGSize(width: 185, height: 32)
    /// Set when the pointer arrives while an alert is showing: the banner stays a banner (so its
    /// buttons can be clicked) and doesn't open the full island until the pointer leaves and returns.
    @Published var holdBanner = false
    /// Progress through the current notch question: which item, and what's picked so far.
    @Published var qStep = 0
    @Published var qPicks: [Int: [String]] = [:]
    var qID: UUID?

    /// Picks option `index` of the question's current item, from a click or the 1–9 keys. A single-choice
    /// item moves straight on (or submits, on the last one); a multi-select item toggles the option.
    func pick(_ index: Int, in q: PendingQuestion, store: AgentStore) {
        startQuestion(q)
        guard !q.items.isEmpty else { return }
        let step = min(qStep, q.items.count - 1), item = q.items[step]
        guard item.options.indices.contains(index) else { return }
        // Only the agent itself can take this answer (OpenCode, or Claude before its request arrives).
        guard q.answer != nil else { store.answer(nil); return }
        let label = item.options[index].label
        if item.multi {
            var p = qPicks[step] ?? []
            if let i = p.firstIndex(of: label) { p.remove(at: i) } else { p.append(label) }
            qPicks[step] = p
            SFX.play(.tap)
        } else {
            qPicks[step] = [label]
            advance(q, store: store)
        }
    }

    /// Next item, or send every answer after the last one. Multi-select items need a pick first.
    func advance(_ q: PendingQuestion, store: AgentStore) {
        startQuestion(q)
        guard !q.items.isEmpty else { return }
        let step = min(qStep, q.items.count - 1)
        guard !(qPicks[step] ?? []).isEmpty else { return }
        if step + 1 < q.items.count {
            withAnimation(.smooth(duration: 0.3)) { qStep = step + 1 }
            return
        }
        var answers: [String: String] = [:]
        for (i, it) in q.items.enumerated() { answers[it.question] = (qPicks[i] ?? []).joined(separator: ", ") }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        store.answer(answers)
    }

    /// Fresh progress for a question not seen before.
    func startQuestion(_ q: PendingQuestion) {
        guard qID != q.id else { return }
        qID = q.id; qStep = 0; qPicks = [:]
    }

    /// Largest size the island can reach; the panel is sized from this.
    static let maxSize = CGSize(width: 620, height: 340)
    static let wing: CGFloat = 54
    static let idleWing: CGFloat = 22
    /// Compact wing width: grows so every live agent's orb fits beside the hardware notch.
    static func wing(_ live: Int) -> CGFloat { max(wing, 40 + 17 * CGFloat(max(0, live - 1))) }
    static let openSpring = Animation.spring(response: 0.52, dampingFraction: 0.8)
    static let closeSpring = Animation.spring(response: 0.44, dampingFraction: 1)

    func mode(_ store: AgentStore) -> IslandMode {
        if store.question != nil { return .question }
        if store.alert != nil && (!hovering || holdBanner) { return .alert }
        if hovering && !holdBanner { return .expanded }
        return store.liveAgents.isEmpty ? .idle : .compact
    }

    func size(_ store: AgentStore) -> CGSize {
        switch mode(store) {
        // A slim wing past the hardware notch so the island stays findable with nothing running.
        case .idle: return CGSize(width: notch.width + Self.idleWing * 2, height: notch.height)
        case .compact: return CGSize(width: notch.width + Self.wing(store.liveAgents.count) * 2, height: notch.height)
        case .alert: return CGSize(width: max(460, notch.width + Self.wing * 2 + 150), height: notch.height + 58)
        case .question:
            let items = store.question?.items ?? []
            let item = items.isEmpty ? nil : items[min(qStep, items.count - 1)]
            let footer: CGFloat = (item?.multi == true || items.count > 1) ? 44 : 0
            return CGSize(width: max(540, notch.width + 300),
                          height: min(Self.maxSize.height, notch.height + 78 + CGFloat(item?.options.count ?? 0) * 44 + footer + 10))
        case .expanded:
            return CGSize(width: max(Self.maxSize.width, notch.width + 400),
                          height: notch.height + (showsEmpty(store) ? 204 : store.pending != nil ? 268 : 226))
        }
    }

    /// Nothing running and no agent picked: the expanded island shows the getting-started view.
    func showsEmpty(_ store: AgentStore) -> Bool { store.liveAgents.isEmpty && selected == nil }
}

private struct BlurFade: ViewModifier {
    let radius: CGFloat
    func body(content: Content) -> some View { content.blur(radius: radius) }
}

extension AnyTransition {
    static func blurFade(_ r: CGFloat) -> AnyTransition {
        .modifier(active: BlurFade(radius: r), identity: BlurFade(radius: 0)).combined(with: .opacity)
    }
}

/// Text tokens for content on the black island.
enum Ink {
    static let primary = Color.white
    static let secondary = Color.white.opacity(0.6)
    static let tertiary = Color.white.opacity(0.38)
    static let hairline = Color.white.opacity(0.1)
}

struct IslandView: View {
    /// The working glow's colours: four per working agent family, interleaved. Both Claudes share one.
    static func workLight(_ kinds: [AgentKind]) -> [Color] {
        var seen = Set<AgentKind>(), palettes: [[Color]] = []
        for k in AgentKind.allCases where kinds.contains(k) {
            let family: AgentKind = k.isClaude ? .claudeCLI : k
            guard seen.insert(family).inserted else { continue }
            switch family {
            case .claudeCLI: palettes.append([Color(hex: 0xFF5A1F), Color(hex: 0xFF9A3C), Color(hex: 0xFF4F6E), Color(hex: 0xFFB36B)])
            case .codex: palettes.append([Color(hex: 0x2F6BFF), Color(hex: 0x36D1FF), Color(hex: 0x8A5CFF), Color(hex: 0x9BE9FF)])
            case .opencode: palettes.append([Color(hex: 0xFFFFFF), Color(hex: 0xC9D3DE), Color(hex: 0xF2F4F7), Color(hex: 0x9FB0C2)])
            default: let g = family.gradient; palettes.append([g[0], g[1], g[3], g[0]])
            }
        }
        return (0..<4).flatMap { i in palettes.map { $0[i] } }
    }

    @ObservedObject var store: AgentStore
    @ObservedObject var model: IslandModel
    @Namespace private var ns

    var body: some View {
        let mode = model.mode(store)
        let size = model.size(store)
        let expanded = mode == .expanded
        let big = mode == .expanded || mode == .alert || mode == .question
        let shape = NotchShape(topRadius: big ? 14 : 6, bottomRadius: expanded ? 30 : big ? 24 : model.notch.height * 0.36)
        let lead = store.alert?.kind ?? store.liveAgents.first(where: { $0.status.isBusy })?.kind ?? store.liveAgents.first?.kind
        // Each working agent's light, woven together when several work at once: orange for Claude,
        // blue for Codex, white for OpenCode, and so on.
        let workColors = Self.workLight(store.liveAgents.filter(\.status.isBusy).map(\.kind))
        let leadPalette = store.question != nil ? amberPalette : store.alert.map { $0.style == .question ? amberPalette : $0.kind.gradient } ?? lead?.gradient

        ZStack(alignment: .top) {
            shape
                .fill(.black)
                .shadow(color: .black.opacity(big ? 0.55 : 0), radius: 24, y: 12)

            if mode == .compact, !workColors.isEmpty {
                WorkingAura(colors: workColors, notch: model.notch, wing: IslandModel.wing(store.liveAgents.count), shape: shape)
                    .transition(.asymmetric(insertion: .opacity.animation(.smooth(duration: 0.6).delay(0.15)),
                                            removal: .opacity.animation(.easeOut(duration: 0.1))))
            }

            if mode == .alert || mode == .question, let pal = leadPalette {
                DarkMeshBackdrop(palette: pal, active: true)
                    .transition(.opacity.animation(.smooth(duration: 0.5)))
            }

            shape
                .stroke(LinearGradient(stops: [.init(color: .white.opacity(0), location: 0), .init(color: .white.opacity(big ? 0.1 : 0), location: 0.35),
                                              .init(color: .white.opacity(big ? 0.2 : 0), location: 1)], startPoint: .top, endPoint: .bottom), lineWidth: 0.75)

            if big, let pal = leadPalette {
                shape
                    .stroke(LinearGradient(colors: [.clear, pal[1], pal[3], pal[0], .clear], startPoint: .leading, endPoint: .trailing), lineWidth: 1)
                    .mask(LinearGradient(stops: [.init(color: .clear, location: 0.75), .init(color: .black, location: 1)], startPoint: .top, endPoint: .bottom))
                    .opacity(0.7)
                    .transition(.opacity)
            }

            Group {
                switch mode {
                case .expanded:
                    Group {
                        if model.showsEmpty(store) { EmptyContent(store: store, model: model) } else { ExpandedContent(store: store, model: model, ns: ns) }
                    }
                        .transition(.asymmetric(
                            insertion: .opacity.animation(.easeOut(duration: 0.25)),
                            removal: .blurFade(6).animation(.easeIn(duration: 0.12))))
                case .question:
                    if let q = store.question {
                        QuestionContent(question: q, store: store, model: model)
                            .transition(.asymmetric(
                                insertion: .blurFade(8).combined(with: .scale(scale: 0.96, anchor: .top)).animation(.spring(response: 0.5, dampingFraction: 0.85).delay(0.1)),
                                removal: .blurFade(6).animation(.easeIn(duration: 0.12))))
                    }
                case .alert:
                    if let alert = store.alert {
                        AlertContent(alert: alert, store: store, notch: model.notch)
                            .transition(.asymmetric(
                                insertion: .blurFade(8).combined(with: .scale(scale: 0.94, anchor: .top)).animation(.spring(response: 0.45, dampingFraction: 0.8).delay(0.08)),
                                removal: .blurFade(6).animation(.smooth(duration: 0.15))))
                    }
                case .compact:
                    CompactContent(store: store, notch: model.notch, ns: ns)
                        .transition(.asymmetric(
                            insertion: .blurFade(6).animation(.easeOut(duration: 0.3).delay(0.22)),
                            removal: .blurFade(4).animation(.easeIn(duration: 0.1))))
                case .idle:
                    HStack {
                        Circle().fill(Ink.tertiary).frame(width: 5, height: 5)
                        Spacer(minLength: model.notch.width)
                    }
                    .padding(.horizontal, (IslandModel.idleWing - 5) / 2)
                    .frame(height: model.notch.height)
                    .transition(.opacity.animation(.easeOut(duration: 0.2)))
                }
            }
            .frame(width: size.width, height: size.height, alignment: .top)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        // One curve drives shape, size and radii together: a soft overshoot opening, no bounce closing.
        .animation(big ? IslandModel.openSpring : IslandModel.closeSpring, value: mode)
        .animation(big ? IslandModel.openSpring : IslandModel.closeSpring, value: size)
        .animation(.spring(response: 0.45, dampingFraction: 0.82), value: store.liveAgents.map(\.kind))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Compact

/// Gradient that streams sideways forever (seamless: the colour run repeats across twice the width).
struct FlowGradient: View {
    let colors: [Color]
    var speed = 0.35

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { tl in
            GeometryReader { g in
                let w = g.size.width
                let ph = CGFloat((tl.date.timeIntervalSinceReferenceDate * speed).truncatingRemainder(dividingBy: 1))
                LinearGradient(colors: colors + colors + [colors[0]], startPoint: .leading, endPoint: .trailing)
                    .frame(width: w * 2)
                    .offset(x: -ph * w)
            }
        }
        .clipped()
    }
}

/// Working state of the closed island: vivid agent light glows up from the bottom edge, traces the
/// island's curved rim, and lights the dot fields in the wings. Additive blending keeps it luminous
/// (light on black) instead of muddy.
private struct WorkingAura<S: Shape>: View {
    let colors: [Color]
    let notch: CGSize
    let wing: CGFloat
    let shape: S

    var body: some View {
        // Slow ambient motion: 30 fps, rasterised on the GPU (see IntelligenceGlow).
        TimelineView(.animation(minimumInterval: 1 / 30)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let breathe = 0.82 + 0.18 * sin(t * 2.2)
            // Colour lives only in the wings: smooth light rising from the outer bottom corners and
            // dissolving to black before the hardware notch. No dots, no hard stops — one seamless wash.
            let side = wing + 4
            let wings = HStack(spacing: 0) {
                LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black.opacity(0.6), location: 0.45),
                                       .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing)
                    .frame(width: side)
                Spacer(minLength: 0)
                LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black.opacity(0.6), location: 0.55),
                                       .init(color: .black, location: 1)], startPoint: .leading, endPoint: .trailing)
                    .frame(width: side)
            }
            ZStack {
                FlowGradient(colors: colors, speed: 0.12)
                    .blur(radius: 10)
                    .opacity(0.75 * breathe)
                let rim = AngularGradient(colors: colors + [colors[0]], center: .center,
                                          angle: .degrees((t * 40).truncatingRemainder(dividingBy: 360)))
                shape.stroke(rim, lineWidth: 6).blur(radius: 6).opacity(0.9)
                shape.stroke(rim, lineWidth: 1).blur(radius: 0.6).opacity(0.8)
            }
            .drawingGroup()
            .mask(wings)
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black.opacity(0.35), location: 0.45),
                                         .init(color: .black, location: 1)], startPoint: .top, endPoint: .bottom))
            .clipShape(shape)
            .blendMode(.plusLighter)
        }
        .allowsHitTesting(false)
    }
}

/// Pitch-black surface; the agent gradient only shows through a dot-matrix field rising from the
/// bottom, fading out toward the top so the island stays continuous with the hardware notch.
struct DarkMeshBackdrop: View {
    let palette: [Color]
    var active = false

    var body: some View {
        ZStack {
            Color.black
            // The gradient itself only shows through a dot-matrix field rising from the bottom.
            MeshField(palette: palette, speed: active ? 0.8 : 0.3, amplitude: 0.3)
                .mask(DotGrid(pitch: 6, dot: 1.5))
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0.35), .init(color: .black.opacity(0.55), location: 1)],
                                     startPoint: .top, endPoint: .bottom))
        }
        .allowsHitTesting(false)
    }
}

private struct CompactContent: View {
    @ObservedObject var store: AgentStore
    let notch: CGSize
    let ns: Namespace.ID

    var body: some View {
        let wing = IslandModel.wing(store.liveAgents.count)
        HStack(spacing: 0) {
            HStack(spacing: -5) {
                ForEach(store.liveAgents) { a in
                    AgentGlyph(kind: a.kind, status: a.status, size: 19)
                        .padding(1.5)
                        .background { if store.liveAgents.count > 1 { Circle().fill(.black) } }
                        .matchedGeometryEffect(id: a.kind, in: ns)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                }
            }
            .frame(width: wing - 10, alignment: .leading)
            .padding(.leading, 10)

            Spacer(minLength: notch.width)

            trailing
                .frame(width: wing - 10, alignment: .trailing)
                .padding(.trailing, 12)
        }
        .frame(height: notch.height)
    }

    @ViewBuilder private var trailing: some View {
        let busy = store.liveAgents.filter(\.status.isBusy)
        if store.pending != nil {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(amber)
                .symbolEffect(.pulse, options: .repeating)
                .transition(.blurFade(4))
        } else if let b = busy.first {
            Group {
                if let start = b.turnStart {
                    ElapsedText(since: start, pitch: 1.5, colors: [b.kind.gradient[3], b.kind.gradient[0]])
                } else {
                    DotSpinner(color: b.kind.gradient[0]).frame(width: 11, height: 11)
                }
            }
            .fixedSize()
            .transition(.blurFade(4))
        } else if let a = store.liveAgents.first, a.contextUsed > 0 {
            DotText(text: "\(Int(a.contextFraction * 100))%", pitch: 1.55, colors: [.white.opacity(0.75), .white.opacity(0.4)])
                .transition(.blurFade(4))
        }
    }
}

/// mm:ss (or h:mm:ss) counting up from a date, redrawn once per second.
struct ElapsedText: View {
    let since: Date
    var pitch: CGFloat = 2
    var colors: [Color] = [.white]
    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { tl in
            let s = max(0, Int(tl.date.timeIntervalSince(since)))
            DotText(text: s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60),
                    pitch: pitch, colors: colors, ghost: 0.06)
        }
    }
}

// MARK: - Alert

private struct AlertContent: View {
    let alert: IslandAlert
    @ObservedObject var store: AgentStore
    let notch: CGSize

    var body: some View {
        let status: AgentStatus = alert.style == .question ? .waiting : (store.agents[alert.kind]?.status ?? .idle)
        VStack(spacing: 0) {
            Color.clear.frame(height: notch.height)
            HStack(spacing: 12) {
                AgentGlyph(kind: alert.kind, status: status, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: alert.style == .done ? "checkmark.circle.fill" : "questionmark.bubble.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(alert.style == .done ? Color.green : amber)
                        Text(alert.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.primary)
                    }
                    Text(alert.message)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 8)
                Button(alert.style == .done ? "Open" : "Answer") {
                    store.focus(alert.kind)
                    store.dismissAlert()
                }
                .buttonStyle(GradientPill(palette: alert.style == .question ? amberPalette : alert.kind.gradient))
                Button { store.dismissAlert() } label: { Image(systemName: "xmark") }
                    .buttonStyle(QuietButton())
            }
            .padding(.horizontal, 22)
            .frame(height: 54)
        }
    }
}

// MARK: - Question

/// Claude's multiple-choice question, answered in the notch. One question at a time; multi-select
/// questions collect picks and submit with a button. "Terminal" hands the question back.
private struct QuestionContent: View {
    let question: PendingQuestion
    @ObservedObject var store: AgentStore
    @ObservedObject var model: IslandModel

    var body: some View {
        let items = question.items
        let step = min(model.qStep, max(0, items.count - 1))
        VStack(spacing: 0) {
            Color.clear.frame(height: model.notch.height)
            if items.isEmpty {
                Spacer()
            } else {
                let item = items[step]
                let picks = model.qPicks[step] ?? []
                HStack(alignment: .top, spacing: 12) {
                    AgentGlyph(kind: question.kind, status: .waiting, size: 30)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(question.kind.title + " asks").font(.system(size: 11, weight: .semibold)).foregroundStyle(amber)
                            if !item.header.isEmpty {
                                Text(item.header).font(.system(size: 10, weight: .medium)).foregroundStyle(Ink.secondary)
                                    .padding(.horizontal, 6).padding(.vertical, 1.5)
                                    .background(Capsule().fill(Ink.hairline))
                            }
                            if items.count > 1 {
                                Text("\(step + 1)/\(items.count)").font(.system(size: 10).monospacedDigit()).foregroundStyle(Ink.tertiary)
                            }
                        }
                        Text(item.question).font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.primary)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button { store.answer(nil) } label: { Image(systemName: "terminal") }
                        .buttonStyle(QuietButton()).help("Answer in the terminal")
                }
                .frame(height: 64, alignment: .top)
                .padding(.top, 8)

                VStack(spacing: 4) {
                    ForEach(Array(item.options.enumerated()), id: \.offset) { i, o in
                        Button { model.pick(i, in: question, store: store) } label: {
                            QuestionOption(index: i + 1, option: o, selected: picks.contains(o.label), multi: item.multi)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 6)

                if item.multi || items.count > 1 {
                    HStack {
                        if step > 0 {
                            Button("Back") { withAnimation(.smooth(duration: 0.25)) { model.qStep = step - 1 } }
                                .buttonStyle(PillButton(tint: Ink.secondary))
                        }
                        Spacer()
                        if item.multi {
                            Button(step == items.count - 1 ? "Submit" : "Next") { model.advance(question, store: store) }
                                .buttonStyle(GradientPill(palette: amberPalette))
                                .disabled(picks.isEmpty).opacity(picks.isEmpty ? 0.5 : 1)
                        }
                    }
                    .padding(.top, 8)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .onAppear { model.startQuestion(question) }
        .onChange(of: question.id) { model.startQuestion(question) }
    }
}

private struct QuestionOption: View {
    let index: Int
    let option: PendingQuestion.Option
    let selected: Bool
    let multi: Bool
    @ObservedObject private var hover = HoverBox()

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 5).fill(selected ? amber : Ink.hairline)
                if selected && multi {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.black)
                } else {
                    Text("\(index)").font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(selected ? .black : Ink.secondary)
                }
            }
            .frame(width: 18, height: 18)
            Text(option.label).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Ink.primary).lineLimit(1)
            Text(option.detail).font(.system(size: 11)).foregroundStyle(Ink.tertiary).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(.white.opacity(selected ? 0.12 : hover.on ? 0.08 : 0.04)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(selected ? amber.opacity(0.6) : .white.opacity(hover.on ? 0.12 : 0.05), lineWidth: 0.75))
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.smooth(duration: 0.15)) { hover.on = h } }
    }
}

/// Hover flag held outside the view (no @State in this package).
final class HoverBox: ObservableObject { @Published var on = false }

// MARK: - Expanded

private struct ExpandedContent: View {
    @ObservedObject var store: AgentStore
    @ObservedObject var model: IslandModel
    let ns: Namespace.ID
    @Namespace private var chipNS

    /// Featured agent: hovered chip, else whoever needs attention most.
    private var hero: Agent {
        if let k = model.selected, let a = store.agents[k] { return a }
        let rank: (Agent) -> Int = { a in
            a.pending != nil ? 0 : a.status == .waiting ? 1 : a.status.isBusy ? 2 : a.live ? 3 : 4
        }
        return store.listed.min { rank($0) < rank($1) } ?? store.ordered[0]
    }

    var body: some View {
        let hero = hero
        VStack(spacing: 0) {
            header(hero)
                .frame(height: model.notch.height)
                .reveal(model.revealed, index: 0)

            HeroView(agent: hero, store: store, ns: ns)
                .id(hero.kind)
                .transition(.asymmetric(
                    insertion: .blurFade(10).combined(with: .offset(x: 14)),
                    removal: .blurFade(10).combined(with: .offset(x: -14))))
                .reveal(model.revealed, index: 1)
                .padding(.top, 14)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 16)
        .background {
            DarkMeshBackdrop(palette: hero.status == .waiting ? amberPalette : hero.kind.gradient, active: hero.status.isBusy)
                .opacity(hero.live ? 1 : 0.45)
                .padding(-30)
                .id(hero.kind)
                .transition(.opacity.animation(.smooth(duration: 0.6)))
                .reveal(model.revealed, index: 0)
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.86), value: hero.kind)
    }

    private func header(_ hero: Agent) -> some View {
        // Chips sit beside the hardware notch: the left side fills first and any overflow continues on
        // the right, tighter when several process-detected agents are running at once.
        let list = store.listed
        let dense = list.count > 5
        let pitch: CGFloat = dense ? 28 : 36
        let side = (model.size(store).width - model.notch.width) / 2 - 28 - 8
        let fit = max(1, Int(side / pitch))
        let left = Array(list.prefix(fit)), right = Array(list.dropFirst(fit))
        return HStack(spacing: 0) {
            chips(left, hero: hero, dense: dense)
            Spacer(minLength: model.notch.width + 16)
            chips(right, hero: hero, dense: dense)
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .buttonStyle(QuietButton()).help("Quit NotchAgents")
                .padding(.leading, right.isEmpty ? 0 : 6)
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.8), value: hero.kind)
    }

    private func chips(_ list: [Agent], hero: Agent, dense: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(list) { a in
                let on = a.kind == hero.kind
                AgentGlyph(kind: a.kind, status: a.status, size: dense ? 14 : 17)
                    .frame(width: dense ? 26 : 34, height: 26)
                    .background {
                        if on {
                            Capsule().fill(.white.opacity(0.1))
                                .overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
                                .matchedGeometryEffect(id: "chip", in: chipNS)
                        }
                    }
                    .opacity(a.live || on ? 1 : 0.45)
                    .contentShape(Capsule())
                    .onHover { inside in if inside { model.selected = a.kind } }
                    .onTapGesture { model.selected = a.kind; BotMood.poke(a.kind) }
                    .help(a.kind.title)
            }
        }
    }
}

// MARK: - Empty states

/// Expanded island with nothing running: what NotchAgents watches and how to start each agent.
private struct EmptyContent: View {
    @ObservedObject var store: AgentStore
    @ObservedObject var model: IslandModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text("NotchAgents").font(.system(size: 11, weight: .semibold)).foregroundStyle(Ink.tertiary)
                Spacer(minLength: model.notch.width + 16)
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .buttonStyle(QuietButton()).help("Quit NotchAgents")
            }
            .frame(height: model.notch.height)
            .reveal(model.revealed, index: 0)

            VStack(alignment: .leading, spacing: 3) {
                Text("No agents running").font(.system(size: 17, weight: .semibold)).tracking(-0.3).foregroundStyle(Ink.primary)
                Text("Start one and it lights up here: live status, approvals and usage.")
                    .font(.system(size: 11.5)).foregroundStyle(Ink.secondary)
            }
            .padding(.top, 12)
            .reveal(model.revealed, index: 1)

            HStack(spacing: 8) {
                ForEach(AgentKind.allCases.filter(\.isCore)) { LaunchCard(kind: $0, store: store) }
            }
            .padding(.top, 14)
            .reveal(model.revealed, index: 2)

            Text("Also detects " + AgentKind.allCases.filter { !$0.isCore }.map(\.title).joined(separator: ", ") + ".")
                .font(.system(size: 10.5)).foregroundStyle(Ink.tertiary)
                .padding(.top, 10)
                .reveal(model.revealed, index: 2)

            Spacer(minLength: 0)
            HookStatus(store: store)
                .reveal(model.revealed, index: 3)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 16)
    }
}

private struct LaunchCard: View {
    let kind: AgentKind
    @ObservedObject var store: AgentStore

    var body: some View {
        HStack(spacing: 10) {
            AgentGlyph(kind: kind, status: .offline, size: 26).frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(kind.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.primary)
                LaunchHint(kind: kind, store: store)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 52)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.06), lineWidth: 0.75))
    }
}

/// How to start an agent: open its app when installed, otherwise the terminal command.
private struct LaunchHint: View {
    let kind: AgentKind
    @ObservedObject var store: AgentStore

    var body: some View {
        if store.appURL(kind) != nil {
            Button("Open") { store.launch(kind) }
                .buttonStyle(PillButton(tint: .white.opacity(0.1)))
                .controlSize(.small)
        } else if let cmd = kind.command {
            Text(cmd).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Ink.secondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5).fill(Ink.hairline))
        } else {
            Text("Not installed").font(.system(size: 10.5)).foregroundStyle(Ink.tertiary)
        }
    }
}

/// Hero body for an agent that isn't running.
private struct OfflinePanel: View {
    let kind: AgentKind
    @ObservedObject var store: AgentStore

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "moon.zzz.fill").font(.system(size: 13)).foregroundStyle(Ink.tertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(kind.title) isn't running").font(.system(size: 12, weight: .medium)).foregroundStyle(Ink.primary)
                Text(store.appURL(kind) != nil ? "Open it to see live activity here." : kind.command.map { "Run \($0) in a terminal to see live activity here." } ?? "Install it to see live activity here.")
                    .font(.system(size: 11)).foregroundStyle(Ink.tertiary)
            }
            Spacer(minLength: 6)
            LaunchHint(kind: kind, store: store)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 52)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.04)))
        .frame(height: 66)
    }
}

/// One line on whether Claude Code is wired up: server listening, hooks installed, events arriving.
struct HookStatus: View {
    @ObservedObject var store: AgentStore

    var body: some View {
        let (color, text): (Color, String) =
            store.serverOK == false ? (Color(hex: 0xF0605A), "Can't listen on 127.0.0.1:47823. Is another copy of NotchAgents running?")
            : !store.hooksInstalled ? (amber, "Claude Code hooks aren't installed. Install them from the menu bar icon.")
            : store.hooksActive ? (.green, "Connected to Claude Code")
            : (Ink.tertiary, "Hooks installed. Waiting for the first Claude Code event.")
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(text).font(.system(size: 10.5)).foregroundStyle(Ink.tertiary).lineLimit(1).truncationMode(.tail)
        }
    }
}

private extension View {
    func reveal(_ on: Bool, index: Int) -> some View {
        self.opacity(on ? 1 : 0)
            .scaleEffect(on ? 1 : 0.96, anchor: .top)
            .offset(y: on ? 0 : -10)
            .blur(radius: on ? 0 : 10)
            .animation(on ? .spring(response: 0.6, dampingFraction: 0.86).delay(0.08 + Double(index) * 0.07) : .easeIn(duration: 0.1), value: on)
    }
}

private struct HeroView: View {
    let agent: Agent
    @ObservedObject var store: AgentStore
    let ns: Namespace.ID

    private var busy: Bool { agent.status.isBusy }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 14) {
                AgentGlyph(kind: agent.kind, status: agent.status, size: 48)
                    .contentShape(Circle())
                    .onTapGesture {
                        BotMood.poke(agent.kind)
                        SFX.play(.tap)
                        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                    }
                    .help("Say hi")
                    .matchedGeometryEffect(id: agent.kind, in: ns, isSource: agent.live)
                    .frame(width: 56, height: 56)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(agent.kind.title)
                            .font(.system(size: 17, weight: .semibold))
                            .tracking(-0.3)
                            .foregroundStyle(Ink.primary)
                    }
                    ShimmerText(text: statusLine, color: statusColor, active: busy || agent.status == .waiting,
                                mono: agent.status == .tool, size: 12.5)
                        .id(statusLine)
                        .transition(.blurFade(5).combined(with: .offset(y: 5)))
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Ink.tertiary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let start = agent.turnStart, busy || agent.status == .waiting {
                    VStack(alignment: .trailing, spacing: 5) {
                        ElapsedText(since: start, pitch: 2.7, colors: [agent.kind.gradient[3], agent.kind.gradient[0]])
                        Text("This turn").font(.system(size: 9.5, weight: .medium)).foregroundStyle(Ink.tertiary)
                    }
                    .transition(.blurFade(4))
                }

                if agent.kind.tracksContext {
                ZStack {
                    ContextRing(fraction: agent.live ? agent.contextFraction : 0, colors: agent.kind.gradient, lineWidth: 3.5)
                    VStack(spacing: 3) {
                        DotText(text: agent.contextUsed > 0 ? "\(Int(agent.contextFraction * 100))" : "—", pitch: 1.9, colors: [.white, .white.opacity(0.7)])
                        Text("ctx").font(.system(size: 8.5, weight: .medium)).foregroundStyle(Ink.tertiary)
                    }
                    .foregroundStyle(Ink.primary)
                }
                .frame(width: 48, height: 48)
                .opacity(agent.live ? 1 : 0.35)
                .help("Context window used")
                }
            }

            Group {
                if let p = agent.pending {
                    ApprovalCard(pending: p, kind: agent.kind, store: store)
                } else if !agent.live {
                    OfflinePanel(kind: agent.kind, store: store)
                } else {
                    ActivityList(agent: agent)
                }
            }
            .transition(.blurFade(6))

            Rectangle().fill(LinearGradient(colors: [.white.opacity(0), Ink.hairline, .white.opacity(0)],
                                            startPoint: .leading, endPoint: .trailing))
                .frame(height: 0.5)

            footer.frame(height: 30)
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.86), value: agent.status)
        .animation(.spring(response: 0.4, dampingFraction: 0.86), value: agent.pending?.id)
        .animation(.spring(response: 0.4, dampingFraction: 0.86), value: agent.log)
        .animation(.smooth(duration: 0.3), value: statusLine)
    }

    /// Footer stats, most important first in drop order: when the row is too wide for the island,
    /// the least useful tiles go first instead of the row overflowing and clipping at the edges.
    private enum Stat: Hashable { case fiveHour, weekly, output, session, today, running }

    private var stats: [Stat] {
        var out: [Stat] = []
        if agent.limit5h != nil { out.append(.fiveHour) }
        if agent.limitWeek != nil { out.append(.weekly) }
        if agent.live, agent.tokens > 0 { out.append(.output) }
        if agent.live, agent.cost != nil { out.append(.session) }
        if agent.kind.isClaude, store.claudeToday[agent.kind] != nil { out.append(.today) }
        if !agent.kind.hasLiveStatus, agent.live, agent.sessionStart != nil { out.append(.running) }
        return out
    }

    @ViewBuilder private func stat(_ s: Stat) -> some View {
        switch s {
        case .fiveHour: Meter(label: "5-hour", value: (agent.limit5h ?? 0) / 100, reset: agent.reset5h, palette: agent.kind.gradient)
        case .weekly: Meter(label: "Weekly", value: (agent.limitWeek ?? 0) / 100, reset: agent.resetWeek, palette: agent.kind.gradient)
        case .output: StatTile(label: "Output", value: Self.compact(agent.tokens)).help("Output tokens this session")
        case .session: StatTile(label: "Session", value: String(format: "$%.2f", agent.cost ?? 0)).help("API-equivalent cost of this session")
        case .today: StatTile(label: "Today", value: String(format: "$%.2f", store.claudeToday[agent.kind] ?? 0))
            .help(agent.kind == .claudeApp ? "API-equivalent spend since midnight, all desktop-app sessions" : "API-equivalent spend since midnight, all CLI sessions")
        case .running:
            TimelineView(.periodic(from: .now, by: 30)) { tl in
                StatTile(label: "Running", value: AgentStore.duration(tl.date.timeIntervalSince(agent.sessionStart ?? tl.date)) ?? "0s")
            }
        }
    }

    private func statRow(_ items: [Stat]) -> some View {
        HStack(spacing: 18) { ForEach(items, id: \.self) { stat($0) } }.fixedSize()
    }

    @ViewBuilder private var footer: some View {
        let all = stats
        HStack(spacing: 12) {
            Group {
                if !all.isEmpty {
                    ViewThatFits(in: .horizontal) {
                        statRow(all)
                        statRow(all.filter { $0 != .output })
                        statRow(all.filter { $0 != .output && $0 != .weekly })
                        statRow(all.filter { $0 != .output && $0 != .weekly && $0 != .session })
                        statRow(all.filter { $0 == .fiveHour || $0 == .today })
                    }
                } else if agent.live {
                    Text(agent.kind.hasLiveStatus ? "Usage appears after the first reply" : "Usage isn't reported by \(agent.kind.title)")
                        .font(.system(size: 11)).foregroundStyle(Ink.tertiary)
                } else {
                    HookStatus(store: store)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 2) {
                if agent.kind.isClaude {
                    ConfirmStop(kind: agent.kind, store: store).disabled(!busy)
                }
                if agent.kind.tracksContext {
                    Button { store.openTranscript(agent.kind) } label: { Image(systemName: "text.alignleft") }
                        .buttonStyle(QuietButton()).help("Reveal transcript")
                }
                Button { store.focus(agent.kind) } label: { Image(systemName: "arrow.up.right") }
                    .buttonStyle(QuietButton()).help("Jump to \(agent.kind.title)")
            }
            .fixedSize()
            .disabled(!agent.live)
            .opacity(agent.live ? 1 : 0.4)
        }
    }

    private var subtitle: String {
        if !agent.live { return "Not running" }
        let bits = [agent.model.map(Self.prettyModel), agent.cwd.map { ($0 as NSString).lastPathComponent }].compactMap { $0 }
        return bits.isEmpty ? " " : bits.joined(separator: "  ·  ")
    }

    private var statusColor: Color {
        switch agent.status {
        case .offline: Ink.tertiary
        case .idle: Ink.secondary
        case .thinking, .tool: agent.kind.gradient[3]
        case .waiting: amber
        }
    }

    private var statusLine: String {
        switch agent.status {
        case .offline: return "Sleeping"
        case .idle where !agent.kind.hasLiveStatus: return "Running"
        case .idle: return agent.lastTurn.flatMap { AgentStore.duration($0) }.map { "Ready  ·  last turn \($0)" } ?? "Ready"
        case .thinking: return "Thinking…"
        case .tool:
            let tool = agent.tool ?? "Working"
            return agent.detail.map { "\(tool)  \($0)" } ?? tool
        case .waiting:
            if let p = agent.pending { return p.summary.isEmpty ? "Waiting for approval" : "Wants to run \(p.tool)" }
            return agent.detail ?? "Waiting for you"
        }
    }

    static func compact(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1e6) : n >= 1000 ? String(format: "%.1fK", Double(n) / 1e3) : "\(n)"
    }

    static func prettyModel(_ m: String) -> String {
        // "claude-opus-5-5" -> "Opus 5.5", "gpt-6.1-sol" -> "GPT 6.1 Sol", "claude-opus-4-5-20251101" -> "Opus 4.5"
        let long = m.contains("[1m]")
        var parts = m.replacingOccurrences(of: "[1m]", with: "").replacingOccurrences(of: "claude-", with: "")
            .split(separator: "-").map(String.init).filter { !($0.count == 8 && $0.allSatisfy(\.isNumber)) }
        if long { parts.append("1M") }
        var out: [String] = []
        while !parts.isEmpty {
            let p = parts.removeFirst()
            if let last = out.last, last.first?.isNumber == true, p.allSatisfy(\.isNumber), p.count <= 2 {
                out[out.count - 1] = last + "." + p
            } else {
                out.append(p == "gpt" ? "GPT" : p.prefix(1).uppercased() + p.dropFirst())
            }
        }
        return out.joined(separator: " ")
    }
}

// MARK: - Activity log

private struct ActivityList: View {
    let agent: Agent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if agent.log.isEmpty {
                Text(!agent.kind.hasLiveStatus ? "\(agent.kind.title) is detected from its process, so tool activity isn't shown"
                     : agent.live ? "No tool calls yet this session" : "No recent activity")
                    .font(.system(size: 11))
                    .foregroundStyle(Ink.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 66, alignment: .center)
            } else {
                ForEach(Array(agent.log.prefix(3).enumerated()), id: \.element.id) { i, e in
                    LogRow(entry: e, palette: agent.kind.gradient, busy: agent.status.isBusy)
                        .opacity([1, 0.6, 0.35][min(i, 2)])
                        .transition(.blurFade(4).combined(with: .move(edge: .top)))
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 66, alignment: .top)
    }
}

private struct LogRow: View {
    let entry: LogEntry
    let palette: [Color]
    let busy: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: Self.symbol(entry.tool))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Ink.tertiary)
                .frame(width: 14)

            Text(entry.tool)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Ink.primary)
            if let d = entry.detail {
                Text(d)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 6)
            if !entry.done && busy {
                DotWave(color: palette[0])
            } else {
                Image(systemName: "checkmark").font(.system(size: 8.5, weight: .bold)).foregroundStyle(Ink.tertiary)
            }
            TimelineView(.periodic(from: entry.date, by: 1)) { tl in
                Text(Self.ago(tl.date.timeIntervalSince(entry.date)))
                    .font(.system(size: 10, weight: .medium)).monospacedDigit()
                    .foregroundStyle(Ink.tertiary)
                    .frame(width: 28, alignment: .trailing)
            }
        }
        .frame(height: 17)
    }

    static func ago(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return s < 60 ? "\(s)s" : s < 3600 ? "\(s / 60)m" : s < 86400 ? "\(s / 3600)h" : "\(s / 86400)d"
    }

    static func symbol(_ tool: String) -> String {
        switch tool.lowercased() {
        case "bash", "exec", "exec_command", "shell", "local_shell": "terminal"
        case "read", "view_image": "doc.text"
        case "edit", "multiedit", "write", "notebookedit", "apply_patch": "pencil"
        case "grep", "glob", "ls": "magnifyingglass"
        case "webfetch", "websearch", "web_search": "globe"
        case "task", "agent": "person.2"
        case "todowrite": "checklist"
        case "askuserquestion": "questionmark"
        default: tool.hasPrefix("mcp") ? "puzzlepiece" : "bolt"
        }
    }
}

private struct Spinner: View {
    let color: Color
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { tl in
            Circle()
                .trim(from: 0, to: 0.7)
                .stroke(AngularGradient(colors: [color.opacity(0), color], center: .center), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .rotationEffect(.radians(tl.date.timeIntervalSinceReferenceDate * 6))
        }
    }
}

// MARK: - Approval

private struct ApprovalCard: View {
    let pending: PendingPermission
    let kind: AgentKind
    @ObservedObject var store: AgentStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(amber)
                Text("Allow \(pending.tool)?").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Ink.primary)
                if !pending.summary.isEmpty {
                    Text(pending.summary).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Ink.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 6)
                Button { store.decide(kind, allow: false) } label: { ShortcutLabel(title: "Deny", key: "N") }
                    .buttonStyle(PillButton(tint: .white.opacity(0.1)))
                Button { store.decide(kind, allow: true) } label: { ShortcutLabel(title: "Allow", key: "Y") }
                    .buttonStyle(GradientPill(palette: amberPalette))
            }
            if !pending.diff.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(pending.diff) { line in
                        HStack(spacing: 6) {
                            Text(line.added ? "+" : "−").foregroundStyle(line.added ? Color.green.opacity(0.9) : Color.red.opacity(0.9))
                            Text(line.text.isEmpty ? " " : line.text).foregroundStyle(Ink.primary.opacity(0.85))
                        }
                        .font(.system(size: 10.5, design: .monospaced))
                        .lineLimit(1)
                        .padding(.horizontal, 8).padding(.vertical, 1.5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background((line.added ? Color.green : Color.red).opacity(0.1))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .padding(10)
        .frame(height: 122, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LinearGradient(colors: [amber.opacity(0.12), .white.opacity(0.03)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(amber.opacity(0.45), lineWidth: 0.75))
        )
    }
}

private struct ShortcutLabel: View {
    let title: String, key: String
    var body: some View {
        HStack(spacing: 5) {
            Text(title)
            Text("⌘\(key)").font(.system(size: 9.5, weight: .semibold)).opacity(0.55)
        }
    }
}

// MARK: - Figures

/// Stat tile: label (sentence case) over a semibold value in proportional figures.
private struct StatTile: View {
    let label: String, value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 9.5, weight: .medium)).foregroundStyle(Ink.tertiary)
            DotText(text: value, pitch: 1.9, colors: [.white, .white.opacity(0.65)])
        }
    }
}

/// Limit meter: the fill carries severity (agent gradient → warning → danger); the track is a
/// light step of the same hue so the state reads across the whole bar.
private struct Meter: View {
    let label: String
    let value: Double
    let reset: Date?
    let palette: [Color]

    private var fill: [Color] {
        value >= 0.9 ? [Color(hex: 0xF0605A), Color(hex: 0xD93B3B)]
            : value >= 0.7 ? [amberPalette[0], amberPalette[1]]
            : [palette[0], palette[1]]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(label).font(.system(size: 9.5, weight: .medium)).foregroundStyle(Ink.tertiary)
                if value >= 0.9 {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 8)).foregroundStyle(Color(hex: 0xF0605A))
                }
            }
            HStack(spacing: 6) {
                Capsule().fill(fill[0].opacity(0.18))
                    .overlay(alignment: .leading) {
                        GeometryReader { g in
                            Capsule().fill(LinearGradient(colors: fill, startPoint: .leading, endPoint: .trailing))
                                .frame(width: max(4, g.size.width * min(1, value)))
                        }
                    }
                    .frame(width: 52, height: 4)
                DotText(text: "\(Int(value * 100))%", pitch: 1.6, colors: [.white, .white.opacity(0.65)])
                if let reset, reset > Date() {
                    Text("↻ " + RelativeTime.short(reset.timeIntervalSinceNow))
                        .font(.system(size: 9.5, weight: .medium)).foregroundStyle(Ink.tertiary)
                        .fixedSize()
                        .help("Resets in \(AgentStore.duration(reset.timeIntervalSinceNow) ?? "")")
                }
            }
            .animation(.smooth(duration: 0.8), value: value)
        }
    }
}

// MARK: - Controls

/// Interrupt needs two taps within 2s so a stray click never kills a run.
private struct ConfirmStop: View {
    let kind: AgentKind
    @ObservedObject var store: AgentStore
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        let armed = store.armedStop == kind
        Button {
            if armed { store.interrupt(kind) } else { store.armStop(kind) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "stop.fill").font(.system(size: 8.5, weight: .bold))
                if armed { Text("Stop").font(.system(size: 10.5, weight: .semibold)).transition(.blurFade(3)) }
            }
            .foregroundStyle(.white.opacity(enabled ? 0.9 : 0.25))
            .padding(.horizontal, armed ? 9 : 0)
            .frame(minWidth: 26, minHeight: 26)
            .background(Capsule().fill(armed ? Color.red.opacity(0.8) : .white.opacity(0.0001)))
        }
        .buttonStyle(.plain)
        .help("Interrupt (tap twice)")
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: armed)
    }
}

struct QuietButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { QuietBody(configuration: configuration) }
    private struct QuietBody: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(enabled ? (configuration.isPressed ? 1 : 0.6) : 0.25))
                .frame(width: 26, height: 26)
                .background(Circle().fill(.white.opacity(configuration.isPressed ? 0.14 : 0.0001)))
                .scaleEffect(configuration.isPressed ? 0.88 : 1)
                .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
                .contentShape(Circle())
        }
    }
}

struct PillButton: ButtonStyle {
    let tint: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12).frame(height: 26)
            .background(Capsule().fill(tint))
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// Primary action: agent gradient with a glass top highlight.
struct GradientPill: ButtonStyle {
    let palette: [Color]
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(.black.opacity(0.85))
            .padding(.horizontal, 13).frame(height: 26)
            .background(
                Capsule().fill(LinearGradient(colors: [palette[3], palette[0]], startPoint: .top, endPoint: .bottom))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 0.5))
            )
            .shadow(color: palette[1].opacity(0.5), radius: 8, y: 2)
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}


/// `NotchAgents --render-preview dir` renders the island in each of its states, on a desktop-like
/// backdrop, to PNGs: for checking layout (nothing clipped) and for the README. It never touches a
/// running instance.
enum IslandPreview {
    @MainActor static func render(to dir: String) {
        let store = AgentStore()
        let ago = { (s: Double) in Date().addingTimeInterval(-s) }

        var claude = Agent(kind: .claudeCLI)
        claude.live = true; claude.status = .tool; claude.tool = "Bash"; claude.detail = "swift test --parallel"
        claude.model = "claude-opus-5-5"; claude.tokens = 48_200; claude.contextUsed = 412_000; claude.contextWindow = 1_000_000
        claude.cost = 3.84; claude.limit5h = 42; claude.limitWeek = 18
        claude.reset5h = Date().addingTimeInterval(2.4 * 3600); claude.resetWeek = Date().addingTimeInterval(5.2 * 86400)
        claude.cwd = "/Users/me/Developer/weather-app"; claude.sessionStart = ago(1500); claude.turnStart = ago(94)
        claude.log = [LogEntry(tool: "Bash", detail: "swift test --parallel", date: ago(6)),
                      LogEntry(tool: "Edit", detail: "ForecastView.swift", date: ago(31), done: true),
                      LogEntry(tool: "Read", detail: "WeatherService.swift", date: ago(52), done: true),
                      LogEntry(tool: "Grep", detail: "fetchForecast", date: ago(70), done: true)]

        var codex = Agent(kind: .codex)
        codex.live = true; codex.status = .thinking; codex.model = "gpt-6.1"; codex.cwd = "/Users/me/Developer/api-server"
        codex.contextUsed = 96_000; codex.contextWindow = 400_000; codex.tokens = 12_900; codex.turnStart = ago(40)
        codex.limit5h = 23; codex.limitWeek = 9
        codex.reset5h = Date().addingTimeInterval(3.1 * 3600); codex.resetWeek = Date().addingTimeInterval(3 * 86400)
        codex.log = [LogEntry(tool: "exec_command", detail: "npm run lint", date: ago(12))]

        func shot(_ name: String, hover: Bool = true, selected: AgentKind? = nil, framing: MacBookMock.Framing = .closeUp) {
            let model = IslandModel(); model.hovering = hover; model.revealed = true; model.selected = selected
            model.notch = CGSize(width: 185, height: 32)
            let size = model.size(store)
            let view = MacBookMock(store: store, model: model, island: size, framing: framing)
            let r = ImageRenderer(content: view); r.scale = 2
            // JPEG: the wallpaper's soft gradients make PNGs several times larger for no visible gain.
            guard let cg = r.cgImage,
                  let jpg = NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else {
                print("render failed"); return
            }
            try? jpg.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".jpg"))
            print(name, cg.width, "x", cg.height)
        }

        store.preview([claude, codex], today: 18.42)
        shot("hero", selected: .claudeCLI, framing: .full)
        shot("working", selected: .claudeCLI)
        shot("codex", selected: .codex)
        shot("compact", hover: false)

        var asking = claude
        asking.status = .waiting; asking.tool = "Edit"; asking.detail = "ForecastView.swift"
        asking.pending = PendingPermission(tool: "Edit", summary: "ForecastView.swift", diff: [
            DiffLine(text: "    Text(day.high, format: .number)", added: false),
            DiffLine(text: "    Text(day.high, format: .measurement(width: .narrow))", added: true),
            DiffLine(text: "        .monospacedDigit()", added: true)]) { _ in }
        store.preview([asking, codex], today: 18.42)
        shot("approval", selected: .claudeCLI)

        let q = PendingQuestion(kind: .claudeCLI, items: [PendingQuestion.Item(
            header: "Storage", question: "Where should forecasts be cached?",
            options: [.init(label: "SwiftData", detail: "Persist across launches, queryable"),
                      .init(label: "In memory", detail: "Simplest; cleared on quit"),
                      .init(label: "URLCache", detail: "Reuse HTTP caching headers")],
            multi: false)], answer: { _ in })
        store.preview([claude, codex], today: 18.42, question: q)
        shot("question", hover: false)

        var done = claude
        done.status = .idle; done.tool = nil; done.detail = nil; done.turnStart = nil
        store.preview([done, codex], today: 18.42, alert: IslandAlert(kind: .claudeCLI, style: .done,
            title: "Claude CLI finished", message: "Done in 2m 14s  ·  weather-app"))
        shot("done", hover: false)

        store.preview([], today: nil)
        shot("empty")
    }
}
