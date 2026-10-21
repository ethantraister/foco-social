import XCTest

/// Tapping a notification while the app is in the background must open it, not crash it. Every tap used to crash the
/// app (20 Oct 2026): the notification handler finished on a background thread, where UIKit refuses to update the
/// app's snapshot. Skipped unless TEST_RUNNER_NOTIFICATION_TAP=1, because the notification has to come from outside:
/// while it runs, send pushes with `xcrun simctl push <simulator> com.ethantraister.FoCoSocial <payload>` whose
/// alert title is "Tap test".
final class NotificationTapTests: XCTestCase {
    private var app: XCUIApplication!
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["NOTIFICATION_TAP"] != nil, "needs pushes sent with simctl")
        continueAfterFailure = false
        app = XCUIApplication()
    }

    func testTappingANotificationOpensTheApp() {
        app.launchArguments = ["-resetForUITests", "-useLocalServer", "YES"]
        app.launch()

        // Following a food during setup is what asks for notifications.
        XCTAssertTrue(app.buttons["Continue"].waitForExistence(timeout: 10))
        app.buttons["Continue"].tap()
        app.buttons["Continue"].tap()
        app.buttons["Steak"].tap()
        app.buttons["Start eating"].tap()
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 5) { allow.tap() }
        XCTAssertTrue(app.navigationBars["Foco"].waitForExistence(timeout: 10))

        // To the home screen, like having the app open in the background.
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10) || app.wait(for: .runningBackgroundSuspended, timeout: 10))

        let banner = springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'Tap test'")).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 120), "a push arrived")
        banner.tap()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "the tap opened the app")
        sleep(5)
        XCTAssertEqual(app.state, .runningForeground, "still running a few seconds after the tap")
        XCTAssertTrue(app.buttons["tab.Menu"].exists, "and showing the app")
    }
}
