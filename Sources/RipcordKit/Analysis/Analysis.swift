import Foundation

/// Everything measured about a track before any decision is made about it.
public struct Analysis: Sendable {
    public var sampleRate: Double
    public var frameCount: Int
    public var channelCount: Int

    public var integratedLUFS: Double
    public var loudnessRangeLU: Double
    public var truePeakDBTP: Double
    public var samplePeakDBFS: Double
    public var rmsDBFS: Double

    /// Energy density per octave band, in dB. Only the shape matters; see `normalizedBands`.
    public var bandsDB: [Double]
    public var resonances: [Resonance]
    public var correlation: Double
    /// Correlation of content below 150 Hz, which decides whether the low end needs collapsing.
    public var lowCorrelation: Double
    public var dcOffset: Double
    public var isSilent: Bool

    public var durationSeconds: Double { Double(frameCount) / sampleRate }
    public var crestFactorDB: Double { samplePeakDBFS - rmsDBFS }

    public struct Resonance: Sendable, Equatable {
        public var frequency: Double
        public var excessDB: Double
    }

    /// Octave band edges, chosen so band 4 (480-960 Hz) sits at the anchor of the target curve.
    public static let bandEdges: [(low: Double, high: Double)] = [
        (30, 60), (60, 120), (120, 240), (240, 480), (480, 960),
        (960, 1920), (1920, 3840), (3840, 7680), (7680, 15360), (15360, 20000),
    ]

    public static let bandLabels = [
        "30", "60", "120", "240", "480", "960", "1.9k", "3.8k", "7.7k", "15k",
    ]

    /// Band levels with their mean removed, so overall loudness does not leak into tonal decisions.
    public var normalizedBands: [Double] {
        // The mean is taken over the bands that carry the body of a mix; the extreme top and
        // bottom vary too much between genres to be a stable reference.
        let referenceRange = 1...7
        let reference = referenceRange.map { bandsDB[$0] }.reduce(0, +) / Double(referenceRange.count)
        return bandsDB.map { $0 - reference }
    }
}

public enum Analyzer {
    public static func analyze(channels: [[Float]], sampleRate: Double) -> Analysis {
        let frameCount = channels.first?.count ?? 0
        guard frameCount > 0 else {
            return Analysis(sampleRate: sampleRate, frameCount: 0, channelCount: channels.count,
                            integratedLUFS: -.infinity, loudnessRangeLU: 0, truePeakDBTP: -.infinity,
                            samplePeakDBFS: -.infinity, rmsDBFS: -.infinity,
                            bandsDB: [Double](repeating: -120, count: Analysis.bandEdges.count),
                            resonances: [], correlation: 1, lowCorrelation: 1, dcOffset: 0, isSilent: true)
        }

        let loudness = LoudnessMeter(sampleRate: sampleRate).measure(channels: channels)
        let truePeak = TruePeakMeter().truePeakDBTP(channels)

        var samplePeak = 0.0
        var sumSquares = 0.0
        var sum = 0.0
        for channel in channels {
            for value in channel {
                let v = Double(value)
                samplePeak = max(samplePeak, abs(v))
                sumSquares += v * v
                sum += v
            }
        }
        let total = Double(frameCount * channels.count)
        let rms = sqrt(sumSquares / total)

        let spectrum = SpectrumAnalyzer.analyze(channels: channels, sampleRate: sampleRate)
        // Total energy per octave band, not per-Hz density. Pink noise is flat in these terms,
        // which is the convention every published "target curve" is stated in.
        let bands = Analysis.bandEdges.map { spectrum.energyDB(from: $0.low, to: min($0.high, sampleRate / 2 - 1)) }

        let left = channels[0]
        let right = channels.count > 1 ? channels[1] : channels[0]
        let correlation = StereoImage.correlation(left: left, right: right)

        return Analysis(
            sampleRate: sampleRate,
            frameCount: frameCount,
            channelCount: channels.count,
            integratedLUFS: loudness.integratedLUFS,
            loudnessRangeLU: loudness.loudnessRangeLU,
            truePeakDBTP: truePeak,
            samplePeakDBFS: 20 * log10(max(samplePeak, 1e-12)),
            rmsDBFS: 20 * log10(max(rms, 1e-12)),
            bandsDB: bands,
            resonances: findResonances(spectrum: spectrum, sampleRate: sampleRate),
            correlation: correlation,
            lowCorrelation: lowBandCorrelation(left: left, right: right, sampleRate: sampleRate),
            dcOffset: sum / total,
            isSilent: loudness.isSilent)
    }

    /// Narrow peaks that stand proud of the local spectral trend — the honks and boxiness that
    /// make an otherwise fine mix tiring. Broadband tilt is handled by the target curve instead.
    static func findResonances(spectrum: PowerSpectrum, sampleRate: Double) -> [Analysis.Resonance] {
        let lowest = 150.0
        let highest = min(6000.0, sampleRate / 2 - 1000)
        guard highest > lowest * 2 else { return [] }

        let stepsPerOctave = 6.0
        let octaves = log2(highest / lowest)
        let count = Int(octaves * stepsPerOctave)
        guard count > 8 else { return [] }

        var frequencies = [Double]()
        var levels = [Double]()
        for i in 0...count {
            let freq = lowest * pow(2, Double(i) / stepsPerOctave)
            let width = freq * (pow(2, 1 / (2 * stepsPerOctave)) - pow(2, -1 / (2 * stepsPerOctave)))
            frequencies.append(freq)
            levels.append(spectrum.densityDB(from: freq - width / 2, to: freq + width / 2))
        }

        // Smooth over roughly a third of an octave either side to get the local trend.
        let smoothingRadius = 2
        var trend = [Double](repeating: 0, count: levels.count)
        for i in levels.indices {
            let lo = max(i - smoothingRadius, 0)
            let hi = min(i + smoothingRadius, levels.count - 1)
            trend[i] = levels[lo...hi].reduce(0, +) / Double(hi - lo + 1)
        }

        var found = [Analysis.Resonance]()
        for i in 1..<(levels.count - 1) {
            let excess = levels[i] - trend[i]
            guard excess > 3.0, levels[i] >= levels[i - 1], levels[i] >= levels[i + 1] else { continue }
            found.append(.init(frequency: frequencies[i], excessDB: excess))
        }
        // Keep the three worst, and never two that sit within a third of an octave of each other.
        var kept = [Analysis.Resonance]()
        for candidate in found.sorted(by: { $0.excessDB > $1.excessDB }) {
            if kept.contains(where: { abs(log2($0.frequency / candidate.frequency)) < 0.34 }) { continue }
            kept.append(candidate)
            if kept.count == 3 { break }
        }
        return kept.sorted { $0.frequency < $1.frequency }
    }

    static func lowBandCorrelation(left: [Float], right: [Float], sampleRate: Double) -> Double {
        let q = 0.7071067811865476
        var lowL = left, lowR = right
        var filterL = BiquadCascade([
            .lowpass(freq: 150, q: q, sampleRate: sampleRate),
            .lowpass(freq: 150, q: q, sampleRate: sampleRate),
        ])
        var filterR = filterL
        filterL.process(&lowL)
        filterR.process(&lowR)
        return StereoImage.correlation(left: lowL, right: lowR)
    }
}
