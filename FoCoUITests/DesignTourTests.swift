import XCTest

/// Screenshots of every main screen, light and dark, for design reviews. Skipped unless DESIGN_TOUR is set
/// (run xcodebuild with TEST_RUNNER_DESIGN_TOUR=1 and TEST_RUNNER_SHOTS=<folder>). Uses the local test server.
final class DesignTourTests: XCTestCase {
    private var app: XCUIApplication!
    private var prefix = "light"
    private var shot = 0

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DESIGN_TOUR"] != nil, "design screenshots only on request")
        continueAfterFailure = true
        app = XCUIApplication()
    }

    override func tearDown() {
        XCUIDevice.shared.appearance = .light
    }

    func testLight() { tour(dark: false) }
    func testDark() { tour(dark: true) }

    private func tour(dark: Bool) {
        prefix = dark ? "dark" : "light"
        XCUIDevice.shared.appearance = dark ? .dark : .light
        signUp()

        snap("together")
        app.swipeUp(); sleep(1)
        snap("together-scrolled")
        app.swipeDown(); app.swipeDown(); sleep(1)

        tapButton("Going soon")
        sleep(1); snap("going-soon")
        app.buttons["Cancel"].firstMatch.tap(); sleep(1)

        tapButton("Plan a meal")
        sleep(1); snap("plan-composer")
        app.buttons["Cancel"].firstMatch.tap(); sleep(1)

        tapButton("Friends")
        sleep(1); snap("friends")
        app.buttons["Done"].firstMatch.tap(); sleep(1)

        let plan = app.staticTexts["Dinner with Priya"].firstMatch
        if plan.waitForExistence(timeout: 3) {
            plan.tap(); sleep(2); snap("plan-detail")
            app.navigationBars.buttons.element(boundBy: 0).tap(); sleep(1)
        }

        tab("Menu"); sleep(3); snap("menu")
        app.swipeUp(); sleep(1); snap("menu-scrolled")
        let dish = onScreenDish(3)
        if dish.exists {
            dish.tap(); sleep(2); snap("dish")
            app.navigationBars.buttons.element(boundBy: 0).tap(); sleep(1)
        }

        app.swipeDown(); app.swipeDown(); sleep(1)
        app.navigationBars["Foco"].buttons["Food alerts"].tap(); sleep(2); snap("food-alerts")
        app.navigationBars.buttons.element(boundBy: 0).tap(); sleep(1)
        tab("Me"); sleep(1); snap("me")
    }

    /// The nth dish (card or row) that's on screen: cards further along a station's row aren't, until it slides.
    private func onScreenDish(_ n: Int) -> XCUIElement {
        let dishes = app.buttons.matching(NSPredicate(format: "label CONTAINS 'calories'"))
        _ = dishes.firstMatch.waitForExistence(timeout: 10)
        let visible = dishes.allElementsBoundByIndex.filter { $0.isHittable }
        return visible.isEmpty ? dishes.firstMatch : visible[min(n, visible.count - 1)]
    }

    private func signUp() {
        app.launchArguments = ["-resetForUITests", "-onboarded", "<true/>", "-useLocalServer", "YES", "-meal", "dinner"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Foco"].waitForExistence(timeout: 5))
        sleep(2)
        snap("signed-out-menu")
        tab("Together")
        let email = app.textFields["NetID"]
        XCTAssertTrue(email.waitForExistence(timeout: 5))
        snap("sign-in")
        email.tap()
        email.typeText("design.\(Int.random(in: 1000...99999))")
        app.buttons["Email me a code"].tap()
        let code = app.textFields["6-digit code"]
        XCTAssertTrue(code.waitForExistence(timeout: 5))
        sleep(1)
        code.tap()
        code.typeText("123456")
        let name = app.textFields["First and last name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        // TOUR_NAME (TEST_RUNNER_TOUR_NAME) gives App Store screenshots a made-up student instead.
        name.typeText((ProcessInfo.processInfo.environment["TOUR_NAME"] ?? "Ethan Traister") + "\n")
        sleep(1)
        app.swipeUp()
        app.switches.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        app.buttons["Join Foco"].tap()
        // Signing up ends on adding friends (it can wait).
        XCTAssertTrue(app.navigationBars["Add your friends"].waitForExistence(timeout: 8), "signing up ends on adding friends")
        sleep(1)
        snap("add-friends")
        app.navigationBars.buttons.matching(NSPredicate(format: "label IN {'Later', 'Done'}")).firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Together"].waitForExistence(timeout: 8))
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow", "Allow While Using App"] where springboard.buttons[label].waitForExistence(timeout: 2) {
            springboard.buttons[label].tap()
        }
        sleep(3)
    }

    private func tab(_ name: String) {
        let item = app.buttons["tab.\(name)"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "\(name) tab")
        item.tap()
    }

    private func tapButton(_ prefix: String) {
        let button = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), prefix)
        button.tap()
    }

    private func snap(_ name: String) {
        shot += 1
        let dir = ProcessInfo.processInfo.environment["SHOTS"] ?? NSTemporaryDirectory()
        let file = String(format: "%@-%02d-%@.png", prefix, shot, name)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent(file))
    }
}
