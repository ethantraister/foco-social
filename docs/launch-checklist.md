# Foco launch checklist

As of 3 Nov 2026 (build 1.1 (12)). Dartmouth Dining has agreed to sponsor the app; what that covers is still to be confirmed (see "Ask Dining").

## Done

- App works end to end on the live server: sign-in, menu and diet filters, food alerts, friends and close friends, automatic and manual check-in, going soon, plans, groups, notifications, report and block, account deletion.
- Notification taps no longer crash the app (build 10). All testers are on build 10.
- Privacy fixes live: the privacy helpers aren't callable (migration 013). Migration 015 (old chat messages can't trigger notifications) is live too.
- 200 server checks and 17 UI tests pass (iOS 26.5 and 27), plus the notification-tap test.
- Privacy manifest, export compliance (no encryption beyond HTTPS), account deletion in the app, report and block (press and hold a person), community-rules agreement at sign-up.

## Ethan: before submitting

1. **Ask Dining** what the sponsorship covers:
   - Can the app say "In partnership with Dartmouth Dining" (welcome screen, About, App Store description)?
   - The D-Pine logo is the College's mark, not Dining's: does Dining have the College's OK, or should the app use its own icon only? (Apple rejects apps that use another organization's marks without permission.)
   - Could Dining host the privacy policy and support pages (for example on dining.dartmouth.edu)?
   - Would Dining cover running costs: Supabase Pro ($25/month: daily backups, no pausing), the Apple Developer Program ($99/year), and an email domain and sending service?
   - Should students' food requests come back, and to whom (an address at Dining)?
   - Would a Dining dietitian review the allergen wording?
   - Promotion: table tents or QR codes at Foco on launch day?
2. **Privacy policy and support pages online.** Apple needs both URLs. `docs/privacy.html` is ready. Options: Dining's site, your own domain, or a public GitHub Pages site (I can set that up if you OK making those pages public). Then I add the privacy link to About.
3. **Email that can handle launch day.**
   - Gmail sends a few hundred emails a day at most, and Supabase's default email rate limit is low (Authentication → Rate Limits; raise it).
   - Better: a domain plus a sending service (Resend, Postmark, Amazon SES), set as Supabase's SMTP.
   - Rename the sender to "Foco" either way.
4. **Supabase Pro** before launch: the free plan has no backups and pauses after a week without use.
5. **App Review account.** Supabase → Authentication → Users → Add user: `focoreview@dartmouth.edu`, a password, "Auto Confirm User" on. Sign in once on a phone (NetID `focoreview`) to make its profile, then friend it from your account and post a plan so reviewers don't see an empty app.
6. **Invite link.** App Store Connect → App Information → Apple ID (a number). Send it to me; invites then link to `https://apps.apple.com/app/id<number>`, which works as soon as the app is live.

## App Store listing (paste into App Store Connect)

- **Name:** Foco Dining (“Foco” was taken). On the home screen the app reads Foco.
- **Subtitle (29/30):** See which friends are at Foco
- **Category:** Food & Drink; secondary Social Networking
- **Promotional text (160/170):** Know who's at Foco before you walk in. See the menu with your diet filters, get alerts for your favorite dishes, and plan meals with friends, teams, and floors.
- **Keywords (97/100):** `dartmouth,dining,menu,53 commons,friends,meal plan,allergens,vegan,vegetarian,gluten free,hanover`
- **Description:**

  > Foco is the easiest way to eat with friends at '53 Commons.
  >
  > SEE WHO'S THERE
  > Walk into Foco and your friends see you're there (it's automatic if you turn it on, and only during meals). See which side they're on: dark side, light side, or upstairs. Heading over? Post "going soon" so friends can join you.
  >
  > PLAN MEALS
  > Pick a day and time, invite friends or a whole group, and see who's going. Teams, clubs, and floors can make groups for team dinners.
  >
  > KNOW WHAT'S ON
  > Today's menu by station, with desserts up top. Filter for vegan, vegetarian, gluten free, halal, or kosher, and hide foods with the allergens you avoid. Follow your favorite dishes and get an alert when they're served.
  >
  > PRIVATE BY DESIGN
  > Only Dartmouth students can join. Your location never leaves your phone: friends only see that you're at Foco. Choose whether all friends or just close friends see you. Block or report anyone, and delete your account anytime.
  >
  > Menu and allergen information comes from Dartmouth Dining. Labels can be incomplete; with a serious allergy, always confirm at the station.

- **Age rating:** answer Yes to user-generated content (profiles, photos, plan notes); No to messaging and chat (there are no chats) and everything else. Expect 13+.
- **App Privacy:** Email Address, Name, User ID, Photos, Other User Content (all App Functionality); Product Interaction (Analytics: feature counts). All linked to the user, none used for tracking. Location: not collected (it never leaves the phone).
- **Review notes:**

  > Foco is for Dartmouth College students; sign-in normally sends a code to a @dartmouth.edu address. For review, type the NetID `focoreview` and the password below, which skips the emailed code.
  >
  > Location ("Always") is only used for optional automatic check-in: when the student walks into '53 Commons (Foco) during a meal, friends see they're there. The location itself never leaves the phone.
  >
  > Report or block: press and hold any person. Delete account: Me → Delete my account.

- **Screenshots:** 6.9-inch iPhone, from the simulator with the made-up demo students (I can generate them).
