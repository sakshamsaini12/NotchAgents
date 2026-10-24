import AVFoundation

/// Interface sounds: soft, low-level glass and mallet tones with a short room tail. Synthesised in code (the app
/// ships no audio files), rendered once to in-memory WAVs and played through a small player pool.
/// Hover is deliberately silent, like the Dynamic Island; sounds mark events, not pointer movement.
enum SFX: CaseIterable {
    case done        // a turn finished
    case attention   // an agent needs you / asks a question
    case permission  // approval requested
    case allow, deny // approval answered
    case submit      // question answered
    case tap         // option picked, orb poked
    case arm, stop   // interrupt armed / sent

    @MainActor static var enabled = UserDefaults.standard.object(forKey: "sounds") as? Bool ?? true
    @MainActor private static var cache: [SFX: Data] = [:]
    @MainActor private static var players: [AVAudioPlayer] = []
    @MainActor private static var last: [SFX: Date] = [:]

    @MainActor static func play(_ s: SFX) {
        guard enabled else { return }
        let now = Date()
        if let t = last[s], now.timeIntervalSince(t) < 0.12 { return }
        last[s] = now
        players.removeAll { !$0.isPlaying }
        let data = cache[s] ?? s.render()
        cache[s] = data
        guard let p = try? AVAudioPlayer(data: data) else { return }
        p.volume = s.volume
        p.play()
        players.append(p)
    }

    /// `NotchAgents --sounds`: plays every sound once, a beat apart, to audition them.
    @MainActor static func audition() {
        enabled = true
        for s in allCases {
            print(s)
            play(s)
            RunLoop.main.run(until: Date().addingTimeInterval(1.1))
        }
    }

    /// Render every sound off the main thread so the first one plays without a hitch.
    @MainActor static func prewarm() {
        DispatchQueue.global(qos: .utility).async {
            let rendered = allCases.map { ($0, $0.render()) }
            DispatchQueue.main.async { for (s, d) in rendered where cache[s] == nil { cache[s] = d } }
        }
    }

    // MARK: - Voicing

    // Quiet by design: these sit under whatever you're doing, like macOS's own UI sounds.
    private var volume: Float {
        switch self {
        case .done, .attention: 0.32
        case .permission: 0.3
        case .allow, .submit: 0.22
        case .deny, .stop: 0.2
        case .arm: 0.16
        case .tap: 0.1
        }
    }

    /// Notes stay in the warm C5–C6 range: higher fundamentals read as shrill on laptop speakers.
    private var notes: [Note] {
        switch self {
        case .done:       // soft rising fourth, like a sent message
            return [Note(f: 783.99, at: 0, tau: 0.16), Note(f: 1046.5, at: 0.075, tau: 0.32)]
        case .attention:  // two gentle mallet notes falling, asking for a look
            return [Note(f: 880, at: 0, tau: 0.18, voice: .mallet), Note(f: 659.26, at: 0.12, tau: 0.3, voice: .mallet)]
        case .permission: // quick soft major arpeggio
            return [Note(f: 523.25, at: 0, tau: 0.14), Note(f: 659.26, at: 0.06, tau: 0.16), Note(f: 783.99, at: 0.12, tau: 0.32)]
        case .allow:
            return [Note(f: 659.26, at: 0, tau: 0.09, voice: .pure, glide: 1.12, glideTime: 0.05)]
        case .deny:
            return [Note(f: 493.88, at: 0, tau: 0.1, voice: .pure, glide: 0.9, glideTime: 0.07)]
        case .submit:
            return [Note(f: 659.26, at: 0, tau: 0.08, voice: .pure), Note(f: 880, at: 0.05, tau: 0.16, voice: .pure)]
        case .tap:        // barely-there tick
            return [Note(f: 1318.5, at: 0, tau: 0.012, voice: .pure, attack: 0.002)]
        case .arm:
            return [Note(f: 440, at: 0, tau: 0.045, voice: .pure)]
        case .stop:
            return [Note(f: 523.25, at: 0, tau: 0.12, voice: .pure, glide: 0.75, glideTime: 0.1)]
        }
    }

    private struct Note {
        enum Voice {
            case glass, mallet, pure
            /// (frequency ratio, amplitude, decay scale) per partial. Only harmonic, quickly fading
            /// overtones: inharmonic ones are what make synthetic chimes sound tinny.
            var partials: [(Double, Double, Double)] {
                switch self {
                case .glass: [(1, 1, 1), (2, 0.14, 0.45), (3, 0.04, 0.25)]
                case .mallet: [(1, 1, 1), (4, 0.05, 0.15)]
                case .pure: [(1, 1, 1), (2, 0.04, 0.4)]
                }
            }
        }
        var f: Double, at: Double, tau: Double
        var voice = Voice.glass
        var glide = 1.0, glideTime = 0.05
        /// Rounded onset; anything much shorter than ~5 ms is heard as a click.
        var attack = 0.008
    }

    // MARK: - Synthesis

    private static let rate = 48_000.0

    private func render() -> Data {
        let sr = Self.rate
        let notes = notes
        let length = Int(((notes.map { $0.at + $0.tau * 6 }.max() ?? 0.3) + 0.25) * sr)
        var dry = [Float](repeating: 0, count: length)
        for n in notes {
            let start = Int(n.at * sr)
            let span = min(length - start, Int(n.tau * 7 * sr))
            for (ratio, amp, decay) in n.voice.partials {
                var phase = 0.0
                for i in 0..<span {
                    let t = Double(i) / sr
                    let g = min(1, t / n.glideTime)
                    let f = n.f * (1 + (n.glide - 1) * (1 - (1 - g) * (1 - g))) * ratio
                    phase += 2 * .pi * f / sr
                    let rise = t < n.attack ? 0.5 - 0.5 * cos(.pi * t / n.attack) : 1
                    dry[start + i] += Float(sin(phase) * amp * rise * exp(-t / (n.tau * decay)))
                }
            }
        }
        // Gentle low-pass (~3.5 kHz) takes the edge off.
        let k = Float(1 - exp(-2 * .pi * 3500 / sr))
        var lp: Float = 0
        for i in 0..<length { lp += k * (dry[i] - lp); dry[i] = lp }
        let left = Self.room(dry, offset: 0), right = Self.room(dry, offset: 23)
        var peak: Float = 0.0001
        for i in 0..<length { peak = max(peak, abs(left[i]), abs(right[i])) }
        // Normalise to -6 dBFS so loudness comes only from `volume`; no saturation.
        let gain = 0.5 / peak
        let fade = Int(0.03 * sr)
        var pcm = [Int16](); pcm.reserveCapacity(length * 2)
        for i in 0..<length {
            let tail: Float = i > length - fade ? Float(length - i) / Float(fade) : 1
            for s in [left[i], right[i]] {
                pcm.append(Int16(max(-1, min(1, s * gain * tail)) * Float(Int16.max)))
            }
        }
        return Self.wav(pcm, channels: 2, rate: Int(sr))
    }

    /// Small Freeverb-style room (damped combs into allpasses), mixed in lightly for air.
    private static func room(_ x: [Float], offset: Int) -> [Float] {
        let combs = [1427, 1781, 1973, 2099].map { $0 + offset }
        let allpasses = [241, 82].map { $0 + offset / 2 }
        var wet = [Float](repeating: 0, count: x.count)
        for len in combs {
            var buf = [Float](repeating: 0, count: len), idx = 0, low: Float = 0
            for i in 0..<x.count {
                let y = buf[idx]
                low = y * 0.65 + low * 0.35
                buf[idx] = x[i] + low * 0.74
                idx = (idx + 1) % len
                wet[i] += y * 0.25
            }
        }
        for len in allpasses {
            var buf = [Float](repeating: 0, count: len), idx = 0
            for i in 0..<wet.count {
                let b = buf[idx]
                buf[idx] = wet[i] + b * 0.5
                wet[i] = b - wet[i]
                idx = (idx + 1) % len
            }
        }
        return zip(x, wet).map { $0 + $1 * 0.1 }
    }

    private static func wav(_ pcm: [Int16], channels: Int, rate: Int) -> Data {
        var d = Data()
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        let bytes = pcm.count * 2
        d.append(Data("RIFF".utf8)); u32(36 + bytes); d.append(Data("WAVE".utf8))
        d.append(Data("fmt ".utf8)); u32(16); u16(1); u16(channels); u32(rate); u32(rate * channels * 2); u16(channels * 2); u16(16)
        d.append(Data("data".utf8)); u32(bytes)
        pcm.withUnsafeBufferPointer { d.append(Data(buffer: $0)) }
        return d
    }
}
