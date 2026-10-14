import SwiftUI
import UserNotifications

@main
struct FoCoApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = MenuStore.shared
    @State private var prefs = Preferences.shared
    @State private var social = SocialStore.shared
    @Environment(\.scenePhase) private var phase

    init() {
        // Created at launch so iOS can wake the app when you arrive at or leave FoCo.
        _ = PresenceMonitor.shared
        // Set before launch finishes, so a notification that opens the app still lands on the right tab.
        UNUserNotificationCenter.current().delegate = NotificationRouter.shared
        // Photos stay on disk between launches. Every upload has its own file name, so they never go stale.
        URLCache.shared = URLCache(memoryCapacity: 16 << 20, diskCapacity: 200 << 20)
        // Everyone lands on Together. (A notification that opened the app moves to its own screen after this.)
        UserDefaults.standard.set(AppTab.together.rawValue, forKey: "tab")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .tint(.dartmouthGreen)
                .environment(store)
                .environment(prefs)
                .environment(social)
                .task { await social.bootstrap() }
                // The message is the title: "That code didn't work…" reads better than "Something went wrong" above it.
                .alert(social.errorMessage ?? "", isPresented: Binding(get: { social.errorMessage != nil }, set: { if !$0 { social.errorMessage = nil } })) {
                    Button("OK", role: .cancel) {}
                }
        }
        .onChange(of: phase) { _, newPhase in
            switch newPhase {
            case .active: Task {
                await social.resume()
                PresenceMonitor.shared.refresh()
                await AlertScheduler.reschedule()
                if social.phase == .ready { await Push.registerIfAllowed(ask: false) }
            }
            case .background: AlertScheduler.scheduleBackgroundRefresh()
            default: break
            }
        }
        .backgroundTask(.appRefresh(AlertScheduler.refreshTaskID)) {
            await AlertScheduler.scheduleBackgroundRefresh()
            await AlertScheduler.reschedule()
            await SocialStore.shared.refreshTogether()
        }
    }
}

struct ContentView: View {
    // Applied here, not in FoCoApp.init: touching UIKit appearance that early drops the global accent color (the app turns iOS blue).
    init() { Theme.apply() }

    @AppStorage("tab") private var tab = AppTab.together.rawValue
    @AppStorage("onboarded") private var onboarded = false
    @Environment(SocialStore.self) private var social
    @State private var bar = TabBarState.shared

    var body: some View {
        ZStack {
            // The tabs side by side, swiped between like Instagram's. With a screen pushed on top of a tab,
            // a sideways swipe goes back (the system's gesture) instead.
            TabPager(selection: $tab, swipeEnabled: bar.canSwipe(from: tab))
                .ignoresSafeArea()
        }
        .overlay(alignment: .bottom) {
            GeometryReader { geo in
                let bottom = geo.safeAreaInsets.bottom
                ZStack(alignment: .bottom) {
                    // Like the system's scroll edge effect: what scrolls under the bar fades, so the bar stays readable.
                    if bar.visible {
                        // Only as tall as the bar's own space, so rows above the bar aren't washed out.
                        LinearGradient(stops: [.init(color: Color(uiColor: .systemGroupedBackground).opacity(0), location: 0),
                                               .init(color: Color(uiColor: .systemGroupedBackground).opacity(0.7), location: 0.5),
                                               .init(color: Color(uiColor: .systemGroupedBackground).opacity(0.9), location: 1)],
                                       startPoint: .top, endPoint: .bottom)
                            .frame(height: TabBarState.height + bottom + 8)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                    VStack(spacing: 8) {
                        // "Plan cancelled · Undo" and other notes, just above the bottom bar on every tab.
                        if let toast = social.toast { ToastBar(toast: toast).padding(.bottom, bar.visible ? 0 : 64) }
                        if bar.visible {
                            FoCoTabBar(selection: $tab, chatsBadge: social.unreadMessages, togetherBadge: social.togetherBadge)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    // The bar floats a little into the home-indicator area, like the system's.
                    .padding(.bottom, bottom > 0 ? max(bottom - 14, 6) : 8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .ignoresSafeArea(edges: .bottom)
            }
        }
        .animation(.snappy(duration: 0.2), value: bar.visible)
        .animation(.snappy, value: social.toast?.id)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in bar.keyboardUp = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in bar.keyboardUp = false }
        .fullScreenCover(isPresented: Binding(get: { !onboarded }, set: { onboarded = !$0 })) {
            OnboardingView()
        }
    }
}
