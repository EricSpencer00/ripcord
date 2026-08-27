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

    /// What a file was, as opposed to what it decoded to.
    ///
    /// Decoding always yields 32-bit float at the file's own rate, so the source's depth and codec
    /// are gone by the time anything downstream sees samples. They are captured here because a
    /// delivery claim about resolution is only evidence if the tool can say what it started from.
    public struct Format: Sendable, Equatable {
        public var sampleRate: Double
        /// Bits per sample of the stored file. Nil for a lossy codec, which has no sample depth.
        public var bitDepth: Int?
        /// Four-character codec name as the system reports it: "lpcm", "aac ", ".mp3", and so on.
        public var codec: String

        public init(sampleRate: Double, bitDepth: Int?, codec: String) {
            self.sampleRate = sampleRate; self.bitDepth = bitDepth; self.codec = codec
        }

        public var isLossless: Bool { bitDepth != nil }

        /// "48.0 kHz · 24-bit" or "44.1 kHz · AAC".
        public var summary: String {
            let rate = String(format: "%.1f kHz", sampleRate / 1000)
            if let bitDepth { return "\(rate) · \(bitDepth)-bit" }
            return "\(rate) · \(Self.codecLabel(codec))"
        }

        static func codecLabel(_ codec: String) -> String {
            switch codec.trimmingCharacters(in: .whitespaces).lowercased() {
            case "lpcm": return "PCM"
            case "aac", "aacl", "aach", "paac": return "AAC"
            case ".mp3", "mp3": return "MP3"
            case "alac": return "ALAC"
            case "flac": return "FLAC"
            default: return codec.trimmingCharacters(in: .whitespaces).uppercased()
            }
        }
    }

    public struct Audio: Sendable {
        public var channels: [[Float]]
        public var sampleRate: Double
        public var sourceURL: URL
        /// The format of the file on disk, before decoding.
        public var sourceFormat: Format

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

        // `processingFormat` is always 32-bit float, so the stored depth has to come from
        // `fileFormat`. It reads 0 for a lossy codec, which is genuinely "no sample depth"
        // rather than a missing value, and is recorded as nil rather than zero.
        let stored = file.fileFormat.streamDescription.pointee
        let depth = Int(stored.mBitsPerChannel)
        let sourceFormat = Format(sampleRate: file.fileFormat.sampleRate,
                                  bitDepth: depth > 0 ? depth : nil,
                                  codec: fourCharacterCode(stored.mFormatID))
        // The decode must not have resampled. AVAudioFile's processing format keeps the file's own
        // rate, and this is the assertion that says so out loud rather than assuming it.
        guard abs(format.sampleRate - file.fileFormat.sampleRate) < 1e-6 else {
            throw Failure.unreadable(url, "The decoder resampled the file, which would lose the source rate.")
        }

        return Audio(channels: channels, sampleRate: format.sampleRate, sourceURL: url,
                     sourceFormat: sourceFormat)
    }

    private static func fourCharacterCode(_ value: UInt32) -> String {
        let bytes = [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
                     UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
        let scalars = bytes.map { (32...126).contains($0) ? Character(UnicodeScalar($0)) : "?" }
        return String(scalars)
    }

    /// Bit depths this writer will produce. 24-bit is the delivery depth and the only one anything
    /// in the app asks for; the range exists so the parameter is explicit rather than implied.
    public static let supportedBitDepths = [24, 32]

    /// Writes PCM WAV at the sample rate it is handed, and never at any other. 24 bits leaves the
    /// noise floor far enough below the limiter's output that dither would be academic.
    ///
    /// There is deliberately no sample-rate argument. Apple asks for the highest native rate and
    /// does its own conversion, so a resampler here could only make the delivery worse; the way to
    /// guarantee that is to give the writer no way to change the rate at all.
    public static func writeWAV(channels: [[Float]], sampleRate: Double, bitDepth: Int = 24,
                                to url: URL) throws {
        precondition(supportedBitDepths.contains(bitDepth),
                     "unsupported delivery bit depth \(bitDepth)")
        let channelCount = AVAudioChannelCount(max(channels.count, 1))
        let frameCount = AVAudioFrameCount(channels.first?.count ?? 0)
        guard frameCount > 0 else { throw Failure.unwritable(url, "No audio to write.") }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: Int(channelCount),
            AVLinearPCMBitDepthKey: bitDepth,
            AVLinearPCMIsFloatKey: bitDepth == 32,
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
            // The rate that reached the file has to be the rate asked for, or the "no conversion"
            // claim in the report is unsupported.
            guard abs(file.fileFormat.sampleRate - sampleRate) < 1e-6 else {
                throw Failure.unwritable(url, "The writer changed the sample rate.")
            }
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
