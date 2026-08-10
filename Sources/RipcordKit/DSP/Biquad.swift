import Foundation

/// Normalized biquad coefficients (a0 divided out).
public struct BiquadCoefficients: Sendable, Equatable {
    public var b0: Double, b1: Double, b2: Double, a1: Double, a2: Double

    public init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0; self.b1 = b1; self.b2 = b2; self.a1 = a1; self.a2 = a2
    }

    /// RBJ cookbook forms. `q` is the classic resonance parameter; `gainDB` applies to shelves and peaks.
    public static func lowpass(freq: Double, q: Double, sampleRate: Double) -> BiquadCoefficients {
        let (w0, cosw, alpha) = prewarp(freq, q, sampleRate)
        _ = w0
        let b1 = 1 - cosw
        return normalized(b0: b1 / 2, b1: b1, b2: b1 / 2,
                          a0: 1 + alpha, a1: -2 * cosw, a2: 1 - alpha)
    }

    public static func highpass(freq: Double, q: Double, sampleRate: Double) -> BiquadCoefficients {
        let (_, cosw, alpha) = prewarp(freq, q, sampleRate)
        let b0 = (1 + cosw) / 2
        return normalized(b0: b0, b1: -(1 + cosw), b2: b0,
                          a0: 1 + alpha, a1: -2 * cosw, a2: 1 - alpha)
    }

    public static func allpass(freq: Double, q: Double, sampleRate: Double) -> BiquadCoefficients {
        let (_, cosw, alpha) = prewarp(freq, q, sampleRate)
        return normalized(b0: 1 - alpha, b1: -2 * cosw, b2: 1 + alpha,
                          a0: 1 + alpha, a1: -2 * cosw, a2: 1 - alpha)
    }

    public static func peaking(freq: Double, q: Double, gainDB: Double, sampleRate: Double) -> BiquadCoefficients {
        let a = pow(10, gainDB / 40)
        let (_, cosw, alpha) = prewarp(freq, q, sampleRate)
        return normalized(b0: 1 + alpha * a, b1: -2 * cosw, b2: 1 - alpha * a,
                          a0: 1 + alpha / a, a1: -2 * cosw, a2: 1 - alpha / a)
    }

    public static func lowShelf(freq: Double, q: Double, gainDB: Double, sampleRate: Double) -> BiquadCoefficients {
        let a = pow(10, gainDB / 40)
        let (_, cosw, alpha) = prewarp(freq, q, sampleRate)
        let twoSqrtAAlpha = 2 * sqrt(a) * alpha
        return normalized(
            b0: a * ((a + 1) - (a - 1) * cosw + twoSqrtAAlpha),
            b1: 2 * a * ((a - 1) - (a + 1) * cosw),
            b2: a * ((a + 1) - (a - 1) * cosw - twoSqrtAAlpha),
            a0: (a + 1) + (a - 1) * cosw + twoSqrtAAlpha,
            a1: -2 * ((a - 1) + (a + 1) * cosw),
            a2: (a + 1) + (a - 1) * cosw - twoSqrtAAlpha)
    }

    public static func highShelf(freq: Double, q: Double, gainDB: Double, sampleRate: Double) -> BiquadCoefficients {
        let a = pow(10, gainDB / 40)
        let (_, cosw, alpha) = prewarp(freq, q, sampleRate)
        let twoSqrtAAlpha = 2 * sqrt(a) * alpha
        return normalized(
            b0: a * ((a + 1) + (a - 1) * cosw + twoSqrtAAlpha),
            b1: -2 * a * ((a - 1) + (a + 1) * cosw),
            b2: a * ((a + 1) + (a - 1) * cosw - twoSqrtAAlpha),
            a0: (a + 1) - (a - 1) * cosw + twoSqrtAAlpha,
            a1: 2 * ((a - 1) - (a + 1) * cosw),
            a2: (a + 1) - (a - 1) * cosw - twoSqrtAAlpha)
    }

    /// Magnitude response in dB at `freq`, evaluated on the unit circle.
    public func magnitudeDB(at freq: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * freq / sampleRate
        let cosw = cos(w), sinw = sin(w)
        let cos2w = cos(2 * w), sin2w = sin(2 * w)
        let numRe = b0 + b1 * cosw + b2 * cos2w
        let numIm = -(b1 * sinw + b2 * sin2w)
        let denRe = 1 + a1 * cosw + a2 * cos2w
        let denIm = -(a1 * sinw + a2 * sin2w)
        let num = sqrt(numRe * numRe + numIm * numIm)
        let den = sqrt(denRe * denRe + denIm * denIm)
        guard den > 0 else { return -.infinity }
        return 20 * log10(max(num / den, 1e-12))
    }

    private static func prewarp(_ freq: Double, _ q: Double, _ sampleRate: Double) -> (Double, Double, Double) {
        let clamped = min(max(freq, 1), sampleRate * 0.49)
        let w0 = 2 * Double.pi * clamped / sampleRate
        return (w0, cos(w0), sin(w0) / (2 * max(q, 1e-4)))
    }

    private static func normalized(b0: Double, b1: Double, b2: Double,
                                   a0: Double, a1: Double, a2: Double) -> BiquadCoefficients {
        BiquadCoefficients(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }
}

/// Direct Form I biquad with double-precision state.
///
/// State is double precision because the RLB high-pass used by the loudness meter has poles
/// close enough to the unit circle that single-precision accumulation drifts audibly.
public struct Biquad: Sendable {
    public var coefficients: BiquadCoefficients
    private var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

    public init(_ coefficients: BiquadCoefficients) {
        self.coefficients = coefficients
    }

    public mutating func reset() {
        x1 = 0; x2 = 0; y1 = 0; y2 = 0
    }

    @inline(__always)
    public mutating func process(_ x: Double) -> Double {
        let c = coefficients
        let y = c.b0 * x + c.b1 * x1 + c.b2 * x2 - c.a1 * y1 - c.a2 * y2
        x2 = x1; x1 = x
        y2 = y1; y1 = y
        return y
    }

    public mutating func process(_ samples: inout [Float]) {
        for i in samples.indices {
            samples[i] = Float(process(Double(samples[i])))
        }
    }

    public mutating func process(_ samples: inout [Double]) {
        for i in samples.indices {
            samples[i] = process(samples[i])
        }
    }
}

/// A fixed cascade of biquads applied in series.
public struct BiquadCascade: Sendable {
    public private(set) var stages: [Biquad]

    public init(_ coefficients: [BiquadCoefficients]) {
        stages = coefficients.map(Biquad.init)
    }

    public var isEmpty: Bool { stages.isEmpty }

    public mutating func reset() {
        for i in stages.indices { stages[i].reset() }
    }

    @inline(__always)
    public mutating func process(_ x: Double) -> Double {
        var y = x
        for i in stages.indices { y = stages[i].process(y) }
        return y
    }

    public mutating func process(_ samples: inout [Float]) {
        guard !stages.isEmpty else { return }
        for i in samples.indices {
            samples[i] = Float(process(Double(samples[i])))
        }
    }

    public mutating func process(_ samples: inout [Double]) {
        guard !stages.isEmpty else { return }
        for i in samples.indices {
            samples[i] = process(samples[i])
        }
    }

    public func magnitudeDB(at freq: Double, sampleRate: Double) -> Double {
        stages.reduce(0) { $0 + $1.coefficients.magnitudeDB(at: freq, sampleRate: sampleRate) }
    }
}
