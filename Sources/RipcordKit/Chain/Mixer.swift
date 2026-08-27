import Foundation

/// The live mixer: what the listener can move, sitting on top of what the tool decided.
///
/// Every knob is optional, and `nil` means "whatever the automatic design chose". That is not a
/// storage trick — it is the difference between a control that is following the analysis and one
/// the user has taken over. A knob that stored the automatic number instead would freeze it, so
/// loading a different track, or switching preset, would silently keep the old decision.
public struct Mixer: Sendable, Equatable, Codable {
    /// The preset the automatic design starts from. Changing it re-designs the whole chain.
    public var intensity: Intensity
    /// What the finished file has to satisfy. Changing it re-designs the chain too.
    public var delivery: Delivery = .none

    public var targetLUFS: Double?
    public var ceilingDBTP: Double?
    /// How much of the measured tonal error to correct, as a multiple of the designed amount.
    public var toneAmount: Double?
    /// Trims folded into the correction curve, in dB, on top of whatever it already asks for.
    public var bassTrimDB: Double?
    public var airTrimDB: Double?
    /// Multiplies the depth of the narrow resonance cuts.
    public var resonanceAmount: Double?
    /// Moves every band's ratio toward 1:1 at 0, leaves it at 1, pushes past it above.
    public var compression: Double?
    public var width: Double?

    public init(intensity: Intensity = .standard, delivery: Delivery = .none) {
        self.intensity = intensity
        self.delivery = delivery
    }

    // MARK: - Knobs

    /// The knobs, in the order they are laid out. Everything the UI needs to draw and label a
    /// control lives here, so adding a knob does not mean editing a view.
    public enum Knob: String, CaseIterable, Sendable, Identifiable, Codable {
        case targetLUFS, ceilingDBTP, toneAmount, bassTrimDB, airTrimDB, resonanceAmount,
             compression, width

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .targetLUFS: return "Loudness"
            case .ceilingDBTP: return "Ceiling"
            case .toneAmount: return "Tone"
            case .bassTrimDB: return "Bass"
            case .airTrimDB: return "Air"
            case .resonanceAmount: return "Resonance"
            case .compression: return "Dynamics"
            case .width: return "Width"
            }
        }

        public var range: ClosedRange<Double> {
            switch self {
            case .targetLUFS: return -20 ... -6
            case .ceilingDBTP: return -3 ... -0.1
            case .toneAmount: return 0 ... 1.6
            case .bassTrimDB: return -4 ... 4
            case .airTrimDB: return -4 ... 4
            case .resonanceAmount: return 0 ... 1.6
            case .compression: return 0 ... 1.6
            case .width: return 0 ... 1.6
            }
        }

        /// Which stage of the chain a move on this knob invalidates. Drawn from the same facts the
        /// engine's cache uses, so the UI can honestly say how much work a knob costs.
        public var stage: Stage {
            switch self {
            case .targetLUFS, .ceilingDBTP: return .level
            case .compression: return .dynamics
            case .toneAmount, .bassTrimDB, .airTrimDB, .resonanceAmount, .width: return .tone
            }
        }

        public enum Stage: Sendable { case tone, dynamics, level }

        public func format(_ value: Double) -> String {
            switch self {
            case .targetLUFS: return String(format: "%.1f LUFS", value)
            case .ceilingDBTP: return String(format: "%.1f dBTP", value)
            case .bassTrimDB, .airTrimDB: return String(format: "%+.1f dB", value)
            case .width: return String(format: "×%.2f", value)
            case .toneAmount, .resonanceAmount, .compression:
                return String(format: "%.0f%%", value * 100)
            }
        }

        /// What the automatic design chose, so a knob sitting at AUTO can still show its number.
        public func autoValue(in designed: MasterSettings) -> Double {
            switch self {
            case .targetLUFS: return designed.targetLUFS
            case .ceilingDBTP: return designed.ceilingDBTP
            case .width: return designed.width
            case .toneAmount, .resonanceAmount, .compression: return 1
            case .bassTrimDB, .airTrimDB: return 0
            }
        }
    }

    public subscript(knob: Knob) -> Double? {
        get {
            switch knob {
            case .targetLUFS: return targetLUFS
            case .ceilingDBTP: return ceilingDBTP
            case .toneAmount: return toneAmount
            case .bassTrimDB: return bassTrimDB
            case .airTrimDB: return airTrimDB
            case .resonanceAmount: return resonanceAmount
            case .compression: return compression
            case .width: return width
            }
        }
        set {
            let clamped = newValue.map { $0.clamped(to: knob.range) }
            switch knob {
            case .targetLUFS: targetLUFS = clamped
            case .ceilingDBTP: ceilingDBTP = clamped
            case .toneAmount: toneAmount = clamped
            case .bassTrimDB: bassTrimDB = clamped
            case .airTrimDB: airTrimDB = clamped
            case .resonanceAmount: resonanceAmount = clamped
            case .compression: compression = clamped
            case .width: width = clamped
            }
        }
    }

    /// True when the user has taken over at least one control.
    public var isTouched: Bool { Knob.allCases.contains { self[$0] != nil } }

    /// Returns every knob to AUTO, keeping the preset.
    public mutating func resetAll() {
        for knob in Knob.allCases { self[knob] = nil }
    }

    // MARK: - Application

    /// Folds the mixer into a designed chain.
    ///
    /// The tone curve is re-solved rather than scaled: octave-spaced bells overlap, so multiplying
    /// each solved gain by the tone amount would not multiply the combined response by it. Solving
    /// is analytic and costs nothing, so there is no reason to approximate.
    public func apply(to designed: MasterSettings, sampleRate: Double) -> MasterSettings {
        var settings = designed
        settings.intensity = intensity
        settings.delivery = delivery
        settings.targetLUFS = targetLUFS ?? designed.targetLUFS
        settings.ceilingDBTP = ceilingDBTP ?? designed.ceilingDBTP
        settings.width = width ?? designed.width

        let amount = toneAmount ?? 1
        let bass = bassTrimDB ?? 0
        let air = airTrimDB ?? 0
        if amount != 1 || bass != 0 || air != 0 {
            var desired = designed.desiredToneDB.map { $0 * amount }
            // Trims are spread over the octaves a listener means by "bass" and "air" rather than
            // parked on one band, so the result is a shelf and not a bump.
            for (index, weight) in [(0, 1.0), (1, 1.0), (2, 0.5)] where index < desired.count {
                desired[index] += bass * weight
            }
            for (index, weight) in [(8, 0.6), (9, 1.0)] where index < desired.count {
                desired[index] += air * weight
            }
            settings.desiredToneDB = desired
            settings.toneBands = ChainDesigner.solveToneBands(desired: desired, sampleRate: sampleRate)
        }

        if let resonanceAmount, resonanceAmount != 1 {
            settings.resonanceCuts = designed.resonanceCuts.map {
                var cut = $0
                cut.gainDB *= resonanceAmount
                return cut
            }.filter { abs($0.gainDB) > 0.05 }
        }

        if let compression, compression != 1 {
            settings.compressorBands = designed.compressorBands.map {
                var band = $0
                band.ratio = max(1, 1 + (band.ratio - 1) * compression)
                return band
            }
        }

        return settings
    }
}
