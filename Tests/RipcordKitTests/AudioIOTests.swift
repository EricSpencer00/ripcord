import AVFoundation
import Foundation
import Testing
@testable import RipcordKit

/// The delivery claims rest on two facts about file I/O: the depth written is the depth asked for,
/// and the rate that arrives is the rate that leaves. Both are checked against files on disk rather
/// than against the settings dictionary that was meant to produce them.
@Suite("Audio file I/O", .timeLimit(.minutes(5)))
struct AudioIOTests {
    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ripcord-io-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Deterministic content with samples spread across the range, so quantisation error shows up.
    static func content(sampleRate: Double, seconds: Double = 1) -> [[Float]] {
        let count = Int(sampleRate * seconds)
        var random = Signal.Random(seed: 0xB17DE7)
        let left = (0..<count).map { i -> Float in
            Float(0.7 * sin(2 * .pi * 220 * Double(i) / sampleRate) + 0.2 * random.next())
        }
        let right = left.map { $0 * 0.93 }
        return [left, right]
    }

    @Test("A 24-bit round trip returns the same samples within one quantisation step")
    func roundTripIsExactToTheStep() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("round-trip.wav")

        let original = Self.content(sampleRate: 48000)
        try AudioIO.writeWAV(channels: original, sampleRate: 48000, bitDepth: 24, to: url)
        let read = try AudioIO.read(url)

        #expect(read.channels.count == 2)
        #expect(read.frameCount == original[0].count)

        // A 24-bit sample is quantised to steps of 2^-23 about full scale. Anything larger than one
        // step means something other than quantisation happened on the way through.
        let step = Float(pow(2.0, -23.0))
        var worst: Float = 0
        for channel in original.indices {
            for i in original[channel].indices {
                worst = max(worst, abs(original[channel][i] - read.channels[channel][i]))
            }
        }
        #expect(worst <= step, "worst difference \(worst) exceeds the 24-bit step \(step)")
    }

    @Test("A multichannel source is rejected instead of being silently truncated")
    func rejectsMultichannelSource() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("surround.wav")
        let frames = 4800
        let layout = try #require(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_MPEG_5_1_A))
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channelLayout: layout)
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<Int(format.channelCount) {
            for frame in 0..<frames {
                buffer.floatChannelData![channel][frame] = Float(channel + 1) / 10
            }
        }
        do {
            var settings = format.settings
            settings[AVLinearPCMIsNonInterleaved] = false
            let file = try AVAudioFile(forWriting: url, settings: settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        }

        do {
            _ = try AudioIO.read(url)
            #expect(Bool(false), "a multichannel source was accepted")
        } catch let error as AudioIO.Failure {
            guard case .unsupportedChannelCount(let receivedURL, let count) = error else {
                #expect(Bool(false), "unexpected AudioIO failure: \(error.localizedDescription)")
                return
            }
            #expect(receivedURL == url)
            #expect(count == 6)
            #expect(error.localizedDescription.contains("mono or stereo"))
        }
    }

    @Test("The written file really is 24-bit at the rate it was handed",
          arguments: [44100.0, 48000.0, 96000.0])
    func writesTheStatedFormat(rate: Double) throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("stated.wav")

        try AudioIO.writeWAV(channels: Self.content(sampleRate: rate, seconds: 0.5),
                             sampleRate: rate, bitDepth: 24, to: url)
        let read = try AudioIO.read(url)

        #expect(read.sourceFormat.bitDepth == 24, "wrote \(String(describing: read.sourceFormat.bitDepth))-bit")
        #expect(read.sourceFormat.sampleRate == rate)
        #expect(read.sampleRate == rate, "the decode resampled")
        #expect(read.sourceFormat.isLossless)
    }

    /// Apple asks for the highest native rate and performs its own conversion, so the only correct
    /// behaviour here is to convert nothing — in either direction.
    @Test("Nothing in the path changes the sample rate",
          arguments: [44100.0, 48000.0, 88200.0, 96000.0])
    func rateSurvives(rate: Double) throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("in.wav")
        let output = directory.appendingPathComponent("out.wav")

        try AudioIO.writeWAV(channels: Self.content(sampleRate: rate, seconds: 0.5),
                             sampleRate: rate, to: input)
        let read = try AudioIO.read(input)
        let mastered = Masterer().master(channels: read.channels, sampleRate: read.sampleRate,
                                         intensity: .standard)
        try AudioIO.writeWAV(channels: mastered.channels, sampleRate: read.sampleRate, to: output)

        let final = try AudioIO.read(output)
        #expect(final.sampleRate == rate)
        #expect(final.sourceFormat.sampleRate == rate)
        #expect(mastered.after.sampleRate == rate)
    }

    @Test("The source format is captured, not inferred from the decode")
    func capturesSourceFormat() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("thirty-two.wav")

        // Written as 32-bit float. The decode is float32 either way, so a format read off the
        // processing format would report the same thing for a 24-bit file and be useless.
        try AudioIO.writeWAV(channels: Self.content(sampleRate: 48000, seconds: 0.3),
                             sampleRate: 48000, bitDepth: 32, to: url)
        let read = try AudioIO.read(url)
        #expect(read.sourceFormat.bitDepth == 32)
        #expect(read.sourceFormat.summary.contains("32-bit"))
        #expect(read.sourceFormat.summary.contains("48.0 kHz"))
    }

    @Test("A lossy source reports no sample depth rather than a wrong one")
    func lossySourceHasNoDepth() {
        let aac = AudioIO.Format(sampleRate: 44100, bitDepth: nil, codec: "aac ")
        #expect(!aac.isLossless)
        #expect(aac.summary == "44.1 kHz · AAC")

        let pcm = AudioIO.Format(sampleRate: 48000, bitDepth: 24, codec: "lpcm")
        #expect(pcm.isLossless)
        #expect(pcm.summary == "48.0 kHz · 24-bit")
    }

    @Test("The report carries the format on both sides")
    func reportCarriesFormat() {
        let audio = Signal.musicLike(seconds: 2)
        let result = Masterer().master(channels: audio, sampleRate: 48000, intensity: .standard)
        let source = AudioIO.Format(sampleRate: 48000, bitDepth: 16, codec: "lpcm")
        let report = Report(result: result, sourceFormat: source)

        let format = report.measurements.first { $0.label == "FORMAT" }
        #expect(format?.before == "48.0 kHz · 16-bit")
        #expect(format?.after == "48.0 kHz · 24-bit")
        #expect(report.plainText().contains("48.0 kHz · 16-bit"))
    }
}
