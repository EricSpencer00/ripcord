import Foundation
import Testing
@testable import RipcordKit

/// The engine's whole claim is that re-rendering after a knob move skips the passes that knob
/// cannot have changed, and that skipping them changes nothing about the audio. Both halves are
/// checked here: which passes ran, and whether the samples came out the same as a cold render.
///
/// The second half is the one that matters. A cache that is merely fast is a bug waiting to be
/// found by a user who hears a difference the report does not mention.
@Suite("Mastering engine", .timeLimit(.minutes(5)))
struct MasteringEngineTests {
    static let seconds = 4.0

    static func track() -> [[Float]] { Signal.musicLike(seconds: seconds) }

    /// Records which stages a render reported, which is a direct observation of what ran rather
    /// than a timing measurement that would be flaky on a loaded machine.
    final class StageLog: @unchecked Sendable {
        private let lock = NSLock()
        private var stages: Set<Masterer.Stage> = []

        func record(_ stage: Masterer.Stage) {
            lock.lock(); defer { lock.unlock() }
            stages.insert(stage)
        }

        var seen: Set<Masterer.Stage> {
            lock.lock(); defer { lock.unlock() }
            return stages
        }

        var handler: Masterer.ProgressHandler {
            { stage, _ in self.record(stage) }
        }
    }

    static func render(_ engine: MasteringEngine, _ mixer: Mixer,
                       log: StageLog = StageLog()) async -> (Masterer.Result, StageLog) {
        let result = await engine.render(mixer: mixer, progress: log.handler)
        return (result!, log)
    }

    // MARK: - Exactness

    @Test("A level-only change re-renders to the same samples as a cold engine")
    func levelChangeIsExact() async {
        let audio = Self.track()
        let engine = MasteringEngine(channels: audio, sampleRate: Signal.sampleRate)
        _ = await Self.render(engine, Mixer(intensity: .standard))

        var moved = Mixer(intensity: .standard)
        moved.targetLUFS = -9
        let (warm, _) = await Self.render(engine, moved)

        let cold = MasteringEngine(channels: audio, sampleRate: Signal.sampleRate)
        let (fresh, _) = await Self.render(cold, moved)

        #expect(warm.channels == fresh.channels, "the cache changed the audio")
        #expect(warm.makeupGainDB == fresh.makeupGainDB)
    }

    @Test("A tone change re-renders to the same samples as a cold engine")
    func toneChangeIsExact() async {
        let audio = Self.track()
        let engine = MasteringEngine(channels: audio, sampleRate: Signal.sampleRate)
        _ = await Self.render(engine, Mixer(intensity: .standard))

        var moved = Mixer(intensity: .standard)
        moved.bassTrimDB = 2.5
        moved.width = 1.3
        let (warm, _) = await Self.render(engine, moved)

        let cold = MasteringEngine(channels: audio, sampleRate: Signal.sampleRate)
        let (fresh, _) = await Self.render(cold, moved)

        #expect(warm.channels == fresh.channels, "the cache changed the audio")
    }

    @Test("Returning a knob to where it was returns the same master")
    func roundTripIsExact() async {
        let audio = Self.track()
        let engine = MasteringEngine(channels: audio, sampleRate: Signal.sampleRate)
        let (first, _) = await Self.render(engine, Mixer(intensity: .standard))

        var moved = Mixer(intensity: .standard)
        moved.compression = 0.2
        _ = await Self.render(engine, moved)

        let (back, _) = await Self.render(engine, Mixer(intensity: .standard))
        #expect(first.channels == back.channels)
    }

    // MARK: - What actually re-runs

    @Test("Moving the loudness target re-runs the level pass alone")
    func levelChangeSkipsUpstream() async {
        let engine = MasteringEngine(channels: Self.track(), sampleRate: Signal.sampleRate)
        _ = await Self.render(engine, Mixer(intensity: .standard))

        var moved = Mixer(intensity: .standard)
        moved.targetLUFS = -13
        let (_, log) = await Self.render(engine, moved)

        #expect(!log.seen.contains(.analyzing), "re-measured the input it already measured")
        #expect(!log.seen.contains(.filtering), "re-ran the tone pass the target cannot affect")
        #expect(!log.seen.contains(.dynamics), "re-ran the compressor the target cannot affect")
        #expect(log.seen.contains(.loudness))
    }

    @Test("Moving compression re-runs the dynamics pass but not the tone pass")
    func compressionChangeSkipsTone() async {
        let engine = MasteringEngine(channels: Self.track(), sampleRate: Signal.sampleRate)
        _ = await Self.render(engine, Mixer(intensity: .standard))

        var moved = Mixer(intensity: .standard)
        moved.compression = 1.4
        let (_, log) = await Self.render(engine, moved)

        #expect(!log.seen.contains(.filtering), "re-ran the tone pass a ratio cannot affect")
        #expect(log.seen.contains(.dynamics))
    }

    @Test("Moving a tone control re-runs everything downstream of it")
    func toneChangeRerunsDownstream() async {
        let engine = MasteringEngine(channels: Self.track(), sampleRate: Signal.sampleRate)
        _ = await Self.render(engine, Mixer(intensity: .standard))

        var moved = Mixer(intensity: .standard)
        moved.airTrimDB = -3
        let (_, log) = await Self.render(engine, moved)

        #expect(log.seen.contains(.filtering))
        #expect(log.seen.contains(.dynamics), "fed the compressor audio it had not been given")
        #expect(!log.seen.contains(.analyzing))
    }

    /// A cache key that covers the audio but not the metadata travelling with it is still wrong.
    /// This is the regression: `standard` and `standard + Apple` share a -1.0 dBTP ceiling, so the
    /// level key matched and the cached result came back still describing itself as having no
    /// delivery target — which made the conformance rows disappear entirely.
    @Test("A cache hit does not serve stale settings alongside the right audio")
    func cacheHitCarriesCurrentSettings() async {
        let audio = Self.track()
        let engine = MasteringEngine(channels: audio, sampleRate: Signal.sampleRate)

        let (plain, _) = await Self.render(engine, Mixer(intensity: .standard, delivery: .none))
        #expect(plain.settings.delivery == .none)

        let (targeted, _) = await Self.render(engine, Mixer(intensity: .standard,
                                                            delivery: .appleMusic))
        #expect(targeted.settings.delivery == .appleMusic,
                "the cached result was served with the previous run's delivery target")
        // Same ceiling, so this is exactly the case where the cache does hit — and the audio
        // therefore has to be identical while the settings are not.
        #expect(targeted.settings.ceilingDBTP == plain.settings.ceilingDBTP)
        #expect(targeted.channels == plain.channels)
    }

    // MARK: - The knobs mean something

    @Test("An untouched mixer is exactly the automatic chain")
    func untouchedMixerChangesNothing() {
        let audio = Self.track()
        let analysis = Analyzer.analyze(channels: audio, sampleRate: Signal.sampleRate)
        let designed = ChainDesigner.design(for: analysis, intensity: .standard)
        let applied = Mixer(intensity: .standard).apply(to: designed, sampleRate: Signal.sampleRate)

        #expect(applied.toneKey == designed.toneKey)
        #expect(applied.dynamicsKey == designed.dynamicsKey)
        #expect(applied.targetLUFS == designed.targetLUFS)
        #expect(applied.ceilingDBTP == designed.ceilingDBTP)
    }

    @Test("The loudness knob lands where it is set")
    func loudnessKnobLands() async {
        let engine = MasteringEngine(channels: Self.track(), sampleRate: Signal.sampleRate)
        var mixer = Mixer(intensity: .standard)
        mixer.targetLUFS = -13.5
        let (result, _) = await Self.render(engine, mixer)
        #expect(abs(result.after.integratedLUFS - (-13.5)) < 0.3,
                "measured \(result.after.integratedLUFS)")
    }

    @Test("The ceiling knob is respected by the limiter")
    func ceilingKnobHolds() async {
        let engine = MasteringEngine(channels: Self.track(), sampleRate: Signal.sampleRate)
        var mixer = Mixer(intensity: .loud)
        mixer.ceilingDBTP = -2.0
        let (result, _) = await Self.render(engine, mixer)
        #expect(result.after.truePeakDBTP <= -1.95, "peaked at \(result.after.truePeakDBTP)")
    }

    @Test("Turning tone off leaves the tonal balance alone")
    func toneOffMakesNoEQMoves() async {
        let engine = MasteringEngine(channels: Self.track(), sampleRate: Signal.sampleRate)
        var mixer = Mixer(intensity: .standard)
        mixer.toneAmount = 0
        let (result, _) = await Self.render(engine, mixer)
        let biggest = result.settings.toneBands.map { abs($0.gainDB) }.max() ?? 0
        #expect(biggest < 0.3, "still moved the tone by \(biggest) dB")
    }

    @Test("Turning dynamics off leaves the ratios at unity")
    func compressionOffIsUnity() async {
        let engine = MasteringEngine(channels: Self.track(), sampleRate: Signal.sampleRate)
        var mixer = Mixer(intensity: .standard)
        mixer.compression = 0
        let (result, _) = await Self.render(engine, mixer)
        #expect(result.settings.compressorBands.allSatisfy { $0.ratio == 1 })
    }

    @Test("Knobs are held inside their published range")
    func knobsClamp() {
        var mixer = Mixer()
        for knob in Mixer.Knob.allCases {
            mixer[knob] = 1e6
            #expect(mixer[knob] == knob.range.upperBound)
            mixer[knob] = -1e6
            #expect(mixer[knob] == knob.range.lowerBound)
        }
        #expect(mixer.isTouched)
        mixer.resetAll()
        #expect(!mixer.isTouched)
    }

    @Test("Silence comes back untouched and is not something to mix")
    func silenceIsUnchanged() async {
        let silent = [[Float]](repeating: [Float](repeating: 0, count: 48000), count: 2)
        let engine = MasteringEngine(channels: silent, sampleRate: Signal.sampleRate)
        let result = await engine.render(mixer: Mixer()) { _, _ in }
        #expect(result?.unchanged == true)
        #expect(result?.channels == silent)
    }
}
