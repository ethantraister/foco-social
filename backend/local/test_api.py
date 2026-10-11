"""End-to-end checks of the FoCo Social API and its privacy rules, run against dev_server.py.

    ~/FoCoSocial-devtools/venv/bin/python backend/local/test_api.py
"""

import json
import sys
import urllib.error
import urllib.request
import uuid

BASE = "http://localhost:54321"
ANON = None
failures = 0


def call(method, path, token=None, body=None, headers=None, raw=None):
    data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
    req = urllib.request.Request(BASE + path, data=data, method=method)
    req.add_header("apikey", ANON or "")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Content-Type", "image/jpeg" if raw is not None else "application/json")
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            text = r.read()
            return r.status, (json.loads(text) if text and r.headers.get("Content-Type", "").startswith("application/json") else text)
    except urllib.error.HTTPError as e:
        text = e.read()
        try:
            return e.code, json.loads(text)
        except Exception:
            return e.code, text


def check(name, ok, detail=""):
    global failures
    print(("  ✓ " if ok else "  ✗ ") + name + ("" if ok else f"   → {detail}"))
    if not ok:
        failures += 1


def login(email):
    call("POST", "/auth/v1/otp", body={"email": email})
    status, session = call("POST", "/auth/v1/verify", body={"type": "email", "email": email, "token": "123456"})
    assert status == 200, session
    return session["access_token"], session["user"]["id"]


def rpc(name, token, args=None):
    return call("POST", f"/rest/v1/rpc/{name}", token, args or {})


def main():
    global ANON
    log = open(sys.argv[1]).read() if len(sys.argv) > 1 else ""
    ANON = next((l.split("anon key: ")[1].strip() for l in log.splitlines() if "anon key: " in l), "")
    service = next((l.split("service key (local only): ")[1].strip() for l in log.splitlines() if "service key (local only): " in l), "")
    tag = uuid.uuid4().hex[:6]

    print("Accounts")
    a_tok, a_id = login(f"tester.a.{tag}@dartmouth.edu")
    b_tok, b_id = login(f"tester.b.{tag}@dartmouth.edu")
    x_tok, x_id = login(f"outsider.{tag}@gmail.com")
    s, r = call("POST", "/rest/v1/profiles", a_tok, {"id": a_id, "email": f"tester.a.{tag}@dartmouth.edu", "name": "Tester A", "class_year": 2030, "emoji": "🧪"})
    check("Dartmouth user can create a profile", s == 201, r)
    s, r = call("POST", "/rest/v1/profiles", b_tok, {"id": b_id, "email": f"tester.b.{tag}@dartmouth.edu", "name": "Tester B", "class_year": 2029})
    check("second Dartmouth user can create a profile", s == 201, r)
    s, r = call("POST", "/rest/v1/profiles", x_tok, {"id": x_id, "email": f"outsider.{tag}@gmail.com", "name": "Outsider"})
    check("non-Dartmouth email is rejected", s >= 400, r)
    s, r = call("POST", "/rest/v1/profiles", b_tok, {"id": str(uuid.uuid4()), "email": f"fake.{tag}@dartmouth.edu", "name": "Impersonator"})
    check("can't create a profile for someone else", s >= 400, r)
    s, r = call("GET", "/rest/v1/profiles?select=id", None)
    check("signed-out requests see nothing", s >= 400 or r == [], r)

    print("Friends")
    s, people = rpc("my_people", a_tok)
    rel = {p["name"]: p["relation"] for p in people}
    check("new user gets demo friends + an incoming request", rel.get("Maya R.") == "friend" and rel.get("Leo M.") == "incoming", rel)
    s, found = rpc("search_people", a_tok, {"q": "Tester B"})
    check("search finds people by name", any(p["id"] == b_id for p in found), found)
    s, r = call("POST", "/rest/v1/friendships", a_tok, {"requester": a_id, "addressee": b_id})
    check("send a friend request", s == 201, r)
    s, r = call("POST", "/rest/v1/friendships", b_tok, {"requester": b_id, "addressee": a_id})
    check("can't send a duplicate request back", s >= 400, r)
    s, r = call("PATCH", f"/rest/v1/friendships?requester=eq.{a_id}&addressee=eq.{b_id}", a_tok, {"status": "accepted"})
    s2, rows = call("GET", f"/rest/v1/friendships?requester=eq.{a_id}&addressee=eq.{b_id}", a_tok)
    check("requester can't accept their own request", rows and rows[0]["status"] == "pending", rows)
    s, r = call("PATCH", f"/rest/v1/friendships?requester=eq.{a_id}&addressee=eq.{b_id}", b_tok, {"status": "accepted"}, {"Prefer": "return=representation"})
    check("recipient accepts", s == 200 and r and r[0]["status"] == "accepted", r)

    print("Check-ins")
    s, r = call("POST", "/rest/v1/checkins", a_tok, {"user_id": a_id, "spot": "Back room"}, {"Prefer": "resolution=merge-duplicates"})
    check("check in at FoCo", s in (200, 201), r)
    s, t = rpc("together", b_tok)
    check("a friend sees the check-in", any(c["user"]["id"] == a_id for c in t["checkins"]), t["checkins"])
    c_tok, c_id = login(f"tester.c.{tag}@dartmouth.edu")
    call("POST", "/rest/v1/profiles", c_tok, {"id": c_id, "email": f"tester.c.{tag}@dartmouth.edu", "name": "Tester C"})
    s, t = rpc("together", c_tok)
    check("a non-friend does NOT see the check-in", not any(c["user"]["id"] == a_id for c in t["checkins"]), t["checkins"])
    s, r = call("POST", "/rest/v1/checkins", b_tok, {"user_id": a_id, "spot": "spoof"}, {"Prefer": "resolution=merge-duplicates"})
    check("can't check in as someone else", s >= 400, r)

    print("Plans")
    s, r = call("POST", "/rest/v1/plans", a_tok, {"meal": "lunch", "starts_at": "2099-01-01T17:00:00Z", "note": "test", "audience": "invited"}, {"Prefer": "return=representation"})
    check("create an invite-only plan", s == 201, r)
    far_plan = r[0]["id"]
    s, r = call("POST", "/rest/v1/plans", a_tok, {"meal": "dinner", "starts_at": _soon(), "note": "soon", "audience": "invited"}, {"Prefer": "return=representation"})
    plan = r[0]["id"]
    s, r = call("POST", "/rest/v1/plan_members", a_tok, {"plan_id": plan, "user_id": b_id, "status": "invited"})
    check("host invites a friend", s == 201, r)
    s, r = call("POST", "/rest/v1/plan_members", a_tok, {"plan_id": plan, "user_id": c_id, "status": "invited"})
    check("host can't invite a non-friend", s >= 400, r)
    s, t = rpc("together", b_tok)
    mine = [p for p in t["plans"] if p["id"] == plan]
    check("invitee sees the plan with their invite", mine and any(m["user"]["id"] == b_id and m["status"] == "invited" for m in mine[0]["members"]), t["plans"])
    s, t = rpc("together", c_tok)
    check("outsider doesn't see an invite-only plan", not any(p["id"] == plan for p in t["plans"]), t["plans"])
    s, r = call("PATCH", f"/rest/v1/plan_members?plan_id=eq.{plan}&user_id=eq.{b_id}", b_tok, {"status": "going"}, {"Prefer": "return=representation"})
    check("invitee says going", s == 200 and r and r[0]["status"] == "going", r)
    s, r = call("POST", "/rest/v1/plan_members", c_tok, {"plan_id": plan, "user_id": c_id, "status": "going"})
    check("outsider can't join an invite-only plan", s >= 400, r)
    demo_maya = "00000000-0000-4000-a000-000000000001"
    s, r = call("POST", "/rest/v1/plan_members", a_tok, {"plan_id": plan, "user_id": demo_maya, "status": "invited"})
    s, t = rpc("together", a_tok)
    p = next(p for p in t["plans"] if p["id"] == plan)
    check("demo friend auto-accepts an invite", any(m["user"]["id"] == demo_maya and m["status"] == "going" for m in p["members"]), p["members"])
    s, r = call("PATCH", f"/rest/v1/plans?id=eq.{plan}", b_tok, {"note": "hijacked"}, {"Prefer": "return=representation"})
    check("a guest can't edit the host's plan", r == [] or s >= 400, r)
    call("DELETE", f"/rest/v1/plans?id=eq.{far_plan}", a_tok)

    print("Groups")
    s, r = call("POST", "/rest/v1/groups", a_tok, {"name": "Test Team", "emoji": "🧪", "created_by": a_id}, {"Prefer": "return=representation"})
    check("create a group", s == 201, r)
    g = r[0]["id"]
    s, r = call("POST", "/rest/v1/group_members", a_tok, {"group_id": g, "user_id": b_id})
    check("add a friend to the group", s == 201, r)
    s, r = call("POST", "/rest/v1/group_members", a_tok, {"group_id": g, "user_id": c_id})
    check("add a non-friend (club teammate) to the group", s == 201, r)
    e_tok, e_id = login(f"tester.e.{tag}@dartmouth.edu")
    call("POST", "/rest/v1/profiles", e_tok, {"id": e_id, "email": f"tester.e.{tag}@dartmouth.edu", "name": "Tester E"})
    s, r = call("POST", "/rest/v1/group_members", e_tok, {"group_id": g, "user_id": e_id})
    check("can't add yourself to a group you're not in", s >= 400, r)
    s, r = call("POST", "/rest/v1/plans", b_tok, {"meal": "dinner", "starts_at": _soon(), "audience": "group", "group_id": g}, {"Prefer": "return=representation"})
    check("a member posts a team dinner", s == 201, r)
    s, r = call("PATCH", f"/rest/v1/groups?id=eq.{g}", a_tok, {"photo_path": f"{a_id}/group-test.jpg"}, {"Prefer": "return=representation"})
    check("the owner sets a group photo from their own folder", s == 200 and r and r[0]["photo_path"] == f"{a_id}/group-test.jpg", r)
    s, r = call("PATCH", f"/rest/v1/groups?id=eq.{g}", a_tok, {"photo_path": f"{b_id}/avatar-x.jpg"}, {"Prefer": "return=representation"})
    check("a group photo can't point into someone else's folder", s >= 400, r)
    s, r = call("PATCH", f"/rest/v1/groups?id=eq.{g}", b_tok, {"photo_path": f"{b_id}/group-b.jpg"}, {"Prefer": "return=representation"})
    check("a regular member can't change the group photo", s >= 400 or r == [], r)
    s, t = rpc("together", a_tok)
    check("other members see the team dinner", any(p.get("group") and p["group"]["id"] == g for p in t["plans"]), "")
    check("the team dinner carries the group photo",
          any(p.get("group") and p["group"]["id"] == g and p["group"].get("photo_path") == f"{a_id}/group-test.jpg" for p in t["plans"]), "")
    s, t = rpc("together", c_tok)
    check("non-friend teammate sees it too", any(p.get("group") and p["group"]["id"] == g for p in t["plans"]), "")
    s, t = rpc("together", e_tok)
    check("non-members don't", not any(p.get("group") and p["group"]["id"] == g for p in t["plans"]), "")
    call("POST", "/rest/v1/checkins", a_tok, {"user_id": a_id, "spot": "Dark side"}, {"Prefer": "resolution=merge-duplicates"})
    s, t = rpc("together", c_tok)
    check("a non-friend teammate can't see your check-in", not any(ci["user"]["id"] == a_id for ci in t["checkins"]), t["checkins"])

    print("Group owner")
    ret = {"Prefer": "return=representation"}
    def members(group):
        s, rows = call("GET", f"/rest/v1/group_members?group_id=eq.{group}&select=user_id,role", a_tok)
        return {r["user_id"]: r["role"] for r in rows} if s == 200 else {}
    s, r = call("DELETE", f"/rest/v1/group_members?group_id=eq.{g}&user_id=eq.{c_id}", b_tok, headers=ret)
    check("a regular member can't remove someone", s >= 400 or r == [], r)
    s, r = call("DELETE", f"/rest/v1/group_members?group_id=eq.{g}&user_id=eq.{a_id}", a_tok, headers=ret)
    check("the owner can't leave without handing it off", (s >= 400 or r == []) and a_id in members(g), r)
    s, r = call("PATCH", f"/rest/v1/groups?id=eq.{g}", a_tok, {"created_by": b_id}, ret)
    check("ownership can't change with a plain update", s >= 400 or r == [], r)
    s, r = rpc("transfer_group", b_tok, {"g": g, "new_owner": b_id})
    check("a regular member can't take ownership", s >= 400, r)
    s, r = rpc("transfer_group", a_tok, {"g": g, "new_owner": e_id})
    check("can't hand the group to a non-member", s >= 400, r)
    s, r = rpc("transfer_group", a_tok, {"g": g, "new_owner": b_id})
    m = members(g)
    check("the owner can hand the group to a member", s in (200, 204) and m.get(b_id) == "owner" and m.get(a_id) == "member", (s, r, m))
    s, r = call("DELETE", f"/rest/v1/groups?id=eq.{g}", a_tok, headers=ret)
    check("the old owner can no longer delete the group", s >= 400 or r == [], r)
    s, r = call("PATCH", f"/rest/v1/groups?id=eq.{g}", b_tok, {"name": "Test Team B"}, ret)
    check("the new owner can rename it, though the old owner set the photo", s == 200 and len(r) == 1, r)
    s, r = call("DELETE", f"/rest/v1/group_members?group_id=eq.{g}&user_id=eq.{c_id}", b_tok, headers=ret)
    check("the new owner can remove someone", s == 200 and len(r) == 1 and c_id not in members(g), r)
    s, r = call("POST", "/rest/v1/group_members", a_tok, {"group_id": g, "user_id": c_id})
    check("any member can add people back", s == 201, r)
    f_tok, f_id = login(f"tester.f.{tag}@dartmouth.edu")
    call("POST", "/rest/v1/profiles", f_tok, {"id": f_id, "email": f"tester.f.{tag}@dartmouth.edu", "name": "Tester F"})
    s, r = call("POST", "/rest/v1/groups", f_tok, {"name": "Heir Test", "emoji": "👑", "created_by": f_id}, ret)
    g2 = r[0]["id"]
    call("POST", "/rest/v1/group_members", f_tok, {"group_id": g2, "user_id": e_id})
    call("PATCH", f"/rest/v1/groups?id=eq.{g2}", f_tok, {"photo_path": f"{f_id}/group-heir.jpg"})
    rpc("delete_my_account", f_tok)
    s, rows = call("GET", f"/rest/v1/groups?id=eq.{g2}&select=created_by,photo_path", e_tok)
    check("if the owner deletes their account, a member takes over", s == 200 and rows and rows[0]["created_by"] == e_id, rows)
    check("and the group goes back to initials (its photo was in the deleted account's folder)", s == 200 and rows and rows[0]["photo_path"] is None, rows)
    s, r = call("DELETE", f"/rest/v1/groups?id=eq.{g2}", e_tok, headers=ret)
    check("the owner can delete the group", s == 200 and len(r) == 1, r)

    print("Profile photos")
    s, r = call("PATCH", f"/rest/v1/profiles?id=eq.{a_id}&select=photo_path", a_tok, {"photo_path": f"{a_id}/avatar-test.jpg"}, {"Prefer": "return=representation"})
    check("set your own profile photo", s == 200 and r and r[0]["photo_path"] == f"{a_id}/avatar-test.jpg", r)
    s, r = call("PATCH", f"/rest/v1/profiles?id=eq.{a_id}", a_tok, {"photo_path": f"{b_id}/avatar-test.jpg"})
    check("a profile photo must be in your own folder", s >= 400, r)
    s, people = rpc("my_people", b_tok)
    check("friends see your photo", any(p["id"] == a_id and p.get("photo_path") == f"{a_id}/avatar-test.jpg" for p in people), people)
    s, t = rpc("together", b_tok)
    check("plans and check-ins carry the photo", any(ci["user"]["id"] == a_id and ci["user"].get("photo_path") for ci in t["checkins"]), t["checkins"])
    s, found = rpc("search_people", c_tok, {"q": "Tester A"})
    check("search shows the photo", s == 200 and any(p.get("photo_path") for p in found), found)
    s, r = call("PATCH", f"/rest/v1/profiles?id=eq.{a_id}&select=photo_path", a_tok, {"photo_path": None}, {"Prefer": "return=representation"})
    check("go back to the emoji", s == 200 and r[0]["photo_path"] is None, r)

    print("Food requests")
    s, r = call("POST", "/rest/v1/food_requests", a_tok, {"food": f"Sushi {tag}", "meal": "dinner"})
    check("request a food", s == 201, r)
    s, r = call("POST", "/rest/v1/food_requests", a_tok, {"food": f" sushi {tag} "})
    check("same food twice in a day is rejected", s >= 400, r)
    s, r = call("POST", "/rest/v1/food_requests", b_tok, {"food": f"sushi {tag}"})
    check("a second student asks for it too", s == 201, r)
    s, r = call("POST", "/rest/v1/food_requests", b_tok, {"food": "Poke", "user_id": a_id})
    check("can't request as someone else", s >= 400, r)
    s, mine = call("GET", "/rest/v1/food_requests?select=food,user_id", b_tok)
    check("you only see your own requests", s == 200 and all(x["user_id"] == b_id for x in mine), mine)
    s, pop = rpc("popular_requests", a_tok)
    row = next((x for x in pop if x["food"].lower() == f"sushi {tag}"), None)
    check("popular requests count students, not names", row and row["students"] == 2 and row["mine"] and "user_id" not in row, pop)
    for i in range(9):
        call("POST", "/rest/v1/food_requests", a_tok, {"food": f"Dish {i} {tag}"})
    s, r = call("POST", "/rest/v1/food_requests", a_tok, {"food": "One too many"})
    check("10 requests a day max", s >= 400, r)
    s, r = rpc("popular_requests", None)
    check("signed-out callers can't see requests", s >= 400, r)
    s, r = rpc("request_digest", a_tok)
    check("students can't read the Dining digest", s >= 400, r)
    s, digest = rpc("request_digest", service)
    row = next((x for x in digest if x["food"].lower() == f"sushi {tag}"), {}) if s == 200 else {}
    check("server digest groups requests by food", row.get("students") == 2 and row.get("meals", {}).get("dinner") == 1 and len(row.get("ids", [])) == 2, digest if s != 200 else row)
    check("digest has no names or user ids", s == 200 and all(set(x) == {"food", "students", "meals", "notes", "ids"} for x in digest), digest[:1] if s == 200 else digest)

    print("Posts, photos, votes")
    jpeg = b"\xff\xd8\xff\xe0" + b"0" * 2000
    s, r = call("POST", f"/storage/v1/object/meal-photos/{a_id}/{uuid.uuid4()}.jpg", a_tok, raw=jpeg)
    check("upload a photo to your own folder", s == 200, r)
    path = r.get("Key", "").split("/", 1)[1] if isinstance(r, dict) else ""
    s, r = call("POST", f"/storage/v1/object/meal-photos/{b_id}/x.jpg", a_tok, raw=jpeg)
    check("can't upload into someone else's folder", s == 403, r)
    s, img = call("GET", f"/storage/v1/object/public/meal-photos/{path}")
    check("uploaded photo is publicly readable", s == 200 and img[:2] == b"\xff\xd8", s)
    s, r = call("POST", "/rest/v1/posts", a_tok, {"kind": "photo", "body": "test plate", "photo_path": path, "meal": "lunch", "dish": "Test"}, {"Prefer": "return=representation"})
    check("post a meal photo", s == 201, r)
    post = r[0]["id"]
    s, r = call("POST", "/rest/v1/posts", a_tok, {"kind": "idea", "body": "  "})
    check("empty ideas are rejected", s >= 400, r)
    s, r = call("POST", "/rest/v1/post_votes", b_tok, {"post_id": post, "user_id": b_id})
    check("vote for a post", s == 201, r)
    s, r = call("POST", "/rest/v1/post_votes", b_tok, {"post_id": post, "user_id": b_id})
    check("can't vote twice", s >= 400, r)
    s, feed = rpc("feed", b_tok, {"kind_filter": "photo", "sort": "top"})
    row = next((f for f in feed if f["id"] == post), None)
    check("feed shows vote count and my vote", row and row["votes"] == 1 and row["voted"], row)
    s, r = call("POST", "/rest/v1/posts", b_tok, {"author": a_id, "kind": "idea", "body": "spoofed"})
    check("can't post as someone else", s >= 400, r)

    print("Moderation")
    call("POST", "/rest/v1/blocks", c_tok, {"blocker": c_id, "blocked": a_id})
    s, feed = rpc("feed", c_tok, {})
    check("blocking hides that person's posts", not any(f["author_id"] == a_id for f in feed), "")
    for tok, uid in [(b_tok, b_id), (c_tok, c_id)]:
        call("POST", "/rest/v1/post_reports", tok, {"post_id": post, "reporter": uid, "reason": "test"})
    d_tok, d_id = login(f"tester.d.{tag}@dartmouth.edu")
    call("POST", "/rest/v1/profiles", d_tok, {"id": d_id, "email": f"tester.d.{tag}@dartmouth.edu", "name": "Tester D"})
    s, feed = rpc("feed", d_tok, {})
    check("post still visible after 2 reports", any(f["id"] == post for f in feed), "")
    call("POST", "/rest/v1/post_reports", d_tok, {"post_id": post, "reporter": d_id, "reason": "test"})
    s, feed = rpc("feed", d_tok, {})
    check("3 reports hide the post", not any(f["id"] == post for f in feed), "")
    s, feed = rpc("feed", a_tok, {})
    check("author still sees their hidden post", any(f["id"] == post for f in feed), "")

    print("Privacy and limits")
    s, r = call("GET", "/rest/v1/profiles?select=email&limit=5", a_tok)
    check("other people's email addresses aren't readable", s >= 400, r)
    s, r = call("GET", f"/rest/v1/profiles?id=eq.{b_id}&select=id,name,emoji,photo_path,class_year", a_tok)
    check("names and photos still are", s == 200 and r and r[0]["name"] == "Tester B", r)
    s, found = rpc("search_people", a_tok, {"q": f"tester.b.{tag}"})
    check("search doesn't match NetIDs (names only)", s == 200 and not any(x["id"] == b_id for x in found), found)
    s, r = call("PATCH", f"/rest/v1/profiles?id=eq.{a_id}", a_tok, {"name": "Tester A", "emoji": "🧪", "class_year": 2030})
    check("you can still edit your profile", s in (200, 204), r)
    s, r = call("POST", "/rest/v1/profiles", a_tok, {"id": a_id, "email": f"tester.a.{tag}@dartmouth.edu", "name": "Again"})
    check("a second profile insert is a conflict (the app updates instead)", s == 409, r)
    s, r = call("POST", "/rest/v1/posts", a_tok, {"kind": "photo", "body": "not mine", "photo_path": f"{b_id}/x.jpg"})
    check("a post's photo has to be in your own folder", s >= 400, r)
    made = []
    for i in range(22):
        s, r = call("POST", "/rest/v1/posts", d_tok, {"kind": "idea", "body": f"limit test {i}"}, ret)
        if s != 201:
            break
        made.append(r[0]["id"])
    check("at most 20 posts a day", len(made) == 20, len(made))
    for pid in made:
        call("DELETE", f"/rest/v1/posts?id=eq.{pid}", d_tok)
    s, r = call("POST", "/rest/v1/plans", e_tok, {"meal": "lunch", "starts_at": _soon(), "audience": "friends"}, ret)
    e_plan = r[0]["id"]
    s, r = call("PATCH", f"/rest/v1/plans?id=eq.{e_plan}", e_tok, {"audience": "group", "group_id": g}, ret)
    check("a host can't move a plan into a group they aren't in", s >= 400 or r == [], r)
    s, r = call("POST", "/rest/v1/plans", a_tok, {"meal": "lunch", "starts_at": _soon(), "audience": "friends"}, ret)
    a_plan = r[0]["id"]
    s, r = call("PATCH", f"/rest/v1/plans?id=eq.{a_plan}", a_tok, {"audience": "group", "group_id": g}, ret)
    check("but can move it into their own group", s == 200 and len(r) == 1, r)
    for tok, pid in [(e_tok, e_plan), (a_tok, a_plan)]:
        call("DELETE", f"/rest/v1/plans?id=eq.{pid}", tok)
    s, rows = call("GET", "/rest/v1/blocks?select=blocked,profiles!blocks_blocked_fkey(id,name,emoji,photo_path,class_year)", c_tok)
    check("you can see who you blocked", s == 200 and any(x["profiles"]["id"] == a_id for x in rows), rows)
    s, r = call("DELETE", f"/rest/v1/blocks?blocker=eq.{c_id}&blocked=eq.{a_id}", c_tok, headers=ret)
    s2, rows = call("GET", "/rest/v1/blocks?select=blocked", c_tok)
    check("and unblock them", s == 200 and len(r) == 1 and rows == [], (r, rows))

    print("Rows can't change hands")
    x_tok, x_id = login(f"tester.x.{tag}@dartmouth.edu")
    call("POST", "/rest/v1/profiles", x_tok, {"id": x_id, "email": f"tester.x.{tag}@dartmouth.edu", "name": "Tester X"})
    y_tok, y_id = login(f"tester.y.{tag}@dartmouth.edu")
    call("POST", "/rest/v1/profiles", y_tok, {"id": y_id, "email": f"tester.y.{tag}@dartmouth.edu", "name": "Tester Y"})
    call("POST", "/rest/v1/checkins", a_tok, {"user_id": a_id, "spot": "Dark side"}, {"Prefer": "resolution=merge-duplicates"})
    call("POST", "/rest/v1/friendships", y_tok, {"requester": y_id, "addressee": x_id})
    s, r = call("PATCH", f"/rest/v1/friendships?requester=eq.{y_id}&addressee=eq.{x_id}", x_tok, {"requester": a_id, "status": "accepted"}, {"Prefer": "return=minimal"})
    s2, rows = call("GET", f"/rest/v1/friendships?requester=eq.{a_id}&addressee=eq.{x_id}&select=status", a_tok)
    check("a friend request can't be rewritten to come from someone else (a fake friendship)", s >= 400 and rows == [], (s, r, rows))
    s, t = rpc("together", x_tok)
    check("so their check-ins stay hidden", not any(ci["user"]["id"] == a_id for ci in t["checkins"]), t["checkins"])
    s, r = call("PATCH", f"/rest/v1/friendships?requester=eq.{y_id}&addressee=eq.{x_id}", x_tok, {"status": "accepted"}, ret)
    check("accepting a real request still works", s == 200 and len(r) == 1 and r[0]["status"] == "accepted", r)
    s, r = call("POST", "/rest/v1/plans", a_tok, {"meal": "dinner", "starts_at": _soon(), "audience": "invited", "note": "private"}, ret)
    secret = r[0]["id"]
    s, r = call("POST", "/rest/v1/plans", x_tok, {"meal": "lunch", "starts_at": _soon(), "audience": "friends"}, ret)
    x_plan = r[0]["id"]
    s, rows = call("GET", f"/rest/v1/plan_members?plan_id=eq.{x_plan}&user_id=eq.{x_id}&select=status", x_tok)
    check("(setup) a host has a reply on their own plan", s == 200 and len(rows) == 1, rows)
    # Without asking for the row back, which would trip the read rule and hide the hole.
    s, r = call("PATCH", f"/rest/v1/plan_members?plan_id=eq.{x_plan}&user_id=eq.{x_id}", x_tok, {"plan_id": secret}, {"Prefer": "return=minimal"})
    s2, rows = call("GET", f"/rest/v1/plans?id=eq.{secret}&select=note", x_tok)
    check("a plan reply can't be moved onto someone else's plan", s >= 400 and rows == [], (s, r, s2, rows))
    s, r = call("PATCH", f"/rest/v1/plan_members?plan_id=eq.{x_plan}&user_id=eq.{x_id}", x_tok, {"status": "maybe"}, ret)
    check("changing your reply still works", s == 200 and len(r) == 1 and r[0]["status"] == "maybe", r)
    call("DELETE", f"/rest/v1/plans?id=eq.{secret}", a_tok)
    call("DELETE", f"/rest/v1/plans?id=eq.{x_plan}", x_tok)
    rpc("delete_my_account", x_tok)
    rpc("delete_my_account", y_tok)

    print("Photo cleanup")
    name = path.split("/", 1)[1] if "/" in path else ""
    s, files = call("POST", "/storage/v1/object/list/meal-photos", a_tok, {"prefix": a_id})
    check("list your own photos", s == 200 and any(f["name"] == name for f in files), files)
    s, files = call("POST", "/storage/v1/object/list/meal-photos", b_tok, {"prefix": a_id})
    check("can't list someone else's", s >= 400 or files == [], files)
    call("DELETE", "/storage/v1/object/meal-photos", b_tok, {"prefixes": [path]})
    s, img = call("GET", f"/storage/v1/object/public/meal-photos/{path}")
    check("can't delete someone else's photo", s == 200, s)
    s, r = call("DELETE", "/storage/v1/object/meal-photos", a_tok, {"prefixes": [path]})
    s2, img = call("GET", f"/storage/v1/object/public/meal-photos/{path}")
    check("delete your own photo", s == 200 and s2 == 404, (s, r, s2))

    print("App Review account")
    s, r = call("POST", "/auth/v1/token?grant_type=password", None, {"email": "focoreview@dartmouth.edu", "password": "wrong"})
    check("wrong password is rejected", s == 400, r)
    s, r = call("POST", "/auth/v1/token?grant_type=password", None, {"email": "focoreview@dartmouth.edu", "password": "local-review-password"})
    check("review account signs in with its password", s == 200 and r.get("access_token"), r)

    print("Account deletion")
    s, r = rpc("delete_my_account", c_tok)
    check("delete account", s in (200, 204), r)
    s, found = rpc("search_people", a_tok, {"q": "Tester C"})
    check("deleted user is gone", not any(p["id"] == c_id for p in found), found)
    s, r = rpc("delete_my_account", None)
    check("signed-out caller can't call delete", s >= 400, r)

    print(f"\n{'ALL PASSED' if failures == 0 else f'{failures} FAILED'}")
    return 1 if failures else 0


def _soon():
    from datetime import datetime, timedelta, timezone
    return (datetime.now(timezone.utc) + timedelta(hours=2)).isoformat()


if __name__ == "__main__":
    sys.exit(main())
