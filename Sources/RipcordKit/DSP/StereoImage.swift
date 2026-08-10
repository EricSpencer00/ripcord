import Foundation

/// Mid/side width control with a mono-below-frequency guard.
///
/// Low frequency stereo content is the usual cause of a track that measures fine but falls apart
/// on a mono system, so the side channel is high-passed rather than merely attenuated.
public enum StereoImage {
    public static func apply(left: inout [Float], right: inout [Float],
                             width: Double, monoBelowHz: Double, sampleRate: Double) {
        precondition(left.count == right.count)
        guard !left.isEmpty else { return }
        let unchangedWidth = abs(width - 1.0) < 1e-6
        guard !unchangedWidth || monoBelowHz > 20 else { return }

        var side = [Float](repeating: 0, count: left.count)
        var mid = [Float](repeating: 0, count: left.count)
        for i in left.indices {
            mid[i] = (left[i] + right[i]) * 0.5
            side[i] = (left[i] - right[i]) * 0.5
        }

        if !unchangedWidth {
            let w = Float(width)
            for i in side.indices { side[i] *= w }
        }

        if monoBelowHz > 20 {
            let q = 0.7071067811865476
            var highpass = BiquadCascade([
                .highpass(freq: monoBelowHz, q: q, sampleRate: sampleRate),
                .highpass(freq: monoBelowHz, q: q, sampleRate: sampleRate),
            ])
            highpass.process(&side)
        }

        for i in left.indices {
            left[i] = mid[i] + side[i]
            right[i] = mid[i] - side[i]
        }
    }

    /// Pearson correlation between channels. +1 is mono, 0 is uncorrelated, -1 is out of phase.
    public static func correlation(left: [Float], right: [Float]) -> Double {
        guard left.count == right.count, !left.isEmpty else { return 1 }
        var sumLR = 0.0, sumLL = 0.0, sumRR = 0.0
        for i in left.indices {
            let l = Double(left[i]), r = Double(right[i])
            sumLR += l * r; sumLL += l * l; sumRR += r * r
        }
        let denominator = sqrt(sumLL * sumRR)
        guard denominator > 1e-12 else { return 1 }
        return sumLR / denominator
    }
}
