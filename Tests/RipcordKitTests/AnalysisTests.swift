import Foundation
import Testing
@testable import RipcordKit

@Suite("Loudness measurement")
struct LoudnessMeterTests {
    /// ITU-R BS.1770-4 Table 1 states the K-weighting coefficients at 48 kHz outright. Deriving
    /// them from the analogue prototype has to land on the same numbers, or every other loudness
    /// figure in the app is quietly wrong.
    @Test("K-weighting reproduces the coefficients published in the standard")
    func referenceCoefficients() {
        let shelf = LoudnessMeter.shelfCoefficients(sampleRate: 48000)
        #expect(abs(shelf.b0 - 1.53512485958697) < 1e-12)
        #expect(abs(shelf.b1 - -2.69169618940638) < 1e-12)
        #expect(abs(shelf.b2 - 1.19839281085285) < 1e-12)
        #expect(abs(shelf.a1 - -1.69065929318241) < 1e-12)
        #expect(abs(shelf.a2 - 0.73248077421585) < 1e-12)

        let rlb = LoudnessMeter.rlbCoefficients(sampleRate: 48000)
        #expect(rlb.b0 == 1.0 && rlb.b1 == -2.0 && rlb.b2 == 1.0)
        #expect(abs(rlb.a1 - -1.99004745483398) < 1e-11)
        #expect(abs(rlb.a2 - 0.99007225036621) < 1e-11)
    }

    /// Cross-checked against ffmpeg's ebur128, an independent implementation: a 1 kHz stereo sine
    /// at amplitude 0.5 measures -6.0 LUFS there.
    @Test("A reference sine measures the same as an independent implementation")
    func absoluteCalibration() {
        let tone = Signal.sine(frequency: 1000, amplitude: 0.5, seconds: 5)
        let measurement = LoudnessMeter(sampleRate: 48000).measure(channels: Signal.stereo(tone))
        #expect(abs(measurement.integratedLUFS - (-6.0)) < 0.1)
    }

    @Test("Doubling amplitude raises loudness by 6.02 LU")
    func scalesWithAmplitude() {
        let quiet = Signal.stereo(Signal.sine(frequency: 1000, amplitude: 0.1, seconds: 4))
        let loud = Signal.stereo(Signal.sine(frequency: 1000, amplitude: 0.2, seconds: 4))
        let meter = LoudnessMeter(sampleRate: 48000)
        let delta = meter.measure(channels: loud).integratedLUFS
            - meter.measure(channels: quiet).integratedLUFS
        #expect(abs(delta - 6.0206) < 0.01)
    }

    /// The same signal has to measure the same regardless of sample rate, which is the whole
    /// reason the coefficients are derived rather than hard-coded at 48 kHz.
    @Test("Measurement is independent of sample rate", arguments: [44100.0, 48000.0, 96000.0])
    func sampleRateIndependence(rate: Double) {
        let tone = Signal.sine(frequency: 1000, amplitude: 0.5, seconds: 4, sampleRate: rate)
        let measurement = LoudnessMeter(sampleRate: rate).measure(channels: Signal.stereo(tone))
        #expect(abs(measurement.integratedLUFS - (-6.0)) < 0.15)
    }

    @Test("Digital silence reports as silent rather than as a number")
    func silence() {
        let silent = [[Float]](repeating: [Float](repeating: 0, count: 48000), count: 2)
        let measurement = LoudnessMeter(sampleRate: 48000).measure(channels: silent)
        #expect(measurement.isSilent)
    }

    /// A quiet passage should not drag the integrated figure down; that is what the -10 LU
    /// relative gate exists to prevent.
    @Test("The relative gate discounts a quiet passage")
    func relativeGating() {
        let loud = Signal.sine(frequency: 1000, amplitude: 0.5, seconds: 6)
        let quiet = Signal.sine(frequency: 1000, amplitude: 0.005, seconds: 6)
        let meter = LoudnessMeter(sampleRate: 48000)
        let loudOnly = meter.measure(channels: Signal.stereo(loud)).integratedLUFS
        let mixed = meter.measure(channels: Signal.stereo(loud + quiet)).integratedLUFS
        #expect(abs(mixed - loudOnly) < 0.5)
    }
}

@Suite("True peak measurement")
struct TruePeakMeterTests {
    /// The textbook inter-sample peak: a sine at a quarter of the sample rate, offset by 45
    /// degrees, lands every sample on ±0.7071 while the reconstructed waveform still reaches 1.0.
    /// A meter that only looks at samples reads this 3 dB too low and lets it clip a converter.
    @Test("Inter-sample peaks are caught where sample peaks miss them")
    func intersamplePeak() {
        let tone = Signal.sine(frequency: 12000, amplitude: 1.0, seconds: 1, phase: .pi / 4)
        let samplePeak = Signal.peakDBFS([tone])
        let truePeak = TruePeakMeter().truePeakDBTP([tone])
        #expect(abs(samplePeak - (-3.01)) < 0.1)
        #expect(abs(truePeak - 0.0) < 0.1)
    }

    @Test("A slow sine reads the same as its sample peak")
    func slowSineMatchesSamplePeak() {
        let tone = Signal.sine(frequency: 100, amplitude: 0.5, seconds: 1)
        #expect(abs(TruePeakMeter().truePeakDBTP([tone]) - (-6.02)) < 0.05)
    }

    @Test("The envelope is aligned to the sample it describes")
    func envelopeAlignment() {
        var impulse = [Float](repeating: 0, count: 4096)
        impulse[2000] = 1.0
        let envelope = TruePeakMeter().peakEnvelope(impulse)
        let loudest = envelope.indices.max { envelope[$0] < envelope[$1] }!
        #expect(abs(loudest - 2000) <= 1)
    }
}

@Suite("Spectral analysis")
struct SpectrumTests {
    /// Octave-band energy is the convention the target curve is stated in, and pink noise is
    /// flat in those terms by definition. If this drifts, every tone decision drifts with it.
    @Test("Pink noise reads flat in octave-band energy")
    func pinkNoiseIsFlat() {
        let pink = Signal.pinkNoise(amplitude: 0.5, seconds: 10)
        let analysis = Analyzer.analyze(channels: Signal.stereo(pink), sampleRate: 48000)
        let bands = analysis.normalizedBands
        // Bands 1 through 7 span 60 Hz to 3.8 kHz, where the pink approximation is accurate.
        for index in 1...7 {
            #expect(abs(bands[index]) < 2.0, "band \(Analysis.bandLabels[index]) reads \(bands[index]) dB")
        }
    }

    @Test("A narrow boost is found at the frequency it was applied to")
    func findsResonance() {
        var noise = Signal.pinkNoise(amplitude: 0.3, seconds: 8)
        var boost = Biquad(.peaking(freq: 1000, q: 6, gainDB: 12, sampleRate: 48000))
        boost.process(&noise)
        let analysis = Analyzer.analyze(channels: Signal.stereo(noise), sampleRate: 48000)
        let found = analysis.resonances.contains { abs(log2($0.frequency / 1000)) < 0.2 }
        #expect(found, "resonances found: \(analysis.resonances)")
    }

    @Test("Flat material reports no resonances")
    func noFalseResonances() {
        let pink = Signal.pinkNoise(amplitude: 0.3, seconds: 8)
        let analysis = Analyzer.analyze(channels: Signal.stereo(pink), sampleRate: 48000)
        #expect(analysis.resonances.isEmpty, "found \(analysis.resonances)")
    }
}

@Suite("Stereo analysis")
struct StereoTests {
    @Test("Identical channels correlate at 1")
    func monoCorrelation() {
        let tone = Signal.sine(frequency: 440, amplitude: 0.5, seconds: 1)
        #expect(abs(StereoImage.correlation(left: tone, right: tone) - 1.0) < 1e-6)
    }

    @Test("Inverted channels correlate at -1")
    func inverted() {
        let tone = Signal.sine(frequency: 440, amplitude: 0.5, seconds: 1)
        let flipped = tone.map { -$0 }
        #expect(abs(StereoImage.correlation(left: tone, right: flipped) - -1.0) < 1e-6)
    }

    /// Measured an octave below the cutoff rather than at it: the side channel is removed with a
    /// 24 dB/oct slope, so content just under the corner is attenuated but not gone. What the
    /// setting promises is that the deep bass — where mono compatibility actually matters — is mono.
    @Test("Collapsing the low end leaves the deep bass mono")
    func monoMaker() {
        var left = Signal.whiteNoise(amplitude: 0.3, seconds: 4, seed: 1)
        var right = Signal.whiteNoise(amplitude: 0.3, seconds: 4, seed: 2)
        let before = correlationBelow(55, left: left, right: right)
        StereoImage.apply(left: &left, right: &right, width: 1.0, monoBelowHz: 110, sampleRate: 48000)
        let after = correlationBelow(55, left: left, right: right)

        #expect(before < 0.2, "uncorrelated noise should start uncorrelated, was \(before)")
        #expect(after > 0.98, "deep bass correlation after collapsing is \(after)")
    }

    @Test("Leaving the low end alone does not silently collapse it")
    func monoMakerOff() {
        var left = Signal.whiteNoise(amplitude: 0.3, seconds: 4, seed: 1)
        var right = Signal.whiteNoise(amplitude: 0.3, seconds: 4, seed: 2)
        StereoImage.apply(left: &left, right: &right, width: 1.0, monoBelowHz: 0, sampleRate: 48000)
        #expect(correlationBelow(55, left: left, right: right) < 0.2)
    }

    private func correlationBelow(_ frequency: Double, left: [Float], right: [Float]) -> Double {
        let q = 0.7071067811865476
        var lowLeft = left, lowRight = right
        var filter = BiquadCascade([
            .lowpass(freq: frequency, q: q, sampleRate: 48000),
            .lowpass(freq: frequency, q: q, sampleRate: 48000),
        ])
        var other = filter
        filter.process(&lowLeft)
        other.process(&lowRight)
        return StereoImage.correlation(left: lowLeft, right: lowRight)
    }
}
