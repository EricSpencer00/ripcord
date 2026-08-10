import Foundation

/// ITU-R BS.1770-4 loudness measurement, plus EBU Tech 3342 loudness range.
///
/// The filter coefficients are derived from the analogue prototype rather than hard-coded at
/// 48 kHz, so 44.1 kHz material measures correctly instead of being resampled first.
public struct LoudnessMeter: Sendable {
    public let sampleRate: Double

    /// Stage 1: head-related high shelf. Stage 2: RLB high-pass.
    private static let shelfFrequency = 1681.974450955533
    private static let shelfGainDB = 3.999843853973347
    private static let shelfQ = 0.7071752369554196
    private static let highpassFrequency = 38.13547087602444
    private static let highpassQ = 0.5003270373238773

    /// The -0.691 dB offset that calibrates the gated measurement, per the standard.
    private static let calibration = -0.691
    private static let absoluteGateLUFS = -70.0

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
    }

    public struct Measurement: Sendable {
        public var integratedLUFS: Double
        public var loudnessRangeLU: Double
        /// Short-term (3 s) block loudnesses, retained for the loudness range calculation.
        public var isSilent: Bool
    }

    public func kWeightingCascade() -> BiquadCascade {
        BiquadCascade([Self.shelfCoefficients(sampleRate: sampleRate),
                       Self.rlbCoefficients(sampleRate: sampleRate)])
    }

    /// Stage 1, the head-related high shelf.
    ///
    /// This is deliberately *not* built from the RBJ shelf in `BiquadCoefficients`. The standard's
    /// shelf uses a different topology, and running its stated f0/Q/gain through the RBJ form comes
    /// out 0.22 dB low at 1 kHz — enough to shift a tone's reading by a quarter of a LU. The form
    /// below, with a bilinear `tan` prewarp, reproduces the reference coefficients in Table 1 to
    /// machine precision at 48 kHz and stays correct at other sample rates.
    public static func shelfCoefficients(sampleRate: Double) -> BiquadCoefficients {
        let k = tan(.pi * shelfFrequency / sampleRate)
        let vh = pow(10.0, shelfGainDB / 20.0)
        // The exponent is the standard's own empirical fit relating shelf and band gain.
        let vb = pow(vh, 0.4996667741545416)
        let a0 = 1.0 + k / shelfQ + k * k
        return BiquadCoefficients(
            b0: (vh + vb * k / shelfQ + k * k) / a0,
            b1: 2.0 * (k * k - vh) / a0,
            b2: (vh - vb * k / shelfQ + k * k) / a0,
            a1: 2.0 * (k * k - 1.0) / a0,
            a2: (1.0 - k / shelfQ + k * k) / a0)
    }

    /// Stage 2, the RLB high-pass. Numerator is exactly [1, -2, 1] per the standard.
    public static func rlbCoefficients(sampleRate: Double) -> BiquadCoefficients {
        let k = tan(.pi * highpassFrequency / sampleRate)
        let denominator = 1.0 + k / highpassQ + k * k
        return BiquadCoefficients(
            b0: 1.0, b1: -2.0, b2: 1.0,
            a1: 2.0 * (k * k - 1.0) / denominator,
            a2: (1.0 - k / highpassQ + k * k) / denominator)
    }

    public func measure(channels: [[Float]]) -> Measurement {
        guard let first = channels.first, !first.isEmpty else {
            return Measurement(integratedLUFS: -.infinity, loudnessRangeLU: 0, isSilent: true)
        }
        // Channel weights G_i. Stereo and mono use 1.0; surround weights are not needed here.
        let weights = [Double](repeating: 1.0, count: channels.count)
        let weighted = channels.map { channel -> [Double] in
            var buffer = channel.map(Double.init)
            var filter = kWeightingCascade()
            filter.process(&buffer)
            return buffer
        }

        let integrated = gatedLoudness(weighted, weights: weights,
                                       blockSeconds: 0.4, stepSeconds: 0.1, relativeGateLU: 10)
        let range = loudnessRange(weighted, weights: weights)
        let silent = !integrated.isFinite || integrated <= Self.absoluteGateLUFS
        return Measurement(integratedLUFS: integrated, loudnessRangeLU: range, isSilent: silent)
    }

    /// Mean-square energy per block for each channel, plus the resulting block loudness.
    private func blockLoudnesses(_ channels: [[Double]], weights: [Double],
                                 blockSeconds: Double, stepSeconds: Double) -> (energies: [[Double]], loudness: [Double]) {
        let blockLength = Int(blockSeconds * sampleRate)
        let step = max(Int(stepSeconds * sampleRate), 1)
        let count = channels[0].count
        guard blockLength > 0, count >= blockLength else { return ([], []) }

        var energies: [[Double]] = []
        var loudness: [Double] = []
        var start = 0
        while start + blockLength <= count {
            var perChannel = [Double](repeating: 0, count: channels.count)
            var sum = 0.0
            for (index, channel) in channels.enumerated() {
                var acc = 0.0
                for i in start..<(start + blockLength) { acc += channel[i] * channel[i] }
                let meanSquare = acc / Double(blockLength)
                perChannel[index] = meanSquare
                sum += weights[index] * meanSquare
            }
            energies.append(perChannel)
            loudness.append(Self.calibration + 10 * log10(max(sum, 1e-30)))
            start += step
        }
        return (energies, loudness)
    }

    private func gatedLoudness(_ channels: [[Double]], weights: [Double],
                               blockSeconds: Double, stepSeconds: Double, relativeGateLU: Double) -> Double {
        let (energies, loudness) = blockLoudnesses(channels, weights: weights,
                                                   blockSeconds: blockSeconds, stepSeconds: stepSeconds)
        guard !loudness.isEmpty else { return -.infinity }

        let absoluteIndices = loudness.indices.filter { loudness[$0] > Self.absoluteGateLUFS }
        guard !absoluteIndices.isEmpty else { return -.infinity }

        let relativeThreshold = mean(of: energies, at: absoluteIndices, weights: weights) - relativeGateLU
        let finalIndices = absoluteIndices.filter { loudness[$0] > relativeThreshold }
        guard !finalIndices.isEmpty else { return -.infinity }

        return mean(of: energies, at: finalIndices, weights: weights)
    }

    /// Loudness of the mean energy across a set of blocks.
    private func mean(of energies: [[Double]], at indices: [Int], weights: [Double]) -> Double {
        var sum = 0.0
        for channel in 0..<weights.count {
            var acc = 0.0
            for index in indices { acc += energies[index][channel] }
            sum += weights[channel] * (acc / Double(indices.count))
        }
        return Self.calibration + 10 * log10(max(sum, 1e-30))
    }

    /// EBU Tech 3342: 3 s blocks stepped by 1 s, gated at -70 LUFS absolute and -20 LU relative,
    /// then the span between the 10th and 95th percentile.
    private func loudnessRange(_ channels: [[Double]], weights: [Double]) -> Double {
        let (energies, loudness) = blockLoudnesses(channels, weights: weights,
                                                   blockSeconds: 3.0, stepSeconds: 1.0)
        guard loudness.count >= 2 else { return 0 }

        let absoluteIndices = loudness.indices.filter { loudness[$0] > Self.absoluteGateLUFS }
        guard !absoluteIndices.isEmpty else { return 0 }
        let relativeThreshold = mean(of: energies, at: absoluteIndices, weights: weights) - 20
        let gated = absoluteIndices.filter { loudness[$0] > relativeThreshold }.map { loudness[$0] }.sorted()
        guard gated.count >= 2 else { return 0 }

        return percentile(gated, 0.95) - percentile(gated, 0.10)
    }

    private func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let position = fraction * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, sorted.count - 1)
        let t = position - Double(lower)
        return sorted[lower] * (1 - t) + sorted[upper] * t
    }
}
