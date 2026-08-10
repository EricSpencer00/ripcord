import Foundation
import Testing
@testable import RipcordKit

/// The designer is a pure function, so these tests state what it is allowed to decide without
/// ever rendering audio.
@Suite("Chain design")
struct ChainDesignerTests {
    /// Builds an analysis with the given octave-band shape, leaving everything else benign.
    static func analysis(bands: [Double], lufs: Double = -18, crest: Double = 12,
                         correlation: Double = 0.5, lowCorrelation: Double = 0.95,
                         channels: Int = 2, resonances: [Analysis.Resonance] = []) -> Analysis {
        Analysis(sampleRate: 48000, frameCount: 48000 * 60, channelCount: channels,
                 integratedLUFS: lufs, loudnessRangeLU: 6, truePeakDBTP: -1.5,
                 samplePeakDBFS: -2, rmsDBFS: -2 - crest,
                 bandsDB: bands, resonances: resonances, correlation: correlation,
                 lowCorrelation: lowCorrelation, dcOffset: 0, isSilent: false)
    }

    static let flatBands = [Double](repeating: 0, count: 10)

    @Test("No band is ever moved further than its own limit", arguments: Intensity.allCases)
    func respectsBandLimits(intensity: Intensity) {
        // A deliberately awful input: heavily scooped and rolled off.
        let awful: [Double] = [20, 18, 12, -8, -14, -10, -6, -2, 6, 14]
        let settings = ChainDesigner.design(for: Self.analysis(bands: awful), intensity: intensity)
        for band in settings.toneBands {
            #expect(abs(band.gainDB) <= 8.0, "\(band.frequency) Hz moved \(band.gainDB) dB")
        }
    }

    /// A track already sitting on the target curve should be left alone tonally. This is the
    /// property that keeps the tool from imposing a sound on material that does not need it.
    @Test("Material already on the target curve is barely touched")
    func matchedInputIsLeftAlone() {
        let onTarget = ChainDesigner.normalize(ChainDesigner.targetCurveDB)
        let settings = ChainDesigner.design(for: Self.analysis(bands: onTarget), intensity: .standard)
        for band in settings.toneBands {
            #expect(abs(band.gainDB) < 0.75, "\(band.frequency) Hz moved \(band.gainDB) dB")
        }
    }

    /// The solver has to account for neighbouring bells overlapping, or the combined curve
    /// overshoots what any single band asked for.
    @Test("The solved EQ curve actually delivers the requested per-band gains")
    func solverConverges() {
        let desired: [Double] = [-2, -3, -1, 0, 1, 2, 2, 1, -1, 2]
        let bands = ChainDesigner.solveToneBands(desired: desired, sampleRate: 48000)
        let cascade = BiquadCascade(bands.map { $0.coefficients(sampleRate: 48000) })
        let centers = Analysis.bandEdges.map { sqrt($0.low * $0.high) }
        for index in desired.indices {
            let achieved = cascade.magnitudeDB(at: centers[index], sampleRate: 48000)
            #expect(abs(achieved - desired[index]) < 0.3,
                    "band \(Analysis.bandLabels[index]) wanted \(desired[index]), got \(achieved)")
        }
    }

    @Test("A mono file is never widened")
    func monoIsNotWidened() {
        let settings = ChainDesigner.design(
            for: Self.analysis(bands: Self.flatBands, correlation: 1.0, channels: 1),
            intensity: .standard)
        #expect(settings.width == 1.0)
        #expect(settings.monoBelowHz == 0)
    }

    @Test("Out-of-phase material is pulled in rather than widened")
    func outOfPhaseIsNarrowed() {
        let settings = ChainDesigner.design(
            for: Self.analysis(bands: Self.flatBands, correlation: -0.3), intensity: .standard)
        #expect(settings.width < 1.0)
    }

    /// Compressing an already-crushed track only makes it smaller, so the ratio has to back off
    /// on its own rather than relying on the user to notice.
    @Test("An already-crushed track gets a gentler ratio than a dynamic one")
    func ratioFollowsCrestFactor() {
        let crushed = ChainDesigner.design(
            for: Self.analysis(bands: Self.flatBands, crest: 5), intensity: .standard)
        let dynamic = ChainDesigner.design(
            for: Self.analysis(bands: Self.flatBands, crest: 20), intensity: .standard)
        let crushedRatio = crushed.compressorBands[0].ratio
        let dynamicRatio = dynamic.compressorBands[0].ratio
        #expect(crushedRatio <= 1.3, "crushed material got \(crushedRatio):1")
        #expect(dynamicRatio > crushedRatio)
    }

    @Test("A finished master is recognized and handled gently")
    func recognizesFinishedMaster() {
        let onTarget = ChainDesigner.normalize(ChainDesigner.targetCurveDB)
        let settings = ChainDesigner.design(
            for: Self.analysis(bands: onTarget, lufs: -11.2, crest: 9), intensity: .standard)
        #expect(settings.alreadyMastered)
        #expect(settings.compressorBands[0].ratio <= 1.3)
    }

    @Test("An unfinished mix is not mistaken for a master")
    func recognizesUnfinishedMix() {
        let settings = ChainDesigner.design(
            for: Self.analysis(bands: [8, 10, 6, 2, 0, -4, -7, -9, -12, -20], lufs: -20),
            intensity: .standard)
        #expect(!settings.alreadyMastered)
    }

    @Test("Resonance cuts only ever cut, and never by more than 3 dB")
    func resonanceCutsAreBounded() {
        let resonances = [Analysis.Resonance(frequency: 400, excessDB: 12),
                          Analysis.Resonance(frequency: 2500, excessDB: 4)]
        let settings = ChainDesigner.design(
            for: Self.analysis(bands: Self.flatBands, resonances: resonances), intensity: .loud)
        #expect(settings.resonanceCuts.count == 2)
        for cut in settings.resonanceCuts {
            #expect(cut.gainDB < 0)
            #expect(cut.gainDB >= -3.0)
        }
    }

    @Test("Louder intensities target higher loudness and never a ceiling above -0.5 dBTP",
          arguments: Intensity.allCases)
    func targetsAreSane(intensity: Intensity) {
        let settings = ChainDesigner.design(for: Self.analysis(bands: Self.flatBands), intensity: intensity)
        #expect(settings.targetLUFS == intensity.targetLUFS)
        #expect(settings.ceilingDBTP <= -0.5)
        #expect(settings.targetLUFS <= -9)
    }
}
