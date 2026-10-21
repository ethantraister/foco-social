import Foundation
import UserNotifications

/// Tapping a notification opens what it's about; food alerts and friends' notifications show as banners while the app is open.
///
/// These take iOS's completion handlers and call them on the main thread. The `async` versions of these methods
/// finish on a background thread, and iOS then updates the app's snapshot from there, which UIKit refuses: every tap
/// on a notification while the app was running crashed it (SIGABRT in -[UIApplication _updateSnapshotAndStateRestorationWithAction:]).
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()

    /// Local notifications, by identifier.
    static func tab(for identifier: String) -> AppTab? {
        if identifier == "autoCheckin" { return .together }
        if identifier.hasPrefix("watch|") { return .menu }
        return nil
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let request = response.notification.request
        let category = request.content.categoryIdentifier
        let identifier = request.identifier
        let action = response.actionIdentifier
        let route = request.content.userInfo["route"] as? [String: Any]
        let plan = (route?["plan"] as? String).flatMap(UUID.init(uuidString:))

        Task { @MainActor in
            // "Going" / "Can't make it" on a Maybe reminder: answer without opening the app.
            if category == MaybeReminders.category, let status = RSVP(rawValue: action), let plan {
                await Self.answer(plan, status)
            } else if let route {
                AppRouter.shared.open(route)
            } else if let tab = Self.tab(for: identifier) {
                UserDefaults.standard.set(tab.rawValue, forKey: "tab")
            }
            completionHandler()   // on the main thread
        }
    }

    @MainActor
    private static func answer(_ planId: UUID, _ status: RSVP) async {
        let social = SocialStore.shared
        if !social.together.plans.contains(where: { $0.id == planId }) { await social.refreshTogether() }
        guard let plan = social.together.plans.first(where: { $0.id == planId }) else { return }
        await social.respond(plan, status, toggle: false)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let fromFriend = notification.request.content.userInfo["route"] != nil
        Task { @MainActor in
            // A friend's news: Together catches up while the banner shows.
            if fromFriend { Task { await SocialStore.shared.refreshTogether() } }
            completionHandler([.banner, .list, .sound])   // on the main thread
        }
    }
}
