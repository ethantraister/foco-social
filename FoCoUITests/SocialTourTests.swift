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

    private func text(containing part: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", part)).firstMatch
    }

    /// The app's own bottom bar (Menu, the big Together button, Me).
    private func tab(_ name: String) {
        let item = app.buttons["tab.\(name)"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "\(name) tab")
        item.tap()
    }

    /// The first photo in the system photo picker. (iOS 26 puts a one-time note about private access above them.)
    private func pickFirstPhoto() {
        let photo = app.images.matching(NSPredicate(format: "label BEGINSWITH 'Photo'")).firstMatch
        if photo.waitForExistence(timeout: 3) {
            // The picker runs in its own process, so its photos don't count as hittable: tap where it is.
            photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.16, dy: 0.43)).tap()
        }
    }

    private func back() {
        app.navigationBars.buttons.element(boundBy: 0).tap()
        sleep(1)
    }

    /// Small drags until the element sits between the top bar and the tab bar (a swipe on a half-hidden row misses).
    private func scrollIntoView(_ element: XCUIElement) {
        let top = app.navigationBars.firstMatch.frame.maxY + 10
        let bar = app.otherElements["tabBar"]
        let bottom = (bar.exists ? bar.frame.minY : app.frame.maxY) - 10
        // Rows off screen don't exist yet in a list: scroll down until it shows up.
        for _ in 0..<6 where !element.exists { app.swipeUp(); sleep(1) }
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

    /// A time Foco is closed gets a popup instead of going through. Returns true if that happened (and dismisses it).
    private func closedPopupShown() -> Bool {
        let alert = app.alerts.matching(NSPredicate(format: "label BEGINSWITH 'Foco is closed'")).firstMatch
        guard alert.waitForExistence(timeout: 2) else { return false }
        snap("foco-closed")
        alert.buttons["OK"].tap()
        return true
    }

    func testSocialTour() {
        app.launchArguments = ["-resetForUITests", "-onboarded", "<true/>", "-useLocalServer", "YES"]
        app.launch()

        // Signed out, it opens on the menu, with a way into the friends side.
        XCTAssertTrue(app.navigationBars["Foco"].waitForExistence(timeout: 5), "signed out, the app opens on the menu")
        XCTAssertFalse(app.buttons["tab.Feed"].exists, "there's no feed")
        let teaser = app.buttons["See which friends are at Foco"]
        XCTAssertTrue(teaser.waitForExistence(timeout: 5), "the menu points to the friends side")
        snap("signed-out-menu")
        teaser.tap()
        let email = app.textFields["NetID"]
        XCTAssertTrue(email.waitForExistence(timeout: 5), "which asks you to sign in")
        XCTAssertTrue(app.buttons["tab.Together"].isSelected)
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
        app.buttons["Join Foco Polo"].tap()
        // Signing up ends on adding friends (it can wait).
        XCTAssertTrue(app.navigationBars["Add your friends"].waitForExistence(timeout: 8), "signing up ends on adding friends")
        XCTAssertTrue(app.searchFields["Find people by name"].exists, "with search by name")
        XCTAssertFalse(app.staticTexts["Groups and teams"].exists, "groups can wait")
        sleep(1)
        snap("add-friends")
        app.navigationBars.buttons.matching(NSPredicate(format: "label IN {'Later', 'Done'}")).firstMatch.tap()

        XCTAssertTrue(app.navigationBars["Together"].waitForExistence(timeout: 8))
        allowAlerts()
        sleep(3)
        snap("together")

        // Being added to a group is an invite you accept.
        let join = app.buttons["Join"].firstMatch
        XCTAssertTrue(join.waitForExistence(timeout: 5), "a group invite waits on Together")
        XCTAssertTrue(text(containing: "invited you").exists, "and says who invited you")
        snap("group-invite")
        join.tap()
        sleep(2)
        XCTAssertFalse(app.buttons["Join"].exists, "joined")

        // Answer an invite, then tap the same answer to take it back.
        let invite = app.cells.containing(NSPredicate(format: "label CONTAINS 'Post-launch-review dinner'")).firstMatch
        XCTAssertTrue(invite.waitForExistence(timeout: 5), "a meal invite waits on Together")
        invite.buttons["Going"].tap()
        sleep(2)
        snap("invite-accepted")
        XCTAssertFalse(app.staticTexts["Invites for you"].exists, "answered invites leave Invites for you")
        scrollIntoView(invite)
        invite.buttons["Going"].tap()
        sleep(2)
        for _ in 0..<4 { app.swipeDown() }
        XCTAssertTrue(app.staticTexts["Invites for you"].waitForExistence(timeout: 5), "tapping Going again takes it back")
        XCTAssertTrue(invite.exists, "the plan is back with your invites")
        snap("rsvp-taken-back")
        invite.buttons["Going"].tap()
        sleep(2)

        // A plan's page: who's coming (from different friend groups), and a text about it for your group chat.
        scrollIntoView(invite)
        button("Dinner with Priya").tap()
        XCTAssertTrue(app.navigationBars["Dinner"].waitForExistence(timeout: 5), "tapping a plan opens it")
        XCTAssertTrue(text(containing: "Going (").exists, "lists who's going")
        XCTAssertFalse(app.buttons["Plan chat"].exists, "no chat: plans are talked about in people's own group chats")
        snap("plan-detail")
        app.buttons["Text about this plan"].tap()
        sleep(3)
        snap("plan-text")   // the simulator can't send texts, so this is the share sheet with the same message
        let closeShare = app.buttons["Close"]
        if closeShare.waitForExistence(timeout: 2) { closeShare.tap() } else { app.swipeDown() }
        sleep(1)
        back()

        // Joining a friend who's heading over.
        let coming = app.buttons["I'm coming"].firstMatch
        for _ in 0..<4 { app.swipeDown() }
        scrollIntoView(coming)
        XCTAssertTrue(coming.waitForExistence(timeout: 5), "a friend heading to Foco can be joined")
        snap("heading-friends")
        coming.tap()
        sleep(2)
        XCTAssertTrue(app.staticTexts["You're heading over"].waitForExistence(timeout: 5))
        snap("heading-me-too")
        for _ in 0..<3 { app.swipeDown() }
        button("Change time").tap()
        sleep(1)
        XCTAssertTrue(app.buttons["Custom"].exists, "15 min, 30 min, 1 hour, or a time you pick")
        app.buttons["15 min"].tap()
        app.buttons["Dark side"].tap()
        let loud = app.switches["Notify friends"]
        XCTAssertTrue(loud.exists, "out loud or quiet")
        if (loud.value as? String) != "1" { loud.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap() }
        XCTAssertTrue(app.buttons["Tell friends"].waitForExistence(timeout: 2), "out loud says Tell friends")
        snap("heading-sheet")
        app.buttons["Tell friends"].tap()
        if closedPopupShown() { app.buttons["Cancel"].tap() }
        allowAlerts()   // posting is when the app asks about notifications
        sleep(2)

        let byHand = app.buttons["Check in manually"]
        for _ in 0..<3 where !byHand.isHittable { app.swipeUp() }
        byHand.tap()
        if !closedPopupShown() {
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
        }
        for _ in 0..<3 { app.swipeDown() }
        sleep(1)

        button("Plan a meal").tap()
        sleep(1)
        button("Tomorrow").tap()
        XCTAssertTrue(app.staticTexts["Meal: Dinner"].waitForExistence(timeout: 3), "the meal follows from the time")
        button("Just people I pick").tap()
        button("Maya R.").tap()
        let note = app.textFields.matching(NSPredicate(format: "placeholderValue BEGINSWITH 'Note'")).firstMatch
        if note.exists { note.tap(); note.typeText("Window tables") }
        snap("plan-composer")
        app.buttons["Post"].tap()
        allowAlerts()
        sleep(2)
        app.swipeUp()
        sleep(1)
        snap("together-with-plan")

        // Swiping your own plan cancels it right away, with Undo instead of a second "are you sure?".
        let mine = app.cells.containing(NSPredicate(format: "label BEGINSWITH 'Your '")).firstMatch
        for _ in 0..<3 where !mine.exists { app.swipeUp() }
        if mine.exists {
            scrollIntoView(mine)
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
        let accept = button("Accept")
        XCTAssertTrue(accept.waitForExistence(timeout: 3), "friend request with Accept")
        XCTAssertTrue(button("Decline").exists, "and Decline next to it")
        XCTAssertEqual(accept.frame.midY, button("Decline").frame.midY, accuracy: 2, "side by side, under the name")
        accept.tap()
        sleep(2)
        snap("friend-accepted")
        let star = app.buttons["Make Maya a close friend"]
        // Lists only make rows as they scroll into view.
        for _ in 0..<3 where !(star.exists && star.isHittable) { app.swipeUp(); sleep(1) }
        XCTAssertTrue(star.waitForExistence(timeout: 3), "a star makes someone a close friend")
        star.tap()
        XCTAssertTrue(app.buttons["Maya is a close friend"].waitForExistence(timeout: 3))
        snap("close-friend")
        let inviteText = button("Invite friends by text")
        for _ in 0..<3 where !(inviteText.exists && inviteText.isHittable) { app.swipeDown(); sleep(1) }
        XCTAssertTrue(inviteText.waitForExistence(timeout: 3), "invite friends by text from Friends")
        inviteText.tap()
        sleep(3)
        snap("invite-by-text")   // the simulator can't send texts, so this is the share sheet with the same message
        let close = app.buttons["Close"]
        if close.waitForExistence(timeout: 2) { close.tap() } else { app.swipeDown() }
        sleep(1)
        app.buttons["Done"].tap()

        XCTAssertFalse(app.buttons["tab.Chats"].exists, "no Chats tab")
        tab("Me")
        sleep(1)
        snap("me")
        app.buttons["Notifications"].tap()
        XCTAssertTrue(text(containing: "Friends going soon").waitForExistence(timeout: 5), "notification settings")
        XCTAssertFalse(app.switches["Messages"].exists, "no message notifications without chats")
        snap("notification-settings")
        back()
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

    /// Walk into Foco, get checked in; walk out, get checked out. Needs a meal to be on (Eastern time).
    func testAutoCheckIn() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        let c = cal.dateComponents([.hour, .minute], from: .now)
        let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        try XCTSkipUnless((7 * 60 + 40..<20 * 60 + 20).contains(m), "Foco isn't serving right now")

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
        app.swipeDown()   // back up to "At Foco now"
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


    /// Plan days ahead (and get turned away at a closed time), and build a club group with someone who isn't a friend.
    func testPlanAheadAndGroups() {
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
        XCTAssertTrue(app.staticTexts["Meal: Dinner"].waitForExistence(timeout: 3), "6 PM is dinner, picked for you")
        XCTAssertFalse(app.segmentedControls.firstMatch.exists, "no meal picker to get wrong")
        // 9 PM: between dinner and Late Night, Foco is closed.
        app.datePickers.firstMatch.tap()
        let hour = app.pickerWheels.element(boundBy: 0)
        if hour.waitForExistence(timeout: 3) {
            hour.adjust(toPickerWheelValue: "9")
            app.navigationBars.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            XCTAssertTrue(app.staticTexts["Foco is closed then"].waitForExistence(timeout: 3), "a closed time says so")
            app.buttons["Post"].tap()
            XCTAssertTrue(closedPopupShown(), "and Post explains it in a popup")
            app.datePickers.firstMatch.tap()
            hour.adjust(toPickerWheelValue: "6")
            app.navigationBars.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        } else {
            XCTFail("time wheel")
        }
        snap("plan-ahead")
        app.buttons["Post"].tap()
        allowAlerts()
        sleep(2)
        let planned = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", weekday)).firstMatch
        for _ in 0..<4 where !planned.exists { app.swipeUp() }
        XCTAssertTrue(planned.exists, "plan \(weekday) shows up")
        snap("plan-ahead-listed")

        // The host can change it later.
        button("Your dinner").tap()
        XCTAssertTrue(app.buttons["Change time or note"].waitForExistence(timeout: 5), "the host can edit a plan")
        app.buttons["Change time or note"].tap()
        XCTAssertTrue(app.navigationBars["Edit plan"].waitForExistence(timeout: 3))
        let note = app.textFields.matching(NSPredicate(format: "placeholderValue BEGINSWITH 'Note'")).firstMatch
        note.tap()
        note.typeText("Upstairs")
        snap("edit-plan")
        app.buttons["Save"].tap()
        XCTAssertTrue(text(containing: "Upstairs").waitForExistence(timeout: 5), "the change shows")
        back()

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
        XCTAssertTrue(app.staticTexts["Your friends, most recent first"].exists, "friends are there to add without searching")
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
        XCTAssertTrue(addFriend.waitForExistence(timeout: 5), "Theo accepted the invite, and as a non-friend has Add friend")
        XCTAssertTrue(app.buttons["Delete group"].exists, "the creator owns the group")
        XCTAssertFalse(app.buttons["Group chat"].exists, "no group chat: teams already have theirs")
        XCTAssertTrue(app.buttons["Add photo"].exists, "and can give it a photo")
        app.buttons["Add photo"].tap()
        XCTAssertTrue(app.staticTexts["Add group photo"].waitForExistence(timeout: 3), "the options sheet is about the group")
        app.buttons["Choose photo"].tap()
        sleep(3)
        pickFirstPhoto()
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
        back()
        app.buttons["Done"].tap()
    }

    private func signUp(_ extraArgs: [String] = [], netID: String = "audit.\(Int.random(in: 1000...99999))") {
        app.launchArguments = ["-resetForUITests", "-onboarded", "<true/>", "-useLocalServer", "YES"] + extraArgs
        app.launch()
        tab("Together")
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
        app.buttons["Join Foco Polo"].tap()
        // Signing up ends on adding friends (it can wait).
        XCTAssertTrue(app.navigationBars["Add your friends"].waitForExistence(timeout: 8), "signing up ends on adding friends")
        app.navigationBars.buttons.matching(NSPredicate(format: "label IN {'Later', 'Done'}")).firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Together"].waitForExistence(timeout: 8))
        allowAlerts()
        sleep(3)
    }

    /// The flows App Review and a public release depend on: the review account's password sign-in, reporting and
    /// blocking (and unblocking) people, changing the profile photo, and deleting the account.
    func testReleaseFlows() {
        app.launchArguments = ["-resetForUITests", "-onboarded", "<true/>", "-useLocalServer", "YES"]
        app.launch()
        tab("Together")
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
            app.buttons["Join Foco Polo"].tap()
            // Signing up ends on adding friends (it can wait).
            if app.navigationBars["Add your friends"].waitForExistence(timeout: 8) {
                app.navigationBars.buttons.matching(NSPredicate(format: "label IN {'Later', 'Done'}")).firstMatch.tap()
            }
        }
        XCTAssertTrue(app.navigationBars["Together"].waitForExistence(timeout: 8), "the review account gets in")
        allowAlerts()
        sleep(2)

        // Press and hold anyone to report or block them; unblock from Me → About → Blocked people.
        button("Friends").tap()
        let friend = app.staticTexts["Maya R. '28"].exists ? app.staticTexts["Maya R. '28"] : text(containing: "Maya R.")
        for _ in 0..<3 where !(friend.exists && friend.isHittable) { app.swipeUp(); sleep(1) }
        XCTAssertTrue(friend.waitForExistence(timeout: 6), "a friend to report")
        friend.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Report Maya"].waitForExistence(timeout: 3), "report opens an email to us about them")
        snap("report-or-block")
        let block = app.buttons["Block Maya"]
        XCTAssertTrue(block.exists)
        let blocked = "Maya"
        block.tap()
        XCTAssertTrue(app.alerts["Block Maya?"].waitForExistence(timeout: 3), "blocking asks first, in the middle of the screen")
        app.alerts.buttons["Block"].tap()
        sleep(2)
        XCTAssertFalse(friend.exists, "they're gone from your friends")
        snap("blocked")
        app.buttons["Done"].tap()
        tab("Me")
        for _ in 0..<3 { app.swipeUp() }
        sleep(1)
        let about = app.buttons["About"]
        XCTAssertTrue(about.waitForExistence(timeout: 3))
        XCTAssertLessThanOrEqual(about.frame.maxY, app.otherElements["tabBar"].frame.minY + 1, "the last rows scroll clear of the bottom bar")
        snap("me-bottom")
        about.tap()
        XCTAssertTrue(app.descendants(matching: .any)["Contact us"].waitForExistence(timeout: 3), "About has a way to reach us")
        XCTAssertFalse(app.buttons["Community rules"].exists, "and nothing else to read")
        snap("about")
        app.buttons["Blocked people"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", blocked)).firstMatch.waitForExistence(timeout: 5),
                      "blocked people are listed")
        snap("blocked-people")
        app.buttons["Unblock"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["You haven't blocked anyone."].waitForExistence(timeout: 5), "and can be unblocked")
        back()   // About
        back()   // Me

        // A new profile photo replaces the old one. (Back at the top first: Edit sits under the status bar from down here.)
        for _ in 0..<3 { app.swipeDown() }
        sleep(1)
        app.buttons["Edit"].tap()
        let editPhoto = app.buttons.matching(NSPredicate(format: "label IN {'Add photo', 'Edit photo'}")).firstMatch
        XCTAssertTrue(editPhoto.waitForExistence(timeout: 3))
        editPhoto.tap()
        XCTAssertTrue(app.buttons["Choose photo"].waitForExistence(timeout: 3))
        snap("photo-options")
        app.buttons["Choose photo"].tap()
        sleep(3)
        pickFirstPhoto()
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

        // A dish's page offers an alert, and promises nothing on Dining's behalf.
        tab("Menu")
        let dish = app.buttons.containing(NSPredicate(format: "label CONTAINS ' station'")).firstMatch
        if dish.waitForExistence(timeout: 8) {
            dish.tap()
            XCTAssertTrue(app.switches.firstMatch.waitForExistence(timeout: 3), "Alert me when it's served")
            XCTAssertFalse(button("Ask Dining").exists)
            snap("dish")
            back()
        }

        // Deleting the account signs you out (and removes your photos; the test script checks the folder).
        tab("Me")
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
        tab("Together")
        XCTAssertTrue(button("Going soon").waitForExistence(timeout: 8), "opens to Together with no connection")
        XCTAssertFalse(app.textFields["NetID"].exists, "still signed in")
        XCTAssertFalse(app.navigationBars["Set up your profile"].exists, "no profile setup screen")
        XCTAssertFalse(app.alerts.firstMatch.exists, "no error pop-up just for being offline")
        let offline = app.staticTexts["No connection. Pull down to try again."]
        XCTAssertTrue(offline.waitForExistence(timeout: 10), "says it's offline instead of spinning")
        XCTAssertTrue(app.staticTexts["Invites for you"].exists, "and shows the plans it last loaded")
        snap("offline-together")
        tab("Me")
        XCTAssertTrue(app.buttons["Edit"].waitForExistence(timeout: 3), "your profile is there offline")
        snap("offline-me")
        sleep(18)   // the connection comes back
        tab("Together")
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
        for name in ["Together", "Me"] {
            tab(name)
            sleep(3)
            try app.performAccessibilityAudit(for: [.contrast, .elementDetection, .hitRegion, .sufficientElementDescription, .trait]) { issue in
                print("A11Y[\(name)] \(issue.auditType.rawValue) — \(issue.compactDescription) — \(issue.element?.label ?? "?")")
                return true
            }
        }
        tab("Menu")
        sleep(3)
        func friendsLine() -> Bool { ["Jordan", "Sam", "Maya", "Theo"].contains { button($0).exists } }
        // Once tonight's dinner is over (and Foco is closed, so no one's there), the demo team dinner is tomorrow's.
        if !friendsLine() {
            button("Tomorrow").tap()
            sleep(2)
        }
        snap("menu-friends-line")
        XCTAssertTrue(friendsLine(), "friends line on Menu")
    }

    func testSocialDarkMode() {
        XCUIDevice.shared.appearance = .dark
        defer { XCUIDevice.shared.appearance = .light }
        signUp()
        snap("dark-together")
        button("Going soon").tap()
        sleep(1)
        snap("dark-going-soon")
        app.buttons["Cancel"].tap()
        sleep(1)
        let plan = button("Dinner with Priya")
        if plan.waitForExistence(timeout: 3) {
            scrollIntoView(plan)
            plan.tap()
            sleep(2)
            snap("dark-plan")
            back()
        }
        tab("Menu")
        sleep(4)
        snap("dark-menu")
        app.swipeUp()
        sleep(1)
        snap("dark-menu-stations")
    }
}
