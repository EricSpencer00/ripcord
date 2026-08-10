import RipcordKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var controller = MasteringController()
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            Masthead()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Footer(controller: controller)
        }
        .background(Theme.paper(scheme))
        .foregroundStyle(Theme.ink(scheme))
        .onDrop(of: [.fileURL], isTargeted: Binding(
            get: { controller.isDropTargeted },
            set: { controller.setDropTargeted($0) })) { providers in
                controller.handleDrop(providers)
            }
        .focusable()
        .onKeyPress(.space) {
            guard case .done = controller.phase else { return .ignored }
            controller.preview.toggle()
            return .handled
        }
        .onKeyPress(KeyEquivalent("a")) {
            guard case .done = controller.phase else { return .ignored }
            controller.preview.flip()
            return .handled
        }
    }

    @ViewBuilder
    private var content: some View {
        switch controller.phase {
        case .idle:
            DropView(targeted: controller.isDropTargeted) { controller.open() }
        case .reading(let name):
            WorkingView(name: name, stageText: "READING", progress: 0.02)
        case .working(let name, let stage, let progress):
            WorkingView(name: name, stageText: stage.rawValue, progress: progress)
        case .done:
            if let report = controller.report {
                ReportView(report: report, controller: controller)
            }
        case .failed(let message):
            FailureView(message: message) { controller.reset() }
        }
    }
}

// MARK: - Chrome

private struct Masthead: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .lastTextBaseline) {
                Text("RIPCORD")
                    .font(Theme.masthead(34))
                    .tracking(-0.5)
                Spacer()
                SectionLabel("Offline Mastering")
            }
            .padding(.horizontal, 26)
            .padding(.top, 22)
            .padding(.bottom, 8)

            Rectangle()
                .fill(Theme.accent(scheme))
                .frame(height: 3)
            Rule(opacity: 0.3)
                .padding(.top, 2)
        }
    }
}

private struct Footer: View {
    @ObservedObject var controller: MasteringController
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            Rule(opacity: 0.3)
            HStack(spacing: 18) {
                IntensityPicker(controller: controller)
                Spacer()
                if let savedURL = controller.savedURL {
                    Button {
                        controller.revealSaved()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                            Text("Saved to \(savedURL.deletingLastPathComponent().lastPathComponent)")
                                .font(Theme.label)
                                .tracking(Theme.labelTracking)
                                .textCase(.uppercase)
                        }
                        .foregroundStyle(Theme.accent(scheme))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Show the saved file in the Finder")
                }
                if controller.canSave {
                    Button("Copy report") { controller.copyReport() }
                        .buttonStyle(FlatButton(prominent: false))
                    Button("Save WAV") { controller.save() }
                        .buttonStyle(FlatButton(prominent: true))
                        .keyboardShortcut("s", modifiers: .command)
                }
                if case .idle = controller.phase {} else {
                    Button("New") { controller.reset() }
                        .buttonStyle(FlatButton(prominent: false))
                }
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 13)
        }
    }
}

private struct IntensityPicker: View {
    @ObservedObject var controller: MasteringController
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Intensity.allCases, id: \.self) { intensity in
                let selected = controller.intensity == intensity
                Button {
                    guard controller.intensity != intensity else { return }
                    controller.intensity = intensity
                    controller.reprocess()
                } label: {
                    VStack(spacing: 2) {
                        Text(intensity.label)
                            .font(Theme.label)
                            .tracking(Theme.labelTracking)
                        Text("\(Int(intensity.targetLUFS)) LUFS")
                            .font(Theme.data(9))
                            .opacity(0.6)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .foregroundStyle(selected ? Theme.paper(scheme) : Theme.ink(scheme).opacity(0.6))
                    .background(selected ? Theme.ink(scheme) : .clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .overlay(Rectangle().stroke(Theme.ink(scheme).opacity(0.3), lineWidth: 1))
    }
}

struct FlatButton: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.label)
            .tracking(Theme.labelTracking)
            .textCase(.uppercase)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .foregroundStyle(prominent ? Theme.paper(scheme) : Theme.ink(scheme))
            .background(prominent ? Theme.accent(scheme) : Color.clear)
            .overlay(Rectangle().stroke(Theme.ink(scheme).opacity(prominent ? 0 : 0.3), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

// MARK: - States

private struct DropView: View {
    let targeted: Bool
    let onChoose: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Text("DROP A TRACK")
                .font(Theme.masthead(64))
                .tracking(-1)
                .foregroundStyle(targeted ? Theme.accent(scheme) : Theme.ink(scheme))

            Rule(weight: 2, opacity: 0.35)
                .frame(width: 300)
                .padding(.vertical, 16)

            Text("It is analysed, corrected, levelled and limited\non this machine. Nothing is uploaded.")
                .font(Theme.body)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .opacity(0.65)

            Button("Choose a file", action: onChoose)
                .buttonStyle(FlatButton(prominent: false))
                .padding(.top, 22)

            Spacer()

            SectionLabel("WAV · MP3 · M4A · AIFF · FLAC · CAF")
                .padding(.bottom, 22)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(perform: onChoose)
    }
}

private struct WorkingView: View {
    let name: String
    let stageText: String
    let progress: Double
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()
            SectionLabel("Now Working")
            Text(name)
                .font(Theme.headline(26))
                .lineLimit(2)
                .padding(.top, 6)

            HStack(spacing: 10) {
                Text(stageText)
                    .font(Theme.data(11, weight: .semibold))
                    .tracking(1.4)
                    .foregroundStyle(Theme.accent(scheme))
                Text(String(format: "%3.0f%%", progress * 100))
                    .font(Theme.data(11))
                    .opacity(0.5)
                    .monospacedDigit()
            }
            .padding(.top, 20)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Theme.ink(scheme).opacity(0.14))
                    Rectangle()
                        .fill(Theme.accent(scheme))
                        .frame(width: geometry.size.width * progress)
                }
            }
            .frame(height: 3)
            .padding(.top, 8)
            .animation(.easeOut(duration: 0.3), value: progress)

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 26)
    }
}

private struct FailureView: View {
    let message: String
    let onReset: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Spacer()
            SectionLabel("Could Not Read", color: Theme.accent(scheme))
            Text(message)
                .font(Theme.headline(20))
                .fixedSize(horizontal: false, vertical: true)
            Button("Try another file", action: onReset)
                .buttonStyle(FlatButton(prominent: false))
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 26)
    }
}
