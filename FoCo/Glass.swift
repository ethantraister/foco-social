import SwiftUI

// Liquid Glass (iOS 26 and later) for the app's floating controls: the bottom bar, Together's two big buttons,
// answer buttons, chips, and notes. Earlier iOS versions get frosted material instead.
// Content itself (lists, cards, messages) stays solid, as Apple's guidelines ask: glass is for controls.

extension View {
    /// Liquid Glass behind the view, in a capsule.
    func glass(tint: Color? = nil, interactive: Bool = false) -> some View {
        glass(in: Capsule(), tint: tint, interactive: interactive)
    }

    /// Liquid Glass behind the view, in the given shape. A tint makes it prominent (like a filled button).
    @ViewBuilder
    func glass<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
        } else if let tint {
            background(tint, in: shape)
        } else {
            background(.regularMaterial, in: shape)
                .overlay(shape.stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
        }
    }

    /// Glass buttons: prominent ones are filled with the accent color (Dartmouth Green).
    @ViewBuilder
    func glassButton(prominent: Bool = false) -> some View {
        // Filled ones use Dartmouth Green itself in dark mode too: the lighter dark-mode accent is for text,
        // and white on it is hard to read.
        if #available(iOS 26.0, *) {
            if prominent { buttonStyle(.glassProminent).tint(.dartmouthDeep) } else { buttonStyle(.glass) }
        } else {
            if prominent { buttonStyle(.borderedProminent).tint(.dartmouthDeep) } else { buttonStyle(.bordered) }
        }
    }

    /// Names a glass shape so it morphs into its new place or shape when it moves.
    @ViewBuilder
    func glassID<ID: Hashable & Sendable>(_ id: ID, in namespace: Namespace.ID) -> some View {
        if #available(iOS 26.0, *) { glassEffectID(id, in: namespace) } else { self }
    }
}

/// Glass shapes inside blend into each other when they're close, and render together (faster).
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat? = nil
    @ViewBuilder var content: Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

extension Color {
    /// Dartmouth Green itself in both appearances (the accent color is lighter in dark mode, for text).
    static let dartmouthDeep = Color(red: 0, green: 0x69 / 255, blue: 0x3e / 255)
}

/// The backdrop behind every tab: a quiet wash of Dartmouth greens at the top that fades into the page,
/// so the glass bar and buttons have something to catch, and the app doesn't look like a settings screen.
struct Backdrop: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        ZStack(alignment: .top) {
            Color(uiColor: .systemGroupedBackground)
            MeshGradient(
                width: 3, height: 3,
                points: [[0, 0], [0.5, 0], [1, 0], [0, 0.5], [0.62, 0.42], [1, 0.55], [0, 1], [0.5, 1], [1, 1]],
                colors: dark ? [
                    Color(red: 0.03, green: 0.20, blue: 0.14), Color(red: 0.02, green: 0.15, blue: 0.12), Color(red: 0.05, green: 0.18, blue: 0.20),
                    Color(red: 0.02, green: 0.11, blue: 0.08), Color(red: 0.03, green: 0.13, blue: 0.10), Color(red: 0.02, green: 0.09, blue: 0.10),
                    .black, .black, .black,
                ] : [
                    Color(red: 0.80, green: 0.92, blue: 0.85), Color(red: 0.87, green: 0.95, blue: 0.89), Color(red: 0.84, green: 0.93, blue: 0.93),
                    Color(red: 0.90, green: 0.95, blue: 0.92), Color(red: 0.93, green: 0.97, blue: 0.94), Color(red: 0.92, green: 0.95, blue: 0.95),
                    Color(uiColor: .systemGroupedBackground), Color(uiColor: .systemGroupedBackground), Color(uiColor: .systemGroupedBackground),
                ]
            )
            .frame(height: 420)
            .mask(LinearGradient(colors: [.black, .black, .clear], startPoint: .top, endPoint: .bottom))
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

extension View {
    /// A list on the app's backdrop instead of plain gray.
    func onBackdrop() -> some View {
        scrollContentBackground(.hidden)
            .background { Backdrop() }
    }
}

/// A section's name as a bold title in the page's serif, instead of small gray text.
struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(.title3, design: .serif).weight(.bold))
            .foregroundStyle(Color.primary)
            .textCase(nil)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Settings-style row icons: a filled symbol on a small colored tile.
struct TileLabelStyle: LabelStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        Label {
            configuration.title
        } icon: {
            configuration.icon
                .symbolVariant(.fill)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(color.gradient, in: .rect(cornerRadius: 8, style: .continuous))
        }
    }
}

extension LabelStyle where Self == TileLabelStyle {
    static func tile(_ color: Color) -> TileLabelStyle { TileLabelStyle(color: color) }
}
