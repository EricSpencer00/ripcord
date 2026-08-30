#!/usr/bin/env swift
// Synthesises the unmastered clip used by the landing page, so the site carries no third party
// audio and the "before" file can be regenerated from source.
// Usage: swift Tools/makedemo.swift <output.wav>

import Foundation

let rate = 48_000.0
let bpm = 96.0
let beat = 60.0 / bpm
let bars = 6
let frames = Int(Double(bars) * 4 * beat * rate)

var left = [Double](repeating: 0, count: frames)
var right = [Double](repeating: 0, count: frames)

/// Deterministic noise, so two runs of this file produce the same clip.
var seed: UInt64 = 0x9E3779B97F4A7C15
func noise() -> Double {
    seed = seed &* 6364136223846793005 &+ 1442695040888963407
    return Double(Int64(bitPattern: seed >> 11)) / Double(1 << 52) - 1
}

func add(_ frame: Int, _ sample: Double, pan: Double = 0) {
    guard frame >= 0, frame < frames else { return }
    left[frame] += sample * (1 - max(0, pan))
    right[frame] += sample * (1 + min(0, pan))
}

func atFrame(bar: Int, beat step: Double) -> Int {
    Int((Double(bar) * 4 + step) * beat * rate)
}

// MARK: - Voices

func kick(at start: Int, gain: Double) {
    let length = Int(0.42 * rate)
    var phase = 0.0
    for i in 0..<length {
        let t = Double(i) / rate
        let frequency = 45 + 75 * exp(-t * 42)          // the pitch drop that makes it read as a kick
        phase += 2 * .pi * frequency / rate
        let body = sin(phase) * exp(-t * 8)
        let click = noise() * exp(-t * 400) * 0.25
        add(start + i, (body + click) * gain)
    }
}

func snare(at start: Int, gain: Double) {
    let length = Int(0.3 * rate)
    var band = 0.0, previous = 0.0
    for i in 0..<length {
        let t = Double(i) / rate
        let source = noise()
        band += (source - previous) * 0.35                // crude band pass around the snare body
        band *= 0.86
        previous = source
        let tone = sin(2 * .pi * 185 * t) * exp(-t * 26)
        add(start + i, (band * exp(-t * 18) + tone * 0.5) * gain)
    }
}

func hat(at start: Int, gain: Double, decay: Double) {
    let length = Int(0.12 * rate)
    var highpassed = 0.0, previous = 0.0
    for i in 0..<length {
        let t = Double(i) / rate
        let source = noise()
        highpassed = 0.72 * (highpassed + source - previous)
        previous = source
        add(start + i, highpassed * exp(-t * decay) * gain, pan: 0.25)
    }
}

/// Saw built from partials, low passed. Used for the bass and, an octave up, the pad.
func saw(_ phase: Double, partials: Int) -> Double {
    var value = 0.0
    for harmonic in 1...partials {
        value += sin(phase * Double(harmonic)) / Double(harmonic)
    }
    return value * 0.55
}

func bass(at start: Int, frequency: Double, length: Int, gain: Double) {
    var phase = 0.0, lowpassed = 0.0
    for i in 0..<length {
        let t = Double(i) / rate
        phase += 2 * .pi * frequency / rate
        let envelope = min(1, t * 60) * exp(-t * 1.4)
        lowpassed += (saw(phase, partials: 12) * envelope - lowpassed) * 0.06
        add(start + i, lowpassed * gain)
    }
}

func pad(at start: Int, frequencies: [Double], length: Int, gain: Double) {
    var phases = [Double](repeating: 0, count: frequencies.count * 2)
    var lowLeft = 0.0, lowRight = 0.0
    for i in 0..<length {
        let t = Double(i) / rate
        let envelope = min(1, t * 6) * min(1, (Double(length) / rate - t) * 4)
        var voiceLeft = 0.0, voiceRight = 0.0
        for (index, frequency) in frequencies.enumerated() {
            phases[index * 2] += 2 * .pi * frequency / rate
            phases[index * 2 + 1] += 2 * .pi * (frequency * 1.004) / rate   // detune, spread across the pair
            voiceLeft += saw(phases[index * 2], partials: 8)
            voiceRight += saw(phases[index * 2 + 1], partials: 8)
        }
        lowLeft += (voiceLeft / Double(frequencies.count) - lowLeft) * 0.09
        lowRight += (voiceRight / Double(frequencies.count) - lowRight) * 0.09
        add(start + i, lowLeft * envelope * gain, pan: -0.5)
        add(start + i, lowRight * envelope * gain, pan: 0.5)
    }
}

// MARK: - Arrangement

// A minor, one chord to a bar.
let roots = [110.0, 87.31, 130.81, 98.0, 110.0, 87.31]
let voicings: [[Double]] = [
    [220, 261.63, 329.63, 392],      // Am7
    [174.61, 220, 261.63, 329.63],   // Fmaj7
    [261.63, 329.63, 392, 493.88],   // Cmaj7
    [196, 246.94, 293.66, 392],      // G
    [220, 261.63, 329.63, 392],
    [174.61, 220, 261.63, 329.63],
]

for bar in 0..<bars {
    let barLength = Int(4 * beat * rate)
    pad(at: atFrame(bar: bar, beat: 0), frequencies: voicings[bar], length: barLength, gain: 0.24)
    bass(at: atFrame(bar: bar, beat: 0), frequency: roots[bar], length: Int(1.9 * beat * rate), gain: 0.2)
    bass(at: atFrame(bar: bar, beat: 2.5), frequency: roots[bar], length: Int(1.4 * beat * rate), gain: 0.18)

    kick(at: atFrame(bar: bar, beat: 0), gain: 0.42)
    kick(at: atFrame(bar: bar, beat: 2.5), gain: 0.36)
    if bar % 2 == 1 { kick(at: atFrame(bar: bar, beat: 3.75), gain: 0.28) }
    snare(at: atFrame(bar: bar, beat: 1), gain: 0.6)
    snare(at: atFrame(bar: bar, beat: 3), gain: 0.6)

    for eighth in stride(from: 0.0, to: 4.0, by: 0.5) {
        let accented = eighth.truncatingRemainder(dividingBy: 1) == 0
        hat(at: atFrame(bar: bar, beat: eighth), gain: accented ? 0.18 : 0.11, decay: accented ? 55 : 90)
    }
}

// MARK: - The state a bedroom mix arrives in

// A low mid pile up around 250 Hz, no air above 9 kHz, and a peak that stops well short of full
// scale. All three are what the chain is asked to correct.
var mudLeft = 0.0, mudRight = 0.0, airLeft = 0.0, airRight = 0.0
let mudCoefficient = 1 - exp(-2 * .pi * 250 / rate)
let airCoefficient = 1 - exp(-2 * .pi * 9000 / rate)
for i in 0..<frames {
    mudLeft += (left[i] - mudLeft) * mudCoefficient
    mudRight += (right[i] - mudRight) * mudCoefficient
    left[i] += mudLeft * 0.4
    right[i] += mudRight * 0.4
    airLeft += (left[i] - airLeft) * airCoefficient
    airRight += (right[i] - airRight) * airCoefficient
    left[i] = airLeft
    right[i] = airRight
}

let loudest = zip(left, right).map { max(abs($0), abs($1)) }.max() ?? 1
let headroom = pow(10, -7.5 / 20) / loudest      // peaks land near -7.5 dBFS
for i in 0..<frames {
    left[i] *= headroom
    right[i] *= headroom
}

// MARK: - Write

let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "demo.wav"
var data = Data()
func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

let bytesPerSample = 3
let dataBytes = frames * 2 * bytesPerSample
data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + dataBytes))
data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16))
append(UInt16(1)); append(UInt16(2)); append(UInt32(rate))
append(UInt32(rate * 2 * Double(bytesPerSample))); append(UInt16(2 * bytesPerSample)); append(UInt16(bytesPerSample * 8))
data.append(contentsOf: Array("data".utf8)); append(UInt32(dataBytes))
for i in 0..<frames {
    for sample in [left[i], right[i]] {
        let clamped = max(-1, min(1, sample))
        let value = Int32(clamped * 8_388_607)
        data.append(contentsOf: [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value >> 16)])
    }
}
try data.write(to: URL(fileURLWithPath: path))
print("→ \(path)  \(String(format: "%.1f", Double(frames) / rate))s")
