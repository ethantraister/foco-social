import Observation
import SwiftUI

/// Whether the bottom bar shows: it steps aside for the keyboard. Also tracks which tabs
/// have a screen pushed on top, since swiping sideways there should go back, not to the next tab.
@MainActor @Observable
final class TabBarState {
    static let shared = TabBarState()
    static let height: CGFloat = 62

    var keyboardUp = false
    var visible: Bool { !keyboardUp }

    /// While the pages are being swiped: where they are (0 = Menu … 4 = Me, in between mid-swipe). Only the bar
    /// reads it, so swiping redraws the bar and not the pages.
    var swipe: CGFloat?

    /// How many of each tab's first screens are showing (0 while something is pushed on top).
    private var roots: [Int: Int] = [:]
    func canSwipe(from tab: Int) -> Bool { roots[tab, default: 1] > 0 }
    func rootAppeared(_ tab: Int) { roots[tab, default: 0] += 1 }
    func rootDisappeared(_ tab: Int) { roots[tab, default: 1] -= 1 }
}

/// The bottom bar: one floating Liquid Glass capsule with the three tabs. Together sits in the middle as a
/// Dartmouth Green button (like Venmo's Pay/Request). The soft highlight behind the selected tab follows your
/// finger while you swipe between pages.
struct FoCoTabBar: View {
    @Binding var selection: Int
    let togetherBadge: Int
    @State private var bar = TabBarState.shared

    var body: some View {
        HStack(spacing: 0) {
            item(.menu, "Menu", "fork.knife", "fork.knife")
            together
            item(.me, "Me", "person.crop.circle", "person.crop.circle.fill")
        }
        .background { highlight }
        .padding(.horizontal, 6)
        .frame(height: TabBarState.height)
        // Three tabs hug the middle, like the system's bar, instead of stretching edge to edge.
        .frame(maxWidth: 300)
        .glass(in: Capsule())
        .padding(.horizontal, 14)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tab bar")
        .accessibilityIdentifier("tabBar")
    }

    /// The soft pill behind the selected tab, like the system bar's. It fades on its way into Together, whose green
    /// button stands out on its own.
    private var highlight: some View {
        GeometryReader { geo in
            let slot = geo.size.width / CGFloat(AppTab.allCases.count)
            let at = bar.swipe ?? CGFloat(selection)
            Capsule()
                .fill(Color.primary.opacity(0.07))
                .frame(width: slot)
                .offset(x: at * slot)
                .opacity(min(1, abs(at - CGFloat(AppTab.together.rawValue))))
                .animation(bar.swipe == nil ? .snappy(duration: 0.28) : nil, value: at)
        }
        .accessibilityHidden(true)
    }

    private func item(_ tab: AppTab, _ title: String, _ icon: String, _ selectedIcon: String, badge: Int = 0) -> some View {
        let selected = selection == tab.rawValue
        return Button { selection = tab.rawValue } label: {
            VStack(spacing: 2) {
                Image(systemName: selected ? selectedIcon : icon)
                    .font(.system(size: 19, weight: selected ? .semibold : .regular))
                    .frame(height: 24)
                    .overlay(alignment: .topTrailing) { Badge(count: badge).offset(x: 12, y: -6) }
                Text(title).font(.system(size: 10.5, weight: selected ? .semibold : .medium)).lineLimit(1).fixedSize()
            }
            .foregroundStyle(selected ? Color.accentColor : Color.primary.opacity(0.88))
            .frame(maxWidth: .infinity)
            .frame(height: TabBarState.height - 12)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityIdentifier("tab.\(title)")
        .accessibilityValue(badge > 0 ? "\(badge) new" : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var together: some View {
        let selected = selection == AppTab.together.rawValue
        return Button { selection = AppTab.together.rawValue } label: {
            VStack(spacing: 2) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .frame(height: 24)
                Text("Together").font(.system(size: 10.5, weight: .bold)).lineLimit(1).fixedSize()
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: TabBarState.height - 12)
            .background {
                // Solid, not a second layer of glass: glass on glass turns muddy. The gradient and the fine edge give
                // it the same sheen as the bar around it.
                Capsule()
                    .fill(Color.dartmouthDeep.gradient)
                    .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 0.5))
                    .shadow(color: Color.dartmouthDeep.opacity(0.35), radius: 6, y: 2)
                    .padding(.horizontal, 1)
            }
            .overlay(alignment: .topTrailing) { Badge(count: togetherBadge).offset(x: 2, y: -5) }
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Together")
        .accessibilityIdentifier("tab.Together")
        .accessibilityValue(togetherBadge > 0 ? "\(togetherBadge) new" : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .sensoryFeedback(.selection, trigger: selected)
    }
}

private struct Badge: View {
    let count: Int
    var body: some View {
        if count > 0 {
            Text(count > 99 ? "99+" : "\(count)")
                .font(.caption2.weight(.bold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .frame(minWidth: 18, minHeight: 18)
                .background(Color(red: 0.84, green: 0.13, blue: 0.12), in: .capsule)   // a deeper red, so white numbers stay readable on glass
                .accessibilityHidden(true)
        }
    }
}

extension EnvironmentValues {
    /// Whether this tab's page is the one on screen. All the pages stay loaded so you can swipe between them,
    /// so anything that refreshes on a timer should only run while this is true.
    @Entry var tabIsActive = true
    /// Which tab's page a view is on.
    @Entry var pagerTab: AppTab? = nil
}

/// Each tab's page: every list in it (pushed screens too) can scroll its last rows clear of our bar. A safe-area
/// inset here doesn't reach lists inside the navigation stack, but content margins do.
private struct TabContent: ViewModifier {
    @State private var bar = TabBarState.shared
    func body(content: Content) -> some View {
        content
            .contentMargins(.bottom, bar.visible ? TabBarState.height + 20 : 0, for: .automatic)
    }
}

/// On a tab's first screen: notes when a screen is pushed on top of it.
private struct TabRoot: ViewModifier {
    @Environment(\.pagerTab) private var tab
    func body(content: Content) -> some View {
        content
            .background { NavigationMargins().frame(width: 0, height: 0).accessibilityHidden(true) }
            .onAppear { if let tab { TabBarState.shared.rootAppeared(tab.rawValue) } }
            .onDisappear { if let tab { TabBarState.shared.rootDisappeared(tab.rawValue) } }
    }
}

/// In the pager, a tab's navigation stack isn't inside a system tab bar, and UIKit then gives it no side margins:
/// large titles sat against the screen's edge. This gives the stack the screen's usual margins.
private struct NavigationMargins: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {}

    final class Controller: UIViewController {
        override func viewIsAppearing(_ animated: Bool) {
            super.viewIsAppearing(animated)
            var next: UIResponder? = view
            while let responder = next, !(responder is UINavigationController) { next = responder.next }
            guard let nav = next as? UINavigationController,
                  let screen = view.window?.rootViewController?.systemMinimumLayoutMargins else { return }
            nav.viewRespectsSystemMinimumLayoutMargins = false
            nav.view.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: screen.leading, bottom: 0, trailing: screen.trailing)
        }
    }
}

extension View {
    /// For sideways scrolling rows inside a tab: no room for the bottom bar (they'd grow taller).
    func noTabBarMargin() -> some View { contentMargins(.bottom, 0, for: .automatic) }
}

extension View {
    func tabContent() -> some View { modifier(TabContent()) }

    /// Marks a tab's first screen (inside its navigation stack), so swiping sideways only changes tabs from there.
    func tabRoot() -> some View { modifier(TabRoot()) }
}
