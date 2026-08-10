import AppKit
import Foundation
import RipcordKit
import SwiftUI
import UniformTypeIdentifiers

/// Owns the one job the app does, and the state it moves through while doing it.
@MainActor
final class MasteringController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case reading(name: String)
        case working(name: String, stage: Masterer.Stage, progress: Double)
        case done(name: String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var report: Report?
    @Published var intensity: Intensity = .standard
    @Published private(set) var isDropTargeted = false

    let preview = AudioPreview()

    /// Where the last save landed, so the app can say so rather than leaving the user guessing.
    @Published private(set) var savedURL: URL?

    private var source: AudioIO.Audio?
    private var result: Masterer.Result?
    private var job: Task<Void, Never>?
    /// Distinguishes the current run from one the user has already superseded.
    private var generation = 0

    var canSave: Bool { result != nil && !(result?.unchanged ?? true) }

    var sourceName: String { source?.sourceURL.lastPathComponent ?? "" }

    // MARK: - Input

    func open() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .mp3, .wav, .aiff, .mpeg4Audio]
        panel.prompt = "Master"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url)
    }

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { [weak self] url, _ in
            guard let url else { return }
            Task { @MainActor in self?.load(url) }
        }
        return true
    }

    func setDropTargeted(_ targeted: Bool) { isDropTargeted = targeted }

    func load(_ url: URL) {
        guard AudioIO.canRead(url) else {
            phase = .failed("\(url.lastPathComponent) is not an audio file Ripcord can read.")
            return
        }
        job?.cancel()
        preview.stop()
        report = nil
        result = nil
        phase = .reading(name: url.lastPathComponent)

        job = Task { [intensity] in
            do {
                let audio = try await Task.detached(priority: .userInitiated) {
                    // A dropped file arrives with a sandbox extension that has to be claimed
                    // before it can be opened.
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    return try AudioIO.read(url)
                }.value
                guard !Task.isCancelled else { return }
                self.source = audio
                await self.run(audio: audio, intensity: intensity)
            } catch {
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Re-runs the chain when the intensity changes, reusing the decoded audio.
    ///
    /// The old result is dropped synchronously. Leaving it in place until the background task
    /// starts leaves a window where the report on screen and the Save button both belong to the
    /// previous intensity, so a quick click would write the wrong audio.
    func reprocess() {
        guard let source else { return }
        job?.cancel()
        preview.stop()
        result = nil
        report = nil
        savedURL = nil
        phase = .working(name: source.sourceURL.lastPathComponent, stage: .analyzing, progress: 0.01)
        job = Task { [intensity] in
            await self.run(audio: source, intensity: intensity)
        }
    }

    private func run(audio: AudioIO.Audio, intensity: Intensity) async {
        let name = audio.sourceURL.lastPathComponent
        generation &+= 1
        let token = generation
        phase = .working(name: name, stage: .analyzing, progress: 0.02)

        // Progress arrives off the main actor and is hopped back. A stale report from a
        // superseded run is dropped by the token, and one that lands after the result is
        // dropped by the phase check, so neither can knock the finished report off screen.
        let outcome = await MasteringJob.run(channels: audio.channels, sampleRate: audio.sampleRate,
                                             intensity: intensity) { [weak self] stage, progress in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                guard case .working = self.phase else { return }
                self.phase = .working(name: name, stage: stage, progress: progress)
            }
        }

        guard !Task.isCancelled, generation == token else { return }
        finish(outcome, name: name, audio: audio)
    }

    private func finish(_ outcome: Masterer.Result, name: String, audio: AudioIO.Audio) {
        result = outcome
        report = Report(result: outcome)
        savedURL = nil
        phase = .done(name: name)
        preview.load(original: audio.channels, mastered: outcome.channels,
                     sampleRate: audio.sampleRate,
                     loudnessGainDB: outcome.after.integratedLUFS - outcome.before.integratedLUFS)
    }

    // MARK: - Output

    func save() {
        guard let result, let source, !result.unchanged else { return }
        _ = result
        let panel = NSSavePanel()
        panel.nameFieldStringValue = AudioIO.defaultOutputURL(for: source.sourceURL).lastPathComponent
        panel.directoryURL = source.sourceURL.deletingLastPathComponent()
        panel.allowedContentTypes = [.wav]
        panel.prompt = "Save"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        save(to: url)
    }

    /// The write itself, split from the panel so the whole flow can be exercised in a test.
    func save(to url: URL) {
        guard let result, let source, !result.unchanged else { return }

        do {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            try AudioIO.writeWAV(channels: result.channels, sampleRate: source.sampleRate, to: url)

            // Confirm the bytes are really on disk before claiming success.
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes?[.size] as? Int) ?? 0
            guard size > 44 else {
                phase = .failed("The file was written but came back empty. Try a different location.")
                return
            }
            savedURL = url
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func revealSaved() {
        guard let savedURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([savedURL])
    }

    func copyReport() {
        guard let report else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report.plainText(), forType: .string)
    }

    func reset() {
        job?.cancel()
        preview.stop()
        source = nil
        result = nil
        report = nil
        phase = .idle
    }
}
