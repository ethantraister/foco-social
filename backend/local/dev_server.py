"""Local stand-in for Supabase, so FoCo Social runs and can be tested without an account.

Starts an embedded Postgres + PostgREST and serves the same URL paths the app uses
against real Supabase:  /auth/v1/*  (email codes),  /rest/v1/*  (database),
/storage/v1/*  (photos).  Login codes are printed here; 123456 always works locally.

    ~/FoCoSocial-devtools/venv/bin/python backend/local/dev_server.py [--reset]
"""

import argparse
import base64
import hashlib
import hmac
import json
import os
import re
import secrets
import shutil
import signal
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pgserver

HERE = Path(__file__).resolve().parent
BACKEND = HERE.parent
STATE = Path.home() / "FoCoSocial-devtools" / "state"
POSTGREST = Path.home() / "FoCoSocial-devtools" / "dl" / "postgrest-patched"
JWT_SECRET = "local-dev-only-secret-not-for-production-0123456789"
PORT = 54321
PGRST_PORT = 54330
EMAIL_RE = re.compile(r"^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]+$")
PATH_RE = re.compile(r"^[A-Za-z0-9._/-]+$")


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def make_jwt(claims: dict) -> str:
    header = b64url(json.dumps({"alg": "HS256", "typ": "JWT"}).encode())
    body = b64url(json.dumps(claims).encode())
    sig = hmac.new(JWT_SECRET.encode(), f"{header}.{body}".encode(), hashlib.sha256).digest()
    return f"{header}.{body}.{b64url(sig)}"


def read_jwt(token: str):
    try:
        header, body, sig = token.split(".")
        expected = hmac.new(JWT_SECRET.encode(), f"{header}.{body}".encode(), hashlib.sha256).digest()
        if not hmac.compare_digest(b64url(expected), sig):
            return None
        claims = json.loads(base64.urlsafe_b64decode(body + "=" * (-len(body) % 4)))
        if claims.get("exp", 0) < time.time():
            return None
        return claims
    except Exception:
        return None


DEMO_PHOTO_AUTHORS = {
    "steak": "00000000-0000-4000-a000-000000000006",
    "stirfry": "00000000-0000-4000-a000-000000000001",
    "waffle": "00000000-0000-4000-a000-000000000007",
    "salad": "00000000-0000-4000-a000-000000000005",
}
# Stand-in for the App Review account, which signs in with a password instead of an emailed code.
# On the live project it's a user created in Supabase (Authentication → Users → Add user) with its own password.
REVIEW_EMAIL = "focoreview@dartmouth.edu"
# For tests: POST /dev/offline?seconds=N makes the server drop every connection for N seconds, like losing signal.
OFFLINE_UNTIL = 0.0
REVIEW_PASSWORD = "local-review-password"

ANON_KEY = make_jwt({"role": "anon", "iss": "foco-local", "exp": 4102444800})
# Local-only stand-in for Supabase's service_role key (bypasses row-level security), for testing server jobs.
SERVICE_KEY = make_jwt({"role": "service_role", "iss": "foco-local", "exp": 4102444800})


class Backend:
    def __init__(self, reset: bool):
        if reset and STATE.exists():
            shutil.rmtree(STATE)
        fresh = not (STATE / "pgdata").exists()
        STATE.mkdir(parents=True, exist_ok=True)
        (STATE / "storage").mkdir(exist_ok=True)
        self.pg = pgserver.get_server(str(STATE / "pgdata"), cleanup_mode="stop")
        if fresh:
            for name in ["local/bootstrap.sql", "schema.sql", "local/demo.sql"]:
                try:
                    self.sql((BACKEND / name).read_text())
                except RuntimeError as e:
                    shutil.rmtree(STATE / "pgdata", ignore_errors=True)
                    raise SystemExit(f"{name} failed:\n{e}")
            print("Database created from schema.sql + demo data.")
        self.refresh_demo()
        self.codes: dict[str, str] = {}
        self.refresh_tokens: dict[str, str] = {}
        self.lock = threading.Lock()
        self.start_postgrest()

    def sql(self, query: str) -> str:
        psql = Path(pgserver.__file__).parent / "pginstall" / "bin" / "psql"
        r = subprocess.run([str(psql), "-X", "-q", "-t", "-A", "-v", "ON_ERROR_STOP=1", self.pg.get_uri()],
                           input=query, capture_output=True, text=True)
        if r.returncode != 0:
            raise RuntimeError(r.stderr.strip())
        return r.stdout

    def refresh_demo(self):
        self.sql("select public.dev_refresh_demo();")
        # Each demo post's photo lives in its author's folder, like real uploads.
        demo_photos = BACKEND / "local" / "demo_photos"
        for photo, author in DEMO_PHOTO_AUTHORS.items():
            src = demo_photos / f"{photo}.jpg"
            if src.exists():
                target = STATE / "storage" / "meal-photos" / author
                target.mkdir(parents=True, exist_ok=True)
                shutil.copy(src, target / src.name)

    def start_postgrest(self):
        uri = self.pg.get_uri()
        host = re.search(r"host=([^&]+)", uri).group(1)
        env = dict(os.environ,
                   PGRST_DB_URI=f"postgresql://authenticator:authenticator@/postgres?host={host}",
                   PGRST_DB_SCHEMAS="public",
                   PGRST_DB_ANON_ROLE="anon",
                   PGRST_JWT_SECRET=JWT_SECRET,
                   PGRST_SERVER_PORT=str(PGRST_PORT),
                   PGRST_SERVER_HOST="127.0.0.1",
                   PGRST_LOG_LEVEL="warn")
        self.postgrest = subprocess.Popen([str(POSTGREST)], env=env)
        for _ in range(50):
            try:
                urllib.request.urlopen(f"http://127.0.0.1:{PGRST_PORT}/", timeout=1)
                return
            except urllib.error.HTTPError:
                return
            except Exception:
                time.sleep(0.2)
        raise SystemExit("PostgREST didn't start")

    def user_for(self, email: str) -> str:
        email = email.lower()
        out = self.sql(f"insert into auth.users (id, email) values ('{uuid.uuid4()}', '{email}') "
                       f"on conflict (email) do update set email = excluded.email returning id;")
        return re.search(r"[0-9a-f-]{36}", out).group(0)

    def session(self, user_id: str, email: str) -> dict:
        now = int(time.time())
        # Test accounts named shortlived.* get tokens that are always about to expire, so the app refreshes before every request.
        ttl = 61 if email.startswith("shortlived.") else 3600
        access = make_jwt({"sub": user_id, "email": email, "role": "authenticated",
                           "aud": "authenticated", "iat": now, "exp": now + ttl})
        refresh = secrets.token_urlsafe(24)
        with self.lock:
            self.refresh_tokens[refresh] = f"{user_id}|{email}"
        return {"access_token": access, "token_type": "bearer", "expires_in": ttl,
                "expires_at": now + ttl, "refresh_token": refresh,
                "user": {"id": user_id, "email": email}}

    def stop(self):
        self.postgrest.terminate()
        pg_ctl = Path(pgserver.__file__).parent / "pginstall" / "bin" / "pg_ctl"
        subprocess.run([str(pg_ctl), "-D", str(STATE / "pgdata"), "stop", "-m", "fast"], capture_output=True)


class Handler(BaseHTTPRequestHandler):
    backend: Backend = None
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        if os.environ.get("VERBOSE"):
            super().log_message(fmt, *args)

    def body(self) -> bytes:
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""

    def reply(self, status: int, payload=None, content_type="application/json", extra=None):
        data = payload if isinstance(payload, bytes) else json.dumps(payload if payload is not None else {}).encode()
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def claims(self):
        auth = self.headers.get("Authorization", "")
        return read_jwt(auth[7:]) if auth.lower().startswith("bearer ") else None

    def do_GET(self): self.route("GET")
    def do_POST(self): self.route("POST")
    def do_PATCH(self): self.route("PATCH")
    def do_DELETE(self): self.route("DELETE")
    def do_PUT(self): self.route("PUT")

    def route(self, method: str):
        global OFFLINE_UNTIL
        path = self.path.split("?")[0]
        if path == "/dev/offline":
            seconds = float((re.search(r"seconds=([0-9.]+)", self.path) or [0, "15"])[1])
            OFFLINE_UNTIL = time.time() + seconds
            return self.reply(200, {"offline_for": seconds})
        if time.time() < OFFLINE_UNTIL:
            self.close_connection = True   # no answer at all, like a dead connection
            return
        try:
            if path.startswith("/rest/v1/"):
                return self.proxy(method)
            if path.startswith("/auth/v1/"):
                return self.auth(path[len("/auth/v1/"):])
            if path.startswith("/storage/v1/object/"):
                return self.storage(method, path[len("/storage/v1/object/"):])
            if path == "/health":
                return self.reply(200, {"ok": True})
            self.reply(404, {"message": "not found"})
        except Exception as e:
            self.reply(500, {"message": str(e)})

    def proxy(self, method: str):
        url = f"http://127.0.0.1:{PGRST_PORT}{self.path[len('/rest/v1'):]}"
        req = urllib.request.Request(url, data=self.body() or None, method=method)
        auth = self.headers.get("Authorization") or (f"Bearer {self.headers['apikey']}" if self.headers.get("apikey") else None)
        if auth:
            req.add_header("Authorization", auth)
        for h in ["Content-Type", "Prefer", "Accept", "Range", "Accept-Profile", "Content-Profile"]:
            if self.headers.get(h):
                req.add_header(h, self.headers[h])
        try:
            with urllib.request.urlopen(req, timeout=20) as r:
                status, data, headers = r.status, r.read(), r.headers
        except urllib.error.HTTPError as e:
            status, data, headers = e.code, e.read(), e.headers
        extra = {k: headers[k] for k in ["Content-Range"] if headers.get(k)}
        self.reply(status, data, headers.get("Content-Type", "application/json"), extra)

    def auth(self, action: str):
        be = self.backend
        payload = json.loads(self.body() or b"{}")
        if action == "otp":
            email = str(payload.get("email", "")).strip().lower()
            if not EMAIL_RE.match(email):
                return self.reply(400, {"msg": "Invalid email"})
            code = f"{secrets.randbelow(10**6):06d}"
            with be.lock:
                be.codes[email] = code
            print(f"\n  ✉️  Login code for {email}: {code}   (123456 also works locally)\n", flush=True)
            return self.reply(200, {})
        if action == "verify":
            email = str(payload.get("email", "")).strip().lower()
            token = str(payload.get("token", ""))
            with be.lock:
                ok = EMAIL_RE.match(email) and (token == "123456" or be.codes.get(email) == token)
            if not ok:
                return self.reply(403, {"msg": "Token has expired or is invalid", "error_code": "otp_expired"})
            return self.reply(200, be.session(be.user_for(email), email))
        if action.startswith("token") and "grant_type=password" in self.path:
            email = str(payload.get("email", "")).strip().lower()
            if email != REVIEW_EMAIL or not hmac.compare_digest(str(payload.get("password", "")), REVIEW_PASSWORD):
                return self.reply(400, {"error": "invalid_grant", "error_description": "Invalid login credentials"})
            return self.reply(200, be.session(be.user_for(email), email))
        if action.startswith("token"):
            with be.lock:
                found = be.refresh_tokens.pop(str(payload.get("refresh_token", "")), None)
            if not found:
                return self.reply(400, {"msg": "Invalid Refresh Token"})
            user_id, email = found.split("|")
            return self.reply(200, be.session(user_id, email))
        if action == "logout":
            return self.reply(204, b"")
        self.reply(404, {"msg": "unknown auth action"})

    def storage(self, method: str, rest: str):
        root = STATE / "storage"
        if method == "GET" and rest.startswith("public/"):
            rel = rest[len("public/"):]
            f = root / rel
            if not PATH_RE.match(rel) or ".." in rel or not f.is_file():
                return self.reply(404, {"message": "Object not found"})
            return self.reply(200, f.read_bytes(), "image/jpeg", {"Cache-Control": "max-age=3600"})
        claims = self.claims()
        if not claims or claims.get("role") != "authenticated":
            return self.reply(401, {"message": "Unauthorized"})
        # Like Supabase's "see own" policy: you can list and bulk-delete only inside your own folder.
        if method == "POST" and rest == "list/meal-photos":
            prefix = str(json.loads(self.body() or b"{}").get("prefix", "")).strip("/")
            folder = root / "meal-photos" / prefix
            if prefix != claims["sub"] or not folder.is_dir():
                return self.reply(200, [])
            return self.reply(200, [{"name": f.name, "id": str(uuid.uuid5(uuid.NAMESPACE_URL, str(f))), "metadata": {"size": f.stat().st_size}}
                                    for f in sorted(folder.iterdir()) if f.is_file()])
        if method == "DELETE" and rest == "meal-photos":
            deleted = []
            for name in json.loads(self.body() or b"{}").get("prefixes", []):
                f = root / "meal-photos" / str(name)
                if PATH_RE.match(str(name)) and ".." not in str(name) and str(name).split("/")[0] == claims["sub"] and f.is_file():
                    f.unlink()
                    deleted.append({"name": name, "bucket_id": "meal-photos"})
            return self.reply(200, deleted)
        if not PATH_RE.match(rest) or ".." in rest:
            return self.reply(400, {"message": "Bad path"})
        bucket, _, obj = rest.partition("/")
        if bucket != "meal-photos" or obj.split("/")[0] != claims["sub"]:
            return self.reply(403, {"message": "new row violates row-level security policy"})
        f = root / bucket / obj
        if method in ("POST", "PUT"):
            data = self.body()
            if len(data) > 5 * 1024 * 1024 or not data.startswith(b"\xff\xd8"):
                return self.reply(400, {"message": "Only JPEGs up to 5 MB"})
            f.parent.mkdir(parents=True, exist_ok=True)
            f.write_bytes(data)
            return self.reply(200, {"Key": rest})
        if method == "DELETE":
            f.unlink(missing_ok=True)
            return self.reply(200, {})
        self.reply(405, {"message": "method not allowed"})


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--reset", action="store_true", help="wipe the local database and start over")
    parser.add_argument("--lan", action="store_true",
                        help="also accept connections from other devices on your network (to test on a real iPhone)")
    args = parser.parse_args()

    backend = Backend(args.reset)
    Handler.backend = backend
    server = ThreadingHTTPServer(("0.0.0.0" if args.lan else "127.0.0.1", PORT), Handler)

    def shutdown(*_):
        backend.stop()
        os._exit(0)

    signal.signal(signal.SIGINT, shutdown)
    signal.signal(signal.SIGTERM, shutdown)
    print(f"FoCo Social local server on http://localhost:{PORT}")
    print(f"anon key: {ANON_KEY}")
    print(f"service key (local only): {SERVICE_KEY}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    sys.exit(main())
