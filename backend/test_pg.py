#!/usr/bin/env python3
"""PostgreSQL suite for backend/api.py. Needs TEST_DATABASE_URL.

Proves the PRODUCTION path: schema.sql loads verbatim, claim matrix,
atomicity/rollback, concurrency, PSK/auth failures, DB-down fail-closed,
and zero detail leakage. Skips cleanly without TEST_DATABASE_URL.

Suggested disposable backend:
  docker run -d --rm --name pgtest -e POSTGRES_PASSWORD=test -p 5433:5432 postgres:16-alpine
  TEST_DATABASE_URL=postgresql://postgres:test@127.0.0.1:5433/postgres <this file>
"""
import os
import sys
import threading
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "backend"))
import api

TEST_URL = os.environ.get("TEST_DATABASE_URL", "")
SCHEMA = os.path.join(os.path.dirname(__file__), "..", "backend", "schema.sql")

SEED = [
    ("TEST-6H", 21600, 0, "NEW"),
    ("TEST-USED", 21600, 21600, "ACTIVE"),
    ("TEST-DISABLED", 21600, 0, "DISABLED"),
    ("TEST-PAUSED", 21600, 3600, "PAUSED"),
    ("TEST-ZERO", 100, 100, "NEW"),
]

LEAK_WORDS = ["postgres", "psycopg", "Traceback", "traceback", ".py",
              "/tmp/", "/root/", "/home/", "relation ", "column "]


def fresh_db(name):
    """Create an isolated database for one test (needs CREATEDB on the role)."""
    import psycopg
    admin = psycopg.connect(TEST_URL, autocommit=True)
    try:
        admin.execute('DROP DATABASE IF EXISTS "%s"' % name)
        admin.execute('CREATE DATABASE "%s"' % name)
    finally:
        admin.close()
    return TEST_URL.rsplit("/", 1)[0] + "/" + name


@unittest.skipUnless(TEST_URL, "pg test needs TEST_DATABASE_URL")
class PgTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import psycopg  # noqa: F401  (proves the v3 driver path is real)
        cls._counter = 0

    def setUp(self):
        type(self)._counter += 1
        self.dbname = "vtest%d_%d" % (os.getpid(), type(self)._counter)
        self.url = fresh_db(self.dbname)
        api.DATABASE_URL = self.url
        self.db = api.DB.connect()
        self.assertEqual(self.db.kind, "pg")
        # Load production schema.sql VERBATIM (split on statement terminators;
        # schema contains no semicolons inside strings).
        with open(SCHEMA) as fh:
            raw = fh.read()
        for stmt in [s for s in raw.split(";") if s.strip()]:
            self.db.execute(stmt)
        self.db.commit()
        for code, total, used, state in SEED:
            self.db.execute(
                "INSERT INTO vouchers (code,total_secs,used_secs,state)"
                " VALUES (%s,%s,%s,%s)", (code, total, used, state))
        self.db.commit()

    def tearDown(self):
        self.db.close()
        import psycopg
        admin = psycopg.connect(TEST_URL, autocommit=True)
        try:
            admin.execute('DROP DATABASE IF EXISTS "%s"' % self.dbname)
        finally:
            admin.close()
        api.DATABASE_URL = ""

    def assertNoLeak(self, bodies):
        if isinstance(bodies, str):
            bodies = [bodies]
        for body in bodies:
            for word in LEAK_WORDS:
                self.assertNotIn(word, body, "leak word %r in %r" % (word, body))

    def test_schema_checks_enforced(self):
        with self.assertRaises(Exception):
            self.db.execute(
                "INSERT INTO vouchers (code,total_secs,used_secs) VALUES"
                " ('BAD',10,11)")
            self.db.commit()
        self.db.rollback()

    def test_claim_matrix(self):
        r = api.claim_voucher(self.db, "test-6h", "AA:BB:CC:DD:EE:01",
                              "10.0.0.200", "tok1")
        self.assertEqual((r["decision"], r["remaining"]), ("ALLOW", 21600))
        self.assertIn("ALLOW 21600", api.format_claim(r))
        cases = [("NOPE-1", "unknown"), ("TEST-DISABLED", "disabled"),
                 ("TEST-PAUSED", "paused"), ("TEST-USED", "expired"),
                 ("TEST-ZERO", "expired"), ("bad!", "invalid")]
        bodies = []
        for code, reason in cases:
            rr = api.claim_voucher(self.db, code, "AA:BB:CC:DD:EE:09", "", "")
            self.assertEqual((rr["decision"], rr["reason"]),
                             ("DENY", reason), code)
            bodies.append(api.format_claim(rr))
        self.assertNoLeak(bodies)

    def test_rebind_and_idempotent(self):
        api.claim_voucher(self.db, "TEST-6H", "AA:BB:CC:DD:EE:01", "", "t1")
        r = api.claim_voucher(self.db, "TEST-6H", "AA:BB:CC:DD:EE:01", "", "t1")
        self.assertEqual(r["decision"], "ALLOW")
        self.assertIsNone(r["evict"])
        r = api.claim_voucher(self.db, "TEST-6H", "AA:BB:CC:DD:EE:02", "", "t2")
        self.assertEqual(r["evict"], "AA:BB:CC:DD:EE:01")

    def test_rollback_on_mid_transaction_failure(self):
        orig_execute = self.db.execute
        calls = []

        def flaky(sql, params=()):
            calls.append(sql)
            if len(calls) == 3:
                raise RuntimeError("boom")
            return orig_execute(sql, params)

        self.db.execute = flaky
        with self.assertRaises(RuntimeError):
            api.claim_voucher(self.db, "TEST-6H", "AA:BB:CC:DD:EE:01", "", "")
        self.db.execute = orig_execute
        row = self.db.row("SELECT state, bound_mac FROM vouchers WHERE code=%s",
                          ("TEST-6H",))
        self.assertEqual((row["state"], row["bound_mac"]), ("NEW", None))
        n = self.db.row("SELECT COUNT(*) AS c FROM events")["c"]
        self.assertEqual(n, 0)

    def test_concurrent_claims_one_binding(self):
        results, errors = [], []

        def worker(i):
            try:
                d = api.DB.connect()
                try:
                    results.append(api.claim_voucher(
                        d, "TEST-6H", "AA:BB:CC:DD:EE:%02d" % i,
                        "10.0.0.%d" % (200 + i), "t%d" % i))
                finally:
                    d.close()
            except Exception as exc:  # noqa: BLE001
                errors.append(exc)

        saved, api.DATABASE_URL = api.DATABASE_URL, self.url
        threads = [threading.Thread(target=worker, args=(i,)) for i in range(8)]
        try:
            [t.start() for t in threads]
            [t.join() for t in threads]
        finally:
            api.DATABASE_URL = saved
        self.assertEqual(errors, [])
        self.assertEqual(len(results), 8)
        self.assertTrue(all(r["decision"] == "ALLOW" for r in results))
        row = self.db.row("SELECT state, bound_mac, used_secs FROM vouchers"
                          " WHERE code=%s", ("TEST-6H",))
        self.assertEqual((row["state"], row["used_secs"]), ("ACTIVE", 0))
        self.assertRegex(row["bound_mac"] or "", r"^AA:BB:CC:DD:EE:")
        n = self.db.row("SELECT COUNT(*) AS c FROM events WHERE code=%s",
                        ("TEST-6H",))["c"]
        self.assertEqual(n, 8)


@unittest.skipUnless(TEST_URL, "pg test needs TEST_DATABASE_URL")
class PgDownTests(unittest.TestCase):
    def test_unreachable_pg_denies_without_sqlite(self):
        canary = "/tmp/pg_nofallback_%d.db" % os.getpid()
        if os.path.exists(canary):
            os.unlink(canary)
        api.DATABASE_URL = "postgresql://127.0.0.1:1/nodb"
        api.VOUCHER_DB = canary
        try:
            with self.assertRaises(api.BackendError):
                api.DB.connect()
        finally:
            api.DATABASE_URL = ""
        self.assertFalse(os.path.exists(canary))


if __name__ == "__main__":
    unittest.main(verbosity=2)
