import Observation
import SwiftUI
import UIKit
import UserNotifications

/// The tabs, in the order they sit along the bottom.
enum AppTab: Int, CaseIterable {
    case menu = 0, chats, together, alerts, me
}

/// Where a tapped notification should land, for the screens to pick up.
@MainActor @Observable
final class AppRouter {
    static let shared = AppRouter()
    var pendingChat: ChatTarget?
    var pendingPlan: UUID?

    func open(_ route: [String: Any]) {
        if let key = route["chat"] as? String, let chat = ChatTarget(key: key) {
            UserDefaults.standard.set(AppTab.chats.rawValue, forKey: "tab")
            pendingChat = chat
        } else if let raw = route["plan"] as? String, let plan = UUID(uuidString: raw) {
            UserDefaults.standard.set(AppTab.together.rawValue, forKey: "tab")
            pendingPlan = plan
        } else if route["tab"] as? String == "together" {
            UserDefaults.standard.set(AppTab.together.rawValue, forKey: "tab")
        }
    }
}

/// Push notifications from friends: asks once, then hands this phone's token to the server on every launch.
enum Push {
    static func registerIfAllowed(ask: Bool) async {
        let center = UNUserNotificationCenter.current()
        var status = await center.notificationSettings().authorizationStatus
        if status == .notDetermined && ask {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            status = await center.notificationSettings().authorizationStatus
        }
        guard status == .authorized || status == .provisional || status == .ephemeral else { return }
        await MainActor.run { UIApplication.shared.registerForRemoteNotifications() }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        MaybeReminders.registerCategory()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in await SocialStore.shared.setDeviceToken(hex) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {}
}

/// "Still a maybe for dinner?" 30 minutes before a plan you said Maybe to, with Going / Can't make it right on it.
enum MaybeReminders {
    static let category = "maybeReminder"
    private static let prefix = "maybe|"

    /// On unless turned off in Me → Notifications.
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "maybeReminders") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "maybeReminders") }
    }

    static func registerCategory() {
        let going = UNNotificationAction(identifier: "going", title: "Going")
        let cant = UNNotificationAction(identifier: "declined", title: "Can't make it")
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: category, actions: [going, cant], intentIdentifiers: []),
        ])
    }

    /// Keeps one reminder per Maybe plan; drops the ones you've since answered.
    static func schedule(for plans: [Plan]) {
        let center = UNUserNotificationCenter.current()
        let wanted = enabled ? plans.filter { $0.startsAt.addingTimeInterval(-30 * 60) > .now } : []
        center.getPendingNotificationRequests { pending in
            let keep = Set(wanted.map { prefix + $0.id.uuidString })
            let stale = pending.map(\.identifier).filter { $0.hasPrefix(prefix) && !keep.contains($0) }
            center.removePendingNotificationRequests(withIdentifiers: stale)
            for plan in wanted {
                let content = UNMutableNotificationContent()
                content.title = "Still a maybe for \(plan.mealKind?.title.lowercased() ?? "the meal")?"
                let time = plan.startsAt.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: FoCoCalendar.tz))
                content.body = "\(plan.group?.name ?? plan.host.firstName)'s plan starts at \(time). Let them know if you're coming."
                content.sound = .default
                content.categoryIdentifier = category
                content.userInfo = ["route": ["plan": plan.id.uuidString]]
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: plan.startsAt.addingTimeInterval(-30 * 60).timeIntervalSinceNow, repeats: false)
                center.add(UNNotificationRequest(identifier: prefix + plan.id.uuidString, content: content, trigger: trigger))
            }
        }
    }

    static func cancelAll() {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { pending in
            center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(prefix) })
        }
    }
}
