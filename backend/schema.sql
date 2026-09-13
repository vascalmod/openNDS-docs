-- Stage 2 voucher schema (PostgreSQL = production).
-- One database, one validation function for BOTH Android CPD and Chrome.
-- Pause-ready columns (used_secs, resume_ts, PAUSED state) exist now but only
-- accrue in Stage 3. Stage 2 performs initial authorization only.
-- Local API tests run the same DDL on SQLite (see backend/api.py); types below
-- are the production contract.

CREATE TABLE IF NOT EXISTS vouchers (
    code         TEXT PRIMARY KEY,          -- normalized: UPPER, A-Z0-9-, 4..20 chars
    total_secs   INTEGER NOT NULL DEFAULT 21600,  -- 6 hours plan
    used_secs    INTEGER NOT NULL DEFAULT 0,      -- Stage 3 accrues on deauth
    state        TEXT NOT NULL DEFAULT 'NEW'
                     CHECK (state IN ('NEW','ACTIVE','PAUSED','EXPIRED','DISABLED')),
    bound_mac    TEXT,                      -- transient metadata, NEVER identity
    last_ip      TEXT,
    last_token   TEXT,
    first_seen   TIMESTAMPTZ,
    last_auth    TIMESTAMPTZ,
    resume_ts    TIMESTAMPTZ,               -- Stage 3 pause accounting anchor
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS events (
    id             BIGSERIAL PRIMARY KEY,
    code           TEXT NOT NULL,
    mac            TEXT,
    ip             TEXT,
    token          TEXT,
    decision       TEXT NOT NULL,           -- ALLOW / DENY
    reason         TEXT NOT NULL,           -- invalid/unknown/expired/disabled/paused/
                                           -- rebound/fresh/rerequest/backend_deny...
    remaining_secs INTEGER,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_events_code ON events (code);
CREATE INDEX IF NOT EXISTS idx_events_created ON events (created_at);
