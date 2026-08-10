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

    private var source: AudioIO.Audio?
    private var result: Masterer.Result?
    private var job: Task<Void, Never>?

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
                    try AudioIO.read(url)
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
    func reprocess() {
        guard let source else { return }
        job?.cancel()
        preview.stop()
        job = Task { [intensity] in
            await self.run(audio: source, intensity: intensity)
        }
    }

    private func run(audio: AudioIO.Audio, intensity: Intensity) async {
        let name = audio.sourceURL.lastPathComponent
        phase = .working(name: name, stage: .analyzing, progress: 0.02)

        let channels = audio.channels
        let sampleRate = audio.sampleRate

        // The chain is pure computation over value types, so it runs off the main actor and
        // reports back through a plain callback.
        let stream = AsyncStream<(Masterer.Stage, Double)> { continuation in
            let task = Task.detached(priority: .userInitiated) {
                let outcome = Masterer().master(channels: channels, sampleRate: sampleRate,
                                                intensity: intensity) { stage, progress in
                    continuation.yield((stage, progress))
                }
                continuation.finish()
                await MainActor.run { self.finish(outcome, name: name, audio: audio) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }

        for await (stage, progress) in stream {
            guard !Task.isCancelled else { return }
            if case .done = phase { continue }
            phase = .working(name: name, stage: stage, progress: progress)
        }
    }

    private func finish(_ outcome: Masterer.Result, name: String, audio: AudioIO.Audio) {
        guard !Task.isCancelled else { return }
        result = outcome
        report = Report(result: outcome)
        phase = .done(name: name)
        preview.load(original: audio.channels, mastered: outcome.channels,
                     sampleRate: audio.sampleRate,
                     loudnessGainDB: outcome.after.integratedLUFS - outcome.before.integratedLUFS)
    }

    // MARK: - Output

    func save() {
        guard let result, let source, !result.unchanged else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = AudioIO.defaultOutputURL(for: source.sourceURL).lastPathComponent
        panel.directoryURL = source.sourceURL.deletingLastPathComponent()
        panel.allowedContentTypes = [.wav]
        panel.prompt = "Save"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try AudioIO.writeWAV(channels: result.channels, sampleRate: source.sampleRate, to: url)
        } catch {
            phase = .failed(error.localizedDescription)
        }
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
