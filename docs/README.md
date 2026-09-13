# OpenNDS voucher portal — static inspection report (index)

Source of truth: local copies under `~/portal_eap/opennds/` taken from EAP225-Outdoor V3.
Do NOT assume upstream parity.

Target: OpenWrt 25.12.x, openNDS 10.3.1-r3, 128 MB RAM / 16 MB flash,
gateway `10.0.0.1`, `gatewayfqdn=status.client`, MHD `:2050`, LuCI `:80`.

UI mockups (design source only, not served raw):

* `index.html:22-39` — `<form class="voucher-form">` has no `action`, no `method`, no `fas` hidden field, input `name="voucher"`.
* `index.html:7`, `status.html:7` — external `<link rel="stylesheet" href="index.css">`.
* `index.css:1` — literal ```` ```css ```` fence. Invalid CSS if served raw.
* `status.html:30-32,40,55` — hardcoded `05:42:17`, `ABCD-1234`, `<button type="button">PAUSE</button>` with no form/action.

These must be adapted into ThemeSpec-generated HTML (see `01-execution-flow.md`, `05-entrypoint-cpd-filemap.md`).

## File map

* `01-execution-flow.md` — Q1 exact HTTP → ThemeSpec → auth → BinAuth flow.
* `02-variables-binauth-voucher.md` — Q2 variables to ThemeSpec, Q3 BinAuth args, Q4 voucher passing via `encode_custom()`.
* `03-status-pause-resume.md` — Q5 status generation, Q6 `ndsctl auth/deauth/json` for PAUSE/RESUME.
* `04-persistence-identity-accounting.md` — Q7 survives reconnect, Q8 voucher-without-permanent-MAC, Q9 randomized MAC, Q10 6-hour usage accounting, Q11 status access while paused.
* `05-entrypoint-cpd-filemap.md` — Q12 single entry `10.0.0.1`, Q13 CSS/JS in CPD, Q14 which file to extend, Q15 minimum new files, Q16 final layout.
* `06-security-constraints-bugs.md` — Q17 injection risks, Q18 flash/RAM, Q19 bugs/assumptions.
* `07-plan-tests.md` — A-E: known, unknown, architecture, files, EAP tests.

No implementation code. No file modifications. No config changes yet.
