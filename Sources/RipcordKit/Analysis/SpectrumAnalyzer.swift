import Accelerate
import Foundation

/// Long-term average power spectrum of a signal.
///
/// Absolute scaling is deliberately unspecified: every consumer normalizes the spectrum against
/// its own mean before using it, so only the shape carries meaning.
public struct PowerSpectrum: Sendable {
    public let sampleRate: Double
    public let fftSize: Int
    /// Mean power per bin, length `fftSize / 2 + 1`.
    public let power: [Double]

    public var binWidth: Double { sampleRate / Double(fftSize) }

    /// Total energy between two frequencies, expressed in dB.
    public func energyDB(from low: Double, to high: Double) -> Double {
        let loBin = max(Int((low / binWidth).rounded(.down)), 1)
        let hiBin = min(Int((high / binWidth).rounded(.up)), power.count - 1)
        guard hiBin >= loBin else { return -120 }
        var sum = 0.0
        for bin in loBin...hiBin { sum += power[bin] }
        return 10 * log10(max(sum, 1e-30))
    }

    /// Energy in a band, normalized per unit bandwidth so wide bands are not automatically louder.
    public func densityDB(from low: Double, to high: Double) -> Double {
        let bandwidth = max(high - low, binWidth)
        return energyDB(from: low, to: high) - 10 * log10(bandwidth / binWidth)
    }
}

public enum SpectrumAnalyzer {
    public static let fftSize = 4096

    /// Welch-style average of Hann-windowed periodograms over the whole signal.
    public static func analyze(channels: [[Float]], sampleRate: Double) -> PowerSpectrum {
        let n = fftSize
        let half = n / 2
        let binCount = half + 1
        guard let first = channels.first, first.count >= n else {
            return PowerSpectrum(sampleRate: sampleRate, fftSize: n,
                                 power: [Double](repeating: 1e-12, count: binCount))
        }

        let log2n = vDSP_Length(log2(Double(n)).rounded())
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return PowerSpectrum(sampleRate: sampleRate, fftSize: n,
                                 power: [Double](repeating: 1e-12, count: binCount))
        }
        defer { vDSP_destroy_fftsetup(setup) }

        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_DENORM))

        var accumulated = [Double](repeating: 0, count: binCount)
        var frameCount = 0
        let hop = n / 2

        var realp = [Float](repeating: 0, count: half)
        var imagp = [Float](repeating: 0, count: half)
        var windowed = [Float](repeating: 0, count: n)
        var magnitudes = [Float](repeating: 0, count: half)

        for channel in channels {
            var start = 0
            while start + n <= channel.count {
                vDSP_vmul(Array(channel[start..<(start + n)]), 1, window, 1, &windowed, 1, vDSP_Length(n))

                realp.withUnsafeMutableBufferPointer { realBuffer in
                    imagp.withUnsafeMutableBufferPointer { imagBuffer in
                        var split = DSPSplitComplex(realp: realBuffer.baseAddress!,
                                                    imagp: imagBuffer.baseAddress!)
                        windowed.withUnsafeBufferPointer { input in
                            input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                                vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                            }
                        }
                        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                        // zrip packs DC in realp[0] and Nyquist in imagp[0]; handle them separately.
                        let dc = split.realp[0]
                        let nyquist = split.imagp[0]
                        split.realp[0] = 0
                        split.imagp[0] = 0
                        vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(half))
                        accumulated[0] += Double(dc * dc)
                        accumulated[half] += Double(nyquist * nyquist)
                        for bin in 1..<half { accumulated[bin] += Double(magnitudes[bin]) }
                    }
                }
                frameCount += 1
                start += hop
            }
        }

        guard frameCount > 0 else {
            return PowerSpectrum(sampleRate: sampleRate, fftSize: n,
                                 power: [Double](repeating: 1e-12, count: binCount))
        }
        let scale = 1.0 / Double(frameCount)
        return PowerSpectrum(sampleRate: sampleRate, fftSize: n,
                             power: accumulated.map { max($0 * scale, 1e-30) })
    }
}
