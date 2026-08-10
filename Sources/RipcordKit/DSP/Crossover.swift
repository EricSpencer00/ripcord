import Foundation

/// Linkwitz-Riley 4th-order crossover tree whose bands sum back flat.
///
/// An LR4 low/high pair sums to a 2nd-order allpass rather than to unity, so every band below a
/// crossover point is passed through a matching allpass to keep all bands phase-aligned.
/// Without that compensation a 4-band split leaves audible dips at the crossover frequencies.
public enum Crossover {
    static let butterworthQ = 0.7071067811865476

    /// The filter chain that isolates one band:
    /// high-pass at every crossover below it, low-pass at its own upper edge, allpass above.
    public static func bandCascade(band: Int, crossovers: [Double], sampleRate: Double) -> BiquadCascade {
        var coefficients: [BiquadCoefficients] = []
        for (index, freq) in crossovers.sorted().enumerated() {
            if index < band {
                let hp = BiquadCoefficients.highpass(freq: freq, q: butterworthQ, sampleRate: sampleRate)
                coefficients.append(hp)
                coefficients.append(hp)
            } else if index == band {
                let lp = BiquadCoefficients.lowpass(freq: freq, q: butterworthQ, sampleRate: sampleRate)
                coefficients.append(lp)
                coefficients.append(lp)
            } else {
                coefficients.append(.allpass(freq: freq, q: butterworthQ, sampleRate: sampleRate))
            }
        }
        return BiquadCascade(coefficients)
    }

    /// Isolates a single band from a channel. Each call runs a fresh filter chain, so bands can be
    /// processed one at a time instead of holding every band of every channel in memory at once.
    public static func isolate(band: Int, from samples: [Float],
                               crossovers: [Double], sampleRate: Double) -> [Float] {
        var cascade = bandCascade(band: band, crossovers: crossovers, sampleRate: sampleRate)
        var output = samples
        cascade.process(&output)
        return output
    }

    /// Splits a channel into every band at once. Convenient for tests; the mastering path uses
    /// `isolate(band:)` so that long files do not need N copies of the signal resident.
    public static func split(_ samples: [Float], crossovers: [Double], sampleRate: Double) -> [[Float]] {
        (0...crossovers.count).map { isolate(band: $0, from: samples, crossovers: crossovers, sampleRate: sampleRate) }
    }
}

/// Sums band buffers back into one signal.
public func sumBands(_ bands: [[Float]]) -> [Float] {
    guard let first = bands.first else { return [] }
    var out = first
    for band in bands.dropFirst() {
        for i in out.indices { out[i] += band[i] }
    }
    return out
}
