import Foundation

/// How hard to push. The only user-facing control in the app.
public enum Intensity: String, Sendable, CaseIterable, Codable {
    case gentle, standard, loud

    public var targetLUFS: Double {
        switch self {
        case .gentle: return -14
        case .standard: return -11
        case .loud: return -9
        }
    }

    public var ceilingDBTP: Double {
        switch self {
        case .gentle: return -1.0
        case .standard: return -1.0
        case .loud: return -0.8
        }
    }

    /// Fraction of the measured tonal error that gets corrected.
    public var correctionFactor: Double {
        switch self {
        case .gentle: return 0.45
        case .standard: return 0.60
        case .loud: return 0.70
        }
    }

    public var label: String { rawValue.uppercased() }
}

/// A complete, declarative description of what will be done to the audio.
///
/// This is the output of every decision the tool makes. It contains no audio and no engine state,
/// which is what makes the decision logic testable on its own.
public struct MasterSettings: Sendable, Equatable {
    public struct EQBand: Sendable, Equatable {
        public enum Kind: Sendable, Equatable { case peak, lowShelf, highShelf }
        public var kind: Kind
        public var frequency: Double
        public var q: Double
        public var gainDB: Double

        public init(kind: Kind, frequency: Double, q: Double, gainDB: Double) {
            self.kind = kind; self.frequency = frequency; self.q = q; self.gainDB = gainDB
        }

        public func coefficients(sampleRate: Double) -> BiquadCoefficients {
            switch kind {
            case .peak: return .peaking(freq: frequency, q: q, gainDB: gainDB, sampleRate: sampleRate)
            case .lowShelf: return .lowShelf(freq: frequency, q: q, gainDB: gainDB, sampleRate: sampleRate)
            case .highShelf: return .highShelf(freq: frequency, q: q, gainDB: gainDB, sampleRate: sampleRate)
            }
        }
    }

    public struct CompressorBand: Sendable, Equatable {
        public var thresholdDB: Double
        public var ratio: Double
        public var attackSeconds: Double
        public var releaseSeconds: Double

        public init(thresholdDB: Double, ratio: Double, attackSeconds: Double, releaseSeconds: Double) {
            self.thresholdDB = thresholdDB; self.ratio = ratio
            self.attackSeconds = attackSeconds; self.releaseSeconds = releaseSeconds
        }
    }

    public var intensity: Intensity
    public var highpassHz: Double
    /// Broad tonal correction derived from the target curve.
    public var toneBands: [EQBand]
    /// Narrow cuts for individual resonances.
    public var resonanceCuts: [EQBand]
    public var crossovers: [Double]
    public var compressorBands: [CompressorBand]
    public var width: Double
    public var monoBelowHz: Double
    public var targetLUFS: Double
    public var ceilingDBTP: Double
    /// True when the input already measures like a finished master and only needs a light touch.
    public var alreadyMastered: Bool

    public var allEQBands: [EQBand] { toneBands + resonanceCuts }

    /// Working level the signal is normalized to before compression, so that fixed thresholds mean
    /// the same thing regardless of how loud the file arrived.
    public static let workingLUFS = -18.0
}
