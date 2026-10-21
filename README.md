# Foco Polo (v2)

See which friends are at Foco, and what's on. Two things, done well: **Together** (who's there, who's going soon and to which side, plans for later) and the **Menu** (what's on, desserts, diet filters, alerts for favorite foods). Everything else is settings. See `docs/strategy.md` for why. v1 (menu only) lives in `~/FoCoApp`. The two apps have different bundle IDs, so both can be installed side by side.

## Tabs

| Tab | What it does |
|---|---|
| **Menu** | Today's Foco menu by station: each station's main dishes, with "More from <station>" for sides and everyday items (pizza counts as everyday). Desserts get their own section at the top. Plus a line like "Jordan and 2 others are eating dinner" when friends are going |
| **Together** (the big middle button; the app opens here) | Invites for you (meal plans and group invites) · "Going soon" (15 min, 30 min, 1 hour, or a time you pick; which side; quiet or out loud; all friends or close friends) · friends at Foco now and heading over, with "I'm coming" · plans (tap one for who's coming and to text about it; Going / Maybe / Can't, tap again to take it back) · automatic check-in |
| **Me** | Profile, friends and groups, invite friends by text, check in automatically, diet, food alerts, notifications, About (community rules, blocked people, privacy, contact), sign out, delete account |

Food alerts (follow a food, see when it's on next) open from the bell on the menu, or by swiping right on a dish. There's no in-app chat: a plan's **Text about this plan** opens Messages with it written out, so conversations stay in the group chats people already have. Press and hold anyone's name to report (an email to `SUPPORT_EMAIL`) or block them. Signing up ends on "Add your friends" (skippable), since seeing friends at Foco is the point.

Swipe sideways anywhere on a tab's first screen to move to the tab beside it, in the bar's order (like Instagram). On a screen pushed on top (a dish, a plan), a sideways swipe goes back instead, and a row that slides open (Remove, Unfollow, Alert me) opens rather than changing tabs.

The Menu (and food alerts) work without an account. Together asks you to sign in with your NetID: the app emails a 6-digit code to NetID@dartmouth.edu (no password). Losing signal never signs you out; the app opens to what it last loaded.

Foco is open 7:30 AM–8:30 PM and 9:30 PM–1:30 AM. Plans, going soon, and checking in by hand turn away times when it's closed, with a popup saying when it opens. A plan's meal (breakfast, lunch, dinner, late night) follows from its time.

**Invite friends by text** (Friends, the Me tab, or the Together tab when you have no friends yet) opens Messages with an invite already written. Put the App Store or TestFlight link in `APP_STORE_URL` in `Info.plist` once there is one, and the invite includes it.

## Try it on your Mac (local test server)

```sh
~/FoCoSocial-devtools/venv/bin/python ~/FoCoSocial/backend/local/dev_server.py
```

Then open `FoCo.xcodeproj` in Xcode and press ▶ with an iPhone simulator selected. Sign in with any `name@dartmouth.edu`; the code is **123456** (or the one printed in the server window). Press Ctrl-C to stop the server.

- The test server runs real Postgres and PostgREST, the same software Supabase uses, against `backend/schema.sql`. Only login emails and photo storage are imitated.
- It seeds eight **made-up** students, plus Water Polo and Rocket Team groups. They befriend you when you sign up, invite you to a dinner, and say yes to your invites. The app shows a banner saying the data is fake.
- `--reset` wipes the database. `--lan` lets a real iPhone on the same Wi-Fi connect: put `http://<your-Mac's-IP>:54321` in `SUPABASE_URL`. Only use `--lan` on a network you trust, because the test server's keys aren't secret.

## Automatic check-in

Off until you turn it on (Together tab or Me tab). iOS watches a 70 m circle around '53 Commons; when you enter during a dining period, the app takes one precise reading (within 60 m of the building) and checks you in for up to 2 hours. Leaving the circle checks you out. Tapping Leave while still inside stops it from re-checking you in until you walk out. Friends see only "at Foco" and the room, never coordinates. Needs Location set to "Always" to work with the app closed.

Dining periods (from Dartmouth Dining): breakfast 7:30–11, lunch 11–4, dinner 4–8:30, late night 9:30 PM–1:30 AM.

## Food requests → daily email to Dining (switched off in the app)

The app no longer offers food requests: it promised they reach Dartmouth Dining, and Dining hasn't agreed to receive them (the digest goes to `DIGEST_TO`). Bring the screen back from git history (`RequestsView.swift`, the dish page's "Ask Dining") once Dining is on board; the server side is unchanged. When it was on, students sent requests (10 a day max, one per food per day) and the `daily-requests` Edge Function (`supabase/functions/daily-requests/`) emailed one summary at 7 AM New York time: each food, how many students, which meals, up to three notes. No names. Setup on the live project:

1. Edge Functions → Secrets: `GMAIL_USER`, `GMAIL_APP_PASSWORD`, `DIGEST_TO` (who gets it; currently focosocial.app@gmail.com until Dining agrees), `CRON_SECRET` (random).
2. Run `backend/migrations/003_daily_requests_cron.sql` with the two placeholders filled in. (Migration 013 unschedules this job while requests are off; this step turns it back on.)
3. Test without sending: POST `/functions/v1/daily-requests?preview=1` with the `x-cron-secret` header.

## Push notifications

Friends' going soon (only when they choose Notify friends), getting to Foco (close friends by default), someone joining you, meal invites and changes, group invites and team meals, and messages. Each person picks what they get in Me → Notifications. The "Still a maybe?" reminder 30 minutes before a plan is local to the phone, with Going / Can't make it buttons on the notification.

How it works: database triggers (migration `010`) put each notification in `push_queue` and call the `push` Edge Function (`supabase/functions/push/`), which sends it through Apple and forgets phones that deleted the app. The app registers its push token with `register_device()` after sign-in and removes it on sign-out. Builds installed from Xcode use Apple's sandbox; TestFlight and App Store builds use production.

Setup on the live project (once):

1. **Apple key.** developer.apple.com → Certificates, Identifiers & Profiles → Keys → **+** → name it "FoCo push", tick **Apple Push Notifications service (APNs)** → Configure → environment **Sandbox & Production** → Save → Continue → Register → **Download** the `.p8` file (Apple only lets you download it once) and note the **Key ID**.
2. **Secrets.** Supabase → Edge Functions → Secrets: `APNS_KEY` (paste the whole `.p8` file, including the BEGIN/END lines), `APNS_KEY_ID`, `APNS_TEAM_ID` = `8VN4WGJA8Y`.
3. **Function.** Supabase → Edge Functions → Deploy a new function → Via editor → name it `push` → paste `supabase/functions/push/index.ts` → Deploy. Leave "Verify JWT" on (the database calls it with the anon key).
4. **Database.** Run `backend/migrations/010_social_v2.sql` with `ANON_KEY_VALUE` replaced by the anon key.
5. **Let the database call the function.** In the SQL editor, run `create extension if not exists pg_net;` (migration `003` does this too, but it may not have run). Without it, notifications pile up in `push_queue` unsent and nothing else breaks.

To check one notification went out: in the SQL editor, `select id, title, sent_at from push_queue order by id desc limit 5;` (a sent one has `sent_at`), and Edge Functions → push → Logs shows Apple's answer for each phone.

## Database changes

Changes after the first deploy live in `backend/migrations/` (already folded into `schema.sql` and `storage.sql`). `001_heading_eta.sql` and `002_groups_and_requests.sql` were run on the live project on 10 Oct 2026; `003` (the schedule) needs the secrets first. `004_group_owner.sql` (one owner per group: delete, remove people, transfer) was run on live on 11 Oct 2026.

`005_profile_photos.sql` (profile photos) and `006_release_hardening.sql` (other people's emails unreadable, a post's photo must be the author's own, 20 posts a day, plans can't be moved into someone else's group, and people can list their own photos so deleting a post or the account deletes its photos) were run on live on 11 Oct 2026.

`007_search_by_name.sql` (people search matches names only, not NetIDs) was run on live on 11 Oct 2026.

`008_group_photos.sql` (group photos instead of emoji; only the owner can change one, and it must be in their own photo folder) was run on live on 11 Oct 2026.

`009_lock_row_owners.sql` (security fix: whoever received a friend request could rewrite its sender to anyone and accept it, a fake friendship that showed that person's check-ins; plan replies get the same lock) was run on live on 11 Oct 2026.

`010_social_v2.sql` (build 2: close friends, "Me too" (now "I'm coming") remembers who you're joining, group invites you accept, taking back an RSVP, chats, push notifications and settings) is for build 2. Build 1 keeps working after it runs: adding someone to a group just becomes an invite, and `invited_by` is deliberately not a foreign key so build 1's group query stays unambiguous.

`011_usage_days.sql` counts which features each person used on which day (no times, places, or content), so you can see what students actually use before cutting or adding anything. The app only adds rows; people can see only their own. Builds before 1.1 never write here, and the app works the same before it's run. Read it in the SQL Editor:

```sql
select * from usage_by_day where day > current_date - 14;   -- people per feature per day
select * from usage_weekly_retention;                        -- of each week's new people, how many came back
select count(distinct user_id) filter (where day = current_date) * 1.0
     / nullif(count(distinct user_id) filter (where day > current_date - 30), 0) as dau_over_mau
from usage_days;
```

`012_foco_caps.sql` makes friends' notifications say Foco ("Maya is at Foco"), matching the app. Wording only; safe to run any time.

`013_private_helpers.sql` moves the small yes/no functions behind the privacy rules (`are_friends`, `is_blocked`, `marked_me_close`, …) into a `private` schema the API doesn't publish. Before it, any signed-in student could call them with anyone's ids and learn who is friends with whom, who blocked whom, and who starred them as a close friend. The rules work exactly as before. It also stops trigger functions being callable, pins three helpers' search_path, and switches off the daily food-request email job. Safe to run twice.

The chat tables (`messages`, `chat_reads`, `message_reports`) are still in the database from build 2–4; nothing new writes them, and they're removed with each account.

## Tests

```sh
# API + privacy rules (201 checks): run while the server is up
~/FoCoSocial-devtools/venv/bin/python backend/local/test_api.py <server log file>

# UI tests: tours of every screen, plan editing and closed hours, swiping between tabs (and back from pushed screens),
# a stress run of fast swipes and taps, accessibility audit, large text, dark mode, photo upload, staying signed in offline
~/FoCoSocial-devtools/runtests.sh ~/FoCoSocial /tmp/shots   # uses -useLocalServer, so the live Info.plist keys are ignored
```

Tapping a notification while the app is in the background (`NotificationTapTests`) needs a push from outside the simulator, so it's skipped unless `TEST_RUNNER_NOTIFICATION_TAP=1`. While it waits, send pushes whose title is "Tap test":

```sh
echo '{"Simulator Target Bundle":"com.ethantraister.FoCoSocial","aps":{"alert":{"title":"Tap test","body":"Tap me"}}}' > /tmp/push.json
xcrun simctl push <simulator id> com.ethantraister.FoCoSocial /tmp/push.json   # repeat every few seconds until the test taps one
```

Before 20 Oct 2026 every such tap crashed the app (the notification handler finished off the main thread).

The local server has two test-only helpers: `POST /dev/offline?seconds=N` drops every connection for N seconds (like losing signal), and NetIDs starting with `shortlived.` get tokens that need refreshing before every request.

## Going live (Supabase, free tier)

1. Create a project at supabase.com.
2. In the SQL editor, run `backend/schema.sql`, then `backend/storage.sql`. **Never run anything in `backend/local/`** there; those files hold the fake data and test-only shortcuts.
3. Turn on email sign-in with codes: Authentication → Providers → Email. Then edit the Magic Link email template so the email shows `{{ .Token }}` (the 6-digit code) instead of a link.
4. **Set up your own email sender** (Authentication → SMTP, for example Resend). Supabase's built-in sender only allows a few emails per hour, which isn't enough for real users.
5. In `Info.plist`, set `SUPABASE_URL` and `SUPABASE_ANON_KEY` (Project Settings → API). The banner disappears and the Me → About → Server row goes away.

## Before submitting to the App Store

1. **App Review account.** Reviewers can't receive a Dartmouth email, so the NetID in `REVIEW_NETID` (`focoreview`) signs in with a password instead of a code. Create it in Supabase: Authentication → Users → Add user → `focoreview@dartmouth.edu`, a strong password, Auto Confirm User. Give the NetID and password to Apple in App Store Connect → App Review Information. Consider adding it as a friend and posting a plan, so the reviewer sees the social side working.
2. **Privacy policy URL.** Host `docs/privacy.html` (GitHub Pages, Google Sites) and put its address in App Store Connect and in `PRIVACY_POLICY_URL` in `Info.plist`; the app links to it from Me → About → Privacy policy (Apple requires the link inside the app too). In App Privacy, declare: email address, name, user ID, photos, and other user content, linked to the user, for app functionality; and product interaction (the daily feature counts), linked to the user, for analytics. None of it is tracking. This matches `PrivacyInfo.xcprivacy`. (Builds 1–4 also declared emails or text messages for the chats; that can come off once no chat build is in use.)
3. **Contact.** `SUPPORT_EMAIL` in `Info.plist` (now focosocial.app@gmail.com) is the Me → About → Contact us link. Apps with profiles people can report must publish a way to reach you.
4. **Permissions from Dartmouth** for the D-Pine logo, the name, and using Dining's menu feed.
5. Export compliance is already answered in the build (`ITSAppUsesNonExemptEncryption = NO`: the app only uses HTTPS).

## What's not built yet

- **Crowd meter** (how busy Foco is). Left out on purpose until enough people use the app for a count to mean something.
- **A moderation dashboard.** Reports arrive by email (press and hold someone's name → Report); old reported messages are in `message_reports`.
- **The old feed's data.** The Feed tab is gone; the `posts` tables are still in the database (nothing reads them) and are removed with each account.

## Privacy model (enforced in the database, tested in `test_api.py`)

- Only `@dartmouth.edu` emails can create a profile.
- Check-ins and plans are visible only to friends (or only close friends, if you pick that), or to the people invited or the group. Check-ins expire after at most 3 hours.
- Your close friends list is readable only by you; nobody can ask the server who marked whom.
- Hosts can only invite friends. Groups can invite anyone on the app (teams and clubs aren't all friends), but you're only in once you accept; until then you see the group's name and members, not its plans. Being in a group never shows you members' check-ins.
- Phones' push tokens and the notification queue can't be read by anyone but the server, and nobody can send a notification directly.
- Other people's email addresses can't be read, and people search matches names only.
- Blocking hides plans and check-ins in both directions, and can be undone from Me → About → Blocked people.
- Feature counts: you can add only your own, only for today, and see only your own; the summaries are for the owner (SQL Editor).
- People can delete their account from the app, which removes all their data, photos and feature counts included.
