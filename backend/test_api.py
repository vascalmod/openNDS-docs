#!/usr/bin/env python3
"""Local unit tests for backend/api.py (stdlib only, temp SQLite). No network."""
import os
import sqlite3
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "backend"))
import api


class ClaimTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.NamedTemporaryFile(suffix=".db", delete=False)
        self.tmp.close()
        self.conn = api.db_connect(self.tmp.name)
        self.conn.executescript("""
          INSERT INTO vouchers (code,total_secs,used_secs,state) VALUES
           ('TEST-6H',21600,0,'NEW'),
           ('TEST-USED',21600,21600,'ACTIVE'),
           ('TEST-DISABLED',21600,0,'DISABLED'),
           ('TEST-PAUSED',21600,3600,'PAUSED');
        """)
        self.conn.commit()

    def tearDown(self):
        self.conn.close()
        os.unlink(self.tmp.name)

    def test_fresh_allow_full_remaining(self):
        r = api.claim_voucher(self.conn, "test-6h", "AA:BB:CC:DD:EE:01",
                              "10.0.0.200", "tok1")
        self.assertEqual(r["decision"], "ALLOW")
        self.assertEqual(r["remaining"], 21600)
        self.assertIsNone(r["evict"])
        self.assertIn("ALLOW 21600 10240 10240", api.format_claim(r))

    def test_unknown_deny(self):
        r = api.claim_voucher(self.conn, "PORTAL-TEST", "AA:BB:CC:DD:EE:99",
                              "10.0.0.200", "t")
        self.assertEqual((r["decision"], r["reason"]), ("DENY", "unknown"))

    def test_bad_charset_deny(self):
        for bad in ["A;B", "A&B", "a b", "x" * 21, "ab", "vouch_er"]:
            r = api.claim_voucher(self.conn, bad, "AA:BB:CC:DD:EE:01", "", "")
            self.assertEqual(r["decision"], "DENY", bad)

    def test_exhausted_expires(self):
        r = api.claim_voucher(self.conn, "TEST-USED", "AA:BB:CC:DD:EE:02", "", "")
        self.assertEqual((r["decision"], r["reason"]), ("DENY", "expired"))
        st = self.conn.execute(
            "SELECT state FROM vouchers WHERE code='TEST-USED'").fetchone()[0]
        self.assertEqual(st, "EXPIRED")

    def test_disabled_deny(self):
        r = api.claim_voucher(self.conn, "TEST-DISABLED", "AA:BB:CC:DD:EE:03",
                              "", "")
        self.assertEqual((r["decision"], r["reason"]), ("DENY", "disabled"))

    def test_paused_deny_stage2(self):
        r = api.claim_voucher(self.conn, "TEST-PAUSED", "AA:BB:CC:DD:EE:04",
                              "", "")
        self.assertEqual((r["decision"], r["reason"]), ("DENY", "paused"))
        self.assertEqual(r["remaining"], 18000)

    def test_rebind_evicts_old(self):
        api.claim_voucher(self.conn, "TEST-6H", "AA:BB:CC:DD:EE:01",
                          "10.0.0.200", "t1")
        r = api.claim_voucher(self.conn, "TEST-6H", "AA:BB:CC:DD:EE:02",
                              "10.0.0.201", "t2")
        self.assertEqual(r["decision"], "ALLOW")
        self.assertEqual(r["evict"], "AA:BB:CC:DD:EE:01")
        self.assertIn("EVICT AA:BB:CC:DD:EE:01", api.format_claim(r))

    def test_same_mac_idempotent(self):
        api.claim_voucher(self.conn, "TEST-6H", "AA:BB:CC:DD:EE:01", "", "t1")
        r = api.claim_voucher(self.conn, "TEST-6H", "AA:BB:CC:DD:EE:01", "", "t1")
        self.assertEqual(r["decision"], "ALLOW")
        self.assertIsNone(r["evict"])

    def test_session_info_six_questions(self):
        s = api.session_info(self.conn, "TEST-6H")
        for key in ("exists", "active", "paused", "remaining_seconds",
                    "active_session", "meta"):
            self.assertIn(key, s)
        api.claim_voucher(self.conn, "TEST-6H", "AA:BB:CC:DD:EE:01", "", "")
        s = api.session_info(self.conn, "TEST-6H")
        self.assertTrue(s["exists"] and s["active"] and not s["paused"])
        self.assertEqual(s["remaining_seconds"], 21600)
        self.assertEqual(s["active_session"]["mac"], "AA:BB:CC:DD:EE:01")
        self.assertFalse(api.session_info(self.conn, "NOPE")["exists"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
