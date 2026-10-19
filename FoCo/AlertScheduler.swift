import BackgroundTasks
import Foundation
import UserNotifications

@MainActor
enum AlertScheduler {
    static let refreshTaskID = "com.ethantraister.FoCoSocial.refresh"
    private static let prefix = "watch|"

    static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    @discardableResult
    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    /// Menus are posted about a week ahead, so alerts are scheduled locally from the menu itself.
    static func reschedule() async {
        let keywords = Preferences.shared.alertKeywords
        let center = UNUserNotificationCenter.current()
        let stale = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(prefix) }
        center.removePendingNotificationRequests(withIdentifiers: stale)
        guard !keywords.isEmpty, await authorizationStatus() == .authorized else { return }

        await MenuStore.shared.loadUpcoming()
        for match in MenuStore.shared.matches(for: keywords, days: 8) {
            guard let fire = match.fireDate, fire > .now, let date = match.date else { continue }
            let content = UNMutableNotificationContent()
            let names = match.items.map(\.name)
            let when = FoCoCalendar.phrase(date)
            content.title = "\(match.keyword.capitalized) at FOCO"
            content.body = "\(names.prefix(3).joined(separator: ", ")) — \(match.meal.title.lowercased()) \(when) at \(match.items[0].station)."
            content.sound = .default
            var comps = FoCoCalendar.cal.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
            comps.timeZone = FoCoCalendar.tz
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: prefix + match.id, content: content, trigger: trigger))
        }
    }

    static func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        request.earliestBeginDate = FoCoCalendar.adding(days: 1, to: .now)
        try? BGTaskScheduler.shared.submit(request)
    }
}
