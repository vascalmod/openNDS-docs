# STAGE 2C — Production BinAuth Integration (final record)

> Verdict: **STAGE 2C — BACKEND PASS, PRODUCTION-GATE OPEN (not a clean PASS).**
> Phases A–I proven with evidence below. J/K + one production anomaly need
> answers before the PASS stamp. No implementation changed in Phase L.
> Nothing deployed beyond the recorded state. No Stage 3.

## 1. Deployed state (recorded, read-only)

| Item | Value |
|---|---|
| EAP | TP-Link EAP225-Outdoor V3, OpenWrt, openNDS 10.3.1, `br-lan`, MHD `10.0.0.1:2050` |
| theme_voucher.sh (EAP) | `6b2121e2…ebba5c4` — MATCHES frozen Stage 1 hash |
| custombinauth.sh (EAP) | `50b15ed3…7ea92d` — MATCHES tested source (`root:root 755`) |
| binauth_log.sh (EAP) | `52212f73…14a8ce4` — stock, intact |
| client_params.sh (EAP) | `85e73b01…ed368e9f32` — stock, intact |
| libopennds.sh (EAP) | `5909844b…618ff1896` — stock, intact |
| Backup | `/usr/lib/opennds/custombinauth.sh.bak-20260913-013501` (449 B stub, `16e4ff0b…`) |
| UCI delta vs Stage 1 | ONE addition: `voucher_api_url='http://192.168.100.49:8080/claim'`; `login_option_enabled=3`, `themespec_path`, faskey untouched |
| PSK file | `/etc/opennds/voucher_psk`, `root:root 600`, 64 B, hash-verified vs production |
| API route used | EAP → wired `192.168.100.49:8080` (NOT Wi-Fi `.107`: Ubuntu `wlo1` is itself a captive client `e8:6f:38:c4:5f:d9`, and openNDS filters EAP→preauth-client traffic) |
| openNDS health | running, MHD listening, BinAuth = stock `binauth_log.sh` |

## 2. Phase results A–I (all PASS, evidence on file)

* A: status/UCI/scripts/checksums recorded; BinAuth default path confirmed.
* B: theme hash `6b2121e2…` verified on-EAP before deploy.
* C: timestamped stub backup, hashes + perms recorded.
* D/E: `scp` unavailable (no sftp-server) → pushed over `ssh cat`; perms reset to stock `755`; deployed sha == source sha; EAP `sh -n` clean.
* F/G: no `PORTAL-TEST`/debug in deployed file; UCI URL set+committed; reload clean (daemon uptime continuous, no restart needed — script is sourced per-event).
* Live defects found+fixed (both proven in production conditions):
  1. **Chunked POST** — EAP `uclient-fetch` sends `--post-data` as `Transfer-Encoding: chunked` with no `Content-Length`; server read empty body → every claim denied. Fixed server-side (`_read_body`, bounded de-chunking) + 2 regression tests. No EAP/protocol change.
  2. **`rev: not found`** — busybox lacks `rev` (masked-logging only, non-fatal). POSIX `cut` range + static busybox-tool gate in harness.
* I-1 ALLOW `360/10240/10240` exit 0 · I-2 unknown DENY exit 1 · I-3 same-MAC rerequest ALLOW (`rerequest` audit, no rebind) · I-4 new-MAC rebind ALLOW + `rebound` audit, binding moved · I-5 API-down DENY + full recovery ALLOW. Backend rows/events verified after each step.
* Guard: manifest + scope + accrual + ndsctl-surface all PASS (local + EAP hashes agree).

## 3. OPEN — production grant outside the voucher path (blocks clean PASS)

At ~01:53 EAP time a real randomized-MAC client (`32:09:8a:5d:13:11`, `cpi_url`,
i.e. browser-driven portal flow) became **Authenticated carrying
`custom=voucher=PORTAL-TEST2`**, session = global defaults (**24 h, null rate
limits** — NOT our `360/10240` policy), ~52 MB flowing.

Why this is NOT our voucher path:
* `PORTAL-TEST2` exists NOWHERE in PostgreSQL (no row, no ALLOW, and not even a
  `DENY unknown` event — a BinAuth `auth_client` deny would have written one).
* `binauthlog.log` holds NO `auth_client` entry for this MAC at 01:53 (only an
  earlier 01:47 `ndsctl_auth` with `PORTAL-TEST` and a 01:49 `client_deauth`).
* openNDS log shows a bare `Authenticating …` at 01:53:06 with no BinAuth
  involvement; preemptive-auth queue dir is empty and no preemptivemac/trust
  lists exist in UCI — mechanism unconfirmed, possibly operator-driven
  (`ndsctl` works from shell) or an openNDS auto-path this project has not
  characterized.

Consequences:
* J/K cannot be marked from this observation: Internet works on the device, but
  NOT demonstrably through voucher validation (acceptance #9–#12, #15–#16 open).
* Related finding: our script passes `ndsctl_auth`-method calls through with
  default ALLOW (only `auth_client` is gated). That is local-shell-only attack
  surface, but it is a fail-open worth an explicit policy decision — NOT changed
  here (would risk breaking preemptive/authmon flows).

Questions for the operator (answers unblock PASS):
1. Was the 01:47 `ndsctl_auth` (PORTAL-TEST) and the 01:53 activity (PORTAL-TEST2)
   your manual testing? If yes, J/K procedure should be re-run cleanly with
   PORTAL-TEST and backend events checked per step.
2. Is preemptive/auto-auth behavior on this EAP acceptable during Stage 2C, or
   must unknown devices stay fully captive until a voucher ALLOW?
3. Policy for `ndsctl_auth` method in `custombinauth`: keep passthrough (admin
   tool stays working) or deny-by-default?

## 4. Rollback procedure (ready, tested path — NOT executed)

```sh
# on the EAP (root):
cp -p /usr/lib/opennds/custombinauth.sh.bak-20260913-013501 /usr/lib/opennds/custombinauth.sh
chmod 755 /usr/lib/opennds/custombinauth.sh
chown root:root /usr/lib/opennds/custombinauth.sh
uci delete opennds.@opennds[0].voucher_api_url
uci commit opennds
rm -f /etc/opennds/voucher_psk
sh -n /usr/lib/opennds/custombinauth.sh && sha256sum /usr/lib/opennds/custombinauth.sh
# expect 16e4ff0b… (stock stub); then:
/etc/init.d/opennds reload
ndsctl status   # expect healthy, BinAuth = binauth_log.sh
# verify: Stage 1 portal renders; voucher login returns to stub behavior
# (allow-by-default); keep backup file in place, do NOT delete it.
```

Effect: stock stub restored (open allow), URL option removed, PSK material gone
from EAP, no other file touched. Ubuntu API/PostgreSQL need no changes (idle).

## 5. Files/config changed (complete list)

* EAP: `/usr/lib/opennds/custombinauth.sh` (stub→`50b15ed3…`), +1 UCI option
  (`voucher_api_url`), +1 backup file, +1 PSK file (`600`). NOTHING else.
* Repo (uncommitted — held pending J/K + anomaly resolution): chunked-body fix
  + tests, `rev` fix + portability gate, this file. No EAP/stage-1 files differ
  from their recorded hashes.

## 6. Acceptance checklist (honest marks)

1. Theme hash unchanged — YES (`6b2121e2…`).
2. UCI intact except required BinAuth setting — YES.
3. `binauth_log.sh` intact — YES.
4. Tested script deployed — YES (`50b15ed3…` both sides).
5. Checksums match — YES.
6. Permissions correct — YES (`root:root 755`, PSK `600`).
7. API reachable — YES (wired path; Wi-Fi `.107` unusable by design, documented).
8. PostgreSQL reachable — YES.
9. Known voucher ALLOW — YES (direct BinAuth proof).
10. Unknown DENY — YES.
11. Same-MAC correct — YES (`rerequest`, no rebind).
12. Rebind correct — YES (`rebound` + binding moved).
13. Outage DENY — YES (live).
14. Recovery ALLOW — YES (live).
15. Android CPD — OPEN (see §3).
16. Chrome — OPEN (see §3).
17. No secrets exposed — YES (hash-compare + redacted transport only).
18. No Stage 1 modified — YES.
19. No Stage 3 introduced — YES.
20. Rollback ready — YES (§4, backup verified present).

## 7. Post-report fix: close the non-`auth_client` grant path (LOCAL ONLY)

Trigger: production showed a 24 h/default-limits grant carrying
`voucher=PORTAL-TEST2` with zero backend events and zero BinAuth involvement —
operator-confirmed manual `ndsctl` testing, but a real fail-open class:
`custombinauth` validated ONLY `auth_client`; every other method fell through
with parent allow-defaults.

Fix (`custombinauth.voucher.sh`, local sha `cd15b276…`, NOT yet deployed):
shared `vbackend_claim()` for all paths; `*deauth` still pure passthrough;
any other method carrying a `voucher=` claim is fully validated (neutral
metadata: strict-or-empty MAC, empty ip/token — slots unreliable there);
absent claim → abstain with defaults untouched; malformed claim → deny;
secondary methods confirm-or-deny only (stranger-owned EVICT → abstain,
defaults restored; only `auth_client` may rebind). Syslog now tags
`method=` for forensics.

Proof locally: harness 41/41 (33 legacy UNCHANGED — `auth_client` behavior
identical — + 8 method cases incl. abstain), `test_api` 11/11, `test_pg` 6/6,
`test_server` 5/5, guard PASS (manifest + scope + accrual + ndsctl-surface).

Blocked deploy: EAP `10.0.0.1` stopped answering L3 (ARP REACHABLE, Wi-Fi
associated, zero ping/SSH) during rollout — backup of deployed `50b15ed3…`
NOT yet taken, fix NOT pushed, live re-verify NOT run. Per stop rules all
EAP work halted; no improvisation. Resume with: backup → push → hash →
T1/T2 + `ndsctl_auth`-method live cases → clean J/K with PORTAL-TEST.

## 8. Recovery + production close-out (EAP returned, fix deployed + proven)

Root cause of the 24 h ghost CONFIRMED: deployed `binauth_log.sh` was
byte-identical to the `custombinauth` snippet (`cd15b276…`) — no `$action`,
no `$custom`, no defaults, no quota echo — so every BinAuth call abstained
into daemon defaults (24 h, unlimited, allow). Remediation in order:
R1 restored stock `binauth_log.sh` from hash-verified backup (`52212f73…`,
`sh -n` clean); R2 timestamp-backed-up superseded `custombinauth.sh`
(`50b15ed3…` kept) and deployed tested `cd15b276…` at the correct slot
(hash match both sides, `sh -n` clean, no daemon restart — scripts exec
per event).

Live on-EAP proof (direct BinAuth invocations + backend rows checked):
T1 PORTAL-TEST ALLOW `360/10240/10240` exit 0 · T2 unknown DENY exit 1 ·
N1 `ndsctl_auth`+valid voucher → ALLOW quotas exit 0 · N2 `ndsctl_auth`+
unknown → DENY exit 1 (the PORTAL-TEST2 hole class, closed at script level) ·
N3 no-custom → passthrough defaults exit 0 (preemptive/admin preserved).
EAP syslog shows `method=auth`/`method=auth_client` decisions with masked
vouchers; backend audit rows match every run. Stale PORTAL-TEST2 session
deauthenticated and gone from the client list.

Positional mapping (§14 verdict): header layout (`$2/$5/$6/$7`) KEPT — the
docs variant belongs to a username/password login mode this deployment does
not run, the vendor ships that header with this daemon, and strict gates fail
closed on mismatch. Empirical gate stands: first J/K portal auth must show
backend event mac/ip/token equal to `ndsctl`-known values, else STOP.

OPEN: clean J/K device runs with PORTAL-TEST + positional proof; then stamp
PASS and commit (implementation + this record held uncommitted until then).

## 9. Direct-to-status portal flow (LOCAL ONLY, undeployed)

Request: after CONNECT, authenticate immediately and render the custom status
UI — no intermediate Continue tap (CPD-friendly). Change is ThemeSpec-only
(`theme_voucher.sh` → new sha recorded in `tests/stage1_manifest.sha256`;
core openNDS files untouched):
ENFORCEMENT REDESIGN (daemon honors request quotas, may skip BinAuth on the
FAS path — proven by debug-trace forensics): new `voucher_api_claim()`
pre-validates through the backend BEFORE any auth call and rebuilds `$quotas`
from the response; `voucher_status_page()` and legacy `landing_page()` (now
also presence-gated + re-encoded) call `auth_log` ONLY on ALLOW with explicit
policy quotas, else render generic fail with NO grant possible (fail closed by
omission). Legacy thankyou/landing kept as hardened fallback.

Proof locally: `tests/theme_voucher_test.sh` 31/31 (login unchanged, direct
status with deterministic timer, voucher shown once, ALLOW→auth-called with
`360|10240|10240`, DENY/fetch-fail→auth SKIPPED, legacy landing gated on
voucher+ALLOW, CPD-safety scans) + full regression (`custombinauth` 41/41,
guard PASS, `test_api` 11/11, `test_pg` 6/6, `test_server` 5/5). EAP deploy
(backup → push → hash → live device re-verify incl. unknown-voucher portal
proof) is a separate approved step, not done here.

## 10. Live portal proof via wlo1 curl FAS flow (no device needed)

Driven end-to-end through captive redirect → preauth → voucher submit:
* Unknown (`NOPE-PORTAL`) → `REQUEST FAILED`, client held preauth (no session),
  backend `DENY unknown` with true client MAC/IP (positional mapping proven).
* Valid (`TEST-PORTAL`, seeded NEW for the test) → `CONNECTED` + `05:59:58`
  timer + own code shown once, backend `ALLOW fresh 21600`, daemon session
  exactly 6h00m with `10240/10240` thresholds. Test client deauthed after;
  daemon debug reset 1. `TEST-PORTAL` row remains (labeled test artifact).

## 11. Deferred (explicitly not this stage)

* Upload-rate calibration (`UP_KBPS` reverted to documented 10240 after an
  unproven 3500 probe; downlink shaping verified at 9.98/10, uplink needs a
  controlled retest).
* 5 GHz preference/band steering (client camped 2.4G HT20 while 5G VHT80 up;
  Wi-Fi config frozen).
* EAP briefly unreachable twice (link/ARP up, L3 silent, self-recovered) —
  cause undetermined, watch item, no config changed for it.
