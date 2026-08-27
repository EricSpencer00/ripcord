import Foundation
import Testing
@testable import RipcordKit

/// The delivery path makes claims in writing, so every claim gets a test that could falsify it.
///
/// Two of these exist because the premises they check turned out to be wrong when measured. The
/// true-peak meter's error is a reconstruction-grid limit and not the filter droop it was assumed
/// to be, and the working meter's under-read is large enough that a master aimed at exactly -1.0
/// dBTP measured -0.99 on the certification meter and failed its own check. Both are pinned here as
/// numbers rather than as "close enough".
@Suite("Delivery", .timeLimit(.minutes(10)))
struct DeliveryTests {
    static let sampleRate = 48000.0

    // MARK: - True-peak meter

    /// The grid bound is exact: a meter oversampling by `factor` can miss a peak lying between two
    /// reconstruction points by `20 log10(cos(pi f / (factor fs)))`, and no more.
    @Test("Each meter reads inside the uncertainty it states",
          arguments: [(8, 16, 0.13), (16, 16, 0.13), (16, 32, 0.02), (32, 32, 0.006)])
    func gridBound(factor: Int, taps: Int, tolerance: Double) {
        let meter = TruePeakMeter(factor: factor, tapsPerPhase: taps)
        var worst = 0.0
        // A fade removes the artificial onset discontinuity, which is a separate effect with its
        // own test below. What is being measured here is the steady-state accuracy.
        for frequency in stride(from: 1000.0, through: 20000.0, by: 500.0) {
            for phase in stride(from: 0.0, to: Double.pi, by: .pi / 8) {
                let tone = Self.fadedSine(frequency: frequency, amplitude: 1.0, phase: phase)
                let measured = meter.truePeakDBTP([tone])
                if abs(measured) > abs(worst) { worst = measured }
            }
        }
        // The true peak of a band-limited sine of amplitude 1.0 is exactly 0 dBTP at any frequency
        // and any sampling phase, so the reading is the error.
        #expect(worst < 0, "the meter over-read, which the grid bound cannot explain: \(worst)")
        #expect(abs(worst) < tolerance,
                "\(factor)x/\(taps) read \(worst) dB, outside the \(tolerance) dB it is meant to hold")
        // The stated uncertainty has to be a real bound, not a formula that flatters the meter.
        #expect(abs(worst) <= abs(meter.uncertaintyDB) + 1e-9,
                "\(factor)x/\(taps) exceeded its own stated uncertainty of \(meter.uncertaintyDB) dB")
    }

    /// Raising the factor without raising the taps is the trap this pins: it improves the stated
    /// grid bound while the meter reads no better at all.
    @Test("Oversampling alone does not make the meter more accurate")
    func factorAloneDoesNotHelp() {
        func worstError(_ meter: TruePeakMeter) -> Double {
            var worst = 0.0
            for frequency in stride(from: 15000.0, through: 20000.0, by: 500.0) {
                for phase in stride(from: 0.0, to: Double.pi, by: .pi / 8) {
                    let measured = meter.truePeakDBTP(
                        [Self.fadedSine(frequency: frequency, amplitude: 1.0, phase: phase)])
                    if abs(measured) > abs(worst) { worst = measured }
                }
            }
            return worst
        }

        let coarseKernel = worstError(TruePeakMeter(factor: 32, tapsPerPhase: 16))
        let fineKernel = worstError(TruePeakMeter(factor: 32, tapsPerPhase: 32))
        #expect(abs(coarseKernel) > 0.05,
                "32x on a 16-tap kernel should still droop; it read \(coarseKernel)")
        #expect(abs(fineKernel) < 0.01)
        // And the stated uncertainty must own up to it rather than quoting the grid alone.
        #expect(abs(TruePeakMeter(factor: 32, tapsPerPhase: 16).uncertaintyDB) > 0.1)
    }

    @Test("The certification meter is the one that is actually accurate")
    func certificationMeter() {
        #expect(TruePeakMeter.certification.factor == 32)
        #expect(abs(TruePeakMeter.certification.uncertaintyDB) < 0.012)
        #expect(abs(TruePeakMeter.working.uncertaintyDB) > 0.1,
                "the working meter must not claim precision it does not have")
    }

    /// The zero-padding artifact, pinned so a future change to the padding cannot move it silently.
    /// A buffer that starts on a non-zero sample presents a step to the reconstruction filter and
    /// rings; that is left in place deliberately, because playing such a file really does overshoot.
    @Test("The zero-padded edges over-read, and only the edges")
    func edgeArtifact() {
        let meter = TruePeakMeter.working
        let dc = [Float](repeating: 1.0, count: 4800)
        let whole = meter.truePeakDBTP([dc])
        let envelope = meter.peakEnvelope(dc)
        let interior = 20 * log10(Double(envelope[64..<(envelope.count - 64)].max()!))

        #expect(whole > 0.9 && whole < 1.2, "edge overshoot moved: \(whole) dB")
        #expect(abs(interior) < 0.001, "the interior should be exact, read \(interior) dB")
    }

    static func fadedSine(frequency: Double, amplitude: Double, phase: Double,
                          seconds: Double = 0.4) -> [Float] {
        let count = Int(seconds * sampleRate)
        let fade = Int(0.05 * sampleRate)
        return (0..<count).map { i in
            var window = 1.0
            if i < fade { window = Double(i) / Double(fade) }
            if i > count - fade - 1 { window = Double(count - 1 - i) / Double(fade) }
            return Float(amplitude * window * sin(2 * .pi * frequency * Double(i) / sampleRate + phase))
        }
    }

    // MARK: - Loudness gating

    /// Apple's Immersive Audio Source Profile cites BS.1770-4, which is gated, so the existing
    /// meter is the right one and no ungated variant is needed. This is the evidence for that.
    @Test("Gated and ungated loudness agree on continuous material and diverge over silence")
    func gatingBehaviour() {
        func measure(dutyOn: Double) -> (gated: Double, ungated: Double) {
            let bed = Signal.pinkNoise(amplitude: 0.2, seconds: 24, sampleRate: Self.sampleRate)
            let period = Int(Self.sampleRate * 4)
            let gappy = bed.enumerated().map { index, value in
                Double(index % period) / Double(period) > dutyOn ? 0 : value
            }
            let meter = LoudnessMeter(sampleRate: Self.sampleRate)
            let gated = meter.measure(channels: [gappy, gappy]).integratedLUFS

            var buffer = gappy.map(Double.init)
            var filter = meter.kWeightingCascade()
            filter.process(&buffer)
            let meanSquare = buffer.reduce(0.0) { $0 + $1 * $1 } / Double(buffer.count)
            return (gated, -0.691 + 10 * log10(2 * meanSquare))
        }

        let continuous = measure(dutyOn: 1.0)
        #expect(abs(continuous.gated - continuous.ungated) < 0.05,
                "with no silence to gate there is nothing to disagree about")

        let gappy = measure(dutyOn: 0.25)
        #expect(gappy.gated - gappy.ungated > 3.0,
                "the gate should have excluded the silence: \(gappy)")
    }

    // MARK: - Encode check

    @Test("A full-scale file is caught by the encode check")
    func encodeCatchesClipping() throws {
        let hot = [Signal.sine(frequency: 997, amplitude: 1.0, seconds: 2),
                   Signal.sine(frequency: 997, amplitude: 1.0, seconds: 2)]
        let result = try EncodeCheck.measure(channels: hot, sampleRate: Self.sampleRate)
        #expect(result.clips, "a 0 dBFS sine came back clean, so the check has no power")
        #expect(result.samplesOverFullScale > 100)
        #expect(result.worstOvershootDB > 0.05)
        #expect(result.firstOverSampleIndex != nil)
    }

    @Test("A master with 1 dB of headroom survives the encode check")
    func encodePassesCompliantFile() throws {
        let mastered = Masterer().master(channels: Signal.musicLike(seconds: 6),
                                         sampleRate: Self.sampleRate, intensity: .standard)
        let result = try EncodeCheck.measure(channels: mastered.channels, sampleRate: Self.sampleRate)
        #expect(!result.clips, "a -1 dBTP master clipped: \(result)")
        #expect(result.peakDBFS < 0)
    }

    /// The bit rate is read back rather than assumed because two separate API paths silently
    /// ignore it, and a check run at 128 kbps would be harsher than the encode Apple performs.
    @Test("The encode really runs at the bit rate it reports")
    func encodeBitRateSticks() throws {
        let audio = Signal.musicLike(seconds: 2)
        let result = try EncodeCheck.measure(channels: audio, sampleRate: Self.sampleRate)
        #expect(result.bitRate == 256_000)
        #expect(result.bitRate == EncodeCheck.targetBitRate)
    }

    @Test("The round trip returns audio, and enough of it to measure")
    func roundTripReturnsAudio() throws {
        let audio = Signal.musicLike(seconds: 2)
        let decoded = try EncodeCheck.roundTrip(channels: audio, sampleRate: Self.sampleRate)
        #expect(decoded.count == 2)
        // AAC adds encoder delay and padding, so the decode is longer than the input, never shorter.
        #expect(decoded[0].count >= audio[0].count)
    }

    // MARK: - The Apple target end to end

    @Test("The Apple target lands inside every requirement it states")
    func appleTargetConforms() async throws {
        let audio = Signal.musicLike(seconds: 6)
        let engine = MasteringEngine(channels: audio, sampleRate: Self.sampleRate)
        let outcome = await engine.conform(mixer: Mixer(intensity: .loud, delivery: .appleMusic)) { _, _ in }
        let checked = try #require(outcome)
        // The printed figure must not round to the limit while the verdict says otherwise.
        #expect(checked.certifiedTruePeakDBTP < -1.0049,
                "\(checked.certifiedTruePeakDBTP) dBTP rounds to the limit it is checked against")

        let source = AudioIO.Format(sampleRate: Self.sampleRate, bitDepth: 24, codec: "lpcm")
        let conformance = try #require(Conformance.evaluate(checked, source: source,
                                                            outputBitDepth: 24))
        #expect(conformance.passed, "checks not met: \(conformance.plainText())")

        // The headroom claim has to hold on the meter that printed it, not the one that aimed.
        #expect(checked.certifiedTruePeakDBTP <= -1.0,
                "certified peak \(checked.certifiedTruePeakDBTP) dBTP breaks the 1 dB claim")
        #expect(checked.encode?.clips == false)
    }

    /// The specific bug the certification meter exposed: aiming at -1.0 with the 8x meter lands at
    /// about -0.99 on the 32x one. The conform pass has to correct for that, not report it as a pass.
    @Test("The master is trimmed when the working meter leaves it fractionally high")
    func correctsForMeterDisagreement() async throws {
        let audio = Signal.musicLike(seconds: 6)
        let engine = MasteringEngine(channels: audio, sampleRate: Self.sampleRate)
        let outcome = try #require(await engine.conform(
            mixer: Mixer(intensity: .loud, delivery: .appleMusic)) { _, _ in })

        // Whatever the reason, the result must be inside the ceiling on the certification meter.
        // What has to hold is the published requirement, measured on the meter that printed it.
        #expect(outcome.certifiedTruePeakDBTP <= -1.0,
                "certified peak \(outcome.certifiedTruePeakDBTP) breaks the 1 dB headroom claim")
        // A gain trim is exact, so the result lands inside its ceiling rather than near it — and
        // inside by more than the rounding of the figure the report prints.
        #expect(outcome.certifiedTruePeakDBTP < outcome.result.settings.ceilingDBTP,
                "settled at \(outcome.certifiedTruePeakDBTP) against a ceiling of \(outcome.result.settings.ceilingDBTP)")

        #expect(outcome.outputTrimDB <= 0, "a correction may only ever turn the master down")
        if outcome.outputTrimDB < -1e-9 {
            #expect(outcome.trimmedForMeter || outcome.trimmedForEncode,
                    "the master was trimmed without recording why")
            // The whole point of trimming rather than re-limiting: the cost is tiny.
            #expect(outcome.outputTrimDB > -0.3,
                    "trimmed \(outcome.outputTrimDB) dB, which is more than a meter disagreement")
        }
    }

    /// A trim must not be a re-limit. The corrected master has to be the same audio at a lower
    /// level, not audio that has been squashed harder to fit.
    @Test("A correction turns the master down rather than limiting it further")
    func trimIsAGainChangeNotMoreLimiting() async throws {
        let audio = Signal.musicLike(seconds: 6)
        let engine = MasteringEngine(channels: audio, sampleRate: Self.sampleRate)
        let mixer = Mixer(intensity: .loud, delivery: .appleMusic)
        let plain = try #require(await engine.render(mixer: mixer) { _, _ in })
        let conformed = try #require(await engine.conform(mixer: mixer) { _, _ in })

        guard conformed.outputTrimDB < -1e-9 else { return }
        #expect(conformed.result.channels[0].count == plain.channels[0].count)

        // Every sample is the untrimmed one scaled by exactly the reported trim.
        let scale = Float(pow(10, conformed.outputTrimDB / 20))
        var worst: Float = 0
        for i in stride(from: 0, to: plain.channels[0].count, by: 97) {
            worst = max(worst, abs(conformed.result.channels[0][i] - plain.channels[0][i] * scale))
        }
        #expect(worst < 1e-6, "the corrected master is not the original scaled: worst \(worst)")

        // Which means the dynamics are untouched.
        #expect(abs(conformed.result.after.loudnessRangeLU - plain.after.loudnessRangeLU) < 0.05)
        #expect(abs(conformed.result.after.crestFactorDB - plain.after.crestFactorDB) < 0.05)
    }

    @Test("A user who overrides the ceiling past the target is told, not overruled")
    func overriddenCeilingFailsRatherThanMoves() async throws {
        let audio = Signal.musicLike(seconds: 6)
        let engine = MasteringEngine(channels: audio, sampleRate: Self.sampleRate)
        var mixer = Mixer(intensity: .loud, delivery: .appleMusic)
        mixer.ceilingDBTP = -0.3
        let outcome = try #require(await engine.conform(mixer: mixer) { _, _ in })

        let source = AudioIO.Format(sampleRate: Self.sampleRate, bitDepth: 24, codec: "lpcm")
        let conformance = try #require(Conformance.evaluate(outcome, source: source,
                                                            outputBitDepth: 24))
        let headroom = try #require(conformance.checks.first { $0.label == "HEADROOM" })
        #expect(!headroom.passed, "a -0.3 dBTP ceiling should not satisfy a 1 dB headroom requirement")
        #expect(!conformance.passed)
        // The knob stays where it was put; only the report objects.
        #expect(outcome.result.settings.ceilingDBTP > -0.9,
                "the ceiling was quietly moved back to spec instead of the check failing")
    }

    @Test("A 16-bit source fails the resolution requirement")
    func sixteenBitSourceFails() async throws {
        let audio = Signal.musicLike(seconds: 4)
        let engine = MasteringEngine(channels: audio, sampleRate: Self.sampleRate)
        let outcome = try #require(await engine.conform(
            mixer: Mixer(intensity: .standard, delivery: .appleMusic)) { _, _ in })

        let sixteen = AudioIO.Format(sampleRate: Self.sampleRate, bitDepth: 16, codec: "lpcm")
        let conformance = try #require(Conformance.evaluate(outcome, source: sixteen,
                                                            outputBitDepth: 24))
        let source = try #require(conformance.checks.first { $0.label == "SOURCE" })
        #expect(!source.passed)
        #expect(!conformance.passed)

        // A lossy source has no sample depth at all, and that is a fail rather than a blank.
        let lossy = AudioIO.Format(sampleRate: Self.sampleRate, bitDepth: nil, codec: "aac ")
        let fromLossy = try #require(Conformance.evaluate(outcome, source: lossy, outputBitDepth: 24))
        #expect(!fromLossy.checks.first { $0.label == "SOURCE" }!.passed)
        #expect(fromLossy.checks.first { $0.label == "SOURCE" }!.measured.contains("AAC"))
    }

    // MARK: - What the report is allowed to say

    @Test("No delivery target means no checks and no claims")
    func noTargetMakesNoClaims() async throws {
        let audio = Signal.musicLike(seconds: 3)
        let engine = MasteringEngine(channels: audio, sampleRate: Self.sampleRate)
        let result = try #require(await engine.render(mixer: Mixer(intensity: .standard)) { _, _ in })
        #expect(result.settings.delivery == .none)

        let report = Report(result: result,
                            sourceFormat: AudioIO.Format(sampleRate: Self.sampleRate, bitDepth: 24,
                                                         codec: "lpcm"))
        #expect(report.conformance == nil)
        #expect(!report.plainText().contains("CHECKED AGAINST"))
    }

    /// Programme marks are not something software can confer on itself.
    @Test("The report never prints badge language")
    func noBadgeLanguage() async throws {
        let audio = Signal.musicLike(seconds: 4)
        let engine = MasteringEngine(channels: audio, sampleRate: Self.sampleRate)
        let outcome = try #require(await engine.conform(
            mixer: Mixer(intensity: .standard, delivery: .appleMusic)) { _, _ in })
        let source = AudioIO.Format(sampleRate: Self.sampleRate, bitDepth: 24, codec: "lpcm")
        let report = Report(result: outcome.result, sourceFormat: source,
                            conformance: Conformance.evaluate(outcome, source: source,
                                                              outputBitDepth: 24))
        let text = report.plainText().lowercased()

        for banned in ["apple digital master ", "apple digital masters certified", "certified",
                       "dolby", "atmos", "mastered for itunes", "badge", "approved"] {
            #expect(!text.contains(banned), "the report said \"\(banned)\"")
        }
        // What it may say is that it checked something against a named document.
        #expect(text.contains("checked against apple digital masters, april 2021"))
    }

    @Test("An unrunnable check is reported as unrun, never as a pass")
    func indeterminateIsNotAPass() {
        let audio = Signal.musicLike(seconds: 1)
        let analysis = Analyzer.analyze(channels: audio, sampleRate: Self.sampleRate)
        let settings = ChainDesigner.design(for: analysis, intensity: .standard,
                                            delivery: .appleMusic)
        let result = Masterer.Result(before: analysis, after: analysis, settings: settings,
                                     channels: audio, makeupGainDB: 0, limiterReductionDB: 0,
                                     passes: 1, unchanged: false)
        let outcome = MasteringEngine.DeliveryOutcome(
            result: result, encode: nil, certifiedTruePeakDBTP: -3.0,
            encodeFailure: "no encoder on this machine")

        let source = AudioIO.Format(sampleRate: Self.sampleRate, bitDepth: 24, codec: "lpcm")
        let conformance = Conformance.evaluate(outcome, source: source, outputBitDepth: 24)!
        let aac = conformance.checks.first { $0.label.hasPrefix("AAC") }!
        #expect(aac.indeterminate)
        #expect(!conformance.passed, "an unrunnable check must not count as met")
        #expect(conformance.hasIndeterminate)
        #expect(conformance.plainText().contains("no encoder on this machine"))
    }

    // MARK: - Delivery does not invent requirements

    @Test("No delivery target states a loudness figure")
    func noTargetInventsLoudness() {
        for delivery in Delivery.allCases {
            #expect(delivery.targetLUFS == nil,
                    "\(delivery) claims a loudness requirement no source document states")
        }
    }

    /// A target may only ever tighten the ceiling. Taking its number outright would push a gentle
    /// master louder in the name of a constraint that was about headroom.
    @Test("A delivery target tightens the ceiling and never loosens it")
    func deliveryOnlyTightens() {
        let analysis = Analyzer.analyze(channels: Signal.musicLike(seconds: 2),
                                        sampleRate: Self.sampleRate)
        for intensity in Intensity.allCases {
            let plain = ChainDesigner.design(for: analysis, intensity: intensity)
            let apple = ChainDesigner.design(for: analysis, intensity: intensity,
                                             delivery: .appleMusic)
            #expect(apple.ceilingDBTP <= plain.ceilingDBTP)
            #expect(apple.ceilingDBTP <= -1.0)
            #expect(apple.targetLUFS == plain.targetLUFS,
                    "the delivery target moved the loudness, which it has no basis to do")
        }
    }

    @Test("Selecting a delivery target changes nothing else about the chain")
    func deliveryTouchesOnlyTheCeiling() {
        let analysis = Analyzer.analyze(channels: Signal.musicLike(seconds: 2),
                                        sampleRate: Self.sampleRate)
        let plain = ChainDesigner.design(for: analysis, intensity: .gentle)
        let apple = ChainDesigner.design(for: analysis, intensity: .gentle, delivery: .appleMusic)

        #expect(apple.toneBands == plain.toneBands)
        #expect(apple.resonanceCuts == plain.resonanceCuts)
        #expect(apple.compressorBands == plain.compressorBands)
        #expect(apple.width == plain.width)
        #expect(apple.highpassHz == plain.highpassHz)
    }
}
