import Foundation
import UserNotifications

/// Tapping a notification opens what it's about; food alerts and friends' notifications show as banners while the app is open.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()

    /// Local notifications, by identifier.
    static func tab(for identifier: String) -> AppTab? {
        if identifier == "autoCheckin" { return .together }
        if identifier.hasPrefix("watch|") { return .menu }
        return nil
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let request = response.notification.request
        let route = request.content.userInfo["route"] as? [String: Any]

        // "Going" / "Can't make it" on a Maybe reminder: answer without opening the app.
        if request.content.categoryIdentifier == MaybeReminders.category,
           let status = RSVP(rawValue: response.actionIdentifier),
           let raw = route?["plan"] as? String, let planId = UUID(uuidString: raw) {
            await Self.answer(planId, status)
            return
        }

        await MainActor.run {
            if let route {
                AppRouter.shared.open(route)
            } else if let tab = Self.tab(for: request.identifier) {
                UserDefaults.standard.set(tab.rawValue, forKey: "tab")
            }
        }
    }

    @MainActor
    private static func answer(_ planId: UUID, _ status: RSVP) async {
        let social = SocialStore.shared
        if !social.together.plans.contains(where: { $0.id == planId }) { await social.refreshTogether() }
        guard let plan = social.together.plans.first(where: { $0.id == planId }) else { return }
        await social.respond(plan, status, toggle: false)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        if notification.request.content.userInfo["route"] != nil {
            // A friend's news: Together catches up while the banner shows.
            Task { @MainActor in await SocialStore.shared.refreshTogether() }
        }
        return [.banner, .list, .sound]
    }
}
