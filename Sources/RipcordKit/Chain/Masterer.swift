import Foundation

/// Applies a `MasterSettings` to audio and lands the result on the loudness target.
///
/// Loudness is hit by measurement rather than by estimation: the chain is rendered, the result is
/// measured, the makeup gain is computed from that measurement, and the limiter is re-run if the
/// gain reduction moved the answer. Two or three passes is enough to sit inside 0.1 LU.
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
        progress?(.analyzing, 0.05)
        let before = Analyzer.analyze(channels: input, sampleRate: sampleRate)
        let settings = ChainDesigner.design(for: before, intensity: intensity)

        guard before.integratedLUFS.isFinite, !before.isSilent else {
            // Nothing measurable to work with. Returning the input untouched is the honest answer.
            return Result(before: before, after: before, settings: settings, channels: input,
                          makeupGainDB: 0, limiterReductionDB: 0, passes: 0, unchanged: true)
        }

        var work = input.map { $0 }
        let isStereo = work.count > 1

        // Normalize to a fixed working level so the compressor thresholds mean the same thing
        // whether the file arrived at -6 or -26 LUFS.
        applyGain(&work, dB: MasterSettings.workingLUFS - before.integratedLUFS)

        progress?(.filtering, 0.25)
        removeDCAndRumble(&work, settings: settings, sampleRate: sampleRate)
        applyEQ(&work, bands: settings.allEQBands, sampleRate: sampleRate)

        if isStereo {
            var left = work[0], right = work[1]
            StereoImage.apply(left: &left, right: &right,
                              width: settings.width, monoBelowHz: settings.monoBelowHz,
                              sampleRate: sampleRate)
            work[0] = left
            work[1] = right
        }

        progress?(.dynamics, 0.45)
        applyMultibandCompression(&work, settings: settings, sampleRate: sampleRate)

        progress?(.loudness, 0.70)
        let preLimiter = work
        let meter = LoudnessMeter(sampleRate: sampleRate)
        let compressed = meter.measure(channels: preLimiter).integratedLUFS

        var makeup = settings.targetLUFS - compressed
        var limiterReduction = 0.0
        var passes = 0
        var best: [[Float]] = work

        // The true-peak envelope of the pre-limiter signal, measured once. Each makeup attempt
        // only rescales that signal, so the envelope rescales with it rather than needing a
        // fresh oversampling pass — which is otherwise the most expensive step in the chain.
        let oversampler = TruePeakMeter()
        let baseEnvelope: [Float] = {
            let l = oversampler.peakEnvelope(preLimiter[0])
            guard isStereo else { return l }
            let r = oversampler.peakEnvelope(preLimiter[1])
            return (0..<l.count).map { max(l[$0], r[$0]) }
        }()

        // Under heavy limiting an extra dB of makeup buys well under a dB of loudness, so a
        // correction of `error` undershoots and the search stalls short of the target. Measuring
        // the actual slope between passes and stepping by `error / slope` converges instead.
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
            if isStereo { candidate[1] = right } else { candidate[0] = left }

            best = candidate
            let achieved = meter.measure(channels: candidate).integratedLUFS
            let error = settings.targetLUFS - achieved
            progress?(.verifying, 0.70 + 0.04 * Double(pass))
            if abs(error) < 0.05 || !error.isFinite { break }

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

        progress?(.verifying, 0.92)
        let after = Analyzer.analyze(channels: best, sampleRate: sampleRate)
        progress?(.verifying, 1.0)

        return Result(before: before, after: after, settings: settings, channels: best,
                      makeupGainDB: makeup, limiterReductionDB: limiterReduction,
                      passes: passes, unchanged: false)
    }

    // MARK: - Stages

    private func applyGain(_ channels: inout [[Float]], dB: Double) {
        guard dB.isFinite, abs(dB) > 1e-6 else { return }
        let gain = Float(pow(10, dB / 20))
        for c in channels.indices {
            for i in channels[c].indices { channels[c][i] *= gain }
        }
    }

    private func removeDCAndRumble(_ channels: inout [[Float]], settings: MasterSettings, sampleRate: Double) {
        for c in channels.indices {
            var cascade = BiquadCascade([
                .highpass(freq: settings.highpassHz, q: Crossover.butterworthQ, sampleRate: sampleRate),
                .highpass(freq: settings.highpassHz, q: Crossover.butterworthQ, sampleRate: sampleRate),
            ])
            cascade.process(&channels[c])
        }
    }

    private func applyEQ(_ channels: inout [[Float]], bands: [MasterSettings.EQBand], sampleRate: Double) {
        guard !bands.isEmpty else { return }
        for c in channels.indices {
            var cascade = BiquadCascade(bands.map { $0.coefficients(sampleRate: sampleRate) })
            cascade.process(&channels[c])
        }
    }

    private func applyMultibandCompression(_ channels: inout [[Float]], settings: MasterSettings, sampleRate: Double) {
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
    }
}
