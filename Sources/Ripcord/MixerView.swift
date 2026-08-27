import RipcordKit
import SwiftUI

/// The live mixer strip: eight controls sitting on top of the chain the tool designed.
///
/// Each control shows what it is doing rather than just where it is. A knob that has not been
/// touched reads AUTO and still shows the number the analysis chose, so handing a control back is a
/// visible act and not just a slider parked somewhere near the middle.
struct MixerView: View {
    @ObservedObject var controller: MasteringController
    @Environment(\.colorScheme) private var scheme

    private static let rows: [[Mixer.Knob]] = [
        [.targetLUFS, .ceilingDBTP, .compression, .width],
        [.toneAmount, .bassTrimDB, .airTrimDB, .resonanceAmount],
    ]

    var body: some View {
        VStack(spacing: 0) {
            Rule(opacity: 0.3)
            RegenBar(regen: controller.regen)
            VStack(spacing: 0) {
                header
                ForEach(Array(Self.rows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .top, spacing: 18) {
                        ForEach(row) { knob in
                            knobColumn(knob)
                        }
                    }
                    .padding(.top, 9)
                }
            }
            .padding(.horizontal, 26)
            .padding(.top, 9)
            .padding(.bottom, 11)
            .disabled(!controller.isMixerEnabled)
            .opacity(controller.isMixerEnabled ? 1 : 0.4)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            SectionLabel("Mixer")
            statusLabel
            Spacer()
            if controller.mixer.isTouched {
                Button("Reset all") { controller.resetAll() }
                    .buttonStyle(.plain)
                    .font(Theme.label)
                    .tracking(Theme.labelTracking)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.ink(scheme).opacity(0.55))
                    .help("Hand every control back to the analysis")
            }
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch controller.regen {
        case .settled:
            SectionLabel(controller.mixer.isTouched ? "Adjusted" : "Automatic",
                         color: Theme.ink(scheme).opacity(0.4))
        case .pending:
            SectionLabel("Queued", color: Theme.accent(scheme))
        case .rendering(let stage, let progress):
            busy(stage.rawValue, progress)
        case .checking(let progress):
            busy("CHECKING", progress)
        }
    }

    private func busy(_ text: String, _ progress: Double) -> some View {
        HStack(spacing: 6) {
            SectionLabel(text, color: Theme.accent(scheme))
            Text(String(format: "%3.0f%%", progress * 100))
                .font(Theme.data(9))
                .monospacedDigit()
                .opacity(0.5)
        }
    }

    @ViewBuilder
    private func knobColumn(_ knob: Mixer.Knob) -> some View {
        let override = controller.mixer[knob]
        let auto = controller.design.map { knob.autoValue(in: $0) } ?? 0
        let value = override ?? auto

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 0) {
                SectionLabel(knob.label)
                Spacer(minLength: 4)
                // The readout doubles as the way back to AUTO. Double-clicking the track works too,
                // but a slider that responds to a zero-distance drag will usually eat the second
                // click, so the only reliable way out cannot be a gesture on the slider itself.
                if override == nil {
                    Text(knob.format(value))
                        .font(Theme.data(10))
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink(scheme).opacity(0.5))
                } else {
                    Button { controller.reset(knob) } label: {
                        Text(knob.format(value))
                            .font(Theme.data(10, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(Theme.accent(scheme))
                            .underline(true, pattern: .dot)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            KnobSlider(value: value,
                       auto: auto,
                       range: knob.range,
                       isOverridden: override != nil,
                       onChange: { controller.set($0, for: knob) },
                       onReset: { controller.reset(knob) })
                .frame(height: 14)
        }
        .frame(maxWidth: .infinity)
        .help(override == nil
              ? "Following the analysis at \(knob.format(auto)). Drag to take it over."
              : "Set to \(knob.format(value)). The analysis chose \(knob.format(auto)) — click the figure to go back to it.")
    }
}

/// A hairline track with a block handle, and a tick where the analysis put it.
///
/// The tick is the part that earns its keep: once a control is overridden, the number it moved away
/// from is otherwise gone, and "put it back roughly where it was" becomes guesswork.
private struct KnobSlider: View {
    let value: Double
    let auto: Double
    let range: ClosedRange<Double>
    let isOverridden: Bool
    let onChange: (Double) -> Void
    let onReset: () -> Void

    @Environment(\.colorScheme) private var scheme

    private func fraction(_ value: Double) -> Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return ((value - range.lowerBound) / span).clamped(to: 0...1)
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let inset: CGFloat = 2
            let usable = max(width - inset * 2, 1)
            let x = inset + usable * CGFloat(fraction(value))
            let autoX = inset + usable * CGFloat(fraction(auto))

            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Theme.ink(scheme).opacity(0.16))
                    .frame(height: 1)

                Rectangle()
                    .fill(isOverridden ? Theme.accent(scheme) : Theme.ink(scheme).opacity(0.4))
                    .frame(width: max(x - inset, 0), height: 1)
                    .offset(x: inset)

                Rectangle()
                    .fill(Theme.ink(scheme).opacity(0.3))
                    .frame(width: 1, height: 7)
                    .offset(x: autoX)

                Rectangle()
                    .fill(isOverridden ? Theme.accent(scheme) : Theme.ink(scheme).opacity(0.65))
                    .frame(width: 3, height: 13)
                    .offset(x: x - 1.5)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let position = Double((drag.location.x - inset) / usable).clamped(to: 0...1)
                        onChange(range.lowerBound + position * (range.upperBound - range.lowerBound))
                    }
            )
            .onTapGesture(count: 2) { onReset() }
        }
    }
}

/// The one-pixel account of what is happening to the result on screen.
private struct RegenBar: View {
    let regen: MasteringController.Regen
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Color.clear
                switch regen {
                case .settled:
                    EmptyView()
                case .pending:
                    Rectangle()
                        .fill(Theme.accent(scheme).opacity(0.35))
                        .frame(width: geometry.size.width)
                case .rendering(_, let progress):
                    Rectangle()
                        .fill(Theme.accent(scheme))
                        .frame(width: geometry.size.width * progress)
                case .checking(let progress):
                    // Drawn hollow rather than solid: the master is already finished and audible,
                    // and only the claims about it are still being worked out.
                    Rectangle()
                        .fill(Theme.accent(scheme).opacity(0.5))
                        .frame(width: geometry.size.width * max(progress, 0.04))
                }
            }
        }
        .frame(height: 2)
        .animation(.easeOut(duration: 0.2), value: regen)
    }
}
