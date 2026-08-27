import Foundation

/// Applies a `MasterSettings` to audio and lands the result on the loudness target.
///
/// Loudness is hit by measurement rather than by estimation: the chain is rendered, the result is
/// measured, the makeup gain is computed from that measurement, and the limiter is re-run if the
/// gain reduction moved the answer. Two or three passes is enough to sit inside 0.1 LU.
///
/// The chain is split into three passes — tone, dynamics, level — each a pure function of the
/// audio handed to it and the part of the settings it reads. That split is what `MasteringEngine`
/// caches against when a mixer knob moves, so a change to the loudness target does not re-run the
/// multiband compressor it cannot possibly have affected.
public struct Masterer: Sendable {
    public struct Result: Sendable {
        public var before: Analysis
        public var after: Analysis
        public var settings: MasterSettings
        public var channels: [[Float]]
        public var makeupGainDB: Double
        public var limiterReductionDB: Double
        public var passes: Int
        public var unchanged: Bool
    }

    public enum Stage: String, Sendable {
        case analyzing = "READING"
        case filtering = "TONE"
        case dynamics = "DYNAMICS"
        case loudness = "LEVEL"
        case verifying = "CHECK"
    }

    public typealias ProgressHandler = @Sendable (Stage, Double) -> Void

    public init() {}

    public func master(channels input: [[Float]], sampleRate: Double, intensity: Intensity,
                       progress: ProgressHandler? = nil) -> Result {
        master(channels: input, sampleRate: sampleRate, mixer: Mixer(intensity: intensity),
               progress: progress)
    }

    public func master(channels input: [[Float]], sampleRate: Double, mixer: Mixer,
                       progress: ProgressHandler? = nil) -> Result {
        progress?(.analyzing, 0.05)
        let before = Analyzer.analyze(channels: input, sampleRate: sampleRate)
        let designed = ChainDesigner.design(for: before, intensity: mixer.intensity)
        let settings = mixer.apply(to: designed, sampleRate: sampleRate)

        guard let result = Self.render(input: input, sampleRate: sampleRate, before: before,
                                       settings: settings, progress: progress) else {
            // Nothing measurable to work with. Returning the input untouched is the honest answer.
            return Result(before: before, after: before, settings: settings, channels: input,
                          makeupGainDB: 0, limiterReductionDB: 0, passes: 0, unchanged: true)
        }
        return result
    }

    /// The whole chain in one shot, with no cache. Returns nil for a file with nothing to measure.
    static func render(input: [[Float]], sampleRate: Double, before: Analysis,
                       settings: MasterSettings, progress: ProgressHandler?) -> Result? {
        guard before.integratedLUFS.isFinite, !before.isSilent else { return nil }

        progress?(.filtering, 0.25)
        let toned = tonePass(input, sampleRate: sampleRate, inputLUFS: before.integratedLUFS,
                             settings: settings)

        progress?(.dynamics, 0.45)
        let preLimiter = dynamicsPass(toned, sampleRate: sampleRate, settings: settings)

        progress?(.loudness, 0.70)
        let oversampler = TruePeakMeter()
        let envelope = truePeakEnvelope(preLimiter, oversampler: oversampler)
        let level = levelPass(preLimiter: preLimiter, baseEnvelope: envelope, sampleRate: sampleRate,
                              settings: settings, oversampler: oversampler) { fraction in
            progress?(.verifying, 0.70 + 0.22 * fraction)
        }

        progress?(.verifying, 0.94)
        let after = Analyzer.analyze(channels: level.channels, sampleRate: sampleRate)
        progress?(.verifying, 1.0)

        return Result(before: before, after: after, settings: settings, channels: level.channels,
                      makeupGainDB: level.makeupGainDB, limiterReductionDB: level.limiterReductionDB,
                      passes: level.passes, unchanged: false)
    }

    // MARK: - Tone

    /// Levels the input to the working reference, then high-passes, equalises and images it.
    ///
    /// Normalising here rather than in the caller is deliberate: the compressor thresholds
    /// downstream are fixed numbers, and they only mean the same thing on every file if the signal
    /// arrives at the same level whether the file was cut at -6 or -26 LUFS.
    public static func tonePass(_ input: [[Float]], sampleRate: Double, inputLUFS: Double,
                                settings: MasterSettings) -> [[Float]] {
        var work = input.map { $0 }
        applyGain(&work, dB: MasterSettings.workingLUFS - inputLUFS)
        removeDCAndRumble(&work, settings: settings, sampleRate: sampleRate)
        applyEQ(&work, bands: settings.allEQBands, sampleRate: sampleRate)

        if work.count > 1 {
            var left = work[0], right = work[1]
            StereoImage.apply(left: &left, right: &right,
                              width: settings.width, monoBelowHz: settings.monoBelowHz,
                              sampleRate: sampleRate)
            work[0] = left
            work[1] = right
        }
        return work
    }

    // MARK: - Dynamics

    public static func dynamicsPass(_ toned: [[Float]], sampleRate: Double,
                                    settings: MasterSettings) -> [[Float]] {
        var channels = toned.map { $0 }
        let frameCount = channels[0].count
        let isStereo = channels.count > 1
        var outLeft = [Float](repeating: 0, count: frameCount)
        var outRight = [Float](repeating: 0, count: frameCount)

        for (index, band) in settings.compressorBands.enumerated() {
            var left = Crossover.isolate(band: index, from: channels[0],
                                         crossovers: settings.crossovers, sampleRate: sampleRate)
            var right = isStereo
                ? Crossover.isolate(band: index, from: channels[1],
                                    crossovers: settings.crossovers, sampleRate: sampleRate)
                : left

            let compressor = Compressor(thresholdDB: band.thresholdDB, ratio: band.ratio,
                                        attackSeconds: band.attackSeconds,
                                        releaseSeconds: band.releaseSeconds, kneeDB: 8)
            compressor.process(left: &left, right: &right, sampleRate: sampleRate)

            for i in 0..<frameCount {
                outLeft[i] += left[i]
                outRight[i] += right[i]
            }
        }

        channels[0] = outLeft
        if isStereo { channels[1] = outRight }
        return channels
    }

    /// The true-peak envelope of the pre-limiter signal, measured once.
    ///
    /// Every makeup attempt only rescales that signal, so the envelope rescales with it rather than
    /// needing a fresh oversampling pass — which is otherwise the most expensive step in the chain.
    public static func truePeakEnvelope(_ preLimiter: [[Float]],
                                        oversampler: TruePeakMeter = TruePeakMeter()) -> [Float] {
        let left = oversampler.peakEnvelope(preLimiter[0])
        guard preLimiter.count > 1 else { return left }
        let right = oversampler.peakEnvelope(preLimiter[1])
        return (0..<left.count).map { max(left[$0], right[$0]) }
    }

    // MARK: - Level

    public struct LevelOutcome: Sendable {
        public var channels: [[Float]]
        public var makeupGainDB: Double
        public var limiterReductionDB: Double
        public var passes: Int
    }

    /// Searches for the makeup gain that lands the limited signal on the loudness target.
    ///
    /// Under heavy limiting an extra dB of makeup buys well under a dB of loudness, so a correction
    /// of `error` undershoots and the search stalls short of the target. Measuring the actual slope
    /// between passes and stepping by `error / slope` converges instead.
    public static func levelPass(preLimiter: [[Float]], baseEnvelope: [Float], sampleRate: Double,
                                 settings: MasterSettings,
                                 oversampler: TruePeakMeter = TruePeakMeter(),
                                 progress: ((Double) -> Void)? = nil) -> LevelOutcome {
        let isStereo = preLimiter.count > 1
        let meter = LoudnessMeter(sampleRate: sampleRate)
        let compressed = meter.measure(channels: preLimiter).integratedLUFS

        var makeup = settings.targetLUFS - compressed
        var limiterReduction = 0.0
        var passes = 0
        var best = preLimiter
        var previousMakeup: Double?
        var previousAchieved: Double?

        for pass in 1...5 {
            passes = pass
            var candidate = preLimiter.map { $0 }
            applyGain(&candidate, dB: makeup)
            let scale = Float(pow(10, makeup / 20))
            let scaledEnvelope = baseEnvelope.map { $0 * scale }

            var left = candidate[0]
            var right = isStereo ? candidate[1] : candidate[0]
            let limiter = Limiter(ceilingDBTP: settings.ceilingDBTP)
            let outcome = limiter.process(left: &left, right: &right, sampleRate: sampleRate,
                                          envelope: scaledEnvelope, oversampler: oversampler)
            limiterReduction = outcome.peakReductionDB
            candidate[0] = left
            if isStereo { candidate[1] = right }

            best = candidate
            let achieved = meter.measure(channels: candidate).integratedLUFS
            let error = settings.targetLUFS - achieved
            progress?(Double(pass) / 5)
            if abs(error) < 0.05 || !error.isFinite { break }
            if Task.isCancelled { break }

            var step = error
            if let previousMakeup, let previousAchieved, abs(makeup - previousMakeup) > 1e-6 {
                let slope = (achieved - previousAchieved) / (makeup - previousMakeup)
                if slope.isFinite, slope > 0.15 {
                    step = error / min(slope, 1.0)
                }
            }
            previousMakeup = makeup
            previousAchieved = achieved
            makeup += step.clamped(to: -6...6)
        }

        return LevelOutcome(channels: best, makeupGainDB: makeup,
                            limiterReductionDB: limiterReduction, passes: passes)
    }

    // MARK: - Primitives

    static func applyGain(_ channels: inout [[Float]], dB: Double) {
        guard dB.isFinite, abs(dB) > 1e-6 else { return }
        let gain = Float(pow(10, dB / 20))
        for c in channels.indices {
            for i in channels[c].indices { channels[c][i] *= gain }
        }
    }

    static func removeDCAndRumble(_ channels: inout [[Float]], settings: MasterSettings, sampleRate: Double) {
        for c in channels.indices {
            var cascade = BiquadCascade([
                .highpass(freq: settings.highpassHz, q: Crossover.butterworthQ, sampleRate: sampleRate),
                .highpass(freq: settings.highpassHz, q: Crossover.butterworthQ, sampleRate: sampleRate),
            ])
            cascade.process(&channels[c])
        }
    }

    static func applyEQ(_ channels: inout [[Float]], bands: [MasterSettings.EQBand], sampleRate: Double) {
        guard !bands.isEmpty else { return }
        for c in channels.indices {
            var cascade = BiquadCascade(bands.map { $0.coefficients(sampleRate: sampleRate) })
            cascade.process(&channels[c])
        }
    }
}
