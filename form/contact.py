#!/usr/bin/env python3
"""Contact form and private inbox for orangiraffe.com.

Python standard library only. No email service is involved:

  POST /api/contact   plain HTML form (no JavaScript). Saves the message to
                      SQLite, then redirects to /thanks or /contact-error.
  GET  /inbox         password-protected list of messages (HTTP Basic auth).
  POST /inbox         delete selected messages, or all of them.

Logs never contain what people send, and IP addresses are never stored: they
are only counted in memory, for rate limiting.

Environment (from /opt/orangiraffe/.env, written by deploy/set-inbox-password.sh):
  INBOX_USER            inbox username
  INBOX_PASSWORD_HASH   pbkdf2_sha256:<iterations>:<salt hex>:<hash hex>
  DB_PATH               default /data/messages.db

  python3 contact.py --hash-password   reads a password on stdin, prints its hash

Code changes take effect on deploy: deploy/pull-deploy.sh restarts this
service whenever form/ changes.
"""
import base64
import hashlib
import hmac
import html
import os
import re
import sqlite3
import sys
import threading
import time
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, quote, urlparse

DB_PATH = os.environ.get("DB_PATH") or "/data/messages.db"
INBOX_USER = os.environ.get("INBOX_USER") or ""
INBOX_HASH = os.environ.get("INBOX_PASSWORD_HASH") or ""

MAX_BODY = 16 * 1024
MAX_INBOX_BODY = 256 * 1024
PER_IP_PER_HOUR = 5
PER_DAY = 100
MAX_STORED = 5000
LOGIN_FAILS = 10          # per IP ...
LOGIN_WINDOW = 15 * 60    # ... per 15 minutes
PBKDF2_ITERATIONS = 300_000

EMAIL_RE = re.compile(r"^[^@\s<>,;:\"]+@[^@\s<>,;:\"]+\.[^@\s<>,;:\"]+$")
CONTROL_RE = re.compile(r"[\x00-\x08\x0b-\x1f\x7f]")

_lock = threading.Lock()
_by_ip = {}
_today = []
_fails = {}
_verified = set()  # sha256 of Authorization headers that already passed


# --- storage -----------------------------------------------------------------

def db():
    con = sqlite3.connect(DB_PATH, timeout=10)
    con.execute(
        "CREATE TABLE IF NOT EXISTS messages ("
        " id INTEGER PRIMARY KEY AUTOINCREMENT,"
        " received_at TEXT NOT NULL,"
        " name TEXT NOT NULL,"
        " email TEXT NOT NULL,"
        " message TEXT NOT NULL)"
    )
    return con


@contextmanager
def dbtx():
    """One connection per request: commits on success, always closes."""
    con = db()
    try:
        with con:
            yield con
    finally:
        con.close()


# --- passwords ---------------------------------------------------------------

def hash_password(password):
    salt = os.urandom(16)
    dk = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, PBKDF2_ITERATIONS)
    return f"pbkdf2_sha256:{PBKDF2_ITERATIONS}:{salt.hex()}:{dk.hex()}"


def check_password(password, stored):
    try:
        algo, iterations, salt, expected = stored.split(":")
        if algo != "pbkdf2_sha256":
            return False
        dk = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), bytes.fromhex(salt), int(iterations))
        return hmac.compare_digest(dk.hex(), expected)
    except (ValueError, TypeError):
        return False


# --- rate limits -------------------------------------------------------------

def allowed(ip):
    """Counts every form submission, valid or not, so a flood cannot probe for free."""
    now = time.time()
    with _lock:
        global _today
        _today = [t for t in _today if now - t < 86400]
        recent = [t for t in _by_ip.get(ip, []) if now - t < 3600]
        if len(recent) >= PER_IP_PER_HOUR or len(_today) >= PER_DAY:
            _by_ip[ip] = recent
            return False
        recent.append(now)
        _by_ip[ip] = recent
        _today.append(now)
        if len(_by_ip) > 5000:
            for k in [k for k, v in _by_ip.items() if not v or now - v[-1] > 3600]:
                del _by_ip[k]
        return True


def login_blocked(ip):
    now = time.time()
    with _lock:
        fails = [t for t in _fails.get(ip, []) if now - t < LOGIN_WINDOW]
        _fails[ip] = fails
        return len(fails) >= LOGIN_FAILS


def login_failed(ip):
    with _lock:
        _fails.setdefault(ip, []).append(time.time())
        if len(_fails) > 5000:
            _fails.clear()


def log(line):
    print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), line, flush=True)


# --- inbox page --------------------------------------------------------------

def inbox_page(rows, total):
    e = html.escape
    items = []
    for mid, received_at, name, email, message in rows:
        reply = "mailto:" + quote(email, safe="@") + "?subject=" + quote("Re: your message to Orangiraffe")
        items.append(
            f'<article class="msg">'
            f'<label class="msg-check"><input type="checkbox" name="id" value="{mid}">'
            f'<span class="visually-hidden">Select message from {e(name)}</span></label>'
            f'<div class="msg-body">'
            f'<p class="msg-meta"><strong>{e(name)}</strong> &middot; '
            f'<a href="{e(reply)}">{e(email)}</a> &middot; '
            f'<time datetime="{e(received_at)}">{e(received_at.replace("T", " ").replace("Z", " UTC"))}</time></p>'
            f'<p class="msg-text">{e(message)}</p>'
            f"</div></article>"
        )
    if items:
        body = (
            f'<form id="inbox-form" method="post" action="/inbox" data-count="{total}">'
            '<div class="inbox-bar">'
            '<label class="select-all" hidden><input type="checkbox" id="select-all"> Select all</label>'
            '<button class="button" type="submit" name="action" value="delete">Delete selected</button>'
            '<button class="button button-quiet" type="submit" name="action" value="delete_all">Delete all</button>'
            "</div>"
            + "".join(items)
            + "</form>"
        )
        if total > len(rows):
            body += f'<p class="form-note">Showing the newest {len(rows)} of {total}.</p>'
    else:
        body = '<p class="inbox-empty">No messages.</p>'
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>Inbox | Orangiraffe LLC</title>
<link rel="icon" href="/favicon.png" type="image/png">
<link rel="stylesheet" href="/assets/site.css">
<script src="/assets/inbox.js" defer></script>
</head>
<body>
<header class="site-header">
  <div class="wrap">
    <a class="brand" href="/">
      <img src="/assets/logo.png" alt="Orangiraffe" width="219" height="44">
    </a>
  </div>
</header>
<div class="strip" aria-hidden="true"></div>
<main id="main">
  <div class="wrap">
    <h1 class="inbox-title">Inbox <span class="inbox-count">{total}</span></h1>
    {body}
  </div>
</main>
</body>
</html>
"""


def simple_page(title, text):
    return (
        '<!doctype html><html lang="en"><head><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width, initial-scale=1">'
        f'<meta name="robots" content="noindex"><title>{html.escape(title)}</title>'
        '<link rel="stylesheet" href="/assets/site.css"></head><body><main><div class="wrap doc">'
        f"<h1>{html.escape(title)}</h1><p>{html.escape(text)}</p></div></main></body></html>"
    )


# --- HTTP --------------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    server_version = "contact"
    sys_version = ""

    def log_message(self, *args):
        pass  # no access log: the privacy policy promises none

    def client_ip(self):
        return (self.headers.get("X-Real-IP") or self.client_address[0]).split(",")[0].strip()

    def send_html(self, code, page, extra=None):
        data = page.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Robots-Tag", "noindex, nofollow")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def redirect(self, where):
        self.send_response(303)
        self.send_header("Location", where)
        self.send_header("Content-Length", "0")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()

    def read_form(self, limit):
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            return None
        if length < 0 or length > limit:
            return None
        raw = self.rfile.read(length).decode("utf-8", "replace")
        return parse_qs(raw, keep_blank_values=True, max_num_fields=MAX_STORED + 10)

    # Inbox access: HTTP Basic auth against a PBKDF2 hash, with a lockout.
    def inbox_guard(self):
        if not (INBOX_USER and INBOX_HASH):
            self.send_html(503, simple_page("Inbox not set up", "Set a password with deploy/set-inbox-password.sh on the server."))
            return False
        ip = self.client_ip()
        if login_blocked(ip):
            self.send_html(429, simple_page("Too many attempts", "Try again in 15 minutes."))
            return False
        header = self.headers.get("Authorization", "")
        key = hashlib.sha256(header.encode("utf-8", "replace")).hexdigest()
        if header and key in _verified:
            return True
        ok = False
        if header.startswith("Basic "):
            try:
                user, _, password = base64.b64decode(header[6:], validate=True).decode("utf-8").partition(":")
                ok = hmac.compare_digest(user.encode(), INBOX_USER.encode()) and check_password(password, INBOX_HASH)
            except (ValueError, UnicodeDecodeError):
                ok = False
        if ok:
            with _lock:
                if len(_verified) > 100:
                    _verified.clear()
                _verified.add(key)
            return True
        if header:
            login_failed(ip)
            log("inbox: failed sign-in")
        self.send_html(401, simple_page("Sign in required", "This page is private."),
                       {"WWW-Authenticate": 'Basic realm="Orangiraffe inbox", charset="UTF-8"'})
        return False

    def same_origin(self):
        """Blocks cross-site form posts: browsers attach Basic credentials to them."""
        host = (self.headers.get("Host") or "").split(":")[0].lower()
        source = self.headers.get("Origin") or self.headers.get("Referer") or ""
        return bool(host) and (urlparse(source).hostname or "").lower() == host

    def do_GET(self):
        if self.path == "/healthz":
            self.send_html(200, "ok\n")
            return
        if self.path.split("?")[0] == "/inbox":
            if not self.inbox_guard():
                return
            with dbtx() as con:
                total = con.execute("SELECT COUNT(*) FROM messages").fetchone()[0]
                rows = con.execute(
                    "SELECT id, received_at, name, email, message FROM messages ORDER BY id DESC LIMIT 500"
                ).fetchall()
            self.send_html(200, inbox_page(rows, total))
            return
        self.send_error(404)

    def do_POST(self):
        path = self.path.split("?")[0]
        if path == "/api/contact":
            self.contact()
        elif path == "/inbox":
            self.inbox_post()
        else:
            self.send_error(404)

    def contact(self):
        fields = self.read_form(MAX_BODY)
        if fields is None:
            self.send_error(413)
            return

        def get(key, limit):
            return (fields.get(key) or [""])[0].strip()[:limit]

        if not allowed(self.client_ip()):
            log("rejected: rate limit")
            self.redirect("/contact-error")
            return
        # Honeypot: a field people never see. Bots fill it; pretend it worked.
        if get("website", 200):
            log("dropped: honeypot")
            self.redirect("/thanks")
            return
        name = CONTROL_RE.sub(" ", get("name", 100)).strip()
        email = CONTROL_RE.sub("", get("email", 254))
        message = CONTROL_RE.sub("", get("message", 5000).replace("\r\n", "\n"))
        if not name or not EMAIL_RE.match(email) or len(message) < 2:
            log("rejected: invalid fields")
            self.redirect("/contact-error")
            return
        try:
            with dbtx() as con:
                if con.execute("SELECT COUNT(*) FROM messages").fetchone()[0] >= MAX_STORED:
                    log("rejected: inbox full")
                    self.redirect("/contact-error")
                    return
                con.execute(
                    "INSERT INTO messages (received_at, name, email, message) VALUES (?, ?, ?, ?)",
                    (time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), name, email, message),
                )
        except sqlite3.Error as e:
            log(f"failed: {type(e).__name__}")
            self.redirect("/contact-error")
            return
        log("saved")
        self.redirect("/thanks")

    def inbox_post(self):
        if not self.inbox_guard():
            return
        if not self.same_origin():
            self.send_html(403, simple_page("Not allowed", "Cross-site request refused."))
            return
        fields = self.read_form(MAX_INBOX_BODY)
        if fields is None:
            self.send_error(413)
            return
        action = (fields.get("action") or [""])[0]
        with dbtx() as con:
            if action == "delete_all":
                n = con.execute("DELETE FROM messages").rowcount
            elif action == "delete":
                ids = [int(i) for i in fields.get("id", []) if i.isdigit()]
                n = 0
                for i in range(0, len(ids), 500):
                    chunk = ids[i:i + 500]
                    n += con.execute(
                        f"DELETE FROM messages WHERE id IN ({','.join('?' * len(chunk))})", chunk
                    ).rowcount
            else:
                n = 0
        log(f"inbox: deleted {n}")
        self.redirect("/inbox")


def main():
    if "--hash-password" in sys.argv:
        password = sys.stdin.read().rstrip("\n")
        if not password:
            sys.exit("No password given.")
        print(hash_password(password))
        return
    with dbtx():
        pass  # create the table up front so a permissions problem shows at start
    log(f"listening on :8000 (inbox {'ready' if INBOX_USER and INBOX_HASH else 'password NOT set'})")
    ThreadingHTTPServer(("0.0.0.0", 8000), Handler).serve_forever()


if __name__ == "__main__":
    main()
