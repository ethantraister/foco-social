# FoCo Social (v2)

The FoCo menu app plus a social layer: eat with friends, post your plate, and vote on the best meal of the day. v1 (menu only) lives in `~/FoCoApp`. The two apps have different bundle IDs, so both can be installed side by side.

## Tabs

| Tab | What it does |
|---|---|
| **Menu** | Today's FoCo menu by meal (same as v1), plus a line like "Jordan and 2 others are eating dinner" when friends are going |
| **Together** | Invites for you · "Going soon" (I'll be at FoCo in 15/30/45/60 min; friends tap Me too) · "I'm at FoCo" check-in for 30/45/60 min (friends only, expires on its own; optional automatic check-in by location, with dark side / light side / upstairs) · friends at FoCo right now, with "On my way" · plans from friends and groups (Going / Maybe / Can't), each showing that meal's main dishes |
| **Feed** | Photos of plates with captions; upvote, and the day's most-upvoted is Plate of the Day. (Ideas and complaints were cut on purpose: no Fizz-style board for now. The database still supports them.) |
| **Alerts** | Follow foods (same as v1) |
| **Me** | Profile, friends and groups, invite friends by text, diet, food requests, community rules, blocked people, privacy, contact, sign out, delete account |

The Menu and Alerts tabs work without an account. Together and Feed ask you to sign in with your NetID: the app emails a 6-digit code to NetID@dartmouth.edu (no password). Losing signal never signs you out; the app opens to what it last loaded.

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

Off until you turn it on (Together tab or Me tab). iOS watches a 70 m circle around '53 Commons; when you enter during a dining period, the app takes one precise reading (within 60 m of the building) and checks you in for up to 2 hours. Leaving the circle checks you out. Tapping Leave while still inside stops it from re-checking you in until you walk out. Friends see only "at FoCo" and the room, never coordinates. Needs Location set to "Always" to work with the app closed.

Dining periods (from Dartmouth Dining): breakfast 7:30–11, lunch 11–4, dinner 4–8:30, late night 9:30 PM–1:30 AM.

## Food requests → daily email to Dining

Students send requests in the app (Me → Food requests): 10 a day max, one per food per day. Others can tap "Me too." The `daily-requests` Edge Function (`supabase/functions/daily-requests/`) emails one summary at 7 AM New York time: each food, how many students, which meals, up to three notes. No names. Setup on the live project:

1. Edge Functions → Secrets: `GMAIL_USER`, `GMAIL_APP_PASSWORD`, `DIGEST_TO` (who gets it; currently focosocial.app@gmail.com until Dining agrees), `CRON_SECRET` (random).
2. Run `backend/migrations/003_daily_requests_cron.sql` with the two placeholders filled in.
3. Test without sending: POST `/functions/v1/daily-requests?preview=1` with the `x-cron-secret` header.

## Database changes

Changes after the first deploy live in `backend/migrations/` (already folded into `schema.sql` and `storage.sql`). `001_heading_eta.sql` and `002_groups_and_requests.sql` were run on the live project on 10 Oct 2026; `003` (the schedule) needs the secrets first. `004_group_owner.sql` (one owner per group: delete, remove people, transfer) was run on live on 11 Oct 2026.

`005_profile_photos.sql` (profile photos) and `006_release_hardening.sql` (other people's emails unreadable, a post's photo must be the author's own, 20 posts a day, plans can't be moved into someone else's group, and people can list their own photos so deleting a post or the account deletes its photos) were run on live on 11 Oct 2026.

`007_search_by_name.sql` (people search matches names only, not NetIDs) was run on live on 11 Oct 2026.

`008_group_photos.sql` (group photos instead of emoji; only the owner can change one, and it must be in their own photo folder) was run on live on 11 Oct 2026.

`009_lock_row_owners.sql` (security fix: whoever received a friend request could rewrite its sender to anyone and accept it, a fake friendship that showed that person's check-ins; plan replies get the same lock) was run on live on 11 Oct 2026. Every migration so far is live except `003` (the daily Dining email schedule).

## Tests

```sh
# API + privacy rules (94 checks): run while the server is up
~/FoCoSocial-devtools/venv/bin/python backend/local/test_api.py <server log file>

# UI tests: tours of every screen, accessibility audit, large text, dark mode, photo upload, staying signed in offline
~/FoCoSocial-devtools/runtests.sh ~/FoCoSocial /tmp/shots   # uses -useLocalServer, so the live Info.plist keys are ignored
```

The local server has two test-only helpers: `POST /dev/offline?seconds=N` drops every connection for N seconds (like losing signal), and NetIDs starting with `shortlived.` get tokens that need refreshing before every request.

## Going live (Supabase, free tier)

1. Create a project at supabase.com.
2. In the SQL editor, run `backend/schema.sql`, then `backend/storage.sql`. **Never run anything in `backend/local/`** there; those files hold the fake data and test-only shortcuts.
3. Turn on email sign-in with codes: Authentication → Providers → Email. Then edit the Magic Link email template so the email shows `{{ .Token }}` (the 6-digit code) instead of a link.
4. **Set up your own email sender** (Authentication → SMTP, for example Resend). Supabase's built-in sender only allows a few emails per hour, which isn't enough for real users.
5. In `Info.plist`, set `SUPABASE_URL` and `SUPABASE_ANON_KEY` (Project Settings → API). The banner disappears and the Me → About → Server row goes away.

## Before submitting to the App Store

1. **App Review account.** Reviewers can't receive a Dartmouth email, so the NetID in `REVIEW_NETID` (`focoreview`) signs in with a password instead of a code. Create it in Supabase: Authentication → Users → Add user → `focoreview@dartmouth.edu`, a strong password, Auto Confirm User. Give the NetID and password to Apple in App Store Connect → App Review Information. Consider adding it as a friend and posting a plan, so the reviewer sees the social side working.
2. **Privacy policy URL.** Host `docs/privacy.html` (GitHub Pages, Google Sites) and put its address in App Store Connect. The same text is in the app under Me → About → Privacy. In App Privacy, declare: email address, name, user ID, photos, and other user content, all linked to the user, used for app functionality, not tracking (it matches `PrivacyInfo.xcprivacy`).
3. **Contact.** `SUPPORT_EMAIL` in `Info.plist` (now focosocial.app@gmail.com) is the Me → About → Contact us link. Apps with posts must publish a way to reach you.
4. **Permissions from Dartmouth** for the D-Pine logo, the name, and using Dining's menu feed.
5. Export compliance is already answered in the build (`ITSAppUsesNonExemptEncryption = NO`: the app only uses HTTPS).

## What's not built yet

- **Push notifications when the app is closed.** Invites currently notify you when the app refreshes: when you open it, or occasionally in the background via iOS. True push needs the $99/yr Apple Developer account, an APNs key, and a Supabase Edge Function.
- **A moderation dashboard.** Posts auto-hide after 3 reports. Reviewing them happens in the Supabase table editor for now.
- **Real-time updates.** Together refreshes every 30 s while it's open, plus pull to refresh.
- **Before a public launch:** get Dartmouth Dining's OK, both for the name and for using their menu feed (it's Nutrislice's public feed, not an official API). Also write a privacy policy; the App Store requires one for any app with accounts.

## Privacy model (enforced in the database, tested in `test_api.py`)

- Only `@dartmouth.edu` emails can create a profile.
- Check-ins and plans are visible only to friends, or to the people invited or the group. Check-ins expire after at most 3 hours.
- Hosts can only invite friends. Groups can include anyone on the app (teams and clubs aren't all friends); being in a group shows you its plans, never members' check-ins.
- Posts are visible to signed-in Dartmouth students. Photos go in each person's own storage folder, and a post can only use a photo from its author's folder.
- Other people's email addresses can't be read, and people search matches names only.
- Blocking hides posts, plans and check-ins in both directions, and can be undone from Me → About → Blocked people. 3 reports hide a post; reporting hides it for the reporter right away.
- At most 20 posts and 10 food requests a day per person.
- People can delete their account from the app, which removes all their data, photos included.
