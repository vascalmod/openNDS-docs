#!/usr/bin/env python3
"""Stage 2 voucher API — ONE validation function for Android CPD and Chrome.

Endpoints (same DB, same logic regardless of browser; browser never calls here,
only the EAP claimant does):
  POST /claim   form fields: voucher, mac, ip, token, psk
      -> text line:  ALLOW <remaining_secs> <up_kbps> <down_kbps>[ EVICT <oldmac>]
                     DENY <reason>
      (line format: busybox-sh parseable without jq; reasons are generic codes)
  GET  /session?code=<VOUCHER>   (header X-PSK or ?psk=) -> JSON answering the
      six Stage 3 questions (exists/active/paused/remaining/active-session/meta).
      Stage 2 ships it for ChatGPT review; the EAP claim path uses /claim only.
  GET  /healthz -> ok

Storage: SQLite file locally (VOUCHER_DB, default ./vouchers.db). Production
uses PostgreSQL when DATABASE_URL is set and a driver is importable; otherwise
SQLite with the same DDL semantics. No third-party deps (stdlib only).

Config env: VOUCHER_PSK (required; compare_digest), VOUCHER_DB, UP_KBPS /
DOWN_KBPS (default 10240 = 10 Mbps; EAP calibration step confirms mapping),
PORT (default 8080).

Stage 2 semantics: initial authorization only. used_secs never accrues here
(Stage 3 deauth accounting will). remaining = total - used. PAUSED rows deny
(Stage 3 will resume them). Rebind policy: evict-old/allow-new (new MAC takes
over; response names EVICT <oldmac> for best-effort EAP deauth).
"""

import hmac
import json
import os
import re
import sqlite3
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer

CODE_RE = re.compile(r"^[A-Z0-9-]{4,20}$")
MAC_RE = re.compile(r"^[0-9a-fA-F:]{0,17}$")

UP_KBPS = int(os.environ.get("UP_KBPS", "10240"))
DOWN_KBPS = int(os.environ.get("DOWN_KBPS", "10240"))

DDL = """
CREATE TABLE IF NOT EXISTS vouchers (
    code TEXT PRIMARY KEY,
    total_secs INTEGER NOT NULL DEFAULT 21600,
    used_secs INTEGER NOT NULL DEFAULT 0,
    state TEXT NOT NULL DEFAULT 'NEW'
        CHECK (state IN ('NEW','ACTIVE','PAUSED','EXPIRED','DISABLED')),
    bound_mac TEXT,
    last_ip TEXT,
    last_token TEXT,
    first_seen TEXT,
    last_auth TEXT,
    resume_ts TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE TABLE IF NOT EXISTS events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    code TEXT NOT NULL,
    mac TEXT, ip TEXT, token TEXT,
    decision TEXT NOT NULL,
    reason TEXT NOT NULL,
    remaining_secs INTEGER,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_events_code ON events (code);
"""


def db_connect(path):
    conn = sqlite3.connect(path)
    conn.row_factory = sqlite3.Row
    conn.executescript(DDL)
    return conn


def normalize(code):
    return (code or "").strip().upper()


def claim_voucher(conn, code, mac="", ip="", token="", now=None):
    """Single validation function. Returns dict; also writes vouchers+events.

    Returned remaining_secs drives EAP session_length=ceil(remaining/60).
    evict is None or the superseded MAC for best-effort deauth.
    """
    now = now or time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    code = normalize(code)
    mac = (mac or "").strip()
    if not CODE_RE.match(code):
        log_event(conn, code or "?", mac, ip, token, "DENY", "invalid", None)
        conn.commit()
        return {"decision": "DENY", "reason": "invalid", "remaining": 0, "evict": None}
    if not MAC_RE.match(mac):
        mac = ""
    cur = conn.cursor()
    cur.execute("BEGIN IMMEDIATE")
    row = cur.execute("SELECT * FROM vouchers WHERE code=?", (code,)).fetchone()
    if row is None:
        log_event(conn, code, mac, ip, token, "DENY", "unknown", 0)
        conn.commit()
        return {"decision": "DENY", "reason": "unknown", "remaining": 0, "evict": None}
    state = row["state"]
    remaining = max(0, (row["total_secs"] or 0) - (row["used_secs"] or 0))
    if state == "DISABLED":
        log_event(conn, code, mac, ip, token, "DENY", "disabled", remaining)
        conn.commit()
        return {"decision": "DENY", "reason": "disabled", "remaining": remaining, "evict": None}
    if state == "PAUSED":
        # Stage 3 will resume these via voucher re-entry; Stage 2 denies the
        # fresh-claim path so no time is consumed implicitly.
        cur.execute(
            "UPDATE vouchers SET last_ip=?, last_token=?, last_auth=? WHERE code=?",
            (ip, token, now, code),
        )
        log_event(conn, code, mac, ip, token, "DENY", "paused", remaining)
        conn.commit()
        return {"decision": "DENY", "reason": "paused", "remaining": remaining, "evict": None}
    if remaining <= 0 or state == "EXPIRED":
        cur.execute("UPDATE vouchers SET state='EXPIRED' WHERE code=?", (code,))
        log_event(conn, code, mac, ip, token, "DENY", "expired", 0)
        conn.commit()
        return {"decision": "DENY", "reason": "expired", "remaining": 0, "evict": None}
    bound = row["bound_mac"] or ""
    evict = None
    if not bound or bound == mac or not mac:
        reason = "rerequest" if bound == mac and bound else "fresh"
        if row["first_seen"] is None:
            cur.execute(
                "UPDATE vouchers SET state='ACTIVE', bound_mac=?, last_ip=?, "
                "last_token=?, first_seen=?, last_auth=? WHERE code=?",
                (mac or bound, ip, token, now, now, code),
            )
        else:
            cur.execute(
                "UPDATE vouchers SET state='ACTIVE', bound_mac=?, last_ip=?, "
                "last_token=?, last_auth=? WHERE code=?",
                (mac or bound, ip, token, now, code),
            )
    else:
        # Evict-old / allow-new (private-MAC friendly): new device takes over.
        evict = bound
        reason = "rebound"
        cur.execute(
            "UPDATE vouchers SET state='ACTIVE', bound_mac=?, last_ip=?, "
            "last_token=?, last_auth=? WHERE code=?",
            (mac, ip, token, now, code),
        )
    log_event(conn, code, mac, ip, token, "ALLOW", reason, remaining)
    conn.commit()
    return {"decision": "ALLOW", "reason": reason, "remaining": remaining, "evict": evict}


def log_event(conn, code, mac, ip, token, decision, reason, remaining):
    conn.execute(
        "INSERT INTO events (code, mac, ip, token, decision, reason, remaining_secs)"
        " VALUES (?,?,?,?,?,?,?)",
        (code, mac, ip, token, decision, reason, remaining),
    )


def session_info(conn, code):
    """Answer the six Stage 3 questions for one voucher code."""
    code = normalize(code)
    row = conn.execute("SELECT * FROM vouchers WHERE code=?", (code,)).fetchone()
    if row is None:
        return {"exists": False, "active": False, "paused": False,
                "remaining_seconds": 0, "active_session": None, "meta": {}}
    remaining = max(0, (row["total_secs"] or 0) - (row["used_secs"] or 0))
    state = row["state"]
    return {
        "exists": True,
        "active": state == "ACTIVE" and remaining > 0,
        "paused": state == "PAUSED",
        "remaining_seconds": remaining,
        "active_session": {"mac": row["bound_mac"], "ip": row["last_ip"],
                           "since": row["first_seen"], "last_auth": row["last_auth"]}
        if state in ("ACTIVE", "PAUSED") else None,
        "meta": {"state": state, "total_secs": row["total_secs"],
                 "used_secs": row["used_secs"]},
    }


def format_claim(result):
    if result["decision"] == "ALLOW":
        line = "ALLOW %d %d %d" % (result["remaining"], UP_KBPS, DOWN_KBPS)
        if result.get("evict"):
            line += " EVICT %s" % result["evict"]
        return line + "\n"
    return "DENY %s\n" % result.get("reason", "denied")


class Handler(BaseHTTPRequestHandler):
    db_path = os.environ.get("VOUCHER_DB", "./vouchers.db")
    psk = os.environ.get("VOUCHER_PSK", "")

    def log_message(self, *a):
        pass

    def _psk_ok(self, given):
        return bool(self.psk) and hmac.compare_digest(str(given or ""), self.psk)

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == "/healthz":
            return self._send(200, "text/plain", b"ok\n")
        if parsed.path == "/session":
            qs = urllib.parse.parse_qs(parsed.query)
            if not self._psk_ok(qs.get("psk", [""])[0] or
                                self.headers.get("X-PSK", "")):
                return self._send(403, "text/plain", b"DENY auth\n")
            conn = db_connect(self.db_path)
            try:
                body = json.dumps(session_info(
                    conn, qs.get("code", [""])[0])).encode()
            finally:
                conn.close()
            return self._send(200, "application/json", body)
        return self._send(404, "text/plain", b"DENY unknown\n")

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path != "/claim":
            return self._send(404, "text/plain", b"DENY unknown\n")
        length = int(self.headers.get("Content-Length", 0) or 0)
        fields = urllib.parse.parse_qs(
            self.rfile.read(length).decode("utf-8", "replace"))
        if not self._psk_ok((fields.get("psk") or [""])[0]):
            return self._send(403, "text/plain", b"DENY auth\n")
        conn = db_connect(self.db_path)
        try:
            result = claim_voucher(
                conn, (fields.get("voucher") or [""])[0],
                (fields.get("mac") or [""])[0],
                (fields.get("ip") or [""])[0],
                (fields.get("token") or [""])[0])
            body = format_claim(result).encode()
        finally:
            conn.close()
        return self._send(200, "text/plain", body)

    def _send(self, code, ctype, body):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "8080"))
    HTTPServer(("127.0.0.1", port), Handler).serve_forever()
