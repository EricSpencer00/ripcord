import Foundation
import Testing
@testable import Ripcord
@testable import RipcordKit

/// Drives the controller through the flow a user actually performs: open a file, wait, save.
///
/// This exists because the app once shipped completely non-functional while every engine test
/// passed. The chain was fine; the controller never reached `.done`, so no report rendered and
/// no Save button was ever drawn. Nothing below touches DSP — it only asks whether the state
/// machine arrives, and whether a file lands on disk.
/// Serialized on purpose: every test here is main-actor bound and drives a full mastering run,
/// so letting them interleave just starves the actor they are all waiting on.
@Suite("Mastering controller", .timeLimit(.minutes(3)), .serialized)
@MainActor
struct MasteringControllerTests {
    /// Writes a short real audio file to a temporary directory and returns its URL.
    static func makeTestFile(seconds: Double = 3) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ripcord-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("fixture.wav")

        var left = [Float](repeating: 0, count: Int(48000 * seconds))
        var right = left
        var state: UInt64 = 0xA5EED
        for i in left.indices {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let noise = Double(state >> 11) / Double(1 << 53) * 2 - 1
            let tone = sin(2 * .pi * 220 * Double(i) / 48000)
            left[i] = Float((tone * 0.25 + noise * 0.05) * 0.5)
            right[i] = Float((tone * 0.25 + noise * 0.04) * 0.5)
        }
        try AudioIO.writeWAV(channels: [left, right], sampleRate: 48000, to: url)
        return url
    }

    /// Polls the controller until it settles, rather than assuming a fixed duration.
    static func waitUntilDone(_ controller: MasteringController, timeout: Double = 90) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if case .done = controller.phase { return true }
            if case .failed = controller.phase { return false }
            try? await Task.sleep(for: .milliseconds(80))
        }
        return false
    }

    /// The exact failure that shipped: the job finished but the result was never delivered.
    @Test("Loading a file reaches the finished state")
    func reachesDone() async throws {
        let url = try Self.makeTestFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let controller = MasteringController()
        controller.load(url)

        #expect(await Self.waitUntilDone(controller), "phase never reached .done: \(controller.phase)")
        #expect(controller.report != nil, "no report was produced")
        #expect(controller.canSave, "the Save button would not be drawn")
    }

    @Test("Saving puts a readable file on disk")
    func savesReadableFile() async throws {
        let url = try Self.makeTestFile()
        let directory = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }

        let controller = MasteringController()
        controller.load(url)
        #expect(await Self.waitUntilDone(controller))

        let destination = directory.appendingPathComponent("out.wav")
        controller.save(to: destination)

        #expect(controller.savedURL == destination, "the app did not record a successful save")
        #expect(FileManager.default.fileExists(atPath: destination.path), "no file at \(destination.path)")

        // It has to be real audio, not just a non-empty file.
        let written = try AudioIO.read(destination)
        #expect(written.channels.count == 2)
        #expect(written.sampleRate == 48000)
        #expect(abs(written.durationSeconds - 3) < 0.05)

        let measured = Analyzer.analyze(channels: written.channels, sampleRate: written.sampleRate)
        #expect(abs(measured.integratedLUFS - (-11)) < 0.3, "saved file measures \(measured.integratedLUFS)")
        #expect(measured.truePeakDBTP <= -0.95)
    }

    @Test("The default name does not stack suffixes when saving a saved file")
    func defaultNameIsStable() {
        let once = AudioIO.defaultOutputURL(for: URL(fileURLWithPath: "/tmp/Song.wav"))
        let twice = AudioIO.defaultOutputURL(for: once)
        #expect(once.lastPathComponent == "Song (mastered).wav")
        #expect(twice.lastPathComponent == "Song (mastered).wav")
    }

    @Test("Changing intensity reprocesses and lands on the new target")
    func reprocessing() async throws {
        let url = try Self.makeTestFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let controller = MasteringController()
        controller.load(url)
        #expect(await Self.waitUntilDone(controller))

        controller.intensity = .loud
        controller.reprocess()
        #expect(await Self.waitUntilDone(controller), "reprocessing never finished")

        let destination = url.deletingLastPathComponent().appendingPathComponent("loud.wav")
        controller.save(to: destination)
        let written = try AudioIO.read(destination)
        let measured = Analyzer.analyze(channels: written.channels, sampleRate: written.sampleRate)
        #expect(abs(measured.integratedLUFS - (-9)) < 0.3, "measured \(measured.integratedLUFS)")
    }

    @Test("An unreadable file reports a failure instead of hanging")
    func rejectsGarbage() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ripcord-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("not-audio.wav")
        try Data("this is not a wave file".utf8).write(to: url)

        let controller = MasteringController()
        controller.load(url)

        let deadline = Date().addingTimeInterval(60)
        var failed = false
        while Date() < deadline {
            if case .failed = controller.phase { failed = true; break }
            try? await Task.sleep(for: .milliseconds(80))
        }
        #expect(failed, "ended in \(controller.phase) instead of reporting a failure")
        #expect(!controller.canSave)
    }
}
