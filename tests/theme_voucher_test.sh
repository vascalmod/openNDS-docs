#!/bin/sh
# tests/theme_voucher_test.sh — mock-render + gating tests for theme_voucher.sh
# Stubs library/transport/daemon calls; no network, no EAP.
# Run: sh tests/theme_voucher_test.sh
cd "$(dirname "$0")/.." || exit 1

PASS=0
FAIL=0

# Fixed clock: now=9912300000, stub session_end=9912345678 -> timer 12:41:18.
THEME="$PWD/theme_voucher.sh"
mkdir -p /tmp/ndscids
: > /tmp/ndscids/ndsinfo
PSKFILE=$(mktemp)
printf 'dummy-test-psk' > "$PSKFILE"
export VOUCHER_API_URL="http://test.invalid/claim"
export VOUCHER_PSK_FILE="$PSKFILE"

# Source the real ThemeSpec (top level only assigns vars; libopennds does the
# same via `. $themespecpath`). Stubs below stand in for library/daemon calls.
load_theme() { . "$THEME"; }

# uclient-fetch cannot be a shell function (hyphen illegal in dash), so stub
# it as an executable on PATH printing $FETCH_RESP (mirrors EAP behavior)
# and counting invocations in $FETCHCOUNT for no-pre-fetch assertions.
STUBBIN=$(mktemp -d)
printf '#!/bin/sh\nprintf "%%s" "$FETCH_RESP"\necho call >> "${FETCHCOUNT:-/dev/null}"\n' > "$STUBBIN/uclient-fetch"
chmod +x "$STUBBIN/uclient-fetch"
PATH="$STUBBIN:$PATH"
export PATH

setup_stubs() {
	encode_custom() { custom="Q1VTVE9N"; }
	auth_log() {
		printf '%s|%s|%s' "$session_length" "$upload_rate" "$download_rate" > "$CALLREC"
		ndsstatus="$AUTH_RESULT"
	}
	configure_log_location() { mountpoint="/tmp"; }
	logger() { printf '%s\n' "$*" >> "${DENYLOG:-/dev/null}"; }
	date() {
		case "$1" in
			+%s) printf '9912300000' ;;
			+*) printf '2026' ;;
			*) command date "$@" ;;
		esac
	}
	ndsctl() {
		case "$1" in
			json) printf '{"session_end": "9912345678"}' ;;
			b64decode) printf '%s' "$2" ;;
		esac
	}
}

# render_login renders the empty-voucher view (never authenticates).
render_login() {
	(
		load_theme
		setup_stubs
		fas="TESTFAS" voucher="" gatewayfqdn="status.client"
		gatewayname="TestGW" clientip="10.0.0.200" clientmac="AA:BB:CC:DD:EE:01"
		header
		voucher_login
	) 2>/dev/null
}

# render_flow <fetch-resp> <auth-result> [voucher]
# Caller owns $CALLREC (mktemp -u path, exported): the auth_log stub records
# quotas there, proving whether the auth call happened and with what policy.
render_flow() {
	(
		load_theme
		setup_stubs
		FETCH_RESP="$1"
		AUTH_RESULT="$2"
		export FETCH_RESP AUTH_RESULT
		fas="TESTFAS" voucher="${3:-TEST-6H}" gatewayfqdn="status.client"
		gatewayname="TestGW" clientip="10.0.0.200" clientmac="AA:BB:CC:DD:EE:01"
		header
		voucher_login
	) 2>/dev/null
}

check() {
	desc="$1"; cond="$2"
	if eval "$cond"; then
		PASS=$((PASS + 1)); echo "PASS: $desc"
	else
		FAIL=$((FAIL + 1)); echo "FAIL: $desc"
	fi
}

LOGIN_OUT=$(render_login)
STATUS_OUT=$(render_flow "ALLOW 21600 10240 10240" "authenticated")
DENIED_OUT=$(render_flow "DENY unknown" "authenticated")

# --- 1. login view unchanged ---
check "login-has-voucher-input" 'printf "%s" "$LOGIN_OUT" | grep -q "name=\"voucher\""'
check "login-has-connect" 'printf "%s" "$LOGIN_OUT" | grep -q "CONNECT"'
check "login-has-plan" 'printf "%s" "$LOGIN_OUT" | grep -q "6 HOURS"'
check "login-has-fas" 'printf "%s" "$LOGIN_OUT" | grep -q "name=\"fas\""'
check "login-no-thankyou" '! printf "%s" "$LOGIN_OUT" | grep -q "VOUCHER RECEIVED"'
check "login-no-status" '! printf "%s" "$LOGIN_OUT" | grep -q "CONNECTED"'
check "login-no-error-initially" '! printf "%s" "$LOGIN_OUT" | grep -q "<div class=\"form-error\""'
check "zone-preset-skips-probe" '( load_theme; [ "$client_zone" = "Wi-Fi" ] )'

# --- 2. CONNECT goes straight to custom status (no Continue tap) ---
check "status-connected" 'printf "%s" "$STATUS_OUT" | grep -q "CONNECTED"'
check "status-timer-12-41-18" 'printf "%s" "$STATUS_OUT" | grep -q "12:41:18"'
check "status-data-seconds" 'printf "%s" "$STATUS_OUT" | grep -q "data-remaining=\"45678\""'
check "status-countdown-script" 'printf "%s" "$STATUS_OUT" | grep -q "setInterval" && printf "%s" "$STATUS_OUT" | grep -q "data-remaining"'
check "status-nojs-fallback-intact" 'printf "%s" "$STATUS_OUT" | sed "s|<script>.*</script>||" | grep -q "12:41:18"'
check "status-shows-own-voucher-once" '[ "$(printf "%s" "$STATUS_OUT" | grep -o "TEST-6H" | wc -l)" -eq 1 ]'
check "status-speed" 'printf "%s" "$STATUS_OUT" | grep -q "10 Mbps"'
check "status-active" 'printf "%s" "$STATUS_OUT" | grep -q "Active"'
check "status-no-thankyou" '! printf "%s" "$STATUS_OUT" | grep -q "VOUCHER RECEIVED"'
check "status-no-landing-field" '! printf "%s" "$STATUS_OUT" | grep -q "landing"'
check "status-no-continue-to-landing" '! printf "%s" "$STATUS_OUT" | grep -q "value=\"Continue\""'

# --- 3. gating: auth call happens ONLY on backend ALLOW, with policy quotas ---
# (CALLREC owned outside each render: footer exits inside the subshell.)
ALLOW_CALLREC=$(mktemp)
ALLOW_CALL_OUT=$(export CALLREC="$ALLOW_CALLREC"; render_flow "ALLOW 21600 10240 10240" "authenticated" 2>/dev/null; printf 'CALL=%s' "$(cat "$ALLOW_CALLREC")"; rm -f "$ALLOW_CALLREC")
DENY_CALLREC=$(mktemp)
DENY_CALL_OUT=$(export CALLREC="$DENY_CALLREC"; render_flow "DENY unknown" "authenticated" 2>/dev/null; printf 'CALL=%s' "$(cat "$DENY_CALLREC")"; rm -f "$DENY_CALLREC")
FAILCALLREC=$(mktemp)
FAILCALL_OUT=$(export CALLREC="$FAILCALLREC"; render_flow "" "authenticated" 2>/dev/null; printf 'CALL=%s' "$(cat "$FAILCALLREC")"; rm -f "$FAILCALLREC")
check "allow-calls-auth-with-policy" 'printf "%s" "$ALLOW_CALL_OUT" | grep -q "CALL=360|10240|10240"'
check "deny-skips-auth-call" 'printf "%s" "$DENY_CALL_OUT" | grep -q "CALL=$"'
check "fetch-fail-skips-auth-call" 'printf "%s" "$FAILCALL_OUT" | grep -q "CALL=$"'
check "denied-invalid-title" 'printf "%s" "$DENIED_OUT" | grep -q "INVALID VOUCHER"'
check "denied-invalid-text" 'printf "%s" "$DENIED_OUT" | grep -q "not valid"'
check "denied-inline-error-block" 'printf "%s" "$DENIED_OUT" | grep -q "<div class=\"form-error\""'
check "denied-preserves-code" 'printf "%s" "$DENIED_OUT" | grep -q "value=\"TEST-6H\""'
check "denied-stays-login-form" 'printf "%s" "$DENIED_OUT" | grep -q "name=\"voucher\""'
check "denied-no-timer" '! printf "%s" "$DENIED_OUT" | grep -q "REMAINING"'

# --- 4. json outage degrades (CONNECTED, no fabricated timer) ---
NOJSON_OUT=$( (
	load_theme
	setup_stubs
	ndsctl() { printf ''; }
	FETCH_RESP="ALLOW 21600 10240 10240" AUTH_RESULT="authenticated"
	export FETCH_RESP AUTH_RESULT
	CALLREC=$(mktemp); export CALLREC
	fas="TESTFAS" voucher="TEST-6H" gatewayfqdn="status.client"
	gatewayname="TestGW" clientip="10.0.0.200" clientmac="AA:BB:CC:DD:EE:01"
	header
	voucher_login
) 2>/dev/null )
check "nojson-still-connected" 'printf "%s" "$NOJSON_OUT" | grep -q "CONNECTED"'
check "nojson-no-timer" '! printf "%s" "$NOJSON_OUT" | grep -q "REMAINING"'

# --- 5. CPD safety: inline CSS present, no JS/href leftovers ---
check "css-status-classes" 'printf "%s" "$STATUS_OUT" | grep -q "connection-status" && printf "%s" "$STATUS_OUT" | grep -q "timer-section" && printf "%s" "$STATUS_OUT" | grep -q "info-row"'
check "no-href" '! printf "%s" "$STATUS_OUT" | grep -qi "href"'
check "no-onclick" '! printf "%s" "$STATUS_OUT" | grep -qi "onclick"'
check "status-single-script" '[ "$(printf "%s" "$STATUS_OUT" | grep -o "<script>" | wc -l)" -eq 1 ]'

# --- 6. legacy paths hardened: landing requires voucher + ALLOW ---
# (CALLREC owned outside: landing_page ends in footer->exit, so the record is
# read after the subshell completes.)
LEGACY_OK_CALLREC=$(mktemp)
LEGACY_OK=$( (
	load_theme
	setup_stubs
	FETCH_RESP="ALLOW 21600 10240 10240" AUTH_RESULT="authenticated"
	export FETCH_RESP AUTH_RESULT
	CALLREC="$LEGACY_OK_CALLREC"; export CALLREC
	fas="TESTFAS" voucher="TEST-6H" landing="yes" gatewayfqdn="status.client"
	gatewayname="TestGW" clientip="10.0.0.200" clientmac="AA:BB:CC:DD:EE:01"
	landing_page
) 2>/dev/null )
LEGACY_OK="$LEGACY_OK CALL=$(cat "$LEGACY_OK_CALLREC")"; rm -f "$LEGACY_OK_CALLREC"
LEGACY_NOVOUCHER_CALLREC=$(mktemp)
LEGACY_NOVOUCHER=$( (
	load_theme
	setup_stubs
	FETCH_RESP="ALLOW 21600 10240 10240" AUTH_RESULT="authenticated"
	export FETCH_RESP AUTH_RESULT
	CALLREC="$LEGACY_NOVOUCHER_CALLREC"; export CALLREC
	fas="TESTFAS" voucher="" landing="yes" gatewayfqdn="status.client"
	gatewayname="TestGW" clientip="10.0.0.200" clientmac="AA:BB:CC:DD:EE:01"
	landing_page
) 2>/dev/null )
LEGACY_NOVOUCHER="$LEGACY_NOVOUCHER CALL=$(cat "$LEGACY_NOVOUCHER_CALLREC")"; rm -f "$LEGACY_NOVOUCHER_CALLREC"
LEGACY_DENY_CALLREC=$(mktemp)
LEGACY_DENY=$( (
	load_theme
	setup_stubs
	FETCH_RESP="DENY unknown" AUTH_RESULT="authenticated"
	export FETCH_RESP AUTH_RESULT
	CALLREC="$LEGACY_DENY_CALLREC"; export CALLREC
	fas="TESTFAS" voucher="TEST-6H" landing="yes" gatewayfqdn="status.client"
	gatewayname="TestGW" clientip="10.0.0.200" clientmac="AA:BB:CC:DD:EE:01"
	landing_page
) 2>/dev/null )
LEGACY_DENY="$LEGACY_DENY CALL=$(cat "$LEGACY_DENY_CALLREC")"; rm -f "$LEGACY_DENY_CALLREC"
check "legacy-allow-calls-auth" 'printf "%s" "$LEGACY_OK" | grep -q "CALL=360|10240|10240"'
check "legacy-allow-renders" 'printf "%s" "$LEGACY_OK" | grep -q "REQUEST SENT"'
check "legacy-no-voucher-skips-auth" 'printf "%s" "$LEGACY_NOVOUCHER" | grep -q "CALL=$"'
check "legacy-no-voucher-required" 'printf "%s" "$LEGACY_NOVOUCHER" | grep -q "VOUCHER REQUIRED"'
check "legacy-deny-skips-auth" 'printf "%s" "$LEGACY_DENY" | grep -q "CALL=$"'

# --- 7. reason-mapped errors (fixed vocabulary, anti-enumeration) ---
# helper: render a denied flow for a backend reason; sets DENYOUT/DENYLOGOUT
render_denied() {
	DENYLOG_F=$(mktemp); export DENYLOG_F
	DENYOUT=$( (
		load_theme
		setup_stubs
		FETCH_RESP="DENY $1" AUTH_RESULT="authenticated"
		export FETCH_RESP AUTH_RESULT
		DENYLOG="$DENYLOG_F"; export DENYLOG
		CALLREC=$(mktemp); export CALLREC
		fas="TESTFAS" voucher="TEST-6H" gatewayfqdn="status.client"
		gatewayname="TestGW" clientip="10.0.0.200" clientmac="AA:BB:CC:DD:EE:01"
		header
		voucher_login
	) 2>/dev/null )
	DENYLOGOUT=$(cat "$DENYLOG_F"); rm -f "$DENYLOG_F"
	export DENYOUT DENYLOGOUT
}
render_denied "expired"
check "expired-title" 'printf "%s" "$DENYOUT" | grep -q "VOUCHER EXPIRED"'
check "expired-text" 'printf "%s" "$DENYOUT" | grep -q "used up"'
check "expired-not-invalid" '! printf "%s" "$DENYOUT" | grep -q "not valid"'
check "expired-logged" 'printf "%s" "$DENYLOGOUT" | grep -q "why=expired"'
check "expired-inline-login" 'printf "%s" "$DENYOUT" | grep -q "name=\"voucher\""'
render_denied "paused"
check "paused-title" 'printf "%s" "$DENYOUT" | grep -q "VOUCHER IN USE"'
check "paused-text" 'printf "%s" "$DENYOUT" | grep -q "another device"'
check "paused-logged" 'printf "%s" "$DENYLOGOUT" | grep -q "why=paused"'
render_denied "invalid"
check "invalid-shares-text-with-unknown" 'printf "%s" "$DENYOUT" | grep -q "not valid"'
render_denied "disabled"
check "disabled-shares-text-with-unknown" 'printf "%s" "$DENYOUT" | grep -q "not valid"'
# Anti-oracle property, stated exactly: unknown / invalid / disabled render
# byte-identical pages (compare against a fresh unknown render).
UNKNOWNOUT=$( (
	load_theme
	setup_stubs
	FETCH_RESP="DENY unknown" AUTH_RESULT="authenticated"
	export FETCH_RESP AUTH_RESULT
	DENYLOG=/dev/null; export DENYLOG
	fas="TESTFAS" voucher="TEST-6H" gatewayfqdn="status.client"
	gatewayname="TestGW" clientip="10.0.0.200" clientmac="AA:BB:CC:DD:EE:01"
	header
	voucher_login
) 2>/dev/null )
check "disabled-identical-to-unknown" '[ "$DENYOUT" = "$UNKNOWNOUT" ]'
render_denied "mysterycode"
check "unknown-reason-falls-back-retry" 'printf "%s" "$DENYOUT" | grep -q "REQUEST FAILED"'
check "unknown-reason-no-leak" '! printf "%s" "$DENYOUT" | grep -qi "mysterycode"'
# malformed input never reaches the network
BADFMT_COUNT=$(mktemp); export FETCHCOUNT="$BADFMT_COUNT"
BADFMT_OUT=$( (
	load_theme
	setup_stubs
	FETCH_RESP="ALLOW 21600 10240 10240" AUTH_RESULT="authenticated"
	export FETCH_RESP AUTH_RESULT
	fas="TESTFAS" voucher="A;B" gatewayfqdn="status.client"
	gatewayname="TestGW" clientip="10.0.0.200" clientmac="AA:BB:CC:DD:EE:01"
	header
	voucher_login
) 2>/dev/null )
check "badformat-invalid-text" 'printf "%s" "$BADFMT_OUT" | grep -q "not valid"'
check "badformat-no-fetch" '[ ! -s "$BADFMT_COUNT" ]'
rm -f "$BADFMT_COUNT"; unset FETCHCOUNT

# --- 8. loading state: spinner + disabled + relabel, progressive only ---
check "login-loading-markup" 'printf "%s" "$LOGIN_OUT" | grep -q "onsubmit=\"return voucherSubmit(this)\"" && printf "%s" "$LOGIN_OUT" | grep -q "btn-spinner" && printf "%s" "$LOGIN_OUT" | grep -q "btn-text"'
check "login-loading-script" 'printf "%s" "$LOGIN_OUT" | grep -q "function voucherSubmit" && printf "%s" "$LOGIN_OUT" | grep -q "pageshow"'
check "login-loading-css" 'printf "%s" "$LOGIN_OUT" | grep -q "btn-spinner" && printf "%s" "$LOGIN_OUT" | grep -q "vspin" && printf "%s" "$LOGIN_OUT" | grep -q "button:disabled"'
check "denied-loading-markup" 'printf "%s" "$DENIED_OUT" | grep -q "btn-spinner"'
check "status-no-loading-needed" '! printf "%s" "$STATUS_OUT" | grep -q "voucherSubmit"'
THANKYOU_OUT=$( (
	load_theme
	setup_stubs
	ndsctl() { printf ''; }
	fas="TESTFAS" voucher="TEST-6H" custom="" gatewayfqdn="status.client"
	thankyou_page
) 2>/dev/null )
check "thankyou-loading-markup" 'printf "%s" "$THANKYOU_OUT" | grep -q "AUTHENTICATING" && printf "%s" "$THANKYOU_OUT" | grep -q "btn-spinner"'

# --- 9. inline scripts are real syntax (node --check when available) ---
if command -v node >/dev/null 2>&1; then
	printf '%s' "$STATUS_OUT $LOGIN_OUT $DENIED_OUT" | grep -o "<script>.*</script>" | sed "s|<script>||;s|</script>||" > /tmp/jsblocks.txt
	JSN=0; JSFAIL=0
	while IFS= read -r jsline; do
		[ -z "$jsline" ] && continue
		JSN=$((JSN + 1))
		printf '%s' "$jsline" > /tmp/jsblock.js
		node --check /tmp/jsblock.js 2>/dev/null || JSFAIL=$((JSFAIL + 1))
	done < /tmp/jsblocks.txt
	rm -f /tmp/jsblocks.txt /tmp/jsblock.js
	[ "$JSN" -ge 1 ] && [ "$JSFAIL" -eq 0 ]
	check "inline-js-syntax-ok" '[ "$JSN" -ge 1 ] && [ "$JSFAIL" -eq 0 ]'
else
	echo "SKIP: node absent, inline-js-syntax-ok not run"
fi

rm -f /tmp/ndscids/ndsinfo "$PSKFILE"
rm -rf "$STUBBIN"
echo "---- theme_voucher: PASS=$PASS FAIL=$FAIL ----"
[ "$FAIL" -eq 0 ]
