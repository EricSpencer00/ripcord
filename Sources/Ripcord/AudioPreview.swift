import AVFoundation
import Combine
import Foundation
import RipcordKit

/// Gapless A/B playback of the original and the master.
///
/// Both versions are scheduled on their own player node at the same sample time and both play
/// continuously; switching sides only changes which node is audible. That way the comparison
/// happens at the same instant in the music, with no reschedule, gap, or click.
@MainActor
final class AudioPreview: ObservableObject {
    enum Side: String {
        case original = "ORIGINAL"
        case mastered = "MASTERED"

        var flipped: Side { self == .original ? .mastered : .original }
    }

    @Published private(set) var isPlaying = false
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published var side: Side = .mastered { didSet { applyMix() } }

    /// Comparing a -16 LUFS original against a -11 LUFS master is not a comparison, it is a
    /// volume test — the louder one always wins. Matching levels is the honest default.
    @Published var levelMatched = true { didSet { applyMix() } }

    private let engine = AVAudioEngine()
    private let originalPlayer = AVAudioPlayerNode()
    private let masteredPlayer = AVAudioPlayerNode()
    private var originalBuffer: AVAudioPCMBuffer?
    private var masteredBuffer: AVAudioPCMBuffer?
    private var sampleRate: Double = 48000
    private var startOffset: AVAudioFramePosition = 0
    private var ticker: Timer?
    /// dB to take off the master so the two sides sit at the same loudness.
    private var matchOffsetDB: Double = 0

    init() {
        for node in [originalPlayer, masteredPlayer] { engine.attach(node) }
    }

    func load(original: [[Float]], mastered: [[Float]], sampleRate: Double, loudnessGainDB: Double) {
        stop()
        self.sampleRate = sampleRate
        matchOffsetDB = -max(loudnessGainDB, 0)

        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate,
                                         channels: AVAudioChannelCount(max(original.count, 1))) else { return }
        originalBuffer = Self.makeBuffer(original, format: format)
        masteredBuffer = Self.makeBuffer(mastered, format: format)
        duration = Double(original.first?.count ?? 0) / sampleRate
        position = 0

        engine.connect(originalPlayer, to: engine.mainMixerNode, format: format)
        engine.connect(masteredPlayer, to: engine.mainMixerNode, format: format)
        applyMix()
    }

    /// Swaps in a freshly rendered master without disturbing the original or the transport.
    ///
    /// A live mixer is only live if it can be heard, so this deliberately does not stop playback.
    /// Rebuilding only the master matters too: the original is unchanged by definition, and copying
    /// a full-length track into a new buffer on every knob move is exactly the kind of work that
    /// turns a live control into a stuttering one.
    func updateMastered(_ channels: [[Float]], loudnessGainDB: Double) {
        guard let format = originalBuffer?.format else { return }
        matchOffsetDB = -max(loudnessGainDB, 0)
        masteredBuffer = Self.makeBuffer(channels, format: format)
        applyMix()
        // Both nodes are scheduled together, so the new buffer only becomes audible by restarting
        // them both from where the playhead is now. Seeking to the current position does that and
        // keeps the two sides sample-aligned, at the cost of a gap too short to hear as a break.
        if isPlaying { seek(to: position) }
    }

    /// Drops both buffers, for when there is no longer a track to compare.
    func unload() {
        stop()
        originalBuffer = nil
        masteredBuffer = nil
        duration = 0
        position = 0
    }

    private static func makeBuffer(_ channels: [[Float]], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(channels.first?.count ?? 0)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let data = buffer.floatChannelData else { return nil }
        buffer.frameLength = frames
        for channel in 0..<Int(format.channelCount) {
            let source = channels[min(channel, channels.count - 1)]
            source.withUnsafeBufferPointer {
                data[channel].update(from: $0.baseAddress!, count: source.count)
            }
        }
        return buffer
    }

    // MARK: - Transport

    func toggle() { isPlaying ? pause() : play() }

    func play() {
        guard let originalBuffer, let masteredBuffer else { return }
        if position >= duration - 0.05 { position = 0 }

        do {
            engine.prepare()
            if !engine.isRunning { try engine.start() }
        } catch {
            return
        }

        let frame = AVAudioFramePosition(position * sampleRate)
        startOffset = frame
        schedule(originalBuffer, on: originalPlayer, from: frame)
        schedule(masteredBuffer, on: masteredPlayer, from: frame)

        originalPlayer.play()
        masteredPlayer.play()
        isPlaying = true
        startTicking()
    }

    private func schedule(_ buffer: AVAudioPCMBuffer, on player: AVAudioPlayerNode,
                          from frame: AVAudioFramePosition) {
        player.stop()
        let remaining = AVAudioFrameCount(max(Int64(buffer.frameLength) - frame, 0))
        guard remaining > 0 else { return }
        player.scheduleBuffer(bufferSegment(buffer, from: frame, length: remaining), at: nil)
    }

    /// `scheduleSegment` only works on files, so playing from an offset means slicing the buffer.
    private func bufferSegment(_ buffer: AVAudioPCMBuffer, from frame: AVAudioFramePosition,
                               length: AVAudioFrameCount) -> AVAudioPCMBuffer {
        guard frame > 0,
              let segment = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: length),
              let source = buffer.floatChannelData, let destination = segment.floatChannelData
        else { return buffer }
        segment.frameLength = length
        for channel in 0..<Int(buffer.format.channelCount) {
            destination[channel].update(from: source[channel].advanced(by: Int(frame)), count: Int(length))
        }
        return segment
    }

    func pause() {
        originalPlayer.pause()
        masteredPlayer.pause()
        isPlaying = false
        stopTicking()
    }

    func stop() {
        originalPlayer.stop()
        masteredPlayer.stop()
        if engine.isRunning { engine.stop() }
        isPlaying = false
        position = 0
        stopTicking()
    }

    func seek(to seconds: Double) {
        let clamped = min(max(seconds, 0), max(duration - 0.01, 0))
        let wasPlaying = isPlaying
        if wasPlaying { pause() }
        position = clamped
        if wasPlaying { play() }
    }

    func flip() { side = side.flipped }

    // MARK: - Mix

    private func applyMix() {
        let match = levelMatched ? Float(pow(10, matchOffsetDB / 20)) : 1
        originalPlayer.volume = side == .original ? 1 : 0
        masteredPlayer.volume = side == .mastered ? match : 0
    }

    // MARK: - Position

    private func startTicking() {
        stopTicking()
        let timer = Timer(timeInterval: 1.0 / 24.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTicking() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        guard isPlaying,
              let nodeTime = masteredPlayer.lastRenderTime,
              let playerTime = masteredPlayer.playerTime(forNodeTime: nodeTime) else { return }
        let elapsed = Double(playerTime.sampleTime) / playerTime.sampleRate
        position = min(Double(startOffset) / sampleRate + elapsed, duration)
        if position >= duration - 0.02 {
            pause()
            position = 0
        }
    }
}
