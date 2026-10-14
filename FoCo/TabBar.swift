import Observation
import SwiftUI

/// Whether the bottom bar shows: it steps aside for the keyboard and for full-screen chats.
@MainActor @Observable
final class TabBarState {
    static let shared = TabBarState()
    static let height: CGFloat = 62

    var keyboardUp = false
    private var hiders = 0
    var visible: Bool { !keyboardUp && hiders == 0 }

    func hide() { hiders += 1 }
    func show() { hiders = max(0, hiders - 1) }
}

/// The bottom bar: a floating Liquid Glass capsule with four tabs, and Together raised in the middle as a
/// Dartmouth Green glass button (like Venmo's Pay/Request). Both are one glass group, so where the button
/// meets the bar they flow into each other.
struct FoCoTabBar: View {
    @Binding var selection: Int
    let chatsBadge: Int
    let togetherBadge: Int
    @Namespace private var selectionSpace

    var body: some View {
        GlassGroup(spacing: 14) {
            ZStack(alignment: .top) {
                HStack(spacing: 0) {
                    item(.menu, "Menu", "fork.knife", "fork.knife")
                    item(.chats, "Chats", "bubble.left.and.bubble.right", "bubble.left.and.bubble.right.fill", badge: chatsBadge)
                    Color.clear.frame(width: 84)
                    item(.alerts, "Alerts", "bell", "bell.fill")
                    item(.me, "Me", "person.crop.circle", "person.crop.circle.fill")
                }
                .padding(.horizontal, 6)
                .frame(height: TabBarState.height)
                .glass(in: Capsule())
                together
            }
        }
        // Drawn above the glass layer (inside the glass group it ended up underneath, and vanished).
        .overlay(alignment: .bottom) {
            Text("Together")
                .font(.system(size: 10.5, weight: .bold))
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(selection == AppTab.together.rawValue ? Color.accentColor : Color.primary)
                .padding(.bottom, 8)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tab bar")
        .accessibilityIdentifier("tabBar")
        .animation(.snappy(duration: 0.28), value: selection)
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
            .background {
                // The selected tab sits in a soft pill that slides across, like the system bar's.
                if selected {
                    Capsule()
                        .fill(Color.primary.opacity(0.07))
                        .matchedGeometryEffect(id: "selected", in: selectionSpace)
                }
            }
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
            Image(systemName: "person.2.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .glass(in: Circle(), tint: .dartmouthDeep, interactive: true)
                .overlay(alignment: .topTrailing) { Badge(count: togetherBadge).offset(x: 2, y: -2) }
                .offset(y: -27)
                .frame(width: 84, height: TabBarState.height, alignment: .top)
                .contentShape(.rect)
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

/// Each tab's content: the system tab bar hidden (ours replaces it), and every list in the tab (pushed screens too)
/// able to scroll its last rows clear of our bar. A safe-area inset here doesn't reach lists inside the
/// navigation stack, but content margins do.
private struct TabContent: ViewModifier {
    @State private var bar = TabBarState.shared
    func body(content: Content) -> some View {
        content
            .toolbar(.hidden, for: .tabBar)
            .contentMargins(.bottom, bar.visible ? TabBarState.height + 20 : 0, for: .automatic)
    }
}

extension View {
    /// For sideways scrolling rows inside a tab: no room for the bottom bar (they'd grow taller).
    func noTabBarMargin() -> some View { contentMargins(.bottom, 0, for: .automatic) }
}

extension View {
    func tabContent() -> some View { modifier(TabContent()) }

    /// For screens that take the whole height, like a chat: the bottom bar steps aside while they're up.
    func hidesTabBar() -> some View {
        onAppear { TabBarState.shared.hide() }
            .onDisappear { TabBarState.shared.show() }
    }
}
