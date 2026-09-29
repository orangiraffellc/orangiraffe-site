#!/usr/bin/env python3
"""Contact form handler for orangiraffe.com.

Python standard library only. Accepts POST /api/contact (a plain HTML form, no
JavaScript), emails the message over SMTP, and redirects the browser to
/thanks or /contact-error. Nothing is written to disk; logs never contain what
people send.

Environment (from /opt/orangiraffe/.env):
  SMTP_HOST  default smtp-relay.brevo.com
  SMTP_PORT  default 587 (STARTTLS); 465 uses implicit TLS
  SMTP_USER, SMTP_PASS   the site's own SMTP key, never another project's
  MAIL_FROM  a sender address verified with the SMTP provider
  MAIL_TO    where messages go, default info@orangiraffe.com

  python3 contact.py --test   sends one test email and exits
"""
import os
import re
import smtplib
import ssl
import sys
import threading
import time
from email.message import EmailMessage
from email.utils import formataddr, formatdate, make_msgid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs

SMTP_HOST = os.environ.get("SMTP_HOST") or "smtp-relay.brevo.com"
SMTP_PORT = int(os.environ.get("SMTP_PORT") or 587)
SMTP_USER = os.environ.get("SMTP_USER") or ""
SMTP_PASS = os.environ.get("SMTP_PASS") or ""
MAIL_FROM = os.environ.get("MAIL_FROM") or ""
MAIL_TO = os.environ.get("MAIL_TO") or "info@orangiraffe.com"

MAX_BODY = 16 * 1024
PER_IP_PER_HOUR = 5
PER_DAY = 100

EMAIL_RE = re.compile(r"^[^@\s<>,;:\"]+@[^@\s<>,;:\"]+\.[^@\s<>,;:\"]+$")
CONTROL_RE = re.compile(r"[\x00-\x1f\x7f]")

_lock = threading.Lock()
_by_ip = {}
_today = []


def allowed(ip):
    """Counts every submission, valid or not, so a flood cannot probe for free."""
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


def configured():
    return bool(SMTP_USER and SMTP_PASS and MAIL_FROM)


def send(name, email, message):
    msg = EmailMessage()
    msg["Subject"] = ("orangiraffe.com contact: " + name)[:150]
    msg["From"] = formataddr(("Orangiraffe website", MAIL_FROM))
    msg["To"] = MAIL_TO
    msg["Reply-To"] = formataddr((name, email))
    msg["Date"] = formatdate(localtime=False)
    msg["Message-ID"] = make_msgid(domain="orangiraffe.com")
    msg.set_content(
        "New message from the contact form on orangiraffe.com.\n\n"
        f"Name:  {name}\nEmail: {email}\n\n{message}\n\n"
        "Reply to this email to answer them directly.\n"
    )
    ctx = ssl.create_default_context()
    if SMTP_PORT == 465:
        with smtplib.SMTP_SSL(SMTP_HOST, SMTP_PORT, timeout=20, context=ctx) as s:
            s.login(SMTP_USER, SMTP_PASS)
            s.send_message(msg)
    else:
        with smtplib.SMTP(SMTP_HOST, SMTP_PORT, timeout=20) as s:
            s.starttls(context=ctx)
            s.login(SMTP_USER, SMTP_PASS)
            s.send_message(msg)


def log(line):
    print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), line, flush=True)


class Handler(BaseHTTPRequestHandler):
    server_version = "contact"
    sys_version = ""

    def log_message(self, *args):
        pass  # no access log: the privacy policy promises none

    def redirect(self, where):
        self.send_response(303)
        self.send_header("Location", where)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        if self.path == "/healthz":
            body = b"ok\n" if configured() else b"ok (smtp not configured)\n"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_error(404)

    def do_POST(self):
        if self.path != "/api/contact":
            self.send_error(404)
            return
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = -1
        if length < 0 or length > MAX_BODY:
            self.send_error(413)
            return
        raw = self.rfile.read(length).decode("utf-8", "replace")
        fields = parse_qs(raw, keep_blank_values=True, max_num_fields=10)

        def get(key, limit):
            return (fields.get(key) or [""])[0].strip()[:limit]

        ip = (self.headers.get("X-Real-IP") or self.client_address[0]).split(",")[0].strip()
        if not allowed(ip):
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
        message = get("message", 5000).replace("\r\n", "\n")
        if not name or not EMAIL_RE.match(email) or len(message) < 2:
            log("rejected: invalid fields")
            self.redirect("/contact-error")
            return
        if not configured():
            log("failed: smtp not configured")
            self.redirect("/contact-error")
            return
        try:
            send(name, email, message)
        except Exception as e:  # report the class only, never the content
            log(f"failed: {type(e).__name__}")
            self.redirect("/contact-error")
            return
        log("sent")
        self.redirect("/thanks")


def main():
    if "--test" in sys.argv:
        if not configured():
            print("SMTP is not configured (SMTP_USER, SMTP_PASS, MAIL_FROM).")
            sys.exit(1)
        try:
            send("Setup test", MAIL_FROM, "Test message from the orangiraffe.com contact form setup.")
        except Exception as e:
            print(f"Test email FAILED: {type(e).__name__}: {e}")
            sys.exit(1)
        print(f"Test email sent to {MAIL_TO}.")
        return
    log(f"listening on :8000 (smtp {'configured' if configured() else 'NOT configured'})")
    ThreadingHTTPServer(("0.0.0.0", 8000), Handler).serve_forever()


if __name__ == "__main__":
    main()
