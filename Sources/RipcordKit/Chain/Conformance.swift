import Foundation

/// What a delivery target asks for, what the rendered file actually measures, and whether the two
/// agree — one row per requirement.
///
/// Two rules govern everything here, and they are the reason this type exists rather than a
/// boolean somewhere.
///
/// **Every measured value comes from rendered audio.** Not from the settings that were meant to
/// produce it. The same rule the rest of `Report` follows, for the same reason: a chain that failed
/// to hit its own ceiling must say so, and it can only do that if the number is measured after the
/// fact.
///
/// **Nothing here is a badge.** "Apple Digital Master" and "Dolby Atmos" are programme marks
/// administered by their owners; passing a technical check is not the same as being admitted to a
/// programme, and no amount of measurement on this machine can confer one. The rows state a limit,
/// a measurement, and whether one is inside the other. The wording never goes further than that.
public struct Conformance: Sendable, Equatable {
    public struct Check: Sendable, Equatable, Identifiable {
        public var id: String { label }
        public var label: String
        /// The requirement, quoted in the form the source document uses.
        public var limit: String
        /// What the rendered file measures.
        public var measured: String
        public var passed: Bool
        /// Set when the check could not be run at all, which is neither a pass nor a fail.
        public var indeterminate: Bool = false
    }

    public var delivery: Delivery
    public var checks: [Check]
    /// Gain applied to bring the master inside the requirements, in dB. Never positive.
    public var outputTrimDB: Double
    /// One sentence saying it happened and why, when it did.
    public var trimNote: String?
    /// Uncertainty of the true-peak meter used for the headroom figure, in dB.
    public var meterUncertaintyDB: Double

    /// True only when every check ran and every check passed. An indeterminate check is not a pass.
    public var passed: Bool { checks.allSatisfy { $0.passed && !$0.indeterminate } }
    public var hasIndeterminate: Bool { checks.contains { $0.indeterminate } }

    /// One line naming what was checked and against what, printed above the rows.
    public var heading: String {
        guard let citation = delivery.citation else { return "Delivery checks" }
        return "Checked against \(citation)"
    }

    /// Builds the rows for a rendered master.
    ///
    /// - Parameters:
    ///   - source: the format of the file as it was on disk, which is the only way to check the
    ///     resolution requirement — decoding throws that information away.
    ///   - outputBitDepth: what the file will be written at, not what it is hoped to be.
    public static func evaluate(_ outcome: MasteringEngine.DeliveryOutcome,
                                source: AudioIO.Format,
                                outputBitDepth: Int) -> Conformance? {
        let delivery = outcome.result.settings.delivery
        guard delivery != .none else { return nil }
        var checks: [Check] = []

        // Resolution of the source. Apple asks for 24-bit sources and says not to bit-pad a 16-bit
        // file into 24. A lossy source has no sample depth at all, which is a clear fail rather
        // than a missing measurement.
        checks.append(Check(
            label: "SOURCE",
            limit: "24-bit or better",
            measured: source.summary,
            passed: (source.bitDepth ?? 0) >= 24))

        checks.append(Check(
            label: "OUTPUT",
            limit: "\(delivery.bitDepth)-bit PCM",
            measured: "\(outputBitDepth)-bit PCM",
            passed: outputBitDepth >= delivery.bitDepth))

        // Apple asks for the highest native rate and performs its own conversion, so the
        // requirement is that nothing here converted anything.
        let rateHeld = abs(outcome.result.after.sampleRate - source.sampleRate) < 1e-6
        checks.append(Check(
            label: "SAMPLE RATE",
            limit: "source rate, no conversion",
            measured: rateHeld
                ? String(format: "%.1f kHz unchanged", source.sampleRate / 1000)
                : String(format: "%.1f kHz → %.1f kHz", source.sampleRate / 1000,
                         outcome.result.after.sampleRate / 1000),
            passed: rateHeld))

        if let headroom = delivery.headroomDB {
            let measured = -outcome.certifiedTruePeakDBTP
            checks.append(Check(
                label: "HEADROOM",
                limit: String(format: "at least %.1f dB below full scale", headroom),
                measured: String(format: "%.2f dB (%.2f dBTP)", measured,
                                 outcome.certifiedTruePeakDBTP),
                passed: measured >= headroom))
        }

        if delivery.requiresEncodeCheck {
            if let encode = outcome.encode {
                checks.append(Check(
                    label: "AAC \(encode.bitRate / 1000)K",
                    limit: "no samples over 0 dBFS",
                    measured: encode.clips
                        ? String(format: "%d samples, worst %+.2f dB",
                                 encode.samplesOverFullScale, encode.worstOvershootDB)
                        : String(format: "none, peaks %.2f dBFS", encode.peakDBFS),
                    passed: !encode.clips))
            } else {
                checks.append(Check(
                    label: "AAC 256K",
                    limit: "no samples over 0 dBFS",
                    measured: outcome.encodeFailure ?? "check did not run",
                    passed: false,
                    indeterminate: true))
            }
        }

        var note: String?
        if outcome.outputTrimDB < -1e-9 {
            let reasons = [
                outcome.trimmedForMeter
                    ? "the limiter's own meter had left it fractionally high" : nil,
                outcome.trimmedForEncode ? "the AAC encode clipped" : nil,
            ].compactMap { $0 }
            note = String(format: "The master was turned down %.2f dB because %@.",
                          -outcome.outputTrimDB, reasons.joined(separator: " and "))
        }

        return Conformance(delivery: delivery, checks: checks,
                           outputTrimDB: outcome.outputTrimDB,
                           trimNote: note,
                           meterUncertaintyDB: TruePeakMeter.certification.uncertaintyDB)
    }

    /// Plain-text rendering, so the CLI and the clipboard carry the same rows as the window.
    public func plainText() -> String {
        var lines = [heading.uppercased(), ""]
        for check in checks {
            let mark = check.indeterminate ? "  ?  " : (check.passed ? " OK  " : "FAIL ")
            lines.append(mark + pad(check.label, 14) + pad(check.limit, 34) + check.measured)
        }
        if let trimNote {
            lines.append("")
            lines.append(trimNote)
        }
        lines.append("")
        lines.append(String(format: "True peak measured at %dx oversampling (worst-case under-read %.3f dB).",
                            TruePeakMeter.certification.factor, -meterUncertaintyDB))
        return lines.joined(separator: "\n")
    }

    private func pad(_ text: String, _ width: Int) -> String {
        text + String(repeating: " ", count: max(width - text.count, 1))
    }
}
