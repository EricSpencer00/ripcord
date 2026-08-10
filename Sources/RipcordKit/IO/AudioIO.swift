import AVFoundation
import Foundation

/// File decode and encode. The only part of the pipeline that touches the system audio stack.
public enum AudioIO {
    public enum Failure: LocalizedError {
        case unreadable(URL, String)
        case emptyFile(URL)
        case unwritable(URL, String)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let url, let reason):
                return "Could not read \(url.lastPathComponent). \(reason)"
            case .emptyFile(let url):
                return "\(url.lastPathComponent) contains no audio."
            case .unwritable(let url, let reason):
                return "Could not write \(url.lastPathComponent). \(reason)"
            }
        }
    }

    public struct Audio: Sendable {
        public var channels: [[Float]]
        public var sampleRate: Double
        public var sourceURL: URL

        public var frameCount: Int { channels.first?.count ?? 0 }
        public var durationSeconds: Double { Double(frameCount) / sampleRate }
    }

    /// Extensions CoreAudio will decode on macOS without any extra components.
    public static let supportedExtensions: Set<String> = [
        "wav", "wave", "mp3", "m4a", "aac", "aif", "aiff", "aifc", "caf", "flac", "mp4",
    ]

    public static func canRead(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    public static func read(_ url: URL) throws -> Audio {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw Failure.unreadable(url, error.localizedDescription)
        }

        let format = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0 else { throw Failure.emptyFile(url) }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw Failure.unreadable(url, "Could not allocate a buffer for \(frames) frames.")
        }
        do {
            try file.read(into: buffer)
        } catch {
            throw Failure.unreadable(url, error.localizedDescription)
        }
        guard let data = buffer.floatChannelData else {
            throw Failure.unreadable(url, "Unexpected sample format.")
        }

        let count = Int(buffer.frameLength)
        guard count > 0 else { throw Failure.emptyFile(url) }
        let channelCount = Int(format.channelCount)
        var channels = [[Float]]()
        for c in 0..<channelCount {
            channels.append(Array(UnsafeBufferPointer(start: data[c], count: count)))
        }
        // Everything downstream assumes one or two channels; fold anything wider down to stereo.
        if channels.count > 2 { channels = Array(channels.prefix(2)) }

        return Audio(channels: channels, sampleRate: format.sampleRate, sourceURL: url)
    }

    /// Writes 24-bit PCM WAV at the source sample rate. 24 bits leaves the noise floor far enough
    /// below the limiter's output that dither would be academic.
    public static func writeWAV(channels: [[Float]], sampleRate: Double, to url: URL) throws {
        let channelCount = AVAudioChannelCount(max(channels.count, 1))
        let frameCount = AVAudioFrameCount(channels.first?.count ?? 0)
        guard frameCount > 0 else { throw Failure.unwritable(url, "No audio to write.") }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: Int(channelCount),
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]

        guard let processingFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate,
                                                   channels: channelCount),
              let buffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: frameCount),
              let data = buffer.floatChannelData else {
            throw Failure.unwritable(url, "Could not prepare the output buffer.")
        }
        buffer.frameLength = frameCount
        for c in 0..<Int(channelCount) {
            let source = channels[min(c, channels.count - 1)]
            source.withUnsafeBufferPointer { data[c].update(from: $0.baseAddress!, count: source.count) }
        }

        do {
            let file = try AVAudioFile(forWriting: url, settings: settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        } catch {
            throw Failure.unwritable(url, error.localizedDescription)
        }
    }

    /// `Song.wav` becomes `Song (mastered).wav`, without stacking suffixes on repeated runs.
    public static func defaultOutputURL(for source: URL) -> URL {
        let base = source.deletingPathExtension().lastPathComponent
        let stem = base.hasSuffix(" (mastered)") ? base : base + " (mastered)"
        return source.deletingLastPathComponent()
            .appendingPathComponent(stem)
            .appendingPathExtension("wav")
    }
}
