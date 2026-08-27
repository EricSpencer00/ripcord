import Foundation

/// What the finished file has to satisfy, as opposed to how hard it was pushed.
///
/// This is deliberately not another `Intensity` case. Intensity is a taste control — how much the
/// chain leans on the music. Delivery is a set of constraints imposed from outside by whoever the
/// file is going to. Conflating them would make the mixer lie: selecting "loud" would silently
/// change what the report claims about conformance, and selecting a delivery target would silently
/// change how the music sounds beyond the constraint that was actually asked for.
///
/// ## Sources
///
/// Every number here is quoted from a primary source, with the wording that supports it, because
/// the widely repeated versions of these figures are wrong in ways that matter.
///
/// **Apple Digital Masters**, Apple technology brief, April 2021 (© 2012–2021),
/// `apple.com/apple-music/apple-digital-masters/docs/apple-digital-masters.pdf`:
///
/// - Headroom: *"One common process is called oversampling. This upsamples the digital data at
///   four times the rate … If the original digital audio data is at 0dBFS, oversampling can result
///   in undesirable clipping. … Our recommendation is to leave at least 1 dB of headroom in order
///   to avoid such clipping."* Note the form of this: it is a **recommendation**, stated as at
///   least 1 dB of headroom. It is not a −1.0 dBTP specification, and this file does not present
///   it as one.
/// - Bit depth: *"use only 24-bit sources"*; *"The deliverable for Apple Digital Masters is the
///   original 24 bit PCM file."*
/// - Sample rate: *"we ask that you deliver the highest native sample rate available"*; *"Don't
///   upsample files to a higher resolution than their original format."* Apple performs its own
///   sample-rate conversion at ingest, so the correct behaviour here is to convert nothing.
/// - Encoding: 256 kbps AAC, *"It utilizes Variable Bit Rate (VBR) encoding"*.
/// - Why the encode check exists: *"levels that don't show overs on PCM can still cause clipping
///   when encoded."*
///
/// **There is no Apple loudness target.** The same document declines to set one, twice:
/// *"Whatever you decide—exquisitely overdriven and loud or exquisitely nuanced and tasteful—we
/// will be sure to encode it and reproduce it accurately"* and *"you should always mix and master
/// your tracks in a way that captures your intended sound, regardless of playback volume."* The
/// −16 LUFS figure in common circulation describes Sound Check's playback normalisation, not a
/// delivery requirement, and no target here is derived from it.
///
/// Dolby Atmos is out of scope: the −18 LKFS / −1 dBTP figures come from Apple's Immersive Audio
/// Source Profile and apply to a 24-bit/48 kHz ADM BWF, which a stereo tool cannot produce.
public enum Delivery: String, Sendable, CaseIterable, Codable {
    /// No external constraint. The chain is whatever the mixer says it is.
    case none
    /// The technical guidance Apple publishes for Apple Digital Masters.
    case appleMusic = "apple"

    public var label: String {
        switch self {
        case .none: return "None"
        case .appleMusic: return "Apple"
        }
    }

    /// Short line naming the document the checks are drawn from, printed with them.
    public var citation: String? {
        switch self {
        case .none: return nil
        case .appleMusic: return "Apple Digital Masters, April 2021"
        }
    }

    /// The minimum headroom below full scale the target asks for, in dB.
    public var headroomDB: Double? {
        switch self {
        case .none: return nil
        case .appleMusic: return 1.0
        }
    }

    /// The ceiling that headroom implies. Stated as a derived value rather than a constant, so the
    /// report can quote the requirement in the form the source actually uses.
    public var ceilingDBTP: Double? { headroomDB.map { -$0 } }

    public var bitDepth: Int {
        switch self {
        case .none, .appleMusic: return 24
        }
    }

    /// Whether a lossy encode of the master has to come back without overs.
    public var requiresEncodeCheck: Bool {
        switch self {
        case .none: return false
        case .appleMusic: return true
        }
    }

    /// Deliberately absent for every target: none of them states one. A delivery target that
    /// invented a loudness figure would be the app claiming a requirement that does not exist.
    public var targetLUFS: Double? { nil }
}
