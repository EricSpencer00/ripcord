import AppKit
import Foundation
import RipcordKit
import SwiftUI
import UniformTypeIdentifiers

/// Owns the one job the app does, and the state it moves through while doing it.
///
/// There are two independent things going on, and they are kept as two properties rather than one
/// enum with a state for every pairing. `phase` is which screen is up — nothing loaded, reading a
/// file, working on the first master, showing a result, or explaining a failure. `regen` is what is
/// happening to the result that is already on screen — settled, waiting out a knob that is still
/// moving, or re-rendering. Folding them together would mean a state for every combination, and the
/// first casualty would be the one that matters: a live mixer has to keep the last good result
/// visible and audible while the next one renders, not blank the window back to a progress bar.
@MainActor
final class MasteringController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case reading(name: String)
        case working(name: String, stage: Masterer.Stage, progress: Double)
        case done(name: String)
        case failed(String)
    }

    /// The state of the result on screen relative to the mixer settings that produced it.
    enum Regen: Equatable {
        /// On screen matches the knobs. Nothing to do.
        case settled
        /// A knob has moved and the render is waiting for it to stop moving.
        case pending
        /// Rendering the current knobs. The previous result is still shown and still plays.
        case rendering(stage: Masterer.Stage, progress: Double)
        /// Running the delivery checks on a finished render. The master on screen is real; it just
        /// has no conformance rows yet, and the ceiling may still move if the AAC encode clips.
        case checking(progress: Double)

        var isBusy: Bool { self != .settled }
    }

    /// How long the knobs have to sit still before a render starts.
    ///
    /// Long enough that dragging a slider across its range does not queue up a render per frame,
    /// short enough that letting go feels like it took effect immediately.
    static let settleDelay = Duration.milliseconds(140)

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var regen: Regen = .settled
    @Published private(set) var report: Report?
    @Published private(set) var mixer = Mixer()
    /// What the tool decided on its own, so a knob at AUTO can still show the number it is using.
    @Published private(set) var design: MasterSettings?
    @Published private(set) var isDropTargeted = false

    let preview = AudioPreview()

    /// Where the last save landed, so the app can say so rather than leaving the user guessing.
    @Published private(set) var savedURL: URL?

    /// Set once a delivery target has been evaluated against the master on screen.
    @Published private(set) var conformance: Conformance?

    private var source: AudioIO.Audio?
    private var engine: MasteringEngine?
    private var result: Masterer.Result?
    /// The mixer the result on screen was rendered from. The gap between this and `mixer` is the
    /// whole of "is the report out of date", so it is one comparison rather than a dirty flag that
    /// can drift out of step with what was actually rendered.
    private var renderedMixer: Mixer?

    /// How many renders have actually delivered a result. The point of coalescing knob moves is
    /// that this stays small while a slider is dragged, which is otherwise invisible from outside.
    private(set) var completedRenders = 0

    private var loadTask: Task<Void, Never>?
    private var settleTask: Task<Void, Never>?
    private var renderTask: Task<Void, Never>?
    /// Distinguishes the current run from one the user has already superseded.
    private var generation = 0

    var canSave: Bool { result != nil && !(result?.unchanged ?? true) }

    /// True when the knobs have moved past what is on screen. The report is still real — it is just
    /// no longer the one the mixer describes.
    var isStale: Bool { renderedMixer != nil && renderedMixer != mixer }

    /// The mixer is only meaningful once there is something to mix.
    var isMixerEnabled: Bool {
        guard case .done = phase else { return false }
        return !(result?.unchanged ?? true)
    }

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
        cancelWork()
        preview.stop()
        preview.unload()
        report = nil
        result = nil
        design = nil
        engine = nil
        source = nil
        conformance = nil
        renderedMixer = nil
        savedURL = nil
        regen = .settled
        // A new file gets the automatic chain. Carrying a previous track's knobs onto it would be
        // applying decisions that were made about different audio.
        mixer = Mixer(intensity: mixer.intensity, delivery: mixer.delivery)
        phase = .reading(name: url.lastPathComponent)

        loadTask = Task {
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
                self.engine = MasteringEngine(channels: audio.channels, sampleRate: audio.sampleRate)
                self.commit()
                await self.renderTask?.value
            } catch {
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - The mixer

    /// Whether a knob move can lead anywhere.
    ///
    /// A file that came back untouched — silence, or nothing measurable — has no chain to adjust,
    /// and letting the knobs move anyway would leave the report permanently marked out of date
    /// against a render that is never going to happen.
    private var acceptsEdits: Bool {
        guard let result else { return true }
        return !result.unchanged
    }

    /// Moves one knob. `nil` hands it back to the automatic design.
    ///
    /// Called on every frame of a drag, so it does no work beyond marking the result stale and
    /// restarting the settle timer.
    func set(_ value: Double?, for knob: Mixer.Knob) {
        guard acceptsEdits, mixer[knob] != value else { return }
        mixer[knob] = value
        knobsMoved()
    }

    func reset(_ knob: Mixer.Knob) { set(nil, for: knob) }

    func resetAll() {
        guard acceptsEdits, mixer.isTouched else { return }
        mixer.resetAll()
        knobsMoved()
    }

    /// Choosing a preset is choosing a different automatic chain, so it returns every knob to AUTO.
    /// Leaving overrides in place would mean the preset visibly did not take effect.
    func select(_ intensity: Intensity) {
        guard acceptsEdits, mixer.intensity != intensity || mixer.isTouched else { return }
        mixer.intensity = intensity
        mixer.resetAll()
        knobsMoved()
        Task { await refreshDesign() }
    }

    /// Choosing a delivery target re-designs the chain — it can tighten the ceiling — and puts the
    /// ceiling knob back to AUTO so the target's number is what takes effect.
    func select(_ delivery: Delivery) {
        guard acceptsEdits, mixer.delivery != delivery else { return }
        mixer.delivery = delivery
        mixer.ceilingDBTP = nil
        conformance = nil
        knobsMoved()
        Task { await refreshDesign() }
    }

    private func knobsMoved() {
        guard engine != nil else { return }
        savedURL = nil
        // Whatever the checks said was about a master that no longer exists.
        conformance = nil
        // The in-flight render is already answering a question nobody is asking any more. Cancelling
        // it now frees the engine so the next one is not queued behind stale work; the passes it
        // finished stay cached, so nothing is wasted.
        renderTask?.cancel()
        settleTask?.cancel()
        regen = mixer == renderedMixer ? .settled : .pending
        guard regen == .pending else { return }
        settleTask = Task { [settleDelay = Self.settleDelay] in
            try? await Task.sleep(for: settleDelay)
            guard !Task.isCancelled else { return }
            self.commit()
        }
    }

    /// Starts a render of the knobs as they stand.
    private func commit() {
        guard let engine, let source else { return }
        settleTask?.cancel()
        settleTask = nil
        guard mixer != renderedMixer || result == nil else {
            regen = .settled
            return
        }
        renderTask?.cancel()
        generation &+= 1
        let token = generation
        let target = mixer
        renderTask = Task {
            await self.render(engine: engine, mixer: target, source: source, token: token)
        }
    }

    private func render(engine: MasteringEngine, mixer target: Mixer,
                        source: AudioIO.Audio, token: Int) async {
        let name = source.sourceURL.lastPathComponent
        let hasResult = result != nil
        show(.analyzing, 0, name: name, hasResult: hasResult, token: token)

        // Progress arrives off the main actor and is hopped back. A report from a superseded run is
        // dropped by the token, so a late one cannot knock the finished state off screen.
        let outcome = await engine.render(mixer: target) { [weak self] stage, progress in
            Task { @MainActor in
                self?.show(stage, progress, name: name, hasResult: hasResult, token: token)
            }
        }

        guard !Task.isCancelled, generation == token else { return }
        // A cancelled render returns nothing and leaves the last good result exactly where it is.
        guard let outcome else { return }
        finish(outcome, name: name, source: source, mixer: target)
        await refreshDesign()

        // The delivery checks are a second, slower pass. They run only once the fast render is on
        // screen and only when a target is selected, because an AAC round trip costs seconds and
        // would make the mixer unusable if it sat in the render path.
        guard target.delivery != .none, regen != .pending else { return }
        await check(engine: engine, mixer: target, source: source, name: name, token: token)
    }

    private func check(engine: MasteringEngine, mixer target: Mixer, source: AudioIO.Audio,
                       name: String, token: Int) async {
        regen = .checking(progress: 0)
        let outcome = await engine.conform(mixer: target) { [weak self] _, progress in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                guard case .checking = self.regen else { return }
                self.regen = .checking(progress: progress)
            }
        }
        guard !Task.isCancelled, generation == token, let outcome else { return }

        // The conformance pass can lower the ceiling, which changes the audio. Whatever it settled
        // on is what goes on screen and what gets saved, or the report would describe one file and
        // the Save button would write another.
        conformance = Conformance.evaluate(outcome, source: source.sourceFormat,
                                           outputBitDepth: target.delivery.bitDepth)
        finish(outcome.result, name: name, source: source, mixer: target)
    }

    /// One progress path, drawn two ways: as the working screen before there is a result, and as the
    /// live re-render indicator once there is one.
    private func show(_ stage: Masterer.Stage, _ progress: Double,
                      name: String, hasResult: Bool, token: Int) {
        guard generation == token else { return }
        if hasResult {
            guard case .done = phase else { return }
            regen = .rendering(stage: stage, progress: progress)
        } else {
            switch phase {
            case .reading, .working: phase = .working(name: name, stage: stage, progress: progress)
            default: return
            }
        }
    }

    private func finish(_ outcome: Masterer.Result, name: String,
                        source: AudioIO.Audio, mixer rendered: Mixer) {
        let isFirst = result == nil
        completedRenders += 1
        result = outcome
        report = Report(result: outcome, sourceFormat: source.sourceFormat,
                        conformance: conformance)
        renderedMixer = rendered
        savedURL = nil
        phase = .done(name: name)
        // A knob may have moved while this was rendering. If so the result is already stale and the
        // settle timer for the next render is running; saying `.settled` here would flash the mixer
        // as up to date for a frame. A target whose checks have not run yet is not settled either.
        if rendered != mixer {
            regen = .pending
        } else if rendered.delivery != .none && conformance == nil {
            regen = .checking(progress: 0)
        } else {
            regen = .settled
        }

        let gain = outcome.after.integratedLUFS - outcome.before.integratedLUFS
        if isFirst {
            preview.load(original: source.channels, mastered: outcome.channels,
                         sampleRate: source.sampleRate, loudnessGainDB: gain)
        } else {
            // The original never changes, so only the master is rebuilt — and playback carries on
            // through it, which is the point of a live mixer.
            preview.updateMastered(outcome.channels, loudnessGainDB: gain)
        }
    }

    private func refreshDesign() async {
        guard let engine else { return }
        design = await engine.design(for: mixer.intensity, delivery: mixer.delivery)
    }

    /// Renders anything outstanding and waits for it, so a caller that is about to read `result`
    /// gets the one the knobs describe rather than the one before the last move.
    func settle() async {
        settleTask?.cancel()
        settleTask = nil
        if mixer != renderedMixer { commit() }
        for _ in 0..<32 {
            guard regen != .settled else { return }
            guard let task = renderTask else { return }
            await task.value
        }
    }

    // MARK: - Output

    func save() {
        Task { await saveWithPanel() }
    }

    /// Flushes pending knob moves before asking where to put the file. Writing the previous render
    /// because the user hit Save mid-drag would put audio on disk that matches nothing on screen.
    private func saveWithPanel() async {
        await settle()
        guard let result, let source, !result.unchanged else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = AudioIO.defaultOutputURL(for: source.sourceURL).lastPathComponent
        panel.directoryURL = source.sourceURL.deletingLastPathComponent()
        panel.allowedContentTypes = [.wav]
        panel.prompt = "Save"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // The knobs cannot have moved during a modal panel, but re-reading the result rather than
        // capturing it above keeps the write and the check on the same value.
        save(to: url)
    }

    /// Renders anything outstanding and then writes it. This is what the Save button does once the
    /// panel has a destination, and what a test drives instead of the panel.
    func flushAndSave(to url: URL) async {
        await settle()
        save(to: url)
    }

    /// The write itself, split from the panel so the whole flow can be exercised in a test.
    func save(to url: URL) {
        guard let result, let source, !result.unchanged else { return }

        do {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            // The rate written is the rate that arrived. There is deliberately no path here that
            // could resample: Apple asks for the highest native rate and converts at its own end.
            guard abs(result.after.sampleRate - source.sampleRate) < 1e-6 else {
                phase = .failed("The master's sample rate no longer matches the source. Nothing was written.")
                return
            }
            try AudioIO.writeWAV(channels: result.channels, sampleRate: source.sampleRate,
                                 bitDepth: mixer.delivery.bitDepth, to: url)

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
        cancelWork()
        preview.stop()
        preview.unload()
        source = nil
        engine = nil
        result = nil
        report = nil
        design = nil
        conformance = nil
        renderedMixer = nil
        savedURL = nil
        regen = .settled
        mixer = Mixer(intensity: mixer.intensity, delivery: mixer.delivery)
        phase = .idle
    }

    private func cancelWork() {
        loadTask?.cancel()
        settleTask?.cancel()
        renderTask?.cancel()
        loadTask = nil
        settleTask = nil
        renderTask = nil
        generation &+= 1
    }
}
