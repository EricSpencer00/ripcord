import SwiftUI

/// Newsprint classified ads: ink on paper, hairline column rules, one signal colour, and numbers
/// set in monospace so columns line up the way a printed listing does.
enum Theme {
    static func paper(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.086, green: 0.082, blue: 0.075)
                        : Color(red: 0.929, green: 0.914, blue: 0.878)
    }

    static func ink(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.914, green: 0.894, blue: 0.847)
                        : Color(red: 0.110, green: 0.106, blue: 0.090)
    }

    /// The single signal colour. Used for the accent rule, the headline figure, and nothing else.
    static func accent(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.949, green: 0.404, blue: 0.133)
                        : Color(red: 0.831, green: 0.322, blue: 0.106)
    }

    // MARK: - Type

    /// Condensed grotesque, the way a classified masthead is set.
    static func masthead(_ size: CGFloat) -> Font {
        .system(size: size, weight: .black).width(.compressed)
    }

    static func headline(_ size: CGFloat) -> Font {
        .system(size: size, weight: .bold).width(.condensed)
    }

    /// Small caps section labels, tracked out.
    static let label = Font.system(size: 9, weight: .semibold)

    /// Figures always set monospaced so columns align.
    static func data(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static let body = Font.system(size: 12)

    static let labelTracking: CGFloat = 1.7
}

/// A hairline column rule.
struct Rule: View {
    @Environment(\.colorScheme) private var scheme
    var weight: CGFloat = 1
    var opacity: Double = 0.22

    var body: some View {
        Rectangle()
            .fill(Theme.ink(scheme).opacity(opacity))
            .frame(height: weight)
    }
}

/// A tracked-out small-caps label, the recurring unit of the layout.
struct SectionLabel: View {
    @Environment(\.colorScheme) private var scheme
    let text: String
    var color: Color?

    init(_ text: String, color: Color? = nil) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text.uppercased())
            .font(Theme.label)
            .tracking(Theme.labelTracking)
            .foregroundStyle(color ?? Theme.ink(scheme).opacity(0.55))
    }
}

/// The one piece of motion in the app: a single left-to-right wipe that reveals content once.
struct Wipe: ViewModifier {
    let active: Bool
    @State private var progress: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .mask(alignment: .leading) {
                GeometryReader { geometry in
                    Rectangle()
                        .frame(width: geometry.size.width * progress)
                }
            }
            .onAppear {
                guard active else { progress = 1; return }
                withAnimation(.easeOut(duration: 0.55)) { progress = 1 }
            }
    }
}

extension View {
    func wipeIn(_ active: Bool = true) -> some View {
        modifier(Wipe(active: active))
    }
}
