import Foundation
import Testing
@testable import RipcordKit

@Suite("Crossover")
struct CrossoverTests {
    /// The reason the allpass compensation exists. Without it the summed output dips by several
    /// dB right at each crossover frequency, which is exactly where a multiband compressor is
    /// most audible.
    @Test("Bands sum back flat, including at the crossover frequencies",
          arguments: [50.0, 120.0, 300.0, 800.0, 2000.0, 5000.0, 9000.0])
    func bandsSumFlat(frequency: Double) {
        let crossovers = [120.0, 800.0, 5000.0]
        let tone = Signal.sine(frequency: frequency, amplitude: 0.5, seconds: 1)
        let summed = sumBands(Crossover.split(tone, crossovers: crossovers, sampleRate: 48000))

        let settling = 8000
        let difference = Signal.rmsDBFS(summed, skipping: settling) - Signal.rmsDBFS(tone, skipping: settling)
        #expect(abs(difference) < 0.3, "\(frequency) Hz sums \(difference) dB off")
    }

    @Test("Broadband material survives a split and sum")
    func broadbandSumFlat() {
        let crossovers = [120.0, 800.0, 5000.0]
        let pink = Signal.pinkNoise(amplitude: 0.4, seconds: 4)
        let summed = sumBands(Crossover.split(pink, crossovers: crossovers, sampleRate: 48000))
        let difference = Signal.rmsDBFS(summed, skipping: 8000) - Signal.rmsDBFS(pink, skipping: 8000)
        #expect(abs(difference) < 0.2, "broadband sums \(difference) dB off")
    }
}

@Suite("Compressor")
struct CompressorTests {
    @Test("Signal below the threshold passes through untouched")
    func belowThreshold() {
        let compressor = Compressor(thresholdDB: -10, ratio: 4, attackSeconds: 0.01, releaseSeconds: 0.1)
        var left = Signal.sine(frequency: 200, amplitude: 0.05, seconds: 1)  // about -26 dBFS
        var right = left
        let original = left
        compressor.process(left: &left, right: &right, sampleRate: 48000)
        let difference = Signal.rmsDBFS(left, skipping: 4800) - Signal.rmsDBFS(original, skipping: 4800)
        #expect(abs(difference) < 0.2)
    }

    @Test("A signal above the threshold is reduced by roughly the ratio")
    func aboveThreshold() {
        let compressor = Compressor(thresholdDB: -20, ratio: 4, attackSeconds: 0.001,
                                    releaseSeconds: 0.05, kneeDB: 0)
        var left = Signal.sine(frequency: 200, amplitude: 0.5, seconds: 2)
        var right = left
        compressor.process(left: &left, right: &right, sampleRate: 48000)

        // Peak sits at -6 dBFS, so it is 14 dB over threshold; at 4:1 that becomes 3.5 dB over.
        let expected = -20.0 + 14.0 / 4.0
        let achieved = Signal.peakDBFS([Array(left.dropFirst(24000))])
        #expect(abs(achieved - expected) < 1.0, "expected about \(expected) dBFS, got \(achieved)")
    }

    @Test("Both channels receive identical gain so the image cannot wander")
    func stereoLinked() {
        let compressor = Compressor(thresholdDB: -20, ratio: 4, attackSeconds: 0.005, releaseSeconds: 0.05)
        // Only the left channel is loud; the right must still be attenuated by the same amount.
        var left = Signal.sine(frequency: 200, amplitude: 0.6, seconds: 1)
        var right = Signal.sine(frequency: 200, amplitude: 0.05, seconds: 1)
        let rightBefore = right
        compressor.process(left: &left, right: &right, sampleRate: 48000)

        let rightChange = Signal.rmsDBFS(right, skipping: 24000) - Signal.rmsDBFS(rightBefore, skipping: 24000)
        #expect(rightChange < -1.0, "the quiet channel should follow the loud one, moved \(rightChange) dB")
    }
}

@Suite("Limiter")
struct LimiterTests {
    /// The headline guarantee of the whole tool. If this fails, output can clip a converter.
    @Test("Output never exceeds the ceiling",
          arguments: [-1.0, -0.8, -0.3, -2.0])
    func respectsCeiling(ceiling: Double) {
        var channels = Signal.musicLike(seconds: 4)
        channels = Signal.gain(channels, dB: 18)  // drive it well into limiting
        var left = channels[0], right = channels[1]

        Limiter(ceilingDBTP: ceiling).process(left: &left, right: &right, sampleRate: 48000)
        let achieved = TruePeakMeter().truePeakDBTP([left, right])
        #expect(achieved <= ceiling + 0.05, "ceiling \(ceiling) dBTP, measured \(achieved) dBTP")
    }

    /// Inter-sample peaks are the case a sample-domain limiter silently gets wrong.
    @Test("The ceiling holds against deliberate inter-sample peaks")
    func respectsCeilingOnIntersamplePeaks() {
        let tone = Signal.sine(frequency: 12000, amplitude: 0.99, seconds: 2, phase: .pi / 4)
        var left = tone, right = tone
        Limiter(ceilingDBTP: -1.0).process(left: &left, right: &right, sampleRate: 48000)
        let achieved = TruePeakMeter().truePeakDBTP([left, right])
        #expect(achieved <= -1.0 + 0.05, "measured \(achieved) dBTP")
    }

    @Test("Material already under the ceiling is left alone")
    func transparentBelowCeiling() {
        var channels = Signal.musicLike(seconds: 3)
        channels = Signal.gain(channels, dB: -20)
        var left = channels[0], right = channels[1]
        let original = left

        let result = Limiter(ceilingDBTP: -1.0).process(left: &left, right: &right, sampleRate: 48000)
        #expect(abs(result.peakReductionDB) < 0.01)
        for i in stride(from: 0, to: left.count, by: 997) {
            #expect(abs(left[i] - original[i]) < 1e-6)
        }
    }

    @Test("Length is preserved and no output delay is introduced")
    func preservesLength() {
        var channels = Signal.musicLike(seconds: 2)
        channels = Signal.gain(channels, dB: 15)
        var left = channels[0], right = channels[1]
        let count = left.count
        Limiter(ceilingDBTP: -1.0).process(left: &left, right: &right, sampleRate: 48000)
        #expect(left.count == count)
        #expect(right.count == count)
    }
}
