import XCTest

/// Swiping sideways between tabs, like Instagram's: it follows the bar's order, stops at both ends, and a screen
/// pushed on top of a tab swipes back instead of changing tabs. Works signed out (Menu and Me don't need an account).
final class PagerTests: XCTestCase {
    private var app: XCUIApplication!
    private var shot = 0

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-resetForUITests", "-onboarded", "<true/>", "-useLocalServer", "YES", "-meal", "dinner"]
        app.launch()
    }

    func testSwipeBetweenTabs() {
        XCTAssertTrue(app.buttons["tab.Menu"].waitForExistence(timeout: 5))
        XCTAssertTrue(selected("Menu"), "signed out, it opens on the menu")
        XCTAssertTrue(app.navigationBars["FoCo"].waitForExistence(timeout: 3))
        snap("menu")
        swipe(left: false)  // the first page: nowhere further to go
        XCTAssertTrue(waitSelected("Menu"))

        swipe(left: true)
        XCTAssertTrue(waitSelected("Together"))
        snap("together")
        swipe(left: true)
        XCTAssertTrue(waitSelected("Me"))
        XCTAssertTrue(app.navigationBars["Me"].waitForExistence(timeout: 3))
        snap("me")
        swipe(left: true)   // the last page
        XCTAssertTrue(waitSelected("Me"))

        swipe(left: false)
        XCTAssertTrue(waitSelected("Together"))
        swipe(left: false)
        XCTAssertTrue(waitSelected("Menu"))

        // The dessert cards slide on their own instead of changing tabs.
        let desserts = app.buttons.matching(NSPredicate(format: "label CONTAINS 'calories'"))
        if let card = desserts.allElementsBoundByIndex.first(where: { $0.isHittable && $0.frame.width < 250 }) {
            card.swipeLeft()
            sleep(1)
            XCTAssertTrue(selected("Menu"), "swiping the dessert cards doesn't change tabs")
            snap("desserts-slid")
        }

        // Tapping the status bar still scrolls the page on screen back to the top.
        let today = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Today'")).firstMatch
        XCTAssertTrue(today.isHittable)
        app.swipeUp(); app.swipeUp(); sleep(1)
        XCTAssertFalse(today.exists && today.isHittable, "scrolled down")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: 12)).tap()
        sleep(2)
        snap("status-bar-tap")
        XCTAssertTrue(today.waitForExistence(timeout: 2) && today.isHittable, "back at the top")

        // Tapping still jumps straight to a tab, however far.
        app.buttons["tab.Me"].tap()
        XCTAssertTrue(waitSelected("Me"))
        app.buttons["tab.Menu"].tap()
        XCTAssertTrue(waitSelected("Menu"))

        // On a dish (pushed on top of Menu), a sideways swipe isn't a tab change.
        let dish = app.buttons.matching(NSPredicate(format: "label CONTAINS 'calories'")).element(boundBy: 2)
        XCTAssertTrue(dish.waitForExistence(timeout: 10), "menu loaded")
        dish.tap()
        let back = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: 3))
        sleep(1)
        snap("dish")
        swipe(left: true)
        sleep(1)
        XCTAssertTrue(selected("Menu"), "a pushed screen doesn't swipe to the next tab")
        back.tap()
        sleep(1)
        swipe(left: true)
        XCTAssertTrue(waitSelected("Together"), "back on Menu's first screen, swiping works again")
    }

    /// On a screen pushed on top of a tab, swiping right goes back, from the screen's edge or (iOS 26) anywhere on it.
    func testSwipeBackFromAPushedScreen() {
        XCTAssertTrue(app.buttons["tab.Menu"].waitForExistence(timeout: 5))
        app.buttons["tab.Menu"].tap()
        let dishes = app.buttons.matching(NSPredicate(format: "label CONTAINS 'calories'"))
        for (i, fromEdge) in [true, false].enumerated() {
            let dish = dishes.element(boundBy: 2 + i)
            XCTAssertTrue(dish.waitForExistence(timeout: 10), "menu loaded")
            dish.tap()
            XCTAssertTrue(app.switches.firstMatch.waitForExistence(timeout: 3), "the dish opened")
            sleep(1)
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: fromEdge ? 0 : 0.2, dy: 0.5))
            start.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
            sleep(1)
            snap(fromEdge ? "back-from-edge" : "back-from-middle")
            XCTAssertTrue(app.navigationBars["FoCo"].waitForExistence(timeout: 3), fromEdge ? "edge swipe went back" : "swipe went back")
            XCTAssertTrue(selected("Menu"))
        }
    }

    /// Pages still move up for the keyboard: the button under the NetID field stays reachable.
    func testKeyboardKeepsTheSignInButtonReachable() {
        app.buttons["tab.Together"].tap()   // signed out, the app opens on the menu
        let email = app.textFields["NetID"]
        XCTAssertTrue(email.waitForExistence(timeout: 5))
        email.tap()
        email.typeText("keyboard.\(Int.random(in: 1000...99999))")
        sleep(1)
        snap("keyboard")
        app.buttons["Email me a code"].tap()
        XCTAssertTrue(app.textFields["6-digit code"].waitForExistence(timeout: 5))
    }

    /// Rows that slide open to show a button still do: swiping on the row opens it instead of changing tabs.
    func testRowSwipeActionsStillWork() {
        signUp()
        let plan = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Water Polo'")).firstMatch
        // Lists only make rows as they scroll into view, and the team dinner is under "Coming up".
        for _ in 0..<6 where !(plan.exists && plan.isHittable) { app.swipeUp(); sleep(1) }
        XCTAssertTrue(plan.waitForExistence(timeout: 5), "the demo team dinner")
        plan.swipeLeft()
        sleep(1)
        snap("after-plan-swipe")
        XCTAssertTrue(app.buttons["Remove"].waitForExistence(timeout: 3), "the plan row slid open")
        snap("plan-row-open")
        XCTAssertTrue(selected("Together"))
        app.navigationBars["Together"].tap()
        sleep(1)

        app.buttons["tab.Menu"].tap()
        XCTAssertTrue(waitSelected("Menu"))
        // A full-width dish row, not one of the dessert cards (those sit in a row that slides on its own).
        let dishes = app.buttons.matching(NSPredicate(format: "label CONTAINS 'calories'"))
        XCTAssertTrue(dishes.firstMatch.waitForExistence(timeout: 10))
        for _ in 0..<3 where !dishes.allElementsBoundByIndex.contains(where: { $0.frame.width > 300 && $0.isHittable }) {
            app.swipeUp(); sleep(1)
        }
        guard let dish = dishes.allElementsBoundByIndex.first(where: { $0.frame.width > 300 && $0.isHittable }) else {
            return XCTFail("no dish row on screen")
        }
        dish.swipeRight()
        XCTAssertTrue(app.buttons["Alert me"].waitForExistence(timeout: 3), "the dish row slid open")
        snap("dish-row-open")
        XCTAssertTrue(selected("Menu"))
        app.navigationBars["FoCo"].tap()
        sleep(1)
        // iOS 26 leaves the row open after a tap elsewhere; swiping it back closes it.
        if app.buttons["Alert me"].exists && app.buttons["Alert me"].isHittable { dish.swipeLeft(); sleep(1) }
        snap("dish-row-closed")

        // A row with nothing on that side lets the pages move: swiping left across a dish goes to Together.
        let y = dish.frame.midY / app.frame.height
        swipe(left: true, y: y)
        snap("after-dish-swipe-left")
        XCTAssertTrue(waitSelected("Together"), "a dish has no button on its right, so the swipe changes tabs")
    }

    private func signUp() {
        app.terminate()
        app.launch()
        app.buttons["tab.Together"].tap()   // signed out, the app opens on the menu
        let email = app.textFields["NetID"]
        XCTAssertTrue(email.waitForExistence(timeout: 5))
        email.tap()
        email.typeText("pager.\(Int.random(in: 1000...99999))")
        app.buttons["Email me a code"].tap()
        let code = app.textFields["6-digit code"]
        XCTAssertTrue(code.waitForExistence(timeout: 5))
        sleep(1)
        code.tap()
        code.typeText("123456")
        let name = app.textFields["First and last name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Pager Test\n")
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
        sleep(3)
    }

    /// A full swipe across the page. By default across the top, under the title: clear of rows that slide sideways
    /// (the dessert cards, day chips).
    private func swipe(left: Bool, y: Double = 0.17) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: left ? 0.85 : 0.15, dy: y))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: left ? 0.15 : 0.85, dy: y))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
        sleep(1)
    }

    private func selected(_ tab: String) -> Bool { app.buttons["tab.\(tab)"].isSelected }

    private func waitSelected(_ tab: String) -> Bool {
        let predicate = NSPredicate(format: "isSelected == true")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: app.buttons["tab.\(tab)"])
        return XCTWaiter().wait(for: [expectation], timeout: 3) == .completed
    }

    private func snap(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["SHOTS"] else { return }
        shot += 1
        let file = String(format: "pager-%02d-%@.png", shot, name)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent(file))
    }
}
