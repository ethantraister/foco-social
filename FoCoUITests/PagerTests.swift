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
        XCTAssertTrue(app.navigationBars["Foco"].waitForExistence(timeout: 3))
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
        let dish = onScreenDish(2)
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
        for (i, fromEdge) in [true, false].enumerated() {
            let dish = onScreenDish(2 + i)
            XCTAssertTrue(dish.waitForExistence(timeout: 10), "menu loaded")
            dish.tap()
            XCTAssertTrue(app.switches.firstMatch.waitForExistence(timeout: 3), "the dish opened")
            sleep(1)
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: fromEdge ? 0 : 0.2, dy: 0.5))
            start.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
            sleep(1)
            snap(fromEdge ? "back-from-edge" : "back-from-middle")
            XCTAssertTrue(app.navigationBars["Foco"].waitForExistence(timeout: 3), fromEdge ? "edge swipe went back" : "swipe went back")
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
        // Clear of the bottom bar, so the swipe starts on the row.
        let bar = app.otherElements["tabBar"]
        for _ in 0..<4 where plan.frame.maxY > bar.frame.minY - 12 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)))
            sleep(1)
        }
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
        // A row of dish cards slides on its own instead of changing tabs.
        let dishes = app.buttons.matching(NSPredicate(format: "label CONTAINS 'calories'"))
        XCTAssertTrue(dishes.firstMatch.waitForExistence(timeout: 10))
        let midScreen = { (e: XCUIElement) in e.isHittable && e.frame.midY > self.app.frame.height * 0.3 && e.frame.midY < self.app.frame.height * 0.75 }
        for _ in 0..<3 where !dishes.allElementsBoundByIndex.contains(where: midScreen) { app.swipeUp(); sleep(1) }
        guard let card = dishes.allElementsBoundByIndex.first(where: midScreen) else { return XCTFail("no dish card on screen") }
        let row = card.frame.midY / app.frame.height
        swipe(left: true, y: row)
        snap("dish-row-slid")
        XCTAssertTrue(selected("Menu"), "the cards slid; the tab stayed")

        // A station's full list (See all, at the end of its row): rows there slide open for an alert.
        let seeAll = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'See all of'")).firstMatch
        for _ in 0..<6 where !(seeAll.exists && seeAll.frame.midY > app.frame.height * 0.25 && seeAll.frame.midY < app.frame.height * 0.75) {
            app.swipeUp(); sleep(1)
        }
        XCTAssertTrue(seeAll.exists, "a station with more dishes than its row shows")
        let seeAllRow = seeAll.frame.midY / app.frame.height
        // Slide the row at an easy pace, and let it stop: a tap on a row that's still coasting only stops it.
        for _ in 0..<5 where !seeAll.isHittable {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: seeAllRow))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: seeAllRow)))
            sleep(2)
        }
        XCTAssertTrue(selected("Menu"))
        snap("see-all-card")
        let station = String(seeAll.label.dropFirst("See all of ".count))
        seeAll.tap()
        XCTAssertTrue(app.navigationBars[station].waitForExistence(timeout: 5), "See all opens \(station)'s list")
        sleep(1)
        // Every dish reads "<name>, <station> station, …" (not every one lists calories).
        let rows = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", " station"))
        let row2 = rows.allElementsBoundByIndex.first { $0.isHittable && $0.frame.width > 300 }
        XCTAssertNotNil(row2, "the station's dishes as a list")
        guard let dish = row2 else { return }
        dish.swipeRight()
        XCTAssertTrue(app.buttons["Alert me"].waitForExistence(timeout: 3), "the dish row slid open")
        snap("dish-row-open")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Foco"].waitForExistence(timeout: 3), "back on the menu")
        sleep(1)

        // Where nothing slides on its own (the title), a sideways swipe changes tabs.
        let title = app.navigationBars["Foco"].frame.midY / app.frame.height
        swipe(left: true, y: title)
        snap("after-title-swipe-left")
        XCTAssertTrue(waitSelected("Together"), "swiping across the title changes tabs")
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
        app.buttons["Join Foco"].tap()
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

    /// Pressing on the bottom bar and sliding sideways, like Instagram's: letting go opens the tab under the finger.
    func testSlideAlongTheTabBar() {
        let menu = app.buttons["tab.Menu"], together = app.buttons["tab.Together"], me = app.buttons["tab.Me"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        XCTAssertTrue(selected("Menu"))

        menu.press(forDuration: 0.15, thenDragTo: me, withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertTrue(waitSelected("Me"), "slid all the way across to Me")
        XCTAssertTrue(app.navigationBars["Me"].waitForExistence(timeout: 3), "and the Me page is showing")
        snap("slid-to-me")

        me.press(forDuration: 0.15, thenDragTo: together, withVelocity: .slow, thenHoldForDuration: 0.3)
        snap("slid-back")
        XCTAssertTrue(waitSelected("Together"), "slid back one tab")

        // Sliding past the end of the bar still lands on the last tab.
        let pastTheEnd = me.coordinate(withNormalizedOffset: CGVector(dx: 2.5, dy: 0.5))
        together.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.15, thenDragTo: pastTheEnd)
        XCTAssertTrue(waitSelected("Me"))

        // A plain tap still works.
        menu.tap()
        XCTAssertTrue(waitSelected("Menu"))
    }


    /// The nth dish (card or row) that's on screen: cards further along a station's row aren't, until it slides.
    private func onScreenDish(_ n: Int) -> XCUIElement {
        let dishes = app.buttons.matching(NSPredicate(format: "label CONTAINS 'calories'"))
        _ = dishes.firstMatch.waitForExistence(timeout: 10)
        let visible = dishes.allElementsBoundByIndex.filter { $0.isHittable }
        return visible.isEmpty ? dishes.firstMatch : visible[min(n, visible.count - 1)]
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
