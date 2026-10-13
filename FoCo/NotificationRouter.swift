import Foundation
import UserNotifications

/// Tapping a notification opens what it's about; food alerts and friends' notifications show as banners while the app is open,
/// except a message for the chat you're already looking at.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()

    /// Local notifications, by identifier.
    static func tab(for identifier: String) -> AppTab? {
        if identifier == "autoCheckin" { return .together }
        if identifier.hasPrefix("watch|") { return .alerts }
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
        let route = notification.request.content.userInfo["route"] as? [String: Any]
        guard let route else { return [.banner, .list, .sound] }   // food alerts, check-in notices
        return await MainActor.run {
            let social = SocialStore.shared
            Task { await social.refreshChats(); await social.refreshTogether() }
            if let key = route["chat"] as? String, social.openChat?.key == key { return [] }
            return [.banner, .list, .sound]
        }
    }
}
