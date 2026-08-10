import Foundation

/// The human-readable account of a mastering pass.
///
/// Every number shown here is measured from the rendered output, not predicted from the settings,
/// so the report cannot claim something the audio does not actually do.
public struct Report: Sendable {
    public struct Measurement: Sendable, Identifiable {
        public var id: String { label }
        public var label: String
        public var before: String
        public var after: String
        public var unit: String
    }

    public struct Move: Sendable, Identifiable {
        public var id: String { label + detail }
        public var label: String
        public var detail: String
    }

    public var headline: String
    public var subhead: String
    public var measurements: [Measurement]
    public var moves: [Move]
    public var bandsBefore: [Double]
    public var bandsAfter: [Double]
    public var bandLabels: [String] { Analysis.bandLabels }

    public init(result: Masterer.Result) {
        let before = result.before
        let after = result.after
        let settings = result.settings

        let gain = after.integratedLUFS - before.integratedLUFS
        if result.unchanged {
            headline = "NO SIGNAL"
            subhead = "This file measures as silence. Nothing was changed."
        } else if settings.alreadyMastered {
            headline = String(format: "%+.1f LU", gain)
            subhead = "Already close to target. Light touch only."
        } else {
            headline = String(format: "%+.1f LU", gain)
            subhead = "\(settings.intensity.label) · \(Report.formatDuration(after.durationSeconds)) · \(Int(after.sampleRate / 1000)) kHz"
        }

        measurements = [
            .init(label: "LOUDNESS", before: Report.format(before.integratedLUFS),
                  after: Report.format(after.integratedLUFS), unit: "LUFS"),
            .init(label: "TRUE PEAK", before: Report.format(before.truePeakDBTP),
                  after: Report.format(after.truePeakDBTP), unit: "dBTP"),
            .init(label: "RANGE", before: Report.format(before.loudnessRangeLU),
                  after: Report.format(after.loudnessRangeLU), unit: "LU"),
            .init(label: "CREST", before: Report.format(before.crestFactorDB),
                  after: Report.format(after.crestFactorDB), unit: "dB"),
            .init(label: "CORRELATION", before: Report.format(before.correlation, decimals: 2),
                  after: Report.format(after.correlation, decimals: 2), unit: ""),
        ]

        var moves = [Move]()
        if !result.unchanged {
            moves.append(.init(label: "HIGH-PASS",
                               detail: String(format: "%.0f Hz, 24 dB/oct", settings.highpassHz)))

            let tone = settings.toneBands
                .filter { abs($0.gainDB) >= 0.25 }
                .sorted { $0.frequency < $1.frequency }
                .map { String(format: "%@ %+.1f", Report.formatFrequency($0.frequency), $0.gainDB) }
            moves.append(.init(label: "TONE",
                               detail: tone.isEmpty ? "already balanced" : tone.joined(separator: "   ")))

            if settings.resonanceCuts.isEmpty {
                moves.append(.init(label: "RESONANCE", detail: "none found"))
            } else {
                let cuts = settings.resonanceCuts.map {
                    String(format: "%@ %+.1f Q%.0f", Report.formatFrequency($0.frequency), $0.gainDB, $0.q)
                }
                moves.append(.init(label: "RESONANCE", detail: cuts.joined(separator: "   ")))
            }

            let ratio = settings.compressorBands.first?.ratio ?? 1
            moves.append(.init(label: "DYNAMICS",
                               detail: String(format: "%d bands at %.2f:1", settings.compressorBands.count, ratio)))

            var stereo = settings.width == 1.0
                ? "unchanged"
                : String(format: "width ×%.2f", settings.width)
            if settings.monoBelowHz > 0 {
                stereo += String(format: ", mono below %.0f Hz", settings.monoBelowHz)
            }
            moves.append(.init(label: "STEREO", detail: stereo))

            moves.append(.init(label: "LIMITER",
                               detail: String(format: "%.1f dB peak reduction, ceiling %.1f dBTP",
                                              -result.limiterReductionDB, settings.ceilingDBTP)))
            moves.append(.init(label: "MAKEUP",
                               detail: String(format: "%+.1f dB, converged in %d pass%@",
                                              result.makeupGainDB, result.passes,
                                              result.passes == 1 ? "" : "es")))
        }
        self.moves = moves
        bandsBefore = before.normalizedBands
        bandsAfter = after.normalizedBands
    }

    /// Plain-text rendering, used by the CLI and by the app's copy-to-clipboard.
    public func plainText() -> String {
        var lines = ["RIPCORD  \(headline)", subhead, ""]
        lines.append(pad("", 13) + rightPad("BEFORE", 9) + rightPad("AFTER", 9))
        for measurement in measurements {
            lines.append(pad(measurement.label, 13)
                         + rightPad(measurement.before, 9)
                         + rightPad(measurement.after, 9)
                         + "  " + measurement.unit)
        }
        lines.append("")
        for move in moves {
            lines.append(pad(move.label, 13) + move.detail)
        }
        return lines.joined(separator: "\n")
    }

    private func pad(_ text: String, _ width: Int) -> String {
        text + String(repeating: " ", count: max(width - text.count, 1))
    }

    private func rightPad(_ text: String, _ width: Int) -> String {
        String(repeating: " ", count: max(width - text.count, 1)) + text
    }

    public static func format(_ value: Double, decimals: Int = 1) -> String {
        guard value.isFinite else { return "—" }
        return String(format: "%.\(decimals)f", value)
    }

    public static func formatFrequency(_ hz: Double) -> String {
        hz >= 1000 ? String(format: "%.1fk", hz / 1000) : String(format: "%.0f", hz)
    }

    public static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
