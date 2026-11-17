// Synthesizes Murmur's UI sounds (48 kHz stereo WAV) — soft, glassy, short.
//   swift scripts/make-sounds.swift Resources/Sounds
import Foundation

let sr = 48_000.0
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/Sounds"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

struct Note { var freq: Double; var start: Double; var dur: Double; var gain: Double }

/// A soft mallet/glass tone: fundamental + gently detuned partials, fast attack,
/// exponential decay, a touch of pitch "settle" at the onset for a rounded feel.
func render(_ notes: [Note], length: Double, brightness: Double = 1, room: Double = 0.22) -> [[Float]] {
    let n = Int(length * sr)
    var dry = [Double](repeating: 0, count: n)
    let partials: [(ratio: Double, amp: Double, decay: Double)] = [
        (1.0, 1.0, 1.0), (2.0, 0.28 * brightness, 1.8), (3.003, 0.10 * brightness, 2.6), (4.98, 0.035 * brightness, 4.0),
    ]
    for note in notes {
        let s0 = Int(note.start * sr), len = Int(note.dur * sr)
        for i in 0..<len where s0 + i < n {
            let t = Double(i) / sr
            let attack = min(1, t / 0.004)
            let settle = 1 + 0.012 * exp(-t / 0.012)           // tiny downward pitch settle
            var v = 0.0
            for p in partials {
                let env = exp(-t * (7.5 / note.dur) * p.decay)
                v += p.amp * env * sin(2 * .pi * note.freq * p.ratio * settle * t)
            }
            dry[s0 + i] += v * attack * note.gain
        }
    }
    // Small stereo "room": a few damped feedback delays, different per side.
    func reverb(_ delays: [Double]) -> [Double] {
        var y = dry
        for d in delays {
            let k = Int(d * sr); var lp = 0.0
            for i in k..<n { lp = lp * 0.55 + y[i - k] * 0.45; y[i] += lp * room * 0.5 }
        }
        return y
    }
    let l = reverb([0.0231, 0.0397, 0.0611]), r = reverb([0.0263, 0.0433, 0.0577])
    // Fade the tail, normalize to a gentle peak (-6 dBFS).
    let peak = max(l.map(abs).max() ?? 1, r.map(abs).max() ?? 1)
    let g = 0.5 / max(peak, 1e-9)
    let fade = Int(0.03 * sr)
    func finish(_ x: [Double]) -> [Float] {
        x.enumerated().map { i, v in
            let f = i > n - fade ? Double(n - i) / Double(fade) : 1
            return Float(v * g * f)
        }
    }
    return [finish(l), finish(r)]
}

func writeWAV(_ ch: [[Float]], _ name: String) {
    let frames = ch[0].count
    var d = Data()
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + frames * 4)); d.append(contentsOf: Array("WAVEfmt ".utf8))
    u32(16); u16(1); u16(2); u32(UInt32(sr)); u32(UInt32(sr) * 4); u16(4); u16(16)
    d.append(contentsOf: Array("data".utf8)); u32(UInt32(frames * 4))
    for i in 0..<frames { for c in 0..<2 { u16(UInt16(bitPattern: Int16(max(-1, min(1, ch[c][i])) * 32767))) } }
    try! d.write(to: URL(fileURLWithPath: "\(out)/\(name).wav"))
    print("\(name).wav  \(String(format: "%.2f", Double(frames) / sr))s")
}

// Notes (Hz): G5 784, B5 988, D6 1175, G6 1568, A4 440, F4 349
writeWAV(render([Note(freq: 784, start: 0, dur: 0.30, gain: 0.8),
                 Note(freq: 1175, start: 0.065, dur: 0.38, gain: 1.0)], length: 0.55), "start")
writeWAV(render([Note(freq: 1175, start: 0, dur: 0.26, gain: 0.8),
                 Note(freq: 784, start: 0.06, dur: 0.36, gain: 0.9)], length: 0.50, brightness: 0.8), "stop")
writeWAV(render([Note(freq: 1568, start: 0, dur: 0.16, gain: 1.0)], length: 0.25, brightness: 0.6, room: 0.15), "done")
writeWAV(render([Note(freq: 440, start: 0, dur: 0.20, gain: 1.0),
                 Note(freq: 349, start: 0.11, dur: 0.30, gain: 1.0)], length: 0.48, brightness: 0.5, room: 0.12), "error")
writeWAV(render([Note(freq: 988, start: 0, dur: 0.18, gain: 0.7)], length: 0.24, brightness: 0.5, room: 0.1), "cancel")
