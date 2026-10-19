import XCTest

/// Hammers the pages the way impatient thumbs do: quick flicks, half swipes let go of, a tap on the bar while the
/// pages are still sliding, screens pushed and popped mid-swipe. The app has to still be running at the end.
final class StressTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-resetForUITests", "-onboarded", "<true/>", "-useLocalServer", "YES", "-meal", "dinner"]
        app.launch()
    }

    func testFastSwipesAndTaps() {
        signUp()
        let tabs = ["Menu", "Together", "Me"]

        // Quick flicks both ways, with no pause between them.
        for round in 0..<12 {
            flick(left: round % 4 < 2, y: [0.17, 0.4, 0.6, 0.75][round % 4])
        }
        alive("after quick flicks")

        // Half swipes that get let go of, so the pages spring back.
        for i in 0..<6 {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: i.isMultiple(of: 2) ? 0.8 : 0.2, dy: 0.5))
            let end = start.withOffset(CGVector(dx: i.isMultiple(of: 2) ? -60 : 60, dy: 0))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
        }
        alive("after half swipes")

        // A tap on the bar the moment a swipe lets go, while the pages are still sliding.
        for i in 0..<10 {
            flick(left: i.isMultiple(of: 2), y: 0.5)
            app.buttons["tab.\(tabs[(i * 2) % tabs.count])"].tap()
        }
        alive("after taps mid-swipe")

        // Scroll a list and swipe sideways while it's still moving.
        for name in ["Together", "Menu", "Me"] {
            app.buttons["tab.\(name)"].tap()
            app.swipeUp(velocity: .fast)
            flick(left: true, y: 0.5)
            app.swipeDown(velocity: .fast)
            flick(left: false, y: 0.5)
        }
        alive("after scroll + swipe")

        // Open a screen on top, go back with the edge swipe, and swipe straight away.
        app.buttons["tab.Menu"].tap()
        for i in 0..<4 {
            let dish = app.buttons.matching(NSPredicate(format: "label CONTAINS 'calories'")).element(boundBy: 2 + i)
            guard dish.waitForExistence(timeout: 5) else { break }
            dish.tap()
            swipeBack()
            flick(left: true, y: 0.5)
            flick(left: false, y: 0.5)
            app.buttons["tab.Menu"].tap()
        }
        alive("after push, edge-swipe back, swipe")

        // The same with a plan's page on Together.
        app.buttons["tab.Together"].tap()
        for _ in 0..<3 {
            let plan = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Lunch with' OR label BEGINSWITH 'Dinner with'")).firstMatch
            guard plan.waitForExistence(timeout: 5), plan.isHittable else { break }
            plan.tap()
            sleep(1)
            swipeBack()
            flick(left: true, y: 0.5)
            flick(left: false, y: 0.5)
            app.buttons["tab.Together"].tap()
        }
        alive("after plans")

        // Every tab in turn, quickly, a few times over.
        for _ in 0..<3 { for name in tabs.shuffled() { app.buttons["tab.\(name)"].tap() } }
        alive("after tab taps")

        // Away and back, as if switching apps.
        XCUIDevice.shared.press(.home)
        sleep(2)
        app.activate()
        flick(left: true, y: 0.5)
        flick(left: false, y: 0.5)
        alive("after leaving and coming back")
    }

    /// The system's back gesture: from the screen's left edge.
    private func swipeBack() {
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
        edge.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
    }

    private func flick(left: Bool, y: Double) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: left ? 0.85 : 0.15, dy: y))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: left ? 0.15 : 0.85, dy: y))
        start.press(forDuration: 0.01, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
    }

    private func alive(_ step: String) {
        snap(step)
        XCTAssertEqual(app.state, .runningForeground, "the app is still running \(step)")
        XCTAssertTrue(app.buttons["tab.Together"].waitForExistence(timeout: 5), "the bar is back \(step)")
    }

    private var shot = 0

    private func snap(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["SHOTS"] else { return }
        shot += 1
        let file = String(format: "stress-%02d-%@.png", shot, name.replacingOccurrences(of: " ", with: "-"))
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent(file))
    }

    private func signUp() {
        app.buttons["tab.Together"].tap()   // signed out, the app opens on the menu
        let email = app.textFields["NetID"]
        XCTAssertTrue(email.waitForExistence(timeout: 5))
        email.tap()
        email.typeText("stress.\(Int.random(in: 1000...99999))")
        app.buttons["Email me a code"].tap()
        let code = app.textFields["6-digit code"]
        XCTAssertTrue(code.waitForExistence(timeout: 5))
        sleep(1)
        code.tap()
        code.typeText("123456")
        let name = app.textFields["First and last name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Stress Test\n")
        sleep(1)
        app.swipeUp()
        app.switches.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        app.buttons["Join FoCo Social"].tap()
        // Signing up ends on adding friends (it can wait).
        XCTAssertTrue(app.navigationBars["Add your friends"].waitForExistence(timeout: 8), "signing up ends on adding friends")
        app.navigationBars.buttons.matching(NSPredicate(format: "label IN {'Later', 'Done'}")).firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Together"].waitForExistence(timeout: 8))
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow", "Allow While Using App"] where springboard.buttons[label].waitForExistence(timeout: 2) {
            springboard.buttons[label].tap()
        }
        sleep(2)
    }
}
