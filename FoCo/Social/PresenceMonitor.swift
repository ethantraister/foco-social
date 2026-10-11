import CoreLocation
import Foundation
import Observation
import UIKit
import UserNotifications

/// Checks you in when you walk into FoCo during a meal and out when you leave.
@MainActor @Observable
final class PresenceMonitor: NSObject, CLLocationManagerDelegate {
    static let shared = PresenceMonitor()

    /// Class of 1953 Commons, from OpenStreetMap (building is ~90 m east–west, ~30 m north–south).
    static let foco = CLLocation(latitude: 43.70310, longitude: -72.29092)
    private static let regionRadius: CLLocationDistance = 70
    private static let confirmRadius: CLLocationDistance = 60

    private let manager = CLLocationManager()
    private(set) var authorization: CLAuthorizationStatus = .notDetermined
    private(set) var isInside = false

    var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "autoCheckin")
            if enabled { requestPermission() }
            apply()
        }
    }

    /// Set when you tap Leave while still inside, so the app doesn't check you right back in.
    private var leftManually: Bool {
        get { UserDefaults.standard.bool(forKey: "autoCheckin.leftManually") }
        set { UserDefaults.standard.set(newValue, forKey: "autoCheckin.leftManually") }
    }

    var needsAlways: Bool { enabled && authorization == .authorizedWhenInUse }
    var isDenied: Bool { enabled && (authorization == .denied || authorization == .restricted) }
    /// On and allowed (with only "While Using", it still works while the app is open).
    var isWorking: Bool { enabled && !isDenied }

    private override init() {
        #if DEBUG
        if CommandLine.arguments.contains("-resetForUITests") {
            for key in ["autoCheckin", "autoCheckin.leftManually", "autoCheckin.active"] { UserDefaults.standard.removeObject(forKey: key) }
        }
        #endif
        enabled = UserDefaults.standard.bool(forKey: "autoCheckin")
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        authorization = manager.authorizationStatus
        apply()
    }

    func requestPermission() {
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse: manager.requestAlwaysAuthorization()
        default: break
        }
    }

    /// Called when the app opens: catches arrivals iOS hasn't reported yet.
    func refresh() {
        guard enabled, authorization == .authorizedAlways || authorization == .authorizedWhenInUse else { return }
        manager.requestLocation()
    }

    func userLeft() {
        if isInside { leftManually = true }
    }

    private var region: CLCircularRegion {
        let r = CLCircularRegion(center: Self.foco.coordinate, radius: Self.regionRadius, identifier: "foco")
        r.notifyOnEntry = true
        r.notifyOnExit = true
        return r
    }

    private func apply() {
        let monitoring = manager.monitoredRegions.contains { $0.identifier == "foco" }
        if enabled && authorization == .authorizedAlways {
            if !monitoring { manager.startMonitoring(for: region) }
            manager.requestState(for: region)
        } else if monitoring {
            manager.stopMonitoring(for: region)
        }
        if enabled { refresh() }
    }

    // MARK: Arrive / leave

    private func arrived() async {
        guard enabled, !leftManually, let serving = Meal.serving() else { return }
        let social = SocialStore.shared
        if social.myId == nil { return }
        if social.together.checkins.isEmpty { await social.refreshTogether() }
        guard social.myCheckin == nil else { return }
        let minutes = max(30, min(120, Int(serving.ends.timeIntervalSinceNow / 60)))
        if await social.checkIn(spot: nil, minutes: minutes, auto: true) {
            notifyCheckedIn(serving.meal)
        }
    }

    private func departed() async {
        leftManually = false
        guard enabled, UserDefaults.standard.bool(forKey: "autoCheckin.active") else { return }
        await SocialStore.shared.checkOut(manual: false)
    }

    private func notifyCheckedIn(_ meal: Meal) {
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = "You're checked in at FoCo"
        content.body = "Friends can see you're at \(meal.title.lowercased()). Open the app to say dark side, light side, or upstairs."
        content.interruptionLevel = .passive
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "autoCheckin", content: content, trigger: nil))
    }

    // MARK: CLLocationManagerDelegate (delivered on the main thread)

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            authorization = status
            if enabled && status == .authorizedWhenInUse { manager.requestAlwaysAuthorization() }
            apply()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        MainActor.assumeIsolated {
            if state == .inside { manager.requestLocation() }
            else if state == .outside && isInside { isInside = false; Task { await departed() } }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        MainActor.assumeIsolated { manager.requestLocation() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        MainActor.assumeIsolated {
            isInside = false
            Task { await departed() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let fix = locations.last else { return }
        MainActor.assumeIsolated {
            let distance = fix.distance(from: Self.foco)
            let inside = distance <= Self.confirmRadius && fix.horizontalAccuracy <= 65
            if inside {
                isInside = true
                Task { await arrived() }
            } else if distance > Self.regionRadius + 30 {
                // Also catches a departure iOS didn't report while the app was closed.
                isInside = false
                Task { await departed() }
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
