import Observation
import SwiftUI

/// Whether the bottom bar shows: it steps aside for the keyboard and for full-screen chats.
@MainActor @Observable
final class TabBarState {
    static let shared = TabBarState()
    static let height: CGFloat = 58

    var keyboardUp = false
    private var hiders = 0
    var visible: Bool { !keyboardUp && hiders == 0 }

    func hide() { hiders += 1 }
    func show() { hiders = max(0, hiders - 1) }
}

/// The bottom bar: four tabs, with Together raised in the middle in Dartmouth Green (like Venmo's Pay/Request).
struct FoCoTabBar: View {
    @Binding var selection: Int
    let chatsBadge: Int
    let togetherBadge: Int

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            item(.menu, "Menu", "fork.knife", "fork.knife")
            item(.chats, "Chats", "bubble.left.and.bubble.right", "bubble.left.and.bubble.right.fill", badge: chatsBadge)
            together
            item(.alerts, "Alerts", "bell", "bell.fill")
            item(.me, "Me", "person.crop.circle", "person.crop.circle.fill")
        }
        .padding(.horizontal, 4)
        .frame(minHeight: TabBarState.height)
        // Solid, so labels stay readable over whatever scrolls behind (and like Venmo's).
        .background {
            Rectangle()
                .fill(Color(uiColor: .systemBackground))
                .overlay(alignment: .top) { Divider() }
                .shadow(color: .black.opacity(0.04), radius: 6, y: -2)
                .ignoresSafeArea(edges: .bottom)
        }
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tab bar")
        .accessibilityIdentifier("tabBar")
    }

    private func item(_ tab: AppTab, _ title: String, _ icon: String, _ selectedIcon: String, badge: Int = 0) -> some View {
        let selected = selection == tab.rawValue
        return Button { selection = tab.rawValue } label: {
            VStack(spacing: 3) {
                Image(systemName: selected ? selectedIcon : icon)
                    .font(.system(size: 21, weight: selected ? .semibold : .regular))
                    .frame(height: 26)
                    .overlay(alignment: .topTrailing) { Badge(count: badge).offset(x: 12, y: -6) }
                Text(title).font(.caption2.weight(selected ? .semibold : .medium)).lineLimit(1).fixedSize()
            }
            .foregroundStyle(selected ? Color.dartmouthGreen : Color.primary.opacity(0.7))
            .frame(maxWidth: .infinity)
            .padding(.bottom, 4)
            .contentShape(.rect)
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
                ZStack {
                    Circle()
                        .fill(Color(red: 0, green: 0x69 / 255, blue: 0x3e / 255).gradient)
                        .overlay(Circle().strokeBorder(Color(uiColor: .systemBackground), lineWidth: 4))
                        .shadow(color: .black.opacity(selected ? 0.25 : 0.15), radius: selected ? 8 : 5, y: 3)
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 66, height: 66)
                .overlay(alignment: .topTrailing) { Badge(count: togetherBadge).offset(x: -2, y: 4) }
                .offset(y: -14)
                .padding(.bottom, -14)
                Text("Together")
                    .font(.caption.weight(.bold))
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(selected ? Color.dartmouthGreen : Color.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 4)
            .contentShape(.rect)
        }
        .buttonStyle(TogetherButtonStyle())
        .accessibilityLabel("Together")
        .accessibilityIdentifier("tab.Together")
        .accessibilityValue(togetherBadge > 0 ? "\(togetherBadge) new" : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .sensoryFeedback(.selection, trigger: selected)
    }
}

private struct TogetherButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
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
                .background(.red, in: .capsule)
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
            .contentMargins(.bottom, bar.visible ? TabBarState.height + 12 : 0, for: .automatic)
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
