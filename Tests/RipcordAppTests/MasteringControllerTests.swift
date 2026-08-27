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
@Suite("Mastering controller", .timeLimit(.minutes(5)), .serialized)
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
    static func waitUntilDone(_ controller: MasteringController, timeout: Double = 240) async -> Bool {
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

    @Test("Changing preset re-renders and lands on the new target")
    func changingPreset() async throws {
        let url = try Self.makeTestFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let controller = MasteringController()
        controller.load(url)
        #expect(await Self.waitUntilDone(controller))

        controller.select(.loud)
        await controller.settle()

        let destination = url.deletingLastPathComponent().appendingPathComponent("loud.wav")
        controller.save(to: destination)
        let written = try AudioIO.read(destination)
        let measured = Analyzer.analyze(channels: written.channels, sampleRate: written.sampleRate)
        #expect(abs(measured.integratedLUFS - (-9)) < 0.3, "measured \(measured.integratedLUFS)")
    }

    // MARK: - The live mixer

    /// The behaviour the mixer exists for: the report and the audio stay put while the next render
    /// happens behind them, instead of the window dropping back to a progress bar.
    @Test("A knob move keeps the report on screen and marks it stale")
    func knobMoveKeepsTheResult() async throws {
        let url = try Self.makeTestFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let controller = MasteringController()
        controller.load(url)
        #expect(await Self.waitUntilDone(controller))
        let firstHeadline = controller.report?.headline

        controller.set(-15, for: .targetLUFS)
        #expect(controller.phase == .done(name: url.lastPathComponent), "the window changed screens")
        #expect(controller.report != nil, "the report was thrown away mid-edit")
        #expect(controller.isStale, "the report is not marked as out of date")
        #expect(controller.regen == .pending)

        await controller.settle()
        #expect(controller.regen == .settled)
        #expect(!controller.isStale)
        #expect(controller.report?.headline != firstHeadline, "the report did not follow the knob")
    }

    /// A drag emits a value per frame. Rendering each one would be both useless and unusable.
    @Test("A drag across a slider renders once, for where it stopped")
    func dragCoalescesIntoOneRender() async throws {
        let url = try Self.makeTestFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let controller = MasteringController()
        controller.load(url)
        #expect(await Self.waitUntilDone(controller))
        let baseline = controller.completedRenders

        for step in 0..<40 {
            controller.set(-18 + Double(step) * 0.2, for: .targetLUFS)
        }
        await controller.settle()

        let renders = controller.completedRenders - baseline
        #expect(renders <= 2, "rendered \(renders) times for one drag")
        #expect(controller.mixer.targetLUFS == -10.2)
    }

    /// Hitting Save mid-drag must not write the render from before the last move.
    @Test("Saving flushes pending knob moves first")
    func savingFlushesPendingEdits() async throws {
        let url = try Self.makeTestFile()
        let directory = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }

        let controller = MasteringController()
        controller.load(url)
        #expect(await Self.waitUntilDone(controller))

        let destination = directory.appendingPathComponent("flushed.wav")
        controller.set(-14, for: .targetLUFS)
        #expect(controller.regen == .pending, "nothing was pending, so this proves nothing")
        await controller.flushAndSave(to: destination)

        let written = try AudioIO.read(destination)
        let measured = Analyzer.analyze(channels: written.channels, sampleRate: written.sampleRate)
        #expect(abs(measured.integratedLUFS - (-14)) < 0.3,
                "saved the render from before the move: \(measured.integratedLUFS)")
    }

    @Test("Handing a knob back returns the automatic master exactly")
    func resettingReturnsTheAutomaticMaster() async throws {
        let url = try Self.makeTestFile()
        let directory = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }

        let controller = MasteringController()
        controller.load(url)
        #expect(await Self.waitUntilDone(controller))
        let automatic = directory.appendingPathComponent("auto.wav")
        controller.save(to: automatic)

        controller.set(1.5, for: .width)
        controller.set(3, for: .bassTrimDB)
        await controller.settle()
        #expect(controller.mixer.isTouched)

        controller.resetAll()
        await controller.settle()
        #expect(!controller.mixer.isTouched)
        #expect(!controller.isStale)

        let restored = directory.appendingPathComponent("restored.wav")
        controller.save(to: restored)
        let a = try AudioIO.read(automatic)
        let b = try AudioIO.read(restored)
        #expect(a.channels == b.channels, "resetting did not return the original master")
    }

    /// Playback is the point of a live mixer, so a re-render must not tear the transport down.
    @Test("Re-rendering keeps the loaded preview rather than reloading it")
    func rerenderKeepsThePreview() async throws {
        let url = try Self.makeTestFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let controller = MasteringController()
        controller.load(url)
        #expect(await Self.waitUntilDone(controller))
        let duration = controller.preview.duration
        #expect(duration > 0)

        controller.set(1.4, for: .compression)
        await controller.settle()
        #expect(controller.preview.duration == duration, "the preview was torn down and rebuilt")
    }

    @Test("A new file hands every knob back to the analysis")
    func loadingClearsTheMixer() async throws {
        let first = try Self.makeTestFile()
        let second = try Self.makeTestFile()
        defer {
            try? FileManager.default.removeItem(at: first.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: second.deletingLastPathComponent())
        }

        let controller = MasteringController()
        controller.load(first)
        #expect(await Self.waitUntilDone(controller))
        controller.set(-16, for: .targetLUFS)
        controller.select(.loud)

        controller.load(second)
        #expect(await Self.waitUntilDone(controller))
        #expect(!controller.mixer.isTouched, "carried a knob onto a different track")
        #expect(controller.mixer.intensity == .loud, "the preset should survive the new file")
        #expect(!controller.isStale)
    }

    /// The delivery pass is slow, so it must not sit in the render path. What the controller has to
    /// get right is that the master appears first and the claims about it appear after.
    @Test("Choosing a delivery target checks the master after showing it")
    func deliveryChecksAfterRendering() async throws {
        let url = try Self.makeTestFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let controller = MasteringController()
        controller.load(url)
        #expect(await Self.waitUntilDone(controller))
        #expect(controller.conformance == nil, "checks appeared without a target being chosen")

        controller.select(Delivery.appleMusic)
        await controller.settle()

        let conformance = try #require(controller.conformance, "the checks never ran")
        #expect(controller.phase == .done(name: url.lastPathComponent))
        #expect(controller.regen == .settled)
        #expect(conformance.delivery == .appleMusic)
        #expect(controller.report?.conformance != nil, "the report did not pick the checks up")
        #expect(controller.report?.plainText().contains("CHECKED AGAINST") == true)

        // The fixture is a 24-bit file at its native rate with a conforming ceiling, so everything
        // it can control should pass.
        #expect(conformance.passed, "checks not met:\n\(conformance.plainText())")
    }

    /// The conformance pass can turn the master down, and if the saved file were the pre-trim
    /// render the report would describe one file while Save wrote another.
    @Test("Saving after a delivery check writes the checked master")
    func savingWritesTheCheckedMaster() async throws {
        let url = try Self.makeTestFile()
        let directory = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }

        let controller = MasteringController()
        controller.load(url)
        #expect(await Self.waitUntilDone(controller))
        controller.select(Delivery.appleMusic)
        await controller.settle()
        let conformance = try #require(controller.conformance)

        let destination = directory.appendingPathComponent("delivered.wav")
        await controller.flushAndSave(to: destination)

        let written = try AudioIO.read(destination)
        #expect(written.sourceFormat.bitDepth == 24)
        #expect(written.sampleRate == 48000, "the delivery write resampled")

        // The headroom claim has to hold on the bytes that landed on disk.
        let peak = TruePeakMeter.certification.truePeakDBTP(written.channels)
        #expect(peak <= -1.0 + 0.01, "the saved file measures \(peak) dBTP")
        #expect(conformance.passed)
    }

    @Test("Moving a knob withdraws the checks until they are re-run")
    func editingWithdrawsTheChecks() async throws {
        let url = try Self.makeTestFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let controller = MasteringController()
        controller.load(url)
        #expect(await Self.waitUntilDone(controller))
        controller.select(Delivery.appleMusic)
        await controller.settle()
        #expect(controller.conformance != nil)

        controller.set(-15, for: .targetLUFS)
        #expect(controller.conformance == nil,
                "the old checks were left standing against a master that no longer exists")

        await controller.settle()
        #expect(controller.conformance != nil, "the checks did not re-run")
        #expect(controller.regen == .settled)
    }

    @Test("A silent file leaves nothing to mix")
    func silenceDisablesTheMixer() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ripcord-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("silence.wav")
        let silence = [[Float]](repeating: [Float](repeating: 0, count: 48000), count: 2)
        try AudioIO.writeWAV(channels: silence, sampleRate: 48000, to: url)

        let controller = MasteringController()
        controller.load(url)
        #expect(await Self.waitUntilDone(controller))
        #expect(!controller.isMixerEnabled)
        #expect(!controller.canSave)

        // A knob move on a file with nothing in it must not start a render that cannot help.
        controller.set(-9, for: .targetLUFS)
        #expect(controller.regen == .settled)
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
