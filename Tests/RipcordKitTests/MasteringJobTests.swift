import Foundation
import Testing
@testable import RipcordKit

/// Regression cover for the hand-off between the background chain and its caller.
///
/// The app once rendered nothing at all because the finished result was dropped on the way
/// back: progress was bridged through an `AsyncStream`, and `onTermination` cancelled the
/// producing task when the stream finished normally, so the delivery was swallowed by a
/// cancellation check. Every symptom pointed at saving; nothing was wrong with saving.
@Suite("Background job", .timeLimit(.minutes(2)))
struct MasteringJobTests {
    /// A concurrent counter, since progress arrives off the calling thread.
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stages: [Masterer.Stage] = []

        func record(_ stage: Masterer.Stage) {
            lock.lock(); defer { lock.unlock() }
            stages.append(stage)
        }

        var observed: [Masterer.Stage] {
            lock.lock(); defer { lock.unlock() }
            return stages
        }
    }

    @Test("The job actually returns its result")
    func deliversResult() async {
        let input = Signal.gain(Signal.musicLike(seconds: 4), dB: -12)
        let recorder = Recorder()

        let result = await MasteringJob.run(channels: input, sampleRate: 48000, intensity: .standard) { stage, _ in
            recorder.record(stage)
        }

        #expect(!result.unchanged)
        #expect(result.channels.count == input.count)
        #expect(result.channels[0].count == input[0].count)
        #expect(abs(result.after.integratedLUFS - (-11)) < 0.15)
    }

    @Test("Progress is reported and finishes at the end")
    func reportsProgress() async {
        let input = Signal.gain(Signal.musicLike(seconds: 4), dB: -12)
        let recorder = Recorder()
        _ = await MasteringJob.run(channels: input, sampleRate: 48000, intensity: .standard) { stage, _ in
            recorder.record(stage)
        }

        let observed = recorder.observed
        #expect(!observed.isEmpty)
        #expect(observed.first == .analyzing)
        #expect(observed.last == .verifying)
    }

    /// A result must survive being awaited from an actor-isolated context, which is how the app
    /// consumes it.
    @Test("The result survives delivery to the main actor")
    @MainActor
    func deliversToMainActor() async {
        let input = Signal.gain(Signal.musicLike(seconds: 3), dB: -12)
        var delivered: Masterer.Result?
        delivered = await MasteringJob.run(channels: input, sampleRate: 48000, intensity: .gentle) { _, _ in }
        #expect(delivered != nil)
        #expect(delivered?.unchanged == false)
    }
}
