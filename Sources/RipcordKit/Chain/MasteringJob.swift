import Foundation

/// Runs the mastering chain off the calling thread and returns the result.
///
/// This exists as its own seam because delivering the result is exactly the thing that broke
/// once: an earlier version bridged progress through an `AsyncStream` whose `onTermination`
/// cancelled the producing task on *normal* completion, so the finished master was thrown away
/// and the UI waited forever on a job that had already succeeded. Putting the hand-off here
/// means a test can assert that a result actually comes back.
public enum MasteringJob {
    /// - Parameter progress: called on a background thread, possibly many times. Callers that
    ///   touch UI must hop to their own actor.
    public static func run(channels: [[Float]], sampleRate: Double, intensity: Intensity,
                           progress: @escaping @Sendable (Masterer.Stage, Double) -> Void)
        async -> Masterer.Result {
        await Task.detached(priority: .userInitiated) {
            Masterer().master(channels: channels, sampleRate: sampleRate,
                              intensity: intensity, progress: progress)
        }.value
    }
}
