import Foundation

/// Offline look-ahead true-peak limiter.
///
/// Because the whole signal is available, the gain curve is computed non-causally and no
/// output delay is introduced. The safety argument is deliberately simple:
///
/// 1. `desired[i]` is the gain that would put input sample `i` exactly at the ceiling.
/// 2. `slidingMin[i] = min(desired[j])` over `|j - i| <= radius`.
/// 3. Smoothing averages `slidingMin` over a kernel whose support is also `<= radius`.
///
/// Every term in that average is a minimum over a window that contains `i`, so every term is
/// `<= desired[i]`, so the smoothed gain is `<= desired[i]`. The release stage only ever lowers
/// the gain further. The ceiling therefore cannot be exceeded, without needing a clipper.
public struct Limiter: Sendable {
    public var ceilingDBTP: Double
    public var lookaheadSeconds: Double
    public var releaseSeconds: Double

    public init(ceilingDBTP: Double, lookaheadSeconds: Double = 0.005, releaseSeconds: Double = 0.10) {
        self.ceilingDBTP = ceilingDBTP
        self.lookaheadSeconds = lookaheadSeconds
        self.releaseSeconds = releaseSeconds
    }

    public struct Result: Sendable {
        public var peakReductionDB: Double
        public var achievedTruePeakDBTP: Double
    }

    /// - Parameter envelope: per-sample true-peak envelope of the signal as it currently stands,
    ///   when the caller already has one. Computing it is the most expensive step in the whole
    ///   chain, and the makeup search only rescales the signal between attempts, so the caller can
    ///   scale a single envelope instead of paying for it again on every pass.
    @discardableResult
    public func process(left: inout [Float], right: inout [Float], sampleRate: Double,
                        envelope: [Float]? = nil,
                        oversampler: TruePeakMeter = TruePeakMeter()) -> Result {
        precondition(left.count == right.count)
        let count = left.count
        guard count > 0 else { return Result(peakReductionDB: 0, achievedTruePeakDBTP: -.infinity) }

        let ceiling = pow(10, ceilingDBTP / 20)
        let radius = max(Int(lookaheadSeconds * sampleRate), 1)

        // Stage 1: gain that would land each sample exactly on the ceiling.
        let peaks: [Float]
        if let envelope, envelope.count == count {
            peaks = envelope
        } else {
            let envelopeL = oversampler.peakEnvelope(left)
            let envelopeR = oversampler.peakEnvelope(right)
            peaks = (0..<count).map { max(envelopeL[$0], envelopeR[$0]) }
        }
        var desired = [Double](repeating: 1, count: count)
        for i in 0..<count {
            let peak = Double(peaks[i])
            desired[i] = peak > ceiling ? ceiling / peak : 1.0
        }

        // Stage 2 + 3: symmetric sliding minimum, then two moving averages of half the radius each.
        var gain = slidingMinimum(desired, radius: radius)
        gain = movingAverage(gain, radius: max(radius / 2, 1))
        gain = movingAverage(gain, radius: max(radius / 2, 1))

        // Stage 4: slew-limited release. Only ever reduces gain relative to the smoothed curve.
        let releaseCoef = exp(-1.0 / (max(releaseSeconds, 1e-4) * sampleRate))
        var held = gain[0]
        var minimumGain = 1.0
        var achievedPeak = 0.0
        for i in 0..<count {
            held = min(gain[i], held * releaseCoef + 1.0 * (1 - releaseCoef))
            minimumGain = min(minimumGain, held)
            // The gain curve is smoothed over hundreds of samples while the reconstruction kernel
            // spans about twelve, so the gain is effectively constant across it and the output
            // envelope is the input envelope scaled. Good enough to report; the caller re-measures.
            achievedPeak = max(achievedPeak, held * Double(peaks[i]))
            let g = Float(held)
            left[i] *= g
            right[i] *= g
        }

        return Result(peakReductionDB: 20 * log10(max(minimumGain, 1e-12)),
                      achievedTruePeakDBTP: 20 * log10(max(achievedPeak, 1e-12)))
    }

    /// Minimum over a centred window, in linear time via a monotonic deque.
    private func slidingMinimum(_ values: [Double], radius: Int) -> [Double] {
        let count = values.count
        var out = [Double](repeating: 0, count: count)
        var deque = [Int]()
        deque.reserveCapacity(2 * radius + 2)
        var head = 0
        var next = 0

        for i in 0..<count {
            let windowEnd = min(i + radius, count - 1)
            while next <= windowEnd {
                while deque.count > head, values[deque[deque.count - 1]] >= values[next] {
                    deque.removeLast()
                }
                deque.append(next)
                next += 1
            }
            let windowStart = max(i - radius, 0)
            while deque[head] < windowStart { head += 1 }
            out[i] = values[deque[head]]

            // Keep the deque from growing without bound over a long file.
            if head > 4096 {
                deque.removeFirst(head)
                head = 0
            }
        }
        return out
    }

    /// Centred box average via a prefix sum, with edges clamped.
    private func movingAverage(_ values: [Double], radius: Int) -> [Double] {
        let count = values.count
        guard count > 0 else { return values }
        var prefix = [Double](repeating: 0, count: count + 1)
        for i in 0..<count { prefix[i + 1] = prefix[i] + values[i] }
        var out = [Double](repeating: 0, count: count)
        for i in 0..<count {
            let lo = max(i - radius, 0)
            let hi = min(i + radius, count - 1)
            out[i] = (prefix[hi + 1] - prefix[lo]) / Double(hi - lo + 1)
        }
        return out
    }
}
