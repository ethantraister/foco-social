import SwiftUI
import UserNotifications

@main
struct FoCoApp: App {
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

    @AppStorage("tab") private var tab = 0
    @AppStorage("onboarded") private var onboarded = false
    @Environment(SocialStore.self) private var social

    var body: some View {
        TabView(selection: $tab) {
            Tab("Menu", systemImage: "fork.knife", value: 0) { MenuView() }
            Tab("Together", systemImage: "person.2.fill", value: 1) {
                SignInGate(reason: "See which friends are at FoCo right now, make meal plans, and get invited to team dinners.") { TogetherView() }
            }
            .badge(social.invites.count + social.incoming.count)
            Tab("Feed", systemImage: "camera.fill", value: 2) {
                SignInGate(reason: "Post your plate and vote for the best meal of the day.") { FeedView() }
            }
            Tab("Alerts", systemImage: "bell.badge", value: 3) { AlertsView() }
            Tab("Me", systemImage: "person.crop.circle", value: 4) { MeView() }
        }
        .fullScreenCover(isPresented: Binding(get: { !onboarded }, set: { onboarded = !$0 })) {
            OnboardingView()
        }
    }
}
