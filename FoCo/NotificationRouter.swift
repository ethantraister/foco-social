import Foundation
import UserNotifications

/// Tapping a notification opens the tab it's about, and food alerts still show as banners while the app is open.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()

    /// Tab numbers match ContentView's tabs.
    static func tab(for identifier: String) -> Int? {
        if identifier.hasPrefix("invite|") || identifier == "autoCheckin" { return 1 }
        if identifier.hasPrefix("watch|") { return 3 }
        return nil
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let tab = Self.tab(for: response.notification.request.identifier) else { return }
        await MainActor.run { UserDefaults.standard.set(tab, forKey: "tab") }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
