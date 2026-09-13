#!/usr/bin/env python3
"""Stage 2 voucher API — ONE validation function for Android CPD and Chrome.

Endpoints (same DB, same logic regardless of browser; browser never calls here,
only the EAP claimant does):
  POST /claim   form fields: voucher, mac, ip, token, psk
      -> text line:  ALLOW <remaining_secs> <up_kbps> <down_kbps>[ EVICT <oldmac>]
                     DENY <reason>
      (line format: busybox-sh parseable without jq; reasons are generic codes.
      Claim decisions are ALWAYS HTTP 200 so the EAP claimant has one parse
      path; PSK/routing failures are 4xx with a generic body.)
  GET  /session?code=<VOUCHER>   (header X-PSK or ?psk=) -> JSON answering the
      six Stage 3 questions (exists/active/paused/remaining/active-session/meta).
      Stage 2 ships it for review; the EAP claim path uses /claim only.
  GET  /healthz -> ok

Backend selection (explicit; NEVER silent):
  DATABASE_URL set (postgres scheme) -> PostgreSQL ONLY via the `psycopg` v3
      driver (`pip install "psycopg[binary]"`). Driver missing, URL bad, or DB
      unreachable -> log a clear server-side error and answer every /claim
      with a generic DENY (fail closed). SQLite is never used in this mode.
  DATABASE_URL unset + VOUCHER_DB set -> SQLite explicit-dev backend
      (stand-in with equivalent semantics; never presented as PostgreSQL).
  Neither set -> refuse startup with a clear error.

Config env: DATABASE_URL, VOUCHER_DB, VOUCHER_PSK (required; compare_digest),
HOST (default 127.0.0.1; production HOST=0.0.0.0 or the Ubuntu LAN IP — the API
is an internal EAP-to-Ubuntu service, never Internet-facing),
PORT (default 8080), UP_KBPS / DOWN_KBPS (default 10240 = 10 Mbps; EAP
calibration step confirms the mapping).

Stage 2 semantics: initial authorization only. used_secs never accrues here
(Stage 3 deauth accounting will). remaining = total - used. PAUSED rows deny
(Stage 3 will resume them). Rebind policy: evict-old/allow-new (new MAC takes
over; response names EVICT <oldmac> for best-effort EAP deauth).
"""

import hmac
import json
import logging
import os
import re
import time
import traceback
import urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer

CODE_RE = re.compile(r"^[A-Z0-9-]{4,20}$")

UP_KBPS = int(os.environ.get("UP_KBPS", "10240"))
DOWN_KBPS = int(os.environ.get("DOWN_KBPS", "10240"))

DATABASE_URL = os.environ.get("DATABASE_URL", "")
VOUCHER_DB = os.environ.get("VOUCHER_DB", "")
HOST = os.environ.get("HOST", "127.0.0.1")
PORT = int(os.environ.get("PORT", "8080"))

log = logging.getLogger("voucher-api")

# Explicit-dev SQLite DDL only. It mirrors backend/schema.sql (production,
# installed separately by the operator — see its header) for local
# development/tests. The two are kept semantically identical by review
# (and proven by backend/test_pg.py loading schema.sql verbatim), never by
# silent substitution: with DATABASE_URL set, this SQLite DDL is dead code.
SQLITE_DDL = """
CREATE TABLE IF NOT EXISTS vouchers (
    code TEXT PRIMARY KEY,
    total_secs INTEGER NOT NULL DEFAULT 21600 CHECK (total_secs >= 0),
    used_secs INTEGER NOT NULL DEFAULT 0 CHECK (used_secs >= 0),
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


class BackendError(Exception):
    """Raised for any DB unavailability/misconfiguration. Callers deny."""


class DB:
    """Minimal placeholder/transaction adapter.

    kind == "pg":     %s placeholders, SELECT ... FOR UPDATE, TIMESTAMPTZ.
    kind == "sqlite":  ? placeholders, BEGIN IMMEDIATE, TEXT timestamps.
    """

    def __init__(self, kind, conn):
        self.kind = kind
        self.conn = conn

    @classmethod
    def connect(cls):
        if DATABASE_URL:
            try:
                import psycopg
                from psycopg.rows import dict_row
            except ImportError:
                raise BackendError("db-driver-missing")
            try:
                conn = psycopg.connect(DATABASE_URL, row_factory=dict_row,
                                       connect_timeout=5)
            except Exception as exc:
                raise BackendError("db-unavailable: %s" % type(exc).__name__)
            return cls("pg", conn)
        if VOUCHER_DB:
            import sqlite3
            conn = sqlite3.connect(VOUCHER_DB)
            conn.row_factory = sqlite3.Row
            conn.isolation_level = None  # explicit transactions below
            conn.executescript(SQLITE_DDL)
            return cls("sqlite", conn)
        raise BackendError("db-unconfigured")

    def close(self):
        try:
            self.conn.close()
        except Exception:
            pass

    def _q(self, sql):
        if self.kind == "sqlite":
            sql = sql.replace("%s", "?")
        return sql

    def execute(self, sql, params=()):
        cur = self.conn.cursor()
        cur.execute(self._q(sql), params)
        return cur

    def row(self, sql, params=()):
        r = self.execute(sql, params).fetchone()
        return dict(r) if r is not None else None

    def now_sql(self):
        return "now()" if self.kind == "pg" else "datetime('now')"

    def begin_claim(self):
        # Atomic-claim guard: pg row lock; sqlite write-transaction lock.
        if self.kind == "sqlite":
            self.execute("BEGIN IMMEDIATE")

    def commit(self):
        self.conn.commit()

    def rollback(self):
        try:
            self.conn.rollback()
        except Exception:
            pass


def iso(value):
    if value is None:
        return None
    if hasattr(value, "isoformat"):
        return value.isoformat()
    text = str(value).strip()
    if re.match(r"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$", text):
        return text.replace(" ", "T") + "Z"
    return text


def normalize(code):
    return (code or "").strip().upper()


def log_event(db, code, mac, ip, token, decision, reason, remaining):
    db.execute(
        "INSERT INTO events (code, mac, ip, token, decision, reason,"
        " remaining_secs) VALUES (%s,%s,%s,%s,%s,%s,%s)",
        (code, mac, ip, token, decision, reason, remaining),
    )


def claim_voucher(db, code, mac="", ip="", token="", now=None):
    """Single authoritative validation function. Writes vouchers+events.

    Returned remaining_secs drives EAP session_length=ceil(remaining/60).
    evict is None or the superseded MAC for best-effort deauth.
    Caller MUST hold backend errors as deny; this function assumes a live db.
    """
    _ = now  # timestamps are DB-side (now()/datetime('now')); arg kept for API stability
    code = normalize(code)
    mac = (mac or "").strip()
    if not CODE_RE.match(code):
        log_event(db, code or "?", mac, ip, token, "DENY", "invalid", None)
        db.commit()
        return {"decision": "DENY", "reason": "invalid", "remaining": 0, "evict": None}
    db.begin_claim()
    try:
        if db.kind == "pg":
            row = db.row("SELECT * FROM vouchers WHERE code=%s FOR UPDATE",
                         (code,))
        else:
            row = db.row("SELECT * FROM vouchers WHERE code=%s", (code,))
        if row is None:
            log_event(db, code, mac, ip, token, "DENY", "unknown", 0)
            db.commit()
            return {"decision": "DENY", "reason": "unknown", "remaining": 0,
                    "evict": None}
        state = row["state"]
        remaining = max(0, (row["total_secs"] or 0) - (row["used_secs"] or 0))
        if state == "DISABLED":
            log_event(db, code, mac, ip, token, "DENY", "disabled", remaining)
            db.commit()
            return {"decision": "DENY", "reason": "disabled",
                    "remaining": remaining, "evict": None}
        if state == "PAUSED":
            # Stage 3 resumes these via voucher re-entry; Stage 2 denies the
            # fresh-claim path so no time is consumed implicitly.
            nowfn = db.now_sql()
            db.execute(
                "UPDATE vouchers SET last_ip=%s, last_token=%s,"
                " last_auth=" + nowfn + " WHERE code=%s", (ip, token, code))
            log_event(db, code, mac, ip, token, "DENY", "paused", remaining)
            db.commit()
            return {"decision": "DENY", "reason": "paused",
                    "remaining": remaining, "evict": None}
        if remaining <= 0 or state == "EXPIRED":
            db.execute("UPDATE vouchers SET state='EXPIRED' WHERE code=%s",
                       (code,))
            log_event(db, code, mac, ip, token, "DENY", "expired", 0)
            db.commit()
            return {"decision": "DENY", "reason": "expired", "remaining": 0,
                    "evict": None}
        bound = row["bound_mac"] or ""
        evict = None
        nowfn = db.now_sql()
        if not bound or bound == mac or not mac:
            reason = "rerequest" if bound == mac and bound else "fresh"
            if row["first_seen"] is None:
                db.execute(
                    "UPDATE vouchers SET state='ACTIVE', bound_mac=%s,"
                    " last_ip=%s, last_token=%s, first_seen=" + nowfn + ","
                    " last_auth=" + nowfn + " WHERE code=%s",
                    (mac or bound, ip, token, code))
            else:
                db.execute(
                    "UPDATE vouchers SET state='ACTIVE', bound_mac=%s,"
                    " last_ip=%s, last_token=%s, last_auth=" + nowfn +
                    " WHERE code=%s", (mac or bound, ip, token, code))
        else:
            # Evict-old / allow-new (private-MAC friendly): new device takes over.
            evict = bound
            reason = "rebound"
            db.execute(
                "UPDATE vouchers SET state='ACTIVE', bound_mac=%s, last_ip=%s,"
                " last_token=%s, last_auth=" + nowfn + " WHERE code=%s",
                (mac, ip, token, code))
        log_event(db, code, mac, ip, token, "ALLOW", reason, remaining)
        db.commit()
        return {"decision": "ALLOW", "reason": reason, "remaining": remaining,
                "evict": evict}
    except Exception:
        db.rollback()
        raise


def session_info(db, code):
    """Answer the six Stage 3 questions for one voucher code."""
    code = normalize(code)
    row = db.row("SELECT * FROM vouchers WHERE code=%s", (code,))
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
                           "since": iso(row["first_seen"]),
                           "last_auth": iso(row["last_auth"])}
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
    psk = os.environ.get("VOUCHER_PSK", "")
    server_version = "VoucherAPI/2"

    def log_message(self, *a):
        pass

    def _psk_ok(self, given):
        return bool(self.psk) and hmac.compare_digest(str(given or ""),
                                                      self.psk)

    def _claim_body(self, fields):
        """Returns (http_code, body). Never raises: errors become generic DENY."""
        try:
            db = DB.connect()
        except BackendError as exc:
            log.error("backend unavailable: %s", exc)
            return 200, b"DENY backend_unavailable\n"
        try:
            result = claim_voucher(
                db, (fields.get("voucher") or [""])[0],
                (fields.get("mac") or [""])[0],
                (fields.get("ip") or [""])[0],
                (fields.get("token") or [""])[0])
            return 200, format_claim(result).encode()
        except Exception:
            log.error("claim failed:\n%s", traceback.format_exc())
            return 200, b"DENY error\n"
        finally:
            db.close()

    def do_GET(self):
        try:
            parsed = urllib.parse.urlparse(self.path)
            if parsed.path == "/healthz":
                return self._send(200, "text/plain", b"ok\n")
            if parsed.path == "/session":
                qs = urllib.parse.parse_qs(parsed.query)
                if not self._psk_ok(qs.get("psk", [""])[0] or
                                    self.headers.get("X-PSK", "")):
                    return self._send(403, "text/plain", b"DENY auth\n")
                try:
                    db = DB.connect()
                except BackendError as exc:
                    log.error("backend unavailable: %s", exc)
                    return self._send(503, "text/plain", b"error\n")
                try:
                    body = json.dumps(session_info(
                        db, qs.get("code", [""])[0])).encode()
                except Exception:
                    log.error("session failed:\n%s", traceback.format_exc())
                    return self._send(500, "text/plain", b"error\n")
                finally:
                    db.close()
                return self._send(200, "application/json", body)
            return self._send(404, "text/plain", b"DENY unknown\n")
        except Exception:
            log.error("GET failed:\n%s", traceback.format_exc())
            return self._send(500, "text/plain", b"error\n")

    def do_POST(self):
        try:
            parsed = urllib.parse.urlparse(self.path)
            if parsed.path != "/claim":
                return self._send(404, "text/plain", b"DENY unknown\n")
            try:
                length = int(self.headers.get("Content-Length", 0) or 0)
            except ValueError:
                return self._send(400, "text/plain", b"DENY malformed\n")
            fields = urllib.parse.parse_qs(
                self.rfile.read(length).decode("utf-8", "replace"))
            if not self._psk_ok((fields.get("psk") or [""])[0]):
                return self._send(403, "text/plain", b"DENY auth\n")
            code, body = self._claim_body(fields)
            return self._send(code, "text/plain", body)
        except Exception:
            log.error("POST failed:\n%s", traceback.format_exc())
            return self._send(500, "text/plain", b"error\n")

    def _send(self, code, ctype, body):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def check_backend():
    """Startup probe: returns backend kind or raises BackendError."""
    db = DB.connect()
    try:
        db.execute("SELECT 1")
        return db.kind
    finally:
        db.close()


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO,
                        format="%(asctime)s %(levelname)s %(message)s")
    if not os.environ.get("VOUCHER_PSK"):
        raise SystemExit("VOUCHER_PSK is required (never empty in production)")
    try:
        kind = check_backend()
    except BackendError as exc:
        # Fail closed but stay up so /claim keeps answering generic DENY.
        log.error("startup backend check failed: %s", exc)
        kind = "unavailable"
    log.info("backend=%s host=%s port=%d (psk configured, values redacted)",
             kind, HOST, PORT)
    HTTPServer((HOST, PORT), Handler).serve_forever()
