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
        TabView(selection: $tab) {
            Tab("Menu", systemImage: "fork.knife", value: AppTab.menu.rawValue) { MenuView().tabContent() }
            Tab("Chats", systemImage: "bubble.left.and.bubble.right", value: AppTab.chats.rawValue) {
                SignInGate(reason: "Message friends, your groups, and the people in each meal plan.") { ChatsView() }.tabContent()
            }
            Tab("Together", systemImage: "person.2.fill", value: AppTab.together.rawValue) {
                SignInGate(reason: "See which friends are at FoCo right now, make meal plans, and get invited to team dinners.") { TogetherView() }
                    .tabContent()
            }
            Tab("Alerts", systemImage: "bell.badge", value: AppTab.alerts.rawValue) { AlertsView().tabContent() }
            Tab("Me", systemImage: "person.crop.circle", value: AppTab.me.rawValue) { MeView().tabContent() }
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 6) {
                // "Plan cancelled · Undo" and other notes, just above the bottom bar on every tab.
                if let toast = social.toast { ToastBar(toast: toast).padding(.bottom, bar.visible ? 0 : 64) }
                if bar.visible {
                    FoCoTabBar(selection: $tab, chatsBadge: social.unreadMessages, togetherBadge: social.togetherBadge)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
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
