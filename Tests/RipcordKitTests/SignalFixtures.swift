import Foundation
@testable import RipcordKit

/// Deterministic signal generators. Every test that needs audio builds it here so that failures
/// are reproducible and the repository carries no binary fixtures.
enum Signal {
    static let sampleRate = 48000.0

    /// A linear congruential generator, so noise is identical on every machine and every run.
    struct Random {
        private var state: UInt64
        init(seed: UInt64 = 0x5EED) { state = seed }
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53) * 2 - 1
        }
    }

    static func sine(frequency: Double, amplitude: Double, seconds: Double,
                     sampleRate: Double = sampleRate, phase: Double = 0) -> [Float] {
        let count = Int(seconds * sampleRate)
        return (0..<count).map {
            Float(amplitude * sin(2 * .pi * frequency * Double($0) / sampleRate + phase))
        }
    }

    static func whiteNoise(amplitude: Double, seconds: Double,
                           sampleRate: Double = sampleRate, seed: UInt64 = 0x5EED) -> [Float] {
        var random = Random(seed: seed)
        let count = Int(seconds * sampleRate)
        return (0..<count).map { _ in Float(amplitude * random.next()) }
    }

    /// Noise with a -3 dB/octave tilt, which reads as a flat line in octave-band energy and is
    /// therefore the natural "already balanced" input for tone tests.
    static func pinkNoise(amplitude: Double, seconds: Double,
                          sampleRate: Double = sampleRate, seed: UInt64 = 0x5EED) -> [Float] {
        let white = whiteNoise(amplitude: 1.0, seconds: seconds, sampleRate: sampleRate, seed: seed)
        // Voss-McCartney style cascade of one-pole filters approximating 1/f.
        var b0 = 0.0, b1 = 0.0, b2 = 0.0
        var out = [Float](repeating: 0, count: white.count)
        var peak = 0.0
        for i in white.indices {
            let w = Double(white[i])
            b0 = 0.99765 * b0 + w * 0.0990460
            b1 = 0.96300 * b1 + w * 0.2965164
            b2 = 0.57000 * b2 + w * 1.0526913
            let value = b0 + b1 + b2 + w * 0.1848
            out[i] = Float(value)
            peak = max(peak, abs(value))
        }
        guard peak > 0 else { return out }
        let scale = Float(amplitude / peak)
        for i in out.indices { out[i] *= scale }
        return out
    }

    /// Pink noise with periodic transients, standing in for music: it has a broadband bed, a
    /// meaningful crest factor, and something for a compressor to actually grab.
    static func musicLike(seconds: Double, sampleRate: Double = sampleRate,
                          seed: UInt64 = 0x1234) -> [[Float]] {
        var left = pinkNoise(amplitude: 0.12, seconds: seconds, sampleRate: sampleRate, seed: seed)
        var right = pinkNoise(amplitude: 0.12, seconds: seconds, sampleRate: sampleRate, seed: seed &+ 99)

        let beat = Int(sampleRate * 0.5)
        let decay = Int(sampleRate * 0.12)
        var position = 0
        while position + decay < left.count {
            for i in 0..<decay {
                let envelope = exp(-Double(i) / (sampleRate * 0.02))
                let hit = Float(0.55 * envelope * sin(2 * .pi * 70 * Double(i) / sampleRate))
                left[position + i] += hit
                right[position + i] += hit
            }
            position += beat
        }
        return [left, right]
    }

    static func stereo(_ mono: [Float]) -> [[Float]] { [mono, mono] }

    static func gain(_ channels: [[Float]], dB: Double) -> [[Float]] {
        let scale = Float(pow(10, dB / 20))
        return channels.map { $0.map { $0 * scale } }
    }

    static func peakDBFS(_ channels: [[Float]]) -> Double {
        var peak: Float = 0
        for channel in channels { for value in channel { peak = max(peak, abs(value)) } }
        return 20 * log10(max(Double(peak), 1e-12))
    }

    static func rmsDBFS(_ samples: [Float], skipping settling: Int = 0) -> Double {
        let usable = samples.dropFirst(settling)
        guard !usable.isEmpty else { return -.infinity }
        let sum = usable.reduce(0.0) { $0 + Double($1) * Double($1) }
        return 20 * log10(max(sqrt(sum / Double(usable.count)), 1e-12))
    }
}
