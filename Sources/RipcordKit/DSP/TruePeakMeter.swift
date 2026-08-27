import Accelerate
import Foundation

/// Inter-sample (true) peak detection by polyphase FIR reconstruction.
///
/// BS.1770 measures peaks on a reconstructed signal rather than on the samples themselves, because
/// a waveform can pass between two legal samples and still clip a converter.
///
/// The oversampling factor is set higher than the standard's 4x minimum after measuring the error
/// directly. The residual is not filter droop; it is the reconstruction grid. The interpolator only
/// evaluates the waveform at `factor` points per input sample, so a peak falling between two of
/// them is missed by
///
///     20 * log10(cos(pi * f / (factor * sampleRate)))
///
/// which is exact — measured against sine sweeps it holds to four decimal places. That bounds the
/// worst-case *under*-read over the whole band at -0.688 dB for 4x, -0.169 dB for 8x, -0.042 dB
/// for 16x and -0.011 dB for 32x. Under-reading is the direction that lets a master exceed its own
/// stated ceiling, which is why 4x is not good enough for anything that gets written down.
///
/// The grid is only half of it, and assuming otherwise is a trap worth naming: the interpolator
/// also **droops** near the top of the band, and droop is set by the kernel's time support —
/// `tapsPerPhase` — not by `factor`. A 32x meter built on a 16-tap kernel still reads 0.114 dB low
/// at 20 kHz, because no amount of extra grid resolution recovers a passband the filter has already
/// rolled off. Raising the oversampling factor without raising the taps buys nothing at all.
/// Measured worst case over 0.5-20 kHz at 48 kHz, across sampling phases:
///
///     8x/16 taps   -0.126 dB      16x/16 taps  -0.124 dB      32x/16 taps  -0.114 dB
///                                 16x/32 taps  -0.018 dB      32x/32 taps  -0.004 dB
///
/// 8x/16 is the working meter: cheap enough to sit inside the makeup search, and conservative in
/// use because the limiter aims below full scale anyway. `certification` is 32x/32, five times the
/// cost and still 215x realtime, used wherever a number is going to be printed as a claim.
///
/// One artifact is deliberately left in place. The input is zero-padded, so a buffer that begins or
/// ends on a non-zero sample presents a step discontinuity to the reconstruction filter and rings:
/// a constant 1.0 reads +1.07 dB across the whole buffer and exactly 0.000 dB in its interior. That
/// is not a bug being tolerated — a file whose first sample sits at full scale genuinely does
/// overshoot when a converter plays it from silence, and the error is in the safe direction. It is
/// recorded here because the number is startling if you meet it without warning.
public struct TruePeakMeter: Sendable {
    /// The working meter: fast enough for the makeup search.
    public static let working = TruePeakMeter()
    /// The meter used for anything that gets reported as a conformance figure. Both the grid and
    /// the kernel have to be raised together; see the note above for why 32x alone is not enough.
    public static let certification = TruePeakMeter(factor: 32, tapsPerPhase: 32)

    public let factor: Int
    private let tapsPerPhase: Int
    private static let kaiserBeta = 9.0

    /// One reversed coefficient set per phase, laid out for `vDSP_conv`.
    private let phases: [[Float]]
    /// Group delay of the interpolator expressed in input samples.
    public let delaySamples: Int

    /// Worst-case under-read of this meter, in dB. Negative.
    ///
    /// Deliberately not the grid formula on its own. That formula describes only what the sampling
    /// grid misses, and a meter whose kernel droops will read further low than it while appearing,
    /// on paper, to be accurate to a hundredth of a dB. The bound returned here is whichever of the
    /// two effects is worse, with the droop figures measured rather than derived — there is no
    /// closed form for a windowed-sinc passband, and quoting one would be inventing precision.
    ///
    /// An unmeasured kernel length falls back to the worst droop seen, so an untested configuration
    /// over-states its uncertainty rather than under-stating it.
    public var uncertaintyDB: Double {
        let grid = 20 * log10(cos(.pi / (2 * Double(factor))))
        let droop = Self.measuredDroopDB[tapsPerPhase] ?? Self.worstMeasuredDroopDB
        return min(grid, droop)
    }

    /// Passband droop at 20 kHz / 48 kHz by kernel length, measured against band-limited sines at
    /// every sampling phase. Independent of `factor`.
    private static let measuredDroopDB: [Int: Double] = [16: -0.126, 32: -0.005, 48: -0.005]
    private static let worstMeasuredDroopDB = -0.15

    /// - Parameters:
    ///   - factor: oversampling factor. BS.1770-4 asks for at least 4; see the note above for what
    ///     each choice costs and buys.
    ///   - tapsPerPhase: time support of the interpolator in input samples, which is what actually
    ///     sets the filter quality. It does not need to grow with `factor`.
    public init(factor: Int = 8, tapsPerPhase: Int = 16) {
        precondition(factor >= 4 && tapsPerPhase >= 4)
        self.factor = factor
        self.tapsPerPhase = tapsPerPhase
        let totalTaps = tapsPerPhase * factor
        self.delaySamples = Int((Double(totalTaps - 1) / 2 / Double(factor)).rounded())

        let n = totalTaps
        let center = Double(n - 1) / 2
        let cutoff = 0.5 / Double(factor)  // normalized to the oversampled rate
        var proto = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let x = Double(i) - center
            let sinc = x == 0 ? 2 * cutoff : sin(2 * .pi * cutoff * x) / (.pi * x)
            let r = 2 * Double(i) / Double(n - 1) - 1
            let window = Self.besselI0(Self.kaiserBeta * (1 - r * r).squareRoot()) / Self.besselI0(Self.kaiserBeta)
            proto[i] = sinc * window
        }
        // Normalize each phase so a DC input of 1.0 reconstructs to 1.0 on every subsample.
        for p in 0..<factor {
            var sum = 0.0
            for k in 0..<tapsPerPhase { sum += proto[p + k * factor] }
            if abs(sum) > 1e-12 {
                for k in 0..<tapsPerPhase { proto[p + k * factor] /= sum }
            }
        }
        // vDSP_conv correlates, so the taps go in reversed to make it a convolution.
        phases = (0..<factor).map { p in
            (0..<tapsPerPhase).reversed().map { k in Float(proto[p + k * factor]) }
        }
    }

    private static func besselI0(_ x: Double) -> Double {
        var sum = 1.0, term = 1.0
        for k in 1..<25 {
            let t = x / 2 / Double(k)
            term *= t * t
            sum += term
        }
        return sum
    }

    /// Per-input-sample maximum absolute value across the reconstructed subsamples,
    /// time-aligned back to the input so index `i` describes input sample `i`.
    public func peakEnvelope(_ x: [Float]) -> [Float] {
        let count = x.count
        guard count > 0 else { return [] }
        let taps = tapsPerPhase
        let delay = delaySamples

        // Pad the front so the first samples have history, and the back so the tail is still
        // covered once the envelope is shifted into alignment.
        let leading = taps - 1
        var padded = [Float](repeating: 0, count: leading + count + delay + taps)
        padded.withUnsafeMutableBufferPointer { destination in
            x.withUnsafeBufferPointer { source in
                destination.baseAddress!.advanced(by: leading)
                    .update(from: source.baseAddress!, count: count)
            }
        }

        let produced = count + delay
        var envelope = [Float](repeating: 0, count: produced)
        var scratch = [Float](repeating: 0, count: produced)

        for phase in phases {
            padded.withUnsafeBufferPointer { input in
                phase.withUnsafeBufferPointer { filter in
                    vDSP_conv(input.baseAddress!, 1, filter.baseAddress!, 1,
                              &scratch, 1, vDSP_Length(produced), vDSP_Length(taps))
                }
            }
            vDSP_vabs(scratch, 1, &scratch, 1, vDSP_Length(produced))
            vDSP_vmax(envelope, 1, scratch, 1, &envelope, 1, vDSP_Length(produced))
        }

        // Shift left by the group delay so the envelope lines up with the input.
        return Array(envelope[delay..<(delay + count)])
    }

    /// True peak of a set of channels, in dBTP.
    public func truePeakDBTP(_ channels: [[Float]]) -> Double {
        var peak: Float = 0
        for channel in channels {
            let envelope = peakEnvelope(channel)
            var channelPeak: Float = 0
            vDSP_maxv(envelope, 1, &channelPeak, vDSP_Length(envelope.count))
            peak = max(peak, channelPeak)
        }
        return 20 * log10(max(Double(peak), 1e-12))
    }
}
