import CoreLocation
import XCTest

final class SocialTourTests: XCTestCase {
    private var app: XCUIApplication!
    private var shot = 0

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
    }

    private func snap(_ name: String) {
        shot += 1
        let dir = ProcessInfo.processInfo.environment["SHOTS"] ?? NSTemporaryDirectory()
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent(String(format: "s%02d-%@.png", shot, name)))
    }

    private func button(_ prefix: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    /// Small drags until the element sits between the top bar and the tab bar (a swipe on a half-hidden row misses).
    private func scrollIntoView(_ element: XCUIElement) {
        let top = app.navigationBars.firstMatch.frame.maxY + 10
        let bottom = app.tabBars.firstMatch.frame.minY - 10
        for _ in 0..<8 {
            let frame = element.frame
            if frame.minY >= top && frame.maxY <= bottom { return }
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: frame.maxY > bottom ? -180 : 180)))
            sleep(1)
        }
    }

    private func allowAlerts() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow", "Allow While Using App", "Change to Always Allow"] where springboard.buttons[label].waitForExistence(timeout: 1) {
            springboard.buttons[label].tap()
        }
    }

    func testSocialTour() {
        app.launchArguments = ["-resetForUITests", "-onboarded", "<true/>", "-useLocalServer", "YES"]
        app.launch()

        app.tabBars.buttons["Together"].tap()
        let email = app.textFields["NetID"]
        XCTAssertTrue(email.waitForExistence(timeout: 5))
        snap("signin")
        email.tap()
        email.typeText("uitest.\(Int.random(in: 1000...99999))")
        app.buttons["Email me a code"].tap()

        let code = app.textFields["6-digit code"]
        XCTAssertTrue(code.waitForExistence(timeout: 5))
        sleep(1)
        code.tap()
        code.typeText("12345")
        snap("code")
        code.typeText("6")   // the sixth digit signs you in, no button

        let name = app.textFields["First and last name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5), "a full code signs in by itself")
        name.tap()
        name.typeText("Ethan T.\n")
        sleep(1)
        app.swipeUp()
        let agree = app.switches.firstMatch
        agree.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        snap("profile-setup")
        app.buttons["Join FoCo Social"].tap()

        XCTAssertTrue(app.navigationBars["Together"].waitForExistence(timeout: 8))
        allowAlerts()
        sleep(3)
        snap("together")

        let going = app.buttons["Going"].firstMatch
        if going.waitForExistence(timeout: 3) {
            going.tap()
            sleep(2)
            snap("invite-accepted")
        }

        let meToo = app.buttons["Me too"].firstMatch
        if !meToo.exists { app.swipeUp() }
        XCTAssertTrue(meToo.waitForExistence(timeout: 5), "friend heading to FoCo shows Me too")
        snap("heading-friends")
        meToo.tap()
        sleep(2)
        XCTAssertTrue(app.staticTexts["You're heading over"].waitForExistence(timeout: 5))
        snap("heading-me-too")
        app.swipeDown()
        button("Change time").tap()
        sleep(1)
        app.buttons["15 min"].tap()
        snap("heading-sheet")
        app.buttons["Tell friends"].tap()
        sleep(2)

        XCTAssertFalse(button("I'm at FoCo").exists, "checking in isn't a main button")
        let byHand = app.buttons["Check in manually"]
        for _ in 0..<3 where !byHand.isHittable { app.swipeUp() }
        byHand.tap()
        sleep(1)
        app.buttons["Dark side"].tap()
        snap("checkin-sheet")
        app.buttons["Check in"].tap()
        sleep(2)
        snap("checked-in")
        app.buttons["Upstairs"].firstMatch.tap()
        sleep(2)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Upstairs'")).firstMatch.waitForExistence(timeout: 5))
        snap("moved-upstairs")
        app.swipeDown()
        sleep(1)

        button("Plan a meal").tap()
        sleep(1)
        button("Just people I pick").tap()
        button("Maya R.").tap()
        let note = app.textFields.matching(NSPredicate(format: "placeholderValue BEGINSWITH 'Note'")).firstMatch
        if note.exists { note.tap(); note.typeText("Window tables") }
        snap("plan-composer")
        app.buttons["Post"].tap()
        sleep(2)
        app.swipeUp()
        sleep(1)
        snap("together-with-plan")

        // Swiping your own plan cancels it right away, with Undo instead of a second "are you sure?".
        let mine = app.cells.containing(NSPredicate(format: "label BEGINSWITH 'Your '")).firstMatch
        for _ in 0..<3 where !mine.exists { app.swipeUp() }
        if mine.exists {
            mine.swipeLeft()
            app.buttons["Cancel plan"].tap()
            XCTAssertTrue(app.staticTexts["Plan cancelled"].waitForExistence(timeout: 5), "undo bar appears")
            XCTAssertFalse(app.sheets.firstMatch.exists, "no confirmation dialog")
            snap("plan-cancelled-undo")
            app.buttons["Undo"].tap()
            sleep(3)
            XCTAssertTrue(mine.waitForExistence(timeout: 5), "Undo brings the plan back")
        } else {
            XCTFail("your own plan shows in Coming up")
        }
        for _ in 0..<4 { app.swipeDown() }

        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Friends'")).firstMatch.tap()
        sleep(2)
        snap("friends")
        if app.buttons["Accept"].firstMatch.exists {
            app.buttons["Accept"].firstMatch.tap()
            sleep(2)
            snap("friend-accepted")
        }
        let invite = button("Invite friends by text")
        XCTAssertTrue(invite.waitForExistence(timeout: 3), "invite friends by text from Friends")
        invite.tap()
        sleep(3)
        snap("invite-by-text")   // the simulator can't send texts, so this is the share sheet with the same message
        let close = app.buttons["Close"]
        if close.waitForExistence(timeout: 2) { close.tap() } else { app.swipeDown() }
        sleep(1)
        app.buttons["Done"].tap()

        app.tabBars.buttons["Feed"].tap()
        sleep(4)
        snap("feed-plates")
        let vote = button("Upvote")
        if vote.waitForExistence(timeout: 3) {
            vote.tap()
            sleep(1)
            snap("feed-voted")
        }
        XCTAssertFalse(app.buttons["Ideas"].exists, "feed is plates only")
        XCTAssertFalse(app.buttons["Complaints"].exists, "feed is plates only")

        app.tabBars.buttons["Me"].tap()
        sleep(1)
        snap("me")
        app.buttons["Edit"].tap()
        XCTAssertTrue(app.buttons["Add photo"].waitForExistence(timeout: 3), "no photo yet: initials, and a way to add one")
        snap("edit-profile")
        app.buttons["Add photo"].tap()
        XCTAssertTrue(app.buttons["Choose photo"].waitForExistence(timeout: 3), "profile picture can come from the camera roll")
        XCTAssertFalse(app.buttons["Remove photo"].exists, "nothing to remove yet")
        snap("photo-options")
        app.buttons["Close"].tap()
        sleep(1)
        app.buttons["Cancel"].tap()
    }

    /// Walk into FoCo, get checked in; walk out, get checked out. Needs a meal to be on (Eastern time).
    func testAutoCheckIn() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        let c = cal.dateComponents([.hour, .minute], from: .now)
        let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        try XCTSkipUnless((7 * 60 + 40..<20 * 60 + 20).contains(m), "FoCo isn't serving right now")

        let baker = XCUILocation(location: CLLocation(latitude: 43.70573, longitude: -72.28869))
        let foco = XCUILocation(location: CLLocation(latitude: 43.70311, longitude: -72.29090))
        XCUIDevice.shared.location = baker
        signUp()
        let leave = app.buttons["Leave"]
        XCTAssertFalse(leave.exists, "not checked in yet")

        let auto = app.switches["Check me in automatically"]
        for _ in 0..<4 where !auto.isHittable { app.swipeUp() }
        auto.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        sleep(1)
        allowAlerts()
        sleep(2)
        allowAlerts()
        snap("auto-on")
        app.swipeDown()   // back up to "At FoCo now"
        app.swipeDown()

        XCUIDevice.shared.location = foco
        XCTAssertTrue(leave.waitForExistence(timeout: 40), "checked in on arrival")
        sleep(1)
        snap("auto-arrived")

        XCUIDevice.shared.location = baker
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: leave)
        wait(for: [gone], timeout: 60)
        snap("auto-left")
    }

    /// Plan days ahead, build a club group with someone who isn't a friend, and send a food request.
    func testPlanAheadGroupsAndRequests() {
        signUp()

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        let f = DateFormatter()
        f.timeZone = cal.timeZone
        f.dateFormat = "EEEE"
        let weekday = f.string(from: cal.date(byAdding: .day, value: 3, to: .now)!)

        button("Plan a meal").tap()
        sleep(1)
        button(weekday).tap()
        app.buttons["Dinner"].tap()
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'On the menu'")).firstMatch.exists, "no menu in the composer")
        snap("plan-ahead")
        app.buttons["Post"].tap()
        sleep(2)
        let planned = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", weekday)).firstMatch
        for _ in 0..<4 where !planned.exists { app.swipeUp() }
        XCTAssertTrue(planned.exists, "plan \(weekday) shows up")
        snap("plan-ahead-listed")

        // Swiping away someone else's plan hides it (and RSVPs "can't make it").
        let teamDinner = app.cells.containing(NSPredicate(format: "label CONTAINS 'Team dinner after practice'")).firstMatch
        for _ in 0..<4 where !teamDinner.exists { app.swipeUp() }
        XCTAssertTrue(teamDinner.exists, "demo team dinner is in Coming up")
        scrollIntoView(teamDinner)
        snap("team-dinner")
        teamDinner.swipeLeft()
        app.buttons["Remove"].tap()
        sleep(2)
        XCTAssertFalse(teamDinner.exists, "swiped-away plan is gone")
        snap("plan-removed")
        for _ in 0..<4 { app.swipeDown() }

        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Friends'")).firstMatch.tap()
        sleep(1)
        button("New group").tap()
        sleep(1)
        let name = app.textFields.matching(NSPredicate(format: "placeholderValue BEGINSWITH 'e.g.'")).firstMatch
        name.tap()
        name.typeText("Ultimate")
        XCTAssertTrue(app.buttons["Add photo"].exists, "a group can have a photo; until then, its initials")
        let search = app.textFields["Search by name"]
        search.tap()
        search.typeText("Theo")
        let theo = button("Theo")
        XCTAssertTrue(theo.waitForExistence(timeout: 5), "find a non-friend by search")
        theo.tap()
        snap("group-search")
        app.buttons["Create"].tap()
        sleep(2)
        app.buttons.containing(NSPredicate(format: "label CONTAINS 'Ultimate'")).firstMatch.tap()
        sleep(2)
        let addFriend = app.buttons["Add Theo as a friend"]
        XCTAssertTrue(addFriend.waitForExistence(timeout: 5), "non-friend teammate has Add friend")
        XCTAssertTrue(app.buttons["Delete group"].exists, "the creator owns the group")
        XCTAssertTrue(app.buttons["Add photo"].exists, "and can give it a photo")
        app.buttons["Add photo"].tap()
        XCTAssertTrue(app.staticTexts["Add group photo"].waitForExistence(timeout: 3), "the options sheet is about the group")
        app.buttons["Choose photo"].tap()
        sleep(3)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.16, dy: 0.43)).tap()
        XCTAssertTrue(app.staticTexts["Move and Scale"].waitForExistence(timeout: 8))
        app.buttons["Choose"].tap()
        XCTAssertTrue(app.buttons["Edit photo"].waitForExistence(timeout: 8), "the group photo saves right away")
        sleep(2)
        snap("group-photo")
        XCTAssertFalse(app.buttons["Leave group"].exists, "the owner can't just leave")
        snap("group-detail")
        addFriend.tap()
        sleep(2)
        XCTAssertFalse(addFriend.exists, "friend request sent")
        app.buttons["Options for Theo"].tap()
        XCTAssertTrue(app.buttons["Make owner"].waitForExistence(timeout: 3), "owner can transfer")
        XCTAssertTrue(app.buttons["Remove from group"].exists, "owner can remove people")
        snap("group-owner-menu")
        app.buttons["Make owner"].tap()
        sleep(1)
        app.buttons["Make owner"].firstMatch.tap()   // confirm
        sleep(2)
        XCTAssertTrue(app.buttons["Leave group"].waitForExistence(timeout: 5), "after handing it off you're a regular member")
        XCTAssertFalse(app.buttons["Delete group"].exists)
        snap("group-transferred")
        app.navigationBars.buttons.firstMatch.tap()
        sleep(1)
        app.buttons["Done"].tap()

        app.tabBars.buttons["Me"].tap()
        app.buttons["Food requests"].tap()
        let food = app.textFields["Food you want at FoCo"]
        XCTAssertTrue(food.waitForExistence(timeout: 5))
        food.tap()
        food.typeText("Ramen")
        app.buttons["Send to Dining"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Requested'")).firstMatch.waitForExistence(timeout: 5))
        sleep(1)
        snap("request-sent")
    }

    private func signUp(_ extraArgs: [String] = [], netID: String = "audit.\(Int.random(in: 1000...99999))") {
        app.launchArguments = ["-resetForUITests", "-onboarded", "<true/>", "-useLocalServer", "YES"] + extraArgs
        app.launch()
        app.tabBars.buttons["Together"].tap()
        let email = app.textFields["NetID"]
        XCTAssertTrue(email.waitForExistence(timeout: 5))
        email.tap()
        email.typeText(netID)
        app.buttons["Email me a code"].tap()
        let code = app.textFields["6-digit code"]
        XCTAssertTrue(code.waitForExistence(timeout: 5))
        sleep(1)
        code.tap()
        code.typeText("123456")
        let name = app.textFields["First and last name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Audit User\n")
        sleep(1)
        app.swipeUp()
        app.switches.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        app.buttons["Join FoCo Social"].tap()
        XCTAssertTrue(app.navigationBars["Together"].waitForExistence(timeout: 8))
        allowAlerts()
        sleep(3)
    }

    /// The flows App Review and a public release depend on: the review account's password sign-in, reporting and
    /// blocking (and unblocking), asking Dining for a dish, changing the profile photo, and deleting the account.
    func testReleaseFlows() {
        app.launchArguments = ["-resetForUITests", "-onboarded", "<true/>", "-useLocalServer", "YES"]
        app.launch()
        app.tabBars.buttons["Together"].tap()
        let netID = app.textFields["NetID"]
        XCTAssertTrue(netID.waitForExistence(timeout: 5))
        netID.tap()
        netID.typeText("focoreview")
        let password = app.secureTextFields["Password"]
        XCTAssertTrue(password.waitForExistence(timeout: 3), "the review account signs in with a password, not a code")
        XCTAssertFalse(app.buttons["Email me a code"].exists)
        password.tap()
        password.typeText("local-review-password")
        snap("review-sign-in")
        app.buttons["Sign in"].tap()
        let name = app.textFields["First and last name"]
        if name.waitForExistence(timeout: 5) {
            name.tap()
            name.typeText("App Review\n")
            sleep(1)
            app.swipeUp()
            app.switches.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
            app.buttons["Join FoCo Social"].tap()
        }
        XCTAssertTrue(app.navigationBars["Together"].waitForExistence(timeout: 8), "the review account gets in")
        allowAlerts()
        sleep(2)

        // Reporting hides the post for you right away.
        app.tabBars.buttons["Feed"].tap()
        let steak = app.staticTexts["Pepper steak + brown rice from A9. Underrated."]
        XCTAssertTrue(steak.waitForExistence(timeout: 6))
        app.buttons["More options"].firstMatch.tap()
        app.buttons["Report post"].tap()
        app.buttons["Spam"].tap()
        XCTAssertTrue(app.staticTexts["Thanks. You won't see that post again."].waitForExistence(timeout: 3),
                      "a note confirms the report (it used to vanish at once if another tab had shown a note)")
        XCTAssertFalse(steak.exists, "reported post is gone for the reporter")
        snap("reported")

        // Block someone from their post, then unblock them from Me → Blocked people.
        let more = app.buttons["More options"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 3))
        more.tap()
        let block = button("Block ")
        XCTAssertTrue(block.waitForExistence(timeout: 3))
        let blockedName = String(block.label.dropFirst("Block ".count))
        block.tap()
        app.buttons["Block"].tap()
        sleep(2)
        XCTAssertFalse(app.staticTexts[blockedName].exists, "their posts are gone")
        app.tabBars.buttons["Me"].tap()
        app.buttons["About"].tap()
        XCTAssertTrue(app.buttons["Community rules"].waitForExistence(timeout: 3), "About has the rules")
        XCTAssertTrue(app.buttons["Privacy"].exists, "and the privacy policy")
        XCTAssertTrue(app.descendants(matching: .any)["Contact us"].exists, "and a way to reach us")
        snap("about")
        app.buttons["Blocked people"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", blockedName)).firstMatch.waitForExistence(timeout: 5),
                      "blocked people are listed")
        snap("blocked-people")
        app.buttons["Unblock"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["You haven't blocked anyone."].waitForExistence(timeout: 5), "and can be unblocked")
        app.navigationBars.buttons.firstMatch.tap()   // back to About
        sleep(1)
        app.navigationBars.buttons.firstMatch.tap()   // back to Me
        sleep(1)

        // A new profile photo replaces the old one.
        app.buttons["Edit"].tap()
        let editPhoto = app.buttons.matching(NSPredicate(format: "label IN {'Add photo', 'Edit photo'}")).firstMatch
        XCTAssertTrue(editPhoto.waitForExistence(timeout: 3))
        editPhoto.tap()
        XCTAssertTrue(app.buttons["Choose photo"].waitForExistence(timeout: 3))
        snap("photo-options")
        app.buttons["Choose photo"].tap()
        sleep(3)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.16, dy: 0.43)).tap()
        // A camera-roll photo opens the crop screen: drag, pinch, then Choose.
        XCTAssertTrue(app.staticTexts["Move and Scale"].waitForExistence(timeout: 8), "a chosen photo can be cropped")
        let photo = app.otherElements["Photo, centered in the circle"]
        snap("crop-start")
        photo.pinch(withScale: 2, velocity: 1)
        photo.swipeLeft()
        snap("crop-photo")
        app.buttons["Choose"].tap()
        XCTAssertTrue(app.buttons["Edit photo"].waitForExistence(timeout: 3), "the cropped photo is the new profile picture")
        snap("edit-photo")
        app.navigationBars.buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars["Me"].waitForExistence(timeout: 10), "Save closes the sheet once it's saved")
        sleep(1)

        // Ask Dining for a dish straight from its page.
        app.tabBars.buttons["Menu"].tap()
        let dish = app.buttons.containing(NSPredicate(format: "label CONTAINS ' station'")).firstMatch
        if dish.waitForExistence(timeout: 8) {
            dish.tap()
            let ask = button("Ask Dining to serve this more")
            XCTAssertTrue(ask.waitForExistence(timeout: 3))
            ask.tap()
            XCTAssertTrue(button("Sent to Dining").waitForExistence(timeout: 5), "the request actually goes to Dining")
            snap("dish-requested")
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }

        // Deleting the account signs you out (and removes your photos; the test script checks the folder).
        app.tabBars.buttons["Me"].tap()
        let delete = app.buttons["Delete my account"]
        for _ in 0..<3 where !delete.isHittable { app.swipeUp() }
        app.buttons["Sign out"].tap()
        XCTAssertTrue(app.alerts["Sign out?"].waitForExistence(timeout: 3), "sign out asks in the middle of the screen")
        snap("sign-out-alert")
        XCTAssertEqual(app.alerts.buttons["Cancel"].frame.midY, app.alerts.buttons["Sign out"].frame.midY, accuracy: 2, "side by side")
        app.alerts.buttons["Cancel"].tap()
        delete.tap()
        XCTAssertTrue(app.alerts["Delete your account?"].waitForExistence(timeout: 3))
        snap("delete-alert")
        let buttons = app.alerts.buttons
        XCTAssertEqual(buttons["Cancel"].frame.midY, buttons["Delete"].frame.midY, accuracy: 2, "side by side, like Sign out")
        app.alerts.buttons["Delete"].tap()
        XCTAssertTrue(button("Sign in with your NetID").waitForExistence(timeout: 10), "signed out after deleting")
        snap("deleted")
    }

    /// Losing signal must never sign you out, and the app opens to what it last loaded.
    func testStaysSignedInOffline() {
        signUp(netID: "shortlived.\(Int.random(in: 1000...99999))")   // tokens that need refreshing before every request
        XCTAssertTrue(button("Going soon").waitForExistence(timeout: 5))
        goOffline(seconds: 20)
        app.terminate()
        app.launchArguments = ["-onboarded", "<true/>", "-useLocalServer", "YES"]   // same phone and session, no reset
        app.launch()
        app.tabBars.buttons["Together"].tap()
        XCTAssertTrue(button("Going soon").waitForExistence(timeout: 8), "opens to Together with no connection")
        XCTAssertFalse(app.textFields["NetID"].exists, "still signed in")
        XCTAssertFalse(app.navigationBars["Set up your profile"].exists, "no profile setup screen")
        XCTAssertFalse(app.alerts.firstMatch.exists, "no error pop-up just for being offline")
        let offline = app.staticTexts["No connection. Pull down to try again."]
        XCTAssertTrue(offline.waitForExistence(timeout: 10), "says it's offline instead of spinning")
        XCTAssertTrue(app.staticTexts["Invites for you"].exists, "and shows the plans it last loaded")
        snap("offline-together")
        app.tabBars.buttons["Me"].tap()
        XCTAssertTrue(app.buttons["Edit"].waitForExistence(timeout: 3), "your profile is there offline")
        snap("offline-me")
        sleep(18)   // the connection comes back
        app.tabBars.buttons["Together"].tap()
        app.swipeDown()
        sleep(3)
        XCTAssertFalse(app.textFields["NetID"].exists, "still signed in once it's back")
        XCTAssertTrue(button("Going soon").exists)
        XCTAssertFalse(offline.exists, "the offline note goes away")
        snap("back-online")
    }

    private func goOffline(seconds: Int) {
        let done = expectation(description: "test server goes offline")
        var request = URLRequest(url: URL(string: "http://localhost:54321/dev/offline?seconds=\(seconds)")!)
        request.httpMethod = "POST"
        URLSession.shared.dataTask(with: request) { _, _, _ in done.fulfill() }.resume()
        wait(for: [done], timeout: 5)
    }

    func testSocialAccessibilityAndMenuLine() throws {
        signUp(["-meal", "dinner"])
        for tab in ["Together", "Feed", "Me"] {
            app.tabBars.buttons[tab].tap()
            sleep(3)
            try app.performAccessibilityAudit(for: [.contrast, .elementDetection, .hitRegion, .sufficientElementDescription, .trait]) { issue in
                print("A11Y[\(tab)] \(issue.auditType.rawValue) — \(issue.compactDescription) — \(issue.element?.label ?? "?")")
                return true
            }
        }
        app.tabBars.buttons["Menu"].tap()
        sleep(3)
        snap("menu-friends-line")
        let line = button("Jordan")
        XCTAssertTrue(line.exists || button("Sam").exists || button("Maya").exists, "friends line on Menu")
    }

    func testSocialDarkMode() {
        XCUIDevice.shared.appearance = .dark
        defer { XCUIDevice.shared.appearance = .light }
        signUp()
        snap("dark-together")
        app.tabBars.buttons["Feed"].tap()
        sleep(4)
        snap("dark-feed")

        button("New post").tap()
        sleep(1)
        let plate = "Test plate \(Int.random(in: 1000...9999))"
        button("Choose photo").tap()
        sleep(3)
        snap("photo-picker")
        do {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.16, dy: 0.43)).tap()
            sleep(3)
            let caption = app.textFields.matching(NSPredicate(format: "placeholderValue BEGINSWITH 'Caption'")).firstMatch
            if caption.waitForExistence(timeout: 3) {
                sleep(2)
                caption.tap()
                sleep(1)
                caption.typeText(plate)
            }
            snap("photo-composer")
            app.navigationBars.buttons["Post"].tap()
            sleep(4)
            app.buttons["Newest"].tap()
            sleep(3)
            snap("photo-posted")
            XCTAssertTrue(app.staticTexts[plate].waitForExistence(timeout: 5), "posted photo shows in feed")

            let more = app.buttons["More options"].firstMatch
            XCTAssertTrue(more.waitForExistence(timeout: 3), "post has a ••• button")
            more.tap()
            sleep(1)
            snap("post-menu")
            let delete = app.buttons["Delete post"]
            XCTAssertTrue(delete.waitForExistence(timeout: 3), "••• opens with Delete post")
            delete.tap()
            let confirm = app.buttons["Delete"]
            XCTAssertTrue(confirm.waitForExistence(timeout: 3), "Delete post asks once")
            snap("delete-confirm")
            confirm.tap()
            sleep(3)
            snap("post-deleted")
            XCTAssertFalse(app.staticTexts[plate].exists, "deleted post is gone")
            app.swipeDown()   // pull to refresh: it shouldn't come back
            sleep(3)
            XCTAssertFalse(app.staticTexts[plate].exists, "deleted post stays gone after refresh")
        }
    }
}
