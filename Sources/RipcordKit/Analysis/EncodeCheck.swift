@preconcurrency import AVFoundation
import Foundation

/// Encodes a master to AAC and decodes it back, so the thing that gets measured is the thing a
/// listener will actually hear.
///
/// This exists because the check cannot be done on the PCM master. Apple's own guidance is explicit
/// about why — "levels that don't show overs on PCM can still cause clipping when encoded"
/// (*Apple Digital Masters*, April 2021) — and the reason is that a lossy codec reconstructs a
/// waveform that does not pass through the original sample points. A file sitting exactly at
/// 0 dBFS comes back over it.
///
/// **This is an approximation of Apple's ingest, not a reproduction of it.** It uses the system
/// AAC encoder through `AVAudioConverter` at the same nominal rate Apple states (256 kbps), but it
/// is not the same invocation as Apple's `afconvert` command line and the encoders may differ in
/// version and settings. A pass here is evidence that the master has sensible headroom, not a
/// guarantee about Apple's own encode. Nothing built on it may say otherwise.
///
/// Shelling out to `afconvert` or `afclip` is not an option: the app is sandboxed, and spawning
/// executables outside the bundle is exactly what that sandbox forbids.
public enum EncodeCheck {
    /// Apple states 256 kbps AAC for the Apple Music catalogue.
    public static let targetBitRate = 256_000

    public enum Failure: LocalizedError {
        case unavailable(String)

        public var errorDescription: String? {
            switch self {
            case .unavailable(let reason): return "The AAC encode check could not run. \(reason)"
            }
        }
    }

    public struct Result: Sendable, Equatable {
        /// True peak of the decoded audio, measured the same way as everything else in the report.
        public var truePeakDBTP: Double
        /// Sample peak of the decoded audio. Above 0 dBFS means the decode itself went over.
        public var peakDBFS: Double
        /// How many decoded samples sit above full scale.
        public var samplesOverFullScale: Int
        /// Index of the first such sample, for anyone who wants to go and listen to it.
        public var firstOverSampleIndex: Int?
        /// How far the worst one went over, in dB. Zero when nothing went over.
        public var worstOvershootDB: Double
        /// What the encoder was actually configured at, read back rather than assumed.
        public var bitRate: Int

        public var clips: Bool { samplesOverFullScale > 0 }
    }

    /// Encodes, decodes, and measures. Synchronous and CPU-bound; call it off the main actor.
    public static func measure(channels: [[Float]], sampleRate: Double,
                               bitRate: Int = targetBitRate) throws -> Result {
        let decoded = try roundTrip(channels: channels, sampleRate: sampleRate, bitRate: bitRate)
        guard let first = decoded.first, !first.isEmpty else {
            throw Failure.unavailable("The decode produced no audio.")
        }

        var peak: Float = 0
        var overs = 0
        var firstOver: Int?
        for channel in decoded {
            for (index, value) in channel.enumerated() {
                let magnitude = abs(value)
                if magnitude > peak { peak = magnitude }
                if magnitude > 1.0 {
                    overs += 1
                    if firstOver == nil || index < firstOver! { firstOver = index }
                }
            }
        }
        let peakDB = 20 * log10(max(Double(peak), 1e-12))
        return Result(truePeakDBTP: TruePeakMeter().truePeakDBTP(decoded),
                      peakDBFS: peakDB,
                      samplesOverFullScale: overs,
                      firstOverSampleIndex: overs > 0 ? firstOver : nil,
                      worstOvershootDB: max(peakDB, 0),
                      bitRate: bitRate)
    }

    /// The round trip itself, exposed so a test can look at the decoded audio directly.
    public static func roundTrip(channels: [[Float]], sampleRate: Double,
                                 bitRate: Int = targetBitRate) throws -> [[Float]] {
        guard let source = channels.first, !source.isEmpty else {
            throw Failure.unavailable("There is no audio to encode.")
        }
        let channelCount = max(channels.count, 1)
        guard let pcmFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate,
                                            channels: AVAudioChannelCount(channelCount)),
              let input = AVAudioPCMBuffer(pcmFormat: pcmFormat,
                                           frameCapacity: AVAudioFrameCount(source.count)) else {
            throw Failure.unavailable("Could not prepare a buffer at \(sampleRate) Hz.")
        }
        input.frameLength = AVAudioFrameCount(source.count)
        for c in 0..<channelCount {
            let channel = channels[min(c, channels.count - 1)]
            channel.withUnsafeBufferPointer {
                input.floatChannelData![c].update(from: $0.baseAddress!, count: channel.count)
            }
        }

        let aacSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
        ]
        guard let aacFormat = AVAudioFormat(settings: aacSettings) else {
            throw Failure.unavailable("This system has no AAC encoder for \(channelCount) channels at \(sampleRate) Hz.")
        }
        guard let encoder = AVAudioConverter(from: pcmFormat, to: aacFormat),
              let decoder = AVAudioConverter(from: aacFormat, to: pcmFormat) else {
            throw Failure.unavailable("Could not open the AAC converters.")
        }

        // Two traps, both found by measurement rather than from the documentation:
        //
        // 1. `AVEncoderBitRateKey` in the format settings is ignored outright — the converter comes
        //    up at 128 kbps regardless.
        // 2. `AVAudioBitRateStrategy_Variable` silently *resets* `bitRate` back to 128 kbps and
        //    ignores any later assignment, because true VBR is driven by quality and not by a rate.
        //    `_LongTermAverage` is the strategy that accepts a rate, and is the closest thing this
        //    API offers to the 256 kbps Apple quotes.
        //
        // Neither failure is reported as an error, so the rate is read back and checked. Silently
        // testing at 128 kbps would make the check harsher than reality and the report wrong.
        encoder.bitRateStrategy = AVAudioBitRateStrategy_LongTermAverage
        encoder.bitRate = bitRate
        guard encoder.bitRate == bitRate else {
            throw Failure.unavailable("The encoder would not accept \(bitRate) bps; it reports \(encoder.bitRate).")
        }

        // The converter's input block is `@Sendable`, so the pull cursor cannot be a captured var.
        let cursor = Cursor()
        var packets: [AVAudioCompressedBuffer] = []
        let chunk: AVAudioFrameCount = 4096

        while true {
            let packet = AVAudioCompressedBuffer(format: aacFormat, packetCapacity: 8,
                                                 maximumPacketSize: encoder.maximumOutputPacketSize)
            var error: NSError?
            let status = encoder.convert(to: packet, error: &error) { _, outStatus in
                let remaining = AVAudioFrameCount(Int64(input.frameLength) - cursor.frame)
                guard remaining > 0 else { outStatus.pointee = .endOfStream; return nil }
                let take = min(chunk, remaining)
                guard let slice = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: take) else {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                slice.frameLength = take
                for c in 0..<channelCount {
                    slice.floatChannelData![c].update(
                        from: input.floatChannelData![c].advanced(by: Int(cursor.frame)),
                        count: Int(take))
                }
                cursor.frame += Int64(take)
                outStatus.pointee = .haveData
                return slice
            }
            if let error { throw Failure.unavailable(error.localizedDescription) }
            if packet.packetCount > 0 { packets.append(packet) }
            if status == .endOfStream || status == .error { break }
        }
        guard !packets.isEmpty else { throw Failure.unavailable("The encoder produced no packets.") }

        var output = [[Float]](repeating: [], count: channelCount)
        while true {
            guard let out = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: 16384) else {
                throw Failure.unavailable("Could not allocate the decode buffer.")
            }
            var error: NSError?
            let status = decoder.convert(to: out, error: &error) { _, outStatus in
                guard cursor.packet < packets.count else { outStatus.pointee = .endOfStream; return nil }
                defer { cursor.packet += 1 }
                outStatus.pointee = .haveData
                return packets[cursor.packet]
            }
            if let error { throw Failure.unavailable(error.localizedDescription) }
            for c in 0..<channelCount {
                output[c].append(contentsOf: UnsafeBufferPointer(start: out.floatChannelData![c],
                                                                 count: Int(out.frameLength)))
            }
            if status == .endOfStream || status == .error { break }
        }
        return output
    }

    private final class Cursor: @unchecked Sendable {
        var frame: AVAudioFramePosition = 0
        var packet = 0
    }
}
