import Foundation

/// One decoded track, held with the intermediate audio of the chain that was last rendered from it.
///
/// This is what makes the mixer live. A knob move does not mean re-mastering the file; it means
/// re-running the passes downstream of the knob. Moving the loudness target re-runs the makeup
/// search alone, which is a fraction of a second on a full-length track, because the compressed
/// signal and its true-peak envelope are exactly the same audio as they were a moment ago.
///
/// Correctness rests on one rule: a cache is keyed by everything its pass reads. `ToneKey` and
/// `DynamicsKey` are built from the settings fields each pass actually touches, so a cache hit is
/// a proof that re-running the pass would produce the same samples, not a guess that it might.
///
/// Cancellation is checked between passes only, and a cancelled render still keeps whatever passes
/// it finished. Dropping that work would mean a fast drag across a slider threw away the tone pass
/// over and over and never got as far as making a sound.
public actor MasteringEngine {
    /// Rough relative cost of each pass, used to make the progress bar tell the truth about a
    /// render that is only doing part of the work.
    private enum Weight {
        static let analyzing = 0.30
        static let tone = 0.15
        static let dynamics = 0.30
        static let level = 0.25
    }

    /// How far inside a stated limit a conforming master is made to land. Larger than the display
    /// rounding of the figures it is checked against, and smaller than anything audible.
    private static let conformanceMarginDB = 0.01

    private let input: [[Float]]
    public nonisolated let sampleRate: Double

    private var analysis: Analysis?
    private var designs: [Intensity: [Delivery: MasterSettings]] = [:]
    private var tone: (key: MasterSettings.ToneKey, channels: [[Float]])?
    private var dynamics: (key: MasterSettings.DynamicsKey, channels: [[Float]], envelope: [Float])?
    /// The finished master, so a re-render at settings that have already been rendered — a knob put
    /// back where it was, or the conformance pass repeating the render it was handed — costs
    /// nothing rather than a limiter search and a full re-analysis.
    private var level: (key: MasterSettings.LevelKey, result: Masterer.Result)?

    public init(channels: [[Float]], sampleRate: Double) {
        self.input = channels
        self.sampleRate = sampleRate
    }

    /// The measurement of the untouched input, once it exists. Cheap to ask for; never recomputed.
    public var sourceAnalysis: Analysis? { analysis }

    /// The chain the tool would design on its own, before any knob is moved. The mixer's AUTO
    /// readouts come from here.
    public func design(for intensity: Intensity, delivery: Delivery) -> MasterSettings? {
        guard let analysis else { return nil }
        return cachedDesign(analysis: analysis, intensity: intensity, delivery: delivery)
    }

    // MARK: - Live render

    /// Renders the mixer's settings, reusing every pass the mixer cannot have changed.
    ///
    /// - Returns: nil if the render was cancelled part-way. A cancelled render is not a failure and
    ///   leaves the caller's previous result standing.
    public func render(mixer: Mixer,
                       progress: @escaping Masterer.ProgressHandler) -> Masterer.Result? {
        guard let staged = stages(mixer: mixer, progress: progress) else { return nil }
        switch staged {
        case .unchanged(let result): return result
        case .ready(let context):
            return master(context, ceilingDBTP: context.settings.ceilingDBTP, progress: progress)
        }
    }

    // MARK: - Delivery conformance

    /// Everything a conformance claim needs, measured on rendered audio.
    public struct DeliveryOutcome: Sendable {
        public var result: Masterer.Result
        /// Nil when the target does not ask for a lossy encode check.
        public var encode: EncodeCheck.Result?
        /// True peak from the 32x meter rather than the working one, because this figure is going
        /// to be printed as a claim.
        public var certifiedTruePeakDBTP: Double
        /// Gain applied to the finished master to bring it inside the requirements, in dB. Never
        /// positive. Zero when the master already conformed.
        public var outputTrimDB = 0.0
        /// Why the trim was applied. The two reasons are different facts about the file: one is the
        /// working meter disagreeing with the certification meter, the other is the lossy encode
        /// reconstructing above full scale.
        public var trimmedForMeter = false
        public var trimmedForEncode = false
        /// Set when the check could not run at all, rather than ran and failed.
        public var encodeFailure: String?
    }

    /// The slow pass: renders, measures the master on the certification meter, encodes it to AAC,
    /// and if the decode clips, lowers the ceiling and re-runs the level pass until it does not.
    ///
    /// This is deliberately not part of `render`. The encode check runs at roughly 37x realtime —
    /// eight seconds on a five-minute track — which is fine once the knobs have stopped moving and
    /// ruinous on every frame of a drag. Keeping it separate is what lets the mixer stay live while
    /// a delivery target is selected.
    ///
    /// The ceiling correction is the same shape as the makeup search: measure, correct, re-measure.
    /// Lowering the ceiling only re-runs the level pass, because nothing upstream of the limiter
    /// depends on it, so each attempt costs a limiter pass and an encode rather than a full master.
    public func conform(mixer: Mixer,
                        progress: @escaping Masterer.ProgressHandler) -> DeliveryOutcome? {
        guard let staged = stages(mixer: mixer, progress: progress) else { return nil }

        let context: Context
        switch staged {
        case .unchanged(let result):
            // Nothing measurable. There is no claim to make and nothing to correct.
            return DeliveryOutcome(result: result, encode: nil,
                                   certifiedTruePeakDBTP: result.after.truePeakDBTP,
                                   encodeFailure: nil)
        case .ready(let ready):
            context = ready
        }

        // The correction is a gain trim, not a lower ceiling, and the difference matters.
        //
        // Lowering the ceiling and re-running the level pass looks like the obvious fix, and it was
        // the first thing tried. It does not work: the makeup search re-normalises to the same
        // loudness target afterwards, so dropping the ceiling 0.41 dB bought only 0.24 dB of peak
        // and paid for it with a quarter of a dB of extra limiting. Scaling the finished master is
        // exact instead — a true peak scales with the signal that produced it — so a hundredth of a
        // dB of excess costs a hundredth of a dB of level and no additional gain reduction at all.
        //
        // Every trim is applied to the untouched master rather than to the previous attempt, so two
        // corrections compose exactly rather than accumulating.
        guard let base = master(context, ceilingDBTP: context.settings.ceilingDBTP,
                                progress: progress) else { return nil }
        var result = base
        var trim = 0.0
        var meterTrimmed = false
        var encodeTrimmed = false

        // The limiter aims using the 8x working meter, which under-reads by up to 0.13 dB. A master
        // that lands exactly on its ceiling by that meter can sit just above it by the 32x one --
        // and the 32x figure is the one that gets printed, so it is the one that has to be true.
        //
        // The target is a hair *inside* the ceiling rather than on it. Landing exactly on the limit
        // produced the worst possible report: a row reading "1.00 dB" next to the verdict FAIL,
        // because the true value was 0.9985 and only the display had rounded. A requirement stated
        // to one decimal place has to be met by more than the rounding, or the report contradicts
        // itself in front of the reader.
        let target = context.settings.ceilingDBTP - Self.conformanceMarginDB
        let excess = certifiedTruePeak(result.channels) - target
        if Task.isCancelled { return nil }
        if excess > 0 {
            trim -= excess
            meterTrimmed = true
            result = trimmed(base, byDB: trim)
            if Task.isCancelled { return nil }
        }

        guard mixer.delivery.requiresEncodeCheck else {
            return DeliveryOutcome(result: result, encode: nil,
                                   certifiedTruePeakDBTP: certifiedTruePeak(result.channels),
                                   outputTrimDB: trim, trimmedForMeter: meterTrimmed,
                                   trimmedForEncode: false, encodeFailure: nil)
        }

        // Three attempts. Each trims by the measured overshoot plus a small margin, so the second is
        // normally the last; the bound exists so a pathological file cannot spin here.
        var encode: EncodeCheck.Result?
        for attempt in 1...3 {
            progress(.verifying, 0.3 + 0.2 * Double(attempt))
            do {
                encode = try EncodeCheck.measure(channels: result.channels, sampleRate: sampleRate)
            } catch {
                // A missing encoder is a reason to say the check did not run, never a reason to
                // report a pass. The distinction is carried through to the report.
                return DeliveryOutcome(result: result, encode: nil,
                                       certifiedTruePeakDBTP: certifiedTruePeak(result.channels),
                                       outputTrimDB: trim, trimmedForMeter: meterTrimmed,
                                       trimmedForEncode: encodeTrimmed,
                                       encodeFailure: error.localizedDescription)
            }
            if Task.isCancelled { return nil }
            guard let measured = encode, measured.clips, attempt < 3 else { break }
            trim -= measured.worstOvershootDB + 0.05
            encodeTrimmed = true
            result = trimmed(base, byDB: trim)
            if Task.isCancelled { return nil }
        }

        progress(.verifying, 1.0)
        return DeliveryOutcome(result: result, encode: encode,
                               certifiedTruePeakDBTP: certifiedTruePeak(result.channels),
                               outputTrimDB: trim, trimmedForMeter: meterTrimmed,
                               trimmedForEncode: encodeTrimmed, encodeFailure: nil)
    }

    /// Scales a finished master, re-measuring it so the report still quotes rendered audio.
    private func trimmed(_ result: Masterer.Result, byDB trim: Double) -> Masterer.Result {
        guard trim < -1e-9 else { return result }
        var channels = result.channels
        Masterer.applyGain(&channels, dB: trim)
        var out = result
        out.channels = channels
        out.after = Analyzer.analyze(channels: channels, sampleRate: sampleRate)
        out.makeupGainDB += trim
        return out
    }

    private func certifiedTruePeak(_ channels: [[Float]]) -> Double {
        TruePeakMeter.certification.truePeakDBTP(channels)
    }

    // MARK: - Staging

    /// Everything the level pass needs, once the cached passes above it have been satisfied.
    private struct Context {
        var before: Analysis
        var settings: MasterSettings
        var preLimiter: [[Float]]
        var envelope: [Float]
        var oversampler: TruePeakMeter
        var report: (Double) -> Void
    }

    private enum Staged {
        case unchanged(Masterer.Result)
        case ready(Context)
    }

    private func stages(mixer: Mixer, progress: @escaping Masterer.ProgressHandler) -> Staged? {
        // The bar is scaled over the passes that are actually going to run, so a level-only
        // re-render sweeps the whole bar quickly rather than appearing to stall at 94%.
        var budget = Weight.level
        let needsAnalysis = analysis == nil
        if needsAnalysis { budget += Weight.analyzing }

        var spent = 0.0
        func report(_ stage: Masterer.Stage, _ fraction: Double, _ weight: Double) {
            progress(stage, ((spent + weight * fraction) / budget).clamped(to: 0...1))
        }

        let before: Analysis
        if let analysis {
            before = analysis
        } else {
            report(.analyzing, 0, Weight.analyzing)
            before = Analyzer.analyze(channels: input, sampleRate: sampleRate)
            analysis = before
            spent += Weight.analyzing
        }

        let designed = cachedDesign(analysis: before, intensity: mixer.intensity,
                                    delivery: mixer.delivery)
        let settings = mixer.apply(to: designed, sampleRate: sampleRate)

        guard before.integratedLUFS.isFinite, !before.isSilent else {
            progress(.verifying, 1)
            return .unchanged(Masterer.Result(before: before, after: before, settings: settings,
                                              channels: input, makeupGainDB: 0,
                                              limiterReductionDB: 0, passes: 0, unchanged: true))
        }
        if Task.isCancelled { return nil }

        // Which passes are stale has to be decided before any of them runs, or the budget the bar
        // is drawn against changes half way through it.
        let toneHit = tone?.key == settings.toneKey
        let dynamicsHit = dynamics?.key == settings.dynamicsKey
        if !toneHit { budget += Weight.tone }
        if !dynamicsHit { budget += Weight.dynamics }

        let toned: [[Float]]
        if toneHit, let cached = tone {
            toned = cached.channels
        } else {
            report(.filtering, 0, Weight.tone)
            toned = Masterer.tonePass(input, sampleRate: sampleRate,
                                      inputLUFS: before.integratedLUFS, settings: settings)
            tone = (settings.toneKey, toned)
            spent += Weight.tone
            if Task.isCancelled { return nil }
        }

        let oversampler = TruePeakMeter.working
        let preLimiter: [[Float]]
        let envelope: [Float]
        if dynamicsHit, let cached = dynamics {
            preLimiter = cached.channels
            envelope = cached.envelope
        } else {
            report(.dynamics, 0, Weight.dynamics)
            preLimiter = Masterer.dynamicsPass(toned, sampleRate: sampleRate, settings: settings)
            report(.dynamics, 0.6, Weight.dynamics)
            envelope = Masterer.truePeakEnvelope(preLimiter, oversampler: oversampler)
            dynamics = (settings.dynamicsKey, preLimiter, envelope)
            spent += Weight.dynamics
            if Task.isCancelled { return nil }
        }

        report(.loudness, 0, Weight.level)
        let levelReport: (Double) -> Void = { fraction in
            report(.verifying, fraction * 0.8, Weight.level)
        }
        return .ready(Context(before: before, settings: settings, preLimiter: preLimiter,
                              envelope: envelope, oversampler: oversampler, report: levelReport))
    }

    /// Runs the level pass at a given ceiling and measures the result, or returns the cached master
    /// if these exact settings have already been rendered. Nil when cancelled part-way.
    private func master(_ context: Context, ceilingDBTP: Double,
                        progress: @escaping Masterer.ProgressHandler) -> Masterer.Result? {
        var settings = context.settings
        settings.ceilingDBTP = ceilingDBTP

        if let cached = level, cached.key == settings.levelKey {
            progress(.verifying, 1)
            // The key covers everything that determines the *audio*, which is what makes the hit
            // safe. It deliberately does not cover the rest of the settings — the delivery target,
            // the intensity label — because those do not change a sample. They do travel with the
            // result and get read back out of it, though, so they are replaced rather than served
            // stale: selecting a delivery target whose ceiling matches the one already rendered
            // otherwise handed back a result still describing itself as having no target, and the
            // conformance rows were silently skipped.
            var result = cached.result
            result.settings = settings
            return result
        }

        let outcome = Masterer.levelPass(preLimiter: context.preLimiter,
                                         baseEnvelope: context.envelope, sampleRate: sampleRate,
                                         settings: settings, oversampler: context.oversampler,
                                         progress: context.report)
        if Task.isCancelled { return nil }
        let after = Analyzer.analyze(channels: outcome.channels, sampleRate: sampleRate)
        if Task.isCancelled { return nil }
        progress(.verifying, 1)

        let result = Masterer.Result(before: context.before, after: after, settings: settings,
                                     channels: outcome.channels, makeupGainDB: outcome.makeupGainDB,
                                     limiterReductionDB: outcome.limiterReductionDB,
                                     passes: outcome.passes, unchanged: false)
        level = (settings.levelKey, result)
        return result
    }

    private func cachedDesign(analysis: Analysis, intensity: Intensity,
                              delivery: Delivery) -> MasterSettings {
        if let cached = designs[intensity]?[delivery] { return cached }
        let designed = ChainDesigner.design(for: analysis, intensity: intensity, delivery: delivery)
        designs[intensity, default: [:]][delivery] = designed
        return designed
    }
}
