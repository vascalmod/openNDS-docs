#!/usr/bin/env python3
"""SQLite explicit-dev suite for backend/api.py (stdlib only, temp DB).

Covers the claim matrix on the dev backend. PostgreSQL coverage lives in
backend/test_pg.py (needs TEST_DATABASE_URL). No network.
"""
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "backend"))
import api


class ClaimTests(unittest.TestCase):
    def setUp(self):
        self._old_db = os.environ.get("VOUCHER_DB")
        self._old_url = os.environ.get("DATABASE_URL")
        os.environ.pop("DATABASE_URL", None)
        self.tmp = tempfile.NamedTemporaryFile(suffix=".db", delete=False)
        self.tmp.close()
        os.environ["VOUCHER_DB"] = self.tmp.name
        # NOTE: api reads VOUCHER_DB at connect time via module global, so
        # rebind it explicitly (import-time default would be stale/empty).
        api.VOUCHER_DB = self.tmp.name
        api.DATABASE_URL = ""
        self.db = api.DB.connect()
        self.assertEqual(self.db.kind, "sqlite")
        self.db.execute(
            "INSERT INTO vouchers (code,total_secs,used_secs,state) VALUES "
            "('TEST-6H',21600,0,'NEW'),('TEST-USED',21600,21600,'ACTIVE'),"
            "('TEST-DISABLED',21600,0,'DISABLED'),"
            "('TEST-PAUSED',21600,3600,'PAUSED')")
        self.db.commit()

    def tearDown(self):
        self.db.close()
        os.unlink(self.tmp.name)
        if self._old_db is None:
            os.environ.pop("VOUCHER_DB", None)
        else:
            os.environ["VOUCHER_DB"] = self._old_db
        if self._old_url is None:
            os.environ.pop("DATABASE_URL", None)
        else:
            os.environ["DATABASE_URL"] = self._old_url

    def test_fresh_allow_full_remaining(self):
        r = api.claim_voucher(self.db, "test-6h", "AA:BB:CC:DD:EE:01",
                              "10.0.0.200", "tok1")
        self.assertEqual(r["decision"], "ALLOW")
        self.assertEqual(r["remaining"], 21600)
        self.assertIsNone(r["evict"])
        self.assertIn("ALLOW 21600 10240 10240", api.format_claim(r))

    def test_unknown_deny(self):
        r = api.claim_voucher(self.db, "PORTAL-TEST", "AA:BB:CC:DD:EE:99",
                              "10.0.0.200", "t")
        self.assertEqual((r["decision"], r["reason"]), ("DENY", "unknown"))

    def test_bad_charset_deny(self):
        for bad in ["A;B", "A&B", "a b", "x" * 21, "ab", "vouch_er"]:
            r = api.claim_voucher(self.db, bad, "AA:BB:CC:DD:EE:01", "", "")
            self.assertEqual(r["decision"], "DENY", bad)

    def test_exhausted_expires(self):
        r = api.claim_voucher(self.db, "TEST-USED", "AA:BB:CC:DD:EE:02", "", "")
        self.assertEqual((r["decision"], r["reason"]), ("DENY", "expired"))
        st = self.db.row("SELECT state FROM vouchers WHERE code=%s",
                         ("TEST-USED",))["state"]
        self.assertEqual(st, "EXPIRED")

    def test_disabled_deny(self):
        r = api.claim_voucher(self.db, "TEST-DISABLED", "AA:BB:CC:DD:EE:03",
                              "", "")
        self.assertEqual((r["decision"], r["reason"]), ("DENY", "disabled"))

    def test_paused_deny_stage2(self):
        r = api.claim_voucher(self.db, "TEST-PAUSED", "AA:BB:CC:DD:EE:04",
                              "", "")
        self.assertEqual((r["decision"], r["reason"]), ("DENY", "paused"))
        self.assertEqual(r["remaining"], 18000)

    def test_rebind_evicts_old(self):
        api.claim_voucher(self.db, "TEST-6H", "AA:BB:CC:DD:EE:01",
                          "10.0.0.200", "t1")
        r = api.claim_voucher(self.db, "TEST-6H", "AA:BB:CC:DD:EE:02",
                              "10.0.0.201", "t2")
        self.assertEqual(r["decision"], "ALLOW")
        self.assertEqual(r["evict"], "AA:BB:CC:DD:EE:01")
        self.assertIn("EVICT AA:BB:CC:DD:EE:01", api.format_claim(r))

    def test_same_mac_idempotent(self):
        api.claim_voucher(self.db, "TEST-6H", "AA:BB:CC:DD:EE:01", "", "t1")
        r = api.claim_voucher(self.db, "TEST-6H", "AA:BB:CC:DD:EE:01", "", "t1")
        self.assertEqual(r["decision"], "ALLOW")
        self.assertIsNone(r["evict"])

    def test_session_info_six_questions(self):
        s = api.session_info(self.db, "TEST-6H")
        for key in ("exists", "active", "paused", "remaining_seconds",
                    "active_session", "meta"):
            self.assertIn(key, s)
        api.claim_voucher(self.db, "TEST-6H", "AA:BB:CC:DD:EE:01", "", "")
        s = api.session_info(self.db, "TEST-6H")
        self.assertTrue(s["exists"] and s["active"] and not s["paused"])
        self.assertEqual(s["remaining_seconds"], 21600)
        self.assertEqual(s["active_session"]["mac"], "AA:BB:CC:DD:EE:01")
        self.assertFalse(api.session_info(self.db, "NOPE")["exists"])


class BackendSelectionTests(unittest.TestCase):
    """DATABASE_URL configured => PostgreSQL attempted, SQLite never touched."""

    def test_pg_configured_never_falls_back_to_sqlite(self):
        canary = tempfile.NamedTemporaryFile(suffix=".db", delete=True)
        canary.close()  # path must NOT be created by a sqlite fallback
        api.DATABASE_URL = "postgresql://127.0.0.1:1/nodb"
        try:
            with self.assertRaises(api.BackendError):
                api.DB.connect()
        finally:
            api.DATABASE_URL = ""
        self.assertFalse(os.path.exists(canary.name),
                         "sqlite fallback created a file despite DATABASE_URL")

    def test_no_backend_configured_refuses(self):
        api.DATABASE_URL = ""
        api.VOUCHER_DB = ""
        try:
            with self.assertRaises(api.BackendError):
                api.DB.connect()
        finally:
            api.VOUCHER_DB = os.environ.get("VOUCHER_DB", "")


if __name__ == "__main__":
    unittest.main(verbosity=2)
