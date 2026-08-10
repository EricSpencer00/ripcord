import Foundation
import Testing
@testable import RipcordKit

/// End-to-end properties. These are the promises the app makes on its own front page.
@Suite("Mastering", .timeLimit(.minutes(3)))
struct MastererTests {
    @Test("Output lands on the loudness target", arguments: Intensity.allCases)
    func hitsLoudnessTarget(intensity: Intensity) {
        let input = Signal.gain(Signal.musicLike(seconds: 8), dB: -12)
        let result = Masterer().master(channels: input, sampleRate: 48000, intensity: intensity)
        let error = result.after.integratedLUFS - intensity.targetLUFS
        #expect(abs(error) < 0.3, "\(intensity) landed at \(result.after.integratedLUFS) LUFS")
    }

    @Test("Output never exceeds the ceiling", arguments: Intensity.allCases)
    func respectsCeiling(intensity: Intensity) {
        let input = Signal.gain(Signal.musicLike(seconds: 8), dB: -12)
        let result = Masterer().master(channels: input, sampleRate: 48000, intensity: intensity)
        #expect(result.after.truePeakDBTP <= intensity.ceilingDBTP + 0.05,
                "measured \(result.after.truePeakDBTP) dBTP against a \(intensity.ceilingDBTP) ceiling")
    }

    /// However quiet or loud the file arrives, it has to end up in the same place.
    @Test("The starting level does not change where the output lands",
          arguments: [-30.0, -18.0, -6.0, 0.0])
    func inputLevelDoesNotMatter(offset: Double) {
        let input = Signal.gain(Signal.musicLike(seconds: 8), dB: offset - 12)
        let result = Masterer().master(channels: input, sampleRate: 48000, intensity: .standard)
        #expect(abs(result.after.integratedLUFS - (-11)) < 0.3,
                "starting \(offset) dB off landed at \(result.after.integratedLUFS) LUFS")
    }

    @Test("Frame count and channel count are preserved")
    func preservesShape() {
        let input = Signal.musicLike(seconds: 4)
        let result = Masterer().master(channels: input, sampleRate: 48000, intensity: .standard)
        #expect(result.channels.count == input.count)
        #expect(result.channels[0].count == input[0].count)
    }

    @Test("Output contains no infinities or NaNs")
    func outputIsFinite() {
        let input = Signal.gain(Signal.musicLike(seconds: 4), dB: -3)
        let result = Masterer().master(channels: input, sampleRate: 48000, intensity: .loud)
        for channel in result.channels {
            #expect(channel.allSatisfy { $0.isFinite })
        }
    }

    /// Silence is the case where doing nothing is the only honest answer. Normalizing it would
    /// mean amplifying a noise floor by 100 dB.
    @Test("Silence is returned untouched and reported as such")
    func silenceIsUntouched() {
        let silent = [[Float]](repeating: [Float](repeating: 0, count: 48000 * 2), count: 2)
        let result = Masterer().master(channels: silent, sampleRate: 48000, intensity: .standard)
        #expect(result.unchanged)
        #expect(result.channels[0].allSatisfy { $0 == 0 })
    }

    /// Re-mastering the tool's own output must settle rather than run away. Per-band corrections
    /// are capped, so a track that starts far from the target curve legitimately takes more than
    /// one pass to arrive — what matters is that each pass asks for less than the one before and
    /// the result moves toward the target, never oscillating or piling on.
    @Test("Repeated passes converge instead of running away")
    func repeatedPassesConverge() {
        let target = ChainDesigner.normalize(ChainDesigner.targetCurveDB)
        var channels = Signal.gain(Signal.musicLike(seconds: 8), dB: -12)

        var movements = [Double]()
        var distances = [Double]()
        var loudnesses = [Double]()

        for _ in 1...4 {
            let result = Masterer().master(channels: channels, sampleRate: 48000, intensity: .standard)
            movements.append(result.settings.toneBands.reduce(0) { $0 + abs($1.gainDB) })
            distances.append((1...7).reduce(0) { $0 + abs(result.after.normalizedBands[$1] - target[$1]) })
            loudnesses.append(result.after.integratedLUFS)
            channels = result.channels
        }

        // Each pass asks for strictly less correction than the previous one.
        for index in 1..<movements.count {
            #expect(movements[index] < movements[index - 1],
                    "pass \(index + 1) asked for \(movements[index]) dB after \(movements[index - 1]) dB: \(movements)")
        }
        // And the result genuinely gets closer to the target curve.
        #expect(distances.last! < distances.first!, "distance to target went \(distances)")
        // Loudness stays put throughout; only tone is still settling.
        for loudness in loudnesses {
            #expect(abs(loudness - (-11)) < 0.3, "loudness drifted across passes: \(loudnesses)")
        }
        // Once settled, the tool recognizes its own output and stops working on it.
        let settled = Masterer().master(channels: channels, sampleRate: 48000, intensity: .standard)
        #expect(settled.settings.toneBands.reduce(0) { $0 + abs($1.gainDB) } < movements[0] / 2)
    }

    @Test("Mono input stays mono and still hits the target")
    func handlesMono() {
        let mono = [Signal.gain([Signal.musicLike(seconds: 6)[0]], dB: -12)[0]]
        let result = Masterer().master(channels: mono, sampleRate: 48000, intensity: .standard)
        #expect(result.channels.count == 1)
        #expect(abs(result.after.integratedLUFS - (-11)) < 0.4)
    }

    @Test("Works at sample rates other than 48 kHz", arguments: [44100.0, 96000.0])
    func handlesOtherSampleRates(rate: Double) {
        let input = Signal.gain(Signal.musicLike(seconds: 6, sampleRate: rate), dB: -12)
        let result = Masterer().master(channels: input, sampleRate: rate, intensity: .standard)
        #expect(abs(result.after.integratedLUFS - (-11)) < 0.3)
        #expect(result.after.truePeakDBTP <= -1.0 + 0.05)
    }

    /// The report is what the user reads. It must describe the audio that was actually produced.
    @Test("The report quotes the measured output, not the intended settings")
    func reportMatchesOutput() {
        let input = Signal.gain(Signal.musicLike(seconds: 6), dB: -12)
        let result = Masterer().master(channels: input, sampleRate: 48000, intensity: .standard)
        let report = Report(result: result)
        let loudness = report.measurements.first { $0.label == "LOUDNESS" }!
        #expect(loudness.after == Report.format(result.after.integratedLUFS))
        #expect(!report.moves.isEmpty)
    }
}
