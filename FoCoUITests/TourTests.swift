import XCTest

final class TourTests: XCTestCase {
    private var app: XCUIApplication!
    private var shot = 0

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
        addUIInterruptionMonitor(withDescription: "Notifications") { alert in
            for label in ["Allow", "Allow Notifications"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
    }

    private func snap(_ name: String) {
        shot += 1
        let png = app.screenshot().pngRepresentation
        let dir = ProcessInfo.processInfo.environment["SHOTS"] ?? NSTemporaryDirectory()
        try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(String(format: "%02d-%@.png", shot, name)))
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func allowNotificationsIfAsked() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
    }

    func testFullTour() {
        app.launchArguments = ["-resetForUITests", "-meal", "dinner"]
        app.launch()

        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Foco Social")).firstMatch.waitForExistence(timeout: 5))
        snap("onboarding-welcome")
        app.buttons["Continue"].tap()
        sleep(1)

        app.buttons["Dairy"].tap()
        sleep(1)
        snap("onboarding-diet")
        app.buttons["Continue"].tap()
        sleep(1)

        app.buttons["Steak"].tap()
        app.buttons["Pad Thai"].tap()
        sleep(1)
        snap("onboarding-favorites")
        app.buttons["Start eating"].tap()
        allowNotificationsIfAsked()

        XCTAssertTrue(app.navigationBars["Foco"].waitForExistence(timeout: 5), "signed out, the app opens on the menu")
        XCTAssertTrue(app.buttons["tab.Menu"].isSelected)
        sleep(4)
        snap("menu-dinner")

        let dish = button("Meatloaf")
        if dish.waitForExistence(timeout: 3) {
            dish.swipeRight()
            sleep(1)
            snap("swipe-to-alert")
            app.buttons["Alert me"].firstMatch.tap()
            sleep(1)
            dish.tap()
            sleep(1)
            snap("detail")
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }

        app.swipeUp()
        sleep(1)
        snap("menu-stations")

        let salad = button("Salad Bar")
        if salad.waitForExistence(timeout: 2) {
            salad.tap()
            sleep(1)
            snap("menu-saladbar")
        }

        // Food alerts live behind the bell on the menu: the dish just followed is there.
        app.swipeDown(); app.swipeDown()
        app.navigationBars["Foco"].buttons["Food alerts"].tap()
        XCTAssertTrue(app.navigationBars["Food alerts"].waitForExistence(timeout: 3), "the bell opens food alerts")
        XCTAssertTrue(app.buttons["Steak, following"].exists, "foods picked during onboarding are followed")
        sleep(2)
        snap("alerts")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        tab("Me")
        XCTAssertFalse(app.buttons["Food requests"].exists, "no food requests until Dining takes them")
        app.buttons["My diet"].tap()
        sleep(1)
        snap("diet")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        tab("Menu")
        let search = app.searchFields.firstMatch
        app.swipeDown()
        app.swipeDown()
        if search.waitForExistence(timeout: 3) {
            search.tap()
            search.typeText("chicken")
            sleep(3)
            snap("search-chicken")
        }
    }

    /// The app's own bottom bar.
    private func tab(_ name: String) {
        let item = app.buttons["tab.\(name)"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "\(name) tab")
        item.tap()
    }

    private func button(_ prefix: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    func testLargeText() {
        app.launchArguments = ["-resetForUITests", "-onboarded", "<true/>", "-meal", "dinner",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"]
        app.launch()
        tab("Menu")
        XCTAssertTrue(app.navigationBars["Foco"].waitForExistence(timeout: 5))
        sleep(4)
        snap("large-menu")
        app.swipeUp()
        snap("large-menu-scrolled")
        tab("Me")
        app.buttons["My diet"].tap()
        sleep(1)
        snap("large-diet")
    }

    func testAccessibilityAudit() throws {
        app.launchArguments = ["-resetForUITests", "-onboarded", "<true/>", "-meal", "dinner"]
        app.launch()
        tab("Menu")
        XCTAssertTrue(app.navigationBars["Foco"].waitForExistence(timeout: 5))
        sleep(4)
        for tab in ["Menu", "Me"] {
            self.tab(tab)
            sleep(2)
            try app.performAccessibilityAudit(for: [.contrast, .elementDetection, .hitRegion, .sufficientElementDescription, .textClipped, .trait]) { issue in
                print("A11Y[\(tab)] \(issue.auditType) — \(issue.compactDescription) — \(issue.element?.label ?? "?")")
                return true
            }
        }
    }

    func testDarkMode() {
        XCUIDevice.shared.appearance = .dark
        defer { XCUIDevice.shared.appearance = .light }
        app.launchArguments = ["-resetForUITests", "-onboarded", "<true/>", "-meal", "lunch"]
        app.launch()
        tab("Menu")
        XCTAssertTrue(app.navigationBars["Foco"].waitForExistence(timeout: 5))
        sleep(4)
        snap("dark-menu")
        app.swipeUp()
        sleep(1)
        snap("dark-stations")
    }
}
