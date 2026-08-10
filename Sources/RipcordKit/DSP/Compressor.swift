import Foundation

/// Stereo-linked feed-forward compressor with a soft knee, working in the log domain.
///
/// Both channels share one gain envelope so the stereo image does not wander when one side
/// is momentarily louder than the other.
public struct Compressor: Sendable {
    public var thresholdDB: Double
    public var ratio: Double
    public var attackSeconds: Double
    public var releaseSeconds: Double
    public var kneeDB: Double
    public var makeupDB: Double

    public init(thresholdDB: Double, ratio: Double, attackSeconds: Double,
                releaseSeconds: Double, kneeDB: Double = 6, makeupDB: Double = 0) {
        self.thresholdDB = thresholdDB
        self.ratio = max(ratio, 1.0)
        self.attackSeconds = attackSeconds
        self.releaseSeconds = releaseSeconds
        self.kneeDB = kneeDB
        self.makeupDB = makeupDB
    }

    /// Gain reduction in dB (<= 0) for an input level, with a quadratic soft knee around threshold.
    func gainReductionDB(forLevelDB level: Double) -> Double {
        let slope = 1.0 / ratio - 1.0
        let over = level - thresholdDB
        if kneeDB > 0 && 2 * over > -kneeDB && 2 * over <= kneeDB {
            let x = over + kneeDB / 2
            return slope * x * x / (2 * kneeDB)
        }
        return over > 0 ? slope * over : 0
    }

    /// Compresses in place and returns the peak gain reduction applied, in dB (<= 0).
    @discardableResult
    public func process(left: inout [Float], right: inout [Float], sampleRate: Double) -> Double {
        precondition(left.count == right.count)
        let attackCoef = coefficient(attackSeconds, sampleRate)
        let releaseCoef = coefficient(releaseSeconds, sampleRate)
        var envelopeDB = 0.0
        var peakReduction = 0.0
        let makeupLinear = pow(10, makeupDB / 20)

        for i in left.indices {
            let level = max(abs(Double(left[i])), abs(Double(right[i])))
            let levelDB = 20 * log10(max(level, 1e-9))
            let target = gainReductionDB(forLevelDB: levelDB)
            // Attack when we need more reduction, release when we need less.
            let coef = target < envelopeDB ? attackCoef : releaseCoef
            envelopeDB = coef * envelopeDB + (1 - coef) * target
            peakReduction = min(peakReduction, envelopeDB)

            let gain = Float(pow(10, envelopeDB / 20) * makeupLinear)
            left[i] *= gain
            right[i] *= gain
        }
        return peakReduction
    }

    private func coefficient(_ seconds: Double, _ sampleRate: Double) -> Double {
        guard seconds > 0 else { return 0 }
        return exp(-1.0 / (seconds * sampleRate))
    }
}
