import RipcordKit
import SwiftUI

/// The finished listing: what changed, by how much, set as a classified column.
struct ReportView: View {
    let report: Report
    @ObservedObject var controller: MasteringController
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    headline
                    Rule(opacity: 0.3).padding(.vertical, 16)

                    HStack(alignment: .top, spacing: 0) {
                        MeasurementTable(measurements: report.measurements)
                            .frame(width: 268)
                        Rectangle()
                            .fill(Theme.ink(scheme).opacity(0.22))
                            .frame(width: 1)
                            .padding(.horizontal, 22)
                        BalanceChart(report: report)
                            .frame(maxWidth: .infinity)
                    }

                    Rule(opacity: 0.3).padding(.vertical, 16)
                    MovesList(moves: report.moves)

                    if let conformance = report.conformance {
                        Rule(opacity: 0.3).padding(.vertical, 16)
                        ChecksList(conformance: conformance)
                    }
                }
                .padding(.horizontal, 26)
                .padding(.top, 20)
                .padding(.bottom, 18)
                .wipeIn()
            }
            // Dimmed, not replaced. The numbers are still true of the audio that is still playing;
            // they are just no longer true of where the knobs are, and that is what fading says.
            .opacity(controller.isStale ? 0.5 : 1)
            .animation(.easeOut(duration: 0.15), value: controller.isStale)

            MixerView(controller: controller)
            Transport(preview: controller.preview)
        }
    }

    private var headline: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(report.headline)
                .font(Theme.masthead(52))
                .foregroundStyle(Theme.accent(scheme))
            VStack(alignment: .leading, spacing: 3) {
                Text(controller.sourceName)
                    .font(Theme.headline(15))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(report.subhead)
                    .font(Theme.body)
                    .opacity(0.6)
            }
            Spacer()
        }
    }
}

private struct MeasurementTable: View {
    let measurements: [Report.Measurement]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionLabel("Measured")
                Spacer()
                SectionLabel("Before")
                    .frame(width: 54, alignment: .trailing)
                SectionLabel("After")
                    .frame(width: 54, alignment: .trailing)
            }
            .padding(.bottom, 7)

            ForEach(measurements) { measurement in
                Rule(opacity: 0.14)
                HStack(spacing: 0) {
                    Text(measurement.label)
                        .font(Theme.data(11))
                        .tracking(0.5)
                    Spacer()
                    Text(measurement.before)
                        .font(Theme.data(12))
                        .opacity(0.5)
                        .frame(width: 54, alignment: .trailing)
                    Text(measurement.after)
                        .font(Theme.data(12, weight: .semibold))
                        .frame(width: 54, alignment: .trailing)
                }
                .monospacedDigit()
                .padding(.vertical, 6)
            }
            Rule(opacity: 0.14)

            HStack(spacing: 5) {
                ForEach(measurements) { measurement in
                    if !measurement.unit.isEmpty {
                        Text(measurement.unit)
                            .font(Theme.data(8))
                            .opacity(0.35)
                    }
                }
            }
            .hidden()
            .frame(height: 0)
        }
    }
}

/// Octave-band balance before and after, drawn against the target curve the chain aims at.
private struct BalanceChart: View {
    let report: Report
    @Environment(\.colorScheme) private var scheme

    private var range: ClosedRange<Double> { -24...12 }

    private func height(_ value: Double, in total: CGFloat) -> CGFloat {
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        let fraction = (clamped - range.lowerBound) / (range.upperBound - range.lowerBound)
        return total * CGFloat(fraction)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionLabel("Tonal Balance")
                Spacer()
                HStack(spacing: 5) {
                    Rectangle().fill(Theme.ink(scheme).opacity(0.28)).frame(width: 9, height: 9)
                    SectionLabel("Before")
                    Rectangle().fill(Theme.accent(scheme)).frame(width: 9, height: 9)
                    SectionLabel("After")
                }
            }
            .padding(.bottom, 9)

            GeometryReader { geometry in
                let total = geometry.size.height
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(Array(report.bandsAfter.enumerated()), id: \.offset) { index, after in
                        let before = report.bandsBefore[index]
                        ZStack(alignment: .bottom) {
                            Rectangle()
                                .fill(Theme.ink(scheme).opacity(0.20))
                                .frame(height: height(before, in: total))
                            Rectangle()
                                .fill(Theme.accent(scheme))
                                .frame(height: 2)
                                .offset(y: -height(after, in: total) + 1)
                        }
                        .frame(maxWidth: .infinity, alignment: .bottom)
                    }
                }
            }
            .frame(height: 92)

            Rule(opacity: 0.22)
            HStack(spacing: 3) {
                ForEach(Array(report.bandLabels.enumerated()), id: \.offset) { _, label in
                    Text(label)
                        .font(Theme.data(8))
                        .opacity(0.45)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.top, 4)
        }
    }
}

private struct MovesList: View {
    let moves: [Report.Move]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("What Was Done")
                .padding(.bottom, 8)
            ForEach(moves) { move in
                HStack(alignment: .top, spacing: 14) {
                    Text(move.label)
                        .font(Theme.data(10, weight: .semibold))
                        .tracking(0.8)
                        .frame(width: 84, alignment: .leading)
                        .opacity(0.55)
                    Text(move.detail)
                        .font(Theme.data(11))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
            }
        }
    }
}

/// The delivery checks: the limit, what the rendered file measures, and whether one is inside the
/// other. Never a badge — passing a technical check is not admission to anyone's programme.
private struct ChecksList: View {
    let conformance: Conformance
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionLabel(conformance.heading)
                Spacer()
                SectionLabel(summary, color: conformance.passed
                             ? Theme.accent(scheme) : Theme.ink(scheme).opacity(0.55))
            }
            .padding(.bottom, 8)

            ForEach(conformance.checks) { check in
                Rule(opacity: 0.14)
                HStack(alignment: .top, spacing: 12) {
                    Text(mark(check))
                        .font(Theme.data(9, weight: .bold))
                        .frame(width: 34, alignment: .leading)
                        .foregroundStyle(colour(check))
                    Text(check.label)
                        .font(Theme.data(10, weight: .semibold))
                        .tracking(0.6)
                        .frame(width: 92, alignment: .leading)
                        .opacity(0.55)
                    Text(check.limit)
                        .font(Theme.data(10))
                        .frame(width: 190, alignment: .leading)
                        .opacity(0.55)
                    Text(check.measured)
                        .font(Theme.data(10, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 5)
            }
            Rule(opacity: 0.14)

            if let note = conformance.trimNote {
                Text(note)
                    .font(Theme.data(10))
                    .opacity(0.6)
                    .padding(.top, 7)
            }
            Text(String(format: "True peak measured at %d× oversampling; worst-case under-read %.3f dB.",
                        TruePeakMeter.certification.factor, -conformance.meterUncertaintyDB))
                .font(Theme.data(9))
                .opacity(0.42)
                .padding(.top, 5)
        }
    }

    private var summary: String {
        if conformance.hasIndeterminate { return "Incomplete" }
        return conformance.passed ? "All checks met" : "Not met"
    }

    private func mark(_ check: Conformance.Check) -> String {
        if check.indeterminate { return "—" }
        return check.passed ? "OK" : "FAIL"
    }

    private func colour(_ check: Conformance.Check) -> Color {
        if check.indeterminate { return Theme.ink(scheme).opacity(0.45) }
        return check.passed ? Theme.ink(scheme).opacity(0.55) : Theme.accent(scheme)
    }
}

// MARK: - Transport

private struct Transport: View {
    @ObservedObject var preview: AudioPreview
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            Rule(opacity: 0.3)
            HStack(spacing: 14) {
                Button {
                    preview.toggle()
                } label: {
                    Image(systemName: preview.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 11))
                        .frame(width: 30, height: 26)
                        .overlay(Rectangle().stroke(Theme.ink(scheme).opacity(0.3), lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Text(Report.formatDuration(preview.position))
                    .font(Theme.data(10))
                    .monospacedDigit()
                    .opacity(0.6)

                Scrubber(preview: preview)
                    .frame(height: 18)

                Text(Report.formatDuration(preview.duration))
                    .font(Theme.data(10))
                    .monospacedDigit()
                    .opacity(0.6)

                ABSwitch(preview: preview)

                Button {
                    preview.levelMatched.toggle()
                } label: {
                    HStack(spacing: 5) {
                        Rectangle()
                            .fill(preview.levelMatched ? Theme.accent(scheme) : Color.clear)
                            .frame(width: 8, height: 8)
                            .overlay(Rectangle().stroke(Theme.ink(scheme).opacity(0.4), lineWidth: 1))
                        SectionLabel("Match level")
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Attenuates the master to the original's loudness so the comparison is about tone and dynamics, not volume.")
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 11)
        }
    }
}

private struct ABSwitch: View {
    @ObservedObject var preview: AudioPreview
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 0) {
            ForEach([AudioPreview.Side.original, .mastered], id: \.rawValue) { side in
                let selected = preview.side == side
                Button {
                    preview.side = side
                } label: {
                    Text(side == .original ? "A" : "B")
                        .font(Theme.data(10, weight: .bold))
                        .frame(width: 26, height: 24)
                        .foregroundStyle(selected ? Theme.paper(scheme) : Theme.ink(scheme).opacity(0.6))
                        .background(selected ? Theme.ink(scheme) : .clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .overlay(Rectangle().stroke(Theme.ink(scheme).opacity(0.3), lineWidth: 1))
        .help("A is the original, B is the master. Press A to flip.")
    }
}

private struct Scrubber: View {
    @ObservedObject var preview: AudioPreview
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geometry in
            let fraction = preview.duration > 0 ? preview.position / preview.duration : 0
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Theme.ink(scheme).opacity(0.14))
                    .frame(height: 2)
                Rectangle()
                    .fill(Theme.accent(scheme))
                    .frame(width: geometry.size.width * CGFloat(fraction), height: 2)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { value in
                        let target = Double(value.location.x / geometry.size.width) * preview.duration
                        preview.seek(to: target)
                    }
            )
        }
    }
}
