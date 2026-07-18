#!/usr/bin/env python3
"""Send an alert over SMTP. Standard library only, no MTA or root required.

Usage:  notify-mail.py "<subject>"        # body is read from stdin
Config: ~/.config/claude-vps-guard/mail.env  (KEY=VALUE, chmod 600)
        Override the path with CLAUDE_GUARD_MAIL_ENV.
Exit:   0 sent, 2 usage error, 3 not configured, 4 SMTP failure.

Keys: SMTP_HOST, SMTP_PORT, SMTP_USER, SMTP_PASS, MAIL_FROM, MAIL_TO and the
optional SMTP_SECURITY (starttls | ssl | none, default starttls).
"""
import os
import ssl
import sys
import smtplib
from email.message import EmailMessage

DEFAULT_CFG = os.path.join(
    os.environ.get("CLAUDE_GUARD_CONFIG_DIR", os.path.expanduser("~/.config/claude-vps-guard")),
    "mail.env",
)
CFG = os.environ.get("CLAUDE_GUARD_MAIL_ENV", DEFAULT_CFG)
REQUIRED = ["SMTP_HOST", "SMTP_PORT", "SMTP_USER", "SMTP_PASS", "MAIL_FROM", "MAIL_TO"]


def load(path):
    values = {}
    try:
        with open(path) as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, value = line.split("=", 1)
                values[key.strip()] = value.strip().strip('"').strip("'")
    except FileNotFoundError:
        pass
    # Environment overrides the file, so a service manager can inject secrets.
    for key in REQUIRED + ["SMTP_SECURITY"]:
        if os.environ.get(key):
            values[key] = os.environ[key]
    return values


def main():
    if len(sys.argv) < 2:
        sys.stderr.write('usage: notify-mail.py "<subject>" (body on stdin)\n')
        return 2

    cfg = load(CFG)
    missing = [k for k in REQUIRED if not cfg.get(k)]
    if missing:
        sys.stderr.write("mail NOT configured (%s missing: %s)\n" % (CFG, ",".join(missing)))
        return 3

    msg = EmailMessage()
    msg["From"] = cfg["MAIL_FROM"]
    msg["To"] = cfg["MAIL_TO"]
    msg["Subject"] = sys.argv[1]
    msg.set_content(sys.stdin.read())

    host, port = cfg["SMTP_HOST"], int(cfg["SMTP_PORT"])
    user, password = cfg["SMTP_USER"], cfg["SMTP_PASS"]
    mode = cfg.get("SMTP_SECURITY", "starttls").lower()

    try:
        if mode == "ssl":
            ctx = ssl.create_default_context()
            with smtplib.SMTP_SSL(host, port, context=ctx, timeout=30) as srv:
                srv.login(user, password)
                srv.send_message(msg)
        else:
            with smtplib.SMTP(host, port, timeout=30) as srv:
                srv.ehlo()
                if mode == "starttls":
                    srv.starttls(context=ssl.create_default_context())
                    srv.ehlo()
                if user:
                    srv.login(user, password)
                srv.send_message(msg)
    except Exception as exc:  # noqa: BLE001 - every failure is reported the same way
        sys.stderr.write("SMTP error: %s\n" % exc)
        return 4

    print("mail sent -> %s" % cfg["MAIL_TO"])
    return 0


if __name__ == "__main__":
    sys.exit(main())
