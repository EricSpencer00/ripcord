import Foundation

/// Turns a measurement into a plan. Pure: same analysis in, same settings out, no audio involved.
public enum ChainDesigner {
    /// Octave-band energy of a well-balanced master, in dB, aligned to `Analysis.bandEdges`.
    ///
    /// Stated as energy per octave, so pink noise would read as a flat line and this curve is the
    /// departure from pink that commercial masters actually show: a lift through the bass, a level
    /// midrange, and a steady rolloff above 2 kHz. Only the shape is used; the offset is arbitrary.
    public static let targetCurveDB: [Double] = [
        -4.0, 2.0, 3.0, 1.0, 0.0, -2.0, -3.5, -6.0, -10.0, -18.0,
    ]

    /// Bands whose measurement is least trustworthy get a tighter leash: the bottom octave is
    /// dominated by room noise and the top octave by lossy-codec rolloff.
    private static let bandLimitsDB: [Double] = [2.5, 4, 4, 4, 4, 4, 4, 4, 3, 2.5]

    public static func design(for analysis: Analysis, intensity: Intensity) -> MasterSettings {
        let target = normalize(targetCurveDB)
        let measured = analysis.normalizedBands
        let alreadyMastered = isAlreadyMastered(analysis: analysis, target: target, measured: measured, intensity: intensity)

        let correction = intensity.correctionFactor * (alreadyMastered ? 0.5 : 1.0)
        var desired = [Double](repeating: 0, count: target.count)
        for i in desired.indices {
            desired[i] = ((target[i] - measured[i]) * correction)
                .clamped(to: -bandLimitsDB[i]...bandLimitsDB[i])
        }

        let toneBands = solveToneBands(desired: desired, sampleRate: analysis.sampleRate)
        let resonanceCuts = analysis.resonances.map { resonance in
            MasterSettings.EQBand(kind: .peak, frequency: resonance.frequency, q: 4.0,
                                  gainDB: -min(resonance.excessDB * 0.7, 3.0) * (alreadyMastered ? 0.5 : 1.0))
        }

        return MasterSettings(
            intensity: intensity,
            highpassHz: highpassFrequency(for: analysis),
            toneBands: toneBands,
            resonanceCuts: resonanceCuts,
            crossovers: [120, 800, 5000],
            compressorBands: compressorBands(for: analysis, alreadyMastered: alreadyMastered),
            width: width(for: analysis, alreadyMastered: alreadyMastered),
            monoBelowHz: analysis.lowCorrelation < 0.9 && analysis.channelCount > 1 ? 110 : 0,
            targetLUFS: intensity.targetLUFS,
            ceilingDBTP: intensity.ceilingDBTP,
            alreadyMastered: alreadyMastered)
    }

    // MARK: - Tone

    /// Chooses EQ gains so the *combined* response hits the desired per-band curve.
    ///
    /// Octave-spaced bells overlap heavily, so setting each band's gain to its desired value
    /// overshoots badly once they sum. A few rounds of measure-and-correct fixes that, and costs
    /// nothing because the response is evaluated analytically rather than by filtering audio.
    static func solveToneBands(desired: [Double], sampleRate: Double) -> [MasterSettings.EQBand] {
        let centers = Analysis.bandEdges.map { sqrt($0.low * $0.high) }
        let nyquist = sampleRate / 2

        func makeBands(_ gains: [Double]) -> [MasterSettings.EQBand] {
            gains.indices.compactMap { i in
                guard abs(gains[i]) > 0.05 else { return nil }
                if i == 0 {
                    return .init(kind: .lowShelf, frequency: 70, q: 0.7, gainDB: gains[i])
                } else if i == gains.count - 1 {
                    return .init(kind: .highShelf, frequency: min(13000, nyquist * 0.6), q: 0.7, gainDB: gains[i])
                }
                return .init(kind: .peak, frequency: centers[i], q: 1.4, gainDB: gains[i])
            }
        }

        var gains = desired
        for _ in 0..<8 {
            let bands = makeBands(gains)
            let cascade = BiquadCascade(bands.map { $0.coefficients(sampleRate: sampleRate) })
            var maxError = 0.0
            for i in gains.indices {
                let probe = min(centers[i], nyquist * 0.95)
                let achieved = cascade.magnitudeDB(at: probe, sampleRate: sampleRate)
                let error = desired[i] - achieved
                maxError = max(maxError, abs(error))
                gains[i] = (gains[i] + error * 0.7).clamped(to: -(bandLimitsDB[i] + 3)...(bandLimitsDB[i] + 3))
            }
            if maxError < 0.05 { break }
        }
        return makeBands(gains)
    }

    static func highpassFrequency(for analysis: Analysis) -> Double {
        // A track with real sub content keeps more of it; one with only rumble down there loses it.
        let bands = analysis.normalizedBands
        let subRelativeToBass = bands[0] - bands[1]
        return subRelativeToBass > -6 ? 25 : 34
    }

    // MARK: - Dynamics

    static func compressorBands(for analysis: Analysis, alreadyMastered: Bool) -> [MasterSettings.CompressorBand] {
        // Crest factor says how much dynamic range is actually left to work with. Squashing an
        // already-squashed track only makes it smaller, so the ratio backs off as crest falls.
        let crest = analysis.crestFactorDB
        let (ratio, threshold): (Double, Double)
        switch crest {
        case ..<8: (ratio, threshold) = (1.25, -14)
        case 8..<16: (ratio, threshold) = (2.0, -20)
        default: (ratio, threshold) = (2.4, -22)
        }
        let effectiveRatio = alreadyMastered ? min(ratio, 1.3) : ratio

        // Low bands need slow ballistics or the bass modulates; high bands need fast ones or
        // transients slip through.
        let timings: [(attack: Double, release: Double, thresholdOffset: Double)] = [
            (0.030, 0.250, 1.0),
            (0.020, 0.180, 0.0),
            (0.010, 0.120, 0.0),
            (0.005, 0.080, 2.0),
        ]
        return timings.map { timing in
            .init(thresholdDB: threshold + timing.thresholdOffset,
                  ratio: effectiveRatio,
                  attackSeconds: timing.attack,
                  releaseSeconds: timing.release)
        }
    }

    // MARK: - Stereo

    static func width(for analysis: Analysis, alreadyMastered: Bool) -> Double {
        guard analysis.channelCount > 1 else { return 1.0 }
        let raw: Double
        switch analysis.correlation {
        case ..<0.0: raw = 0.70    // out of phase; pulling in is damage control, not taste
        case 0.0..<0.2: raw = 0.85
        case 0.2..<0.7: raw = 1.0
        case 0.7..<0.95: raw = 1.08
        default: raw = 1.15        // very nearly mono, so a little space is safe
        }
        return alreadyMastered ? 1 + (raw - 1) * 0.5 : raw
    }

    // MARK: - Idempotence

    /// A file that already measures like a finished master should come out sounding like itself.
    static func isAlreadyMastered(analysis: Analysis, target: [Double], measured: [Double],
                                  intensity: Intensity) -> Bool {
        guard analysis.integratedLUFS.isFinite else { return false }
        let loudnessClose = abs(analysis.integratedLUFS - intensity.targetLUFS) < 1.5
        let worstDeviation = (1...7).map { abs(target[$0] - measured[$0]) }.max() ?? 0
        return loudnessClose && worstDeviation < 2.0
    }

    static func normalize(_ curve: [Double]) -> [Double] {
        let referenceRange = 1...7
        let reference = referenceRange.map { curve[$0] }.reduce(0, +) / Double(referenceRange.count)
        return curve.map { $0 - reference }
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
