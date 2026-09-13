#!/bin/sh
# tests/client_params_voucher_test.sh — mock tests for client_params_voucher.sh
# Runs the real file as a subprocess with stubbed ndsctl/libopennds.sh/date.
# No network, no EAP. Run: sh tests/client_params_voucher_test.sh
cd "$(dirname "$0")/.." || exit 1

PASS=0
FAIL=0

FILE="$PWD/client_params_voucher.sh"
STUBBIN=$(mktemp -d)
mkdir -p /tmp/ndscids
printf 'gatewayname="TestGW"\nversion="10.3.1"\n' > /tmp/ndscids/ndsinfo

# Fixed clock: date +%s -> 9912300000. Authed fixture end 9912345678 (timer 12:41:18).
cat > "$STUBBIN/date" <<'EOF'
#!/bin/sh
case "$1" in
	+%s) printf '9912300000' ;;
	+*) printf '2026' ;;
	*) exec /bin/date "$@" ;;
esac
EOF
cat > "$STUBBIN/ndsctl" <<'EOF'
#!/bin/sh
if [ "$1" = "json" ]; then
	printf '%s' "$JSON_RESP"
elif [ "$1" = "b64decode" ]; then
	printf '%s' "$2" | base64 -d 2>/dev/null
else
	exit 1
fi
EOF
cat > "$STUBBIN/libopennds.sh" <<'EOF'
#!/bin/sh
if [ "$1" = "tmpfs" ]; then
	printf '/tmp'
fi
exit 0
EOF
chmod +x "$STUBBIN/date" "$STUBBIN/ndsctl" "$STUBBIN/libopennds.sh"

# run_status <json-variant> : prints page stdout. Caller sets JSON_RESP.
run_status() {
	JSON_RESP="$1"
	export JSON_RESP
	PATH="$STUBBIN:$PATH" sh "$FILE" status 10.0.0.200 "" 2>/dev/null
}

check() {
	desc="$1"; cond="$2"
	if eval "$cond"; then
		PASS=$((PASS + 1)); echo "PASS: $desc"
	else
		FAIL=$((FAIL + 1)); echo "FAIL: $desc"
	fi
}

# NOTE: fixtures MUST be pretty-printed one-param-per-line, exactly like real
# `ndsctl json` output: the stock parser takes awk $4 of the matched line, so
# single-line JSON would parse every param as the first value (even in stock).
mkjson() {
	# $1 state, $2 session_end raw (already quoted or null), $3 custom raw
	printf '{\n"gatewayname": "TestGW",\n"gatewayaddress": "10.0.0.1",\n"gatewayfqdn": "status.client",\n"mac": "AA:BB:CC:DD:EE:01",\n"version": "10.3.1",\n"ip": "10.0.0.200",\n"client_type": "cpd",\n"clientif": "br-lan",\n"session_start": "0",\n"session_end": %s,\n"last_active": "9912300000",\n"token": "tok",\n"state": "%s",\n"custom": %s\n}' "$2" "$1" "$3"
}
PREAUTH_JSON=$(mkjson "Preauthenticated" "null" "null")
AUTHED_JSON=$(mkjson "Authenticated" '"9912345678"' '"dm91Y2hlcj1URVNULTZI"')
EXPIRED_JSON=$(mkjson "Authenticated" '"9912299990"' '"dm91Y2hlcj1URVNULTZI"')
NOCUSTOM_JSON=$(mkjson "Authenticated" '"9912345678"' "null")
BADCUSTOM_JSON=$(mkjson "Authenticated" '"9912345678"' '"aGVsbG8="')

PREAUTH_OUT=$(run_status "$PREAUTH_JSON")
AUTHED_OUT=$(run_status "$AUTHED_JSON")
EXPIRED_OUT=$(run_status "$EXPIRED_JSON")
FAIL_OUT=$(run_status "")
NOCUSTOM_OUT=$(run_status "$NOCUSTOM_JSON")
BADCUSTOM_OUT=$(run_status "$BADCUSTOM_JSON")

# --- 1. preauth -> auto-forward, zero clicks, no stock dump ---
# Painted loading state navigates on window load; meta + button survive.
check "forward-meta-refresh" 'printf "%s" "$PREAUTH_OUT" | grep "refresh" | grep -q "url=http://status.client/login"'
check "forward-fallback-form" 'printf "%s" "$PREAUTH_OUT" | grep -q "action=\"http://status.client/login\""'
check "forward-loading-state" 'printf "%s" "$PREAUTH_OUT" | grep -q "CREATING SESSION" && printf "%s" "$PREAUTH_OUT" | grep -q "load-spinner"'
check "forward-load-navigation" 'printf "%s" "$PREAUTH_OUT" | grep -q "addEventListener"'
check "forward-light-bg" 'printf "%s" "$PREAUTH_OUT" | grep -q "color-scheme"'
check "forward-brand" 'printf "%s" "$PREAUTH_OUT" | grep -q "WI-FI E-VOUCHER"'
check "forward-no-session-status" '! printf "%s" "$PREAUTH_OUT" | grep -q "Session Status"'
check "forward-no-account-dump" '! printf "%s" "$PREAUTH_OUT" | grep -q "MAC address"'
check "forward-no-voucher-form" '! printf "%s" "$PREAUTH_OUT" | grep -q "name=\"voucher\""'

# --- 2. authenticated -> custom status, never stock dump ---
check "status-connected" 'printf "%s" "$AUTHED_OUT" | grep -q "CONNECTED"'
check "status-timer" 'printf "%s" "$AUTHED_OUT" | grep -q "12:41:18"'
check "status-data-seconds" 'printf "%s" "$AUTHED_OUT" | grep -q "data-remaining=\"45678\""'
check "status-countdown-script" 'printf "%s" "$AUTHED_OUT" | grep -q "setInterval"'
check "status-nojs-fallback-intact" 'printf "%s" "$AUTHED_OUT" | sed "s|<script>.*</script>||" | grep -q "12:41:18"'
check "status-voucher-once" '[ "$(printf "%s" "$AUTHED_OUT" | grep -o "TEST-6H" | wc -l)" -eq 1 ]'
check "status-logout-kept" 'printf "%s" "$AUTHED_OUT" | grep -q "action=\"http://status.client/opennds_deny/\""'
check "status-no-session-status" '! printf "%s" "$AUTHED_OUT" | grep -q "Session Status"'
check "status-no-account-dump" '! printf "%s" "$AUTHED_OUT" | grep -q "Average Download"'

# --- 3. expired -> forward, not authed UI ---
check "expired-forwards" 'printf "%s" "$EXPIRED_OUT" | grep -q "url=http://status.client/login"'
check "expired-no-connected" '! printf "%s" "$EXPIRED_OUT" | grep -q "CONNECTED"'

# --- 4. json failure -> forward (fail-closed to login, never stock dump) ---
# (host varies when json yields nothing; mechanism, not host, is asserted)
check "jsonfail-forwards" 'printf "%s" "$FAIL_OUT" | grep -q "url=.*/login"'
check "jsonfail-no-session-status" '! printf "%s" "$FAIL_OUT" | grep -q "Session Status"'

# --- 5. missing/non-voucher custom -> still CONNECTED, code blanked ---
check "nocustom-connected" 'printf "%s" "$NOCUSTOM_OUT" | grep -q "CONNECTED"'
check "nocustom-no-code" '! printf "%s" "$NOCUSTOM_OUT" | grep -q "TEST-6H"'
check "badcustom-connected" 'printf "%s" "$BADCUSTOM_OUT" | grep -q "CONNECTED"'
check "badcustom-no-hello" '! printf "%s" "$BADCUSTOM_OUT" | grep -q "hello"'

# --- 6. stock code provably preserved where kept; old entry pages gone ---
# err511 needs absolute EAP paths so its full render cannot execute locally;
# instead: (a) every KEPT stock region is verbatim, (b) the old entry pages
# are provably absent, (c) dispatch routes err511 to the tested forward page.
# Live EAP deploy exercises the real err511 render via CPD traffic.
STOCK="opennds/client_params.sh"
FORK="client_params_voucher.sh"
sed 's/[[:space:]]*$//' "$FORK" > /tmp/got.txt
: > /tmp/want.txt
stock_range() { sed -n "$1,$2p" "$STOCK" | sed 's/[[:space:]]*$//' | grep -v '^[[:space:]]*$' >> /tmp/want.txt; }
stock_range 9 29
stock_range 31 51
stock_range 53 70
stock_range 73 92
stock_range 94 102
stock_range 107 144
stock_range 146 171
stock_range 173 191
stock_range 194 201
stock_range 289 315
MISSING=$(grep -v -F -x -f /tmp/got.txt /tmp/want.txt | head -5)
check "stock-regions-verbatim" '[ -z "$MISSING" ]'
check "custom-in-allowlist" 'grep -q "token state custom upload_rate_limit_threshold" "$FORK"'
check "old-entry-pages-gone" '! grep -q "To login, click or tap" "$FORK"'
check "no-stock-dump" '! grep -q "Average Download" "$FORK"'
check "err511-dispatches-forward" 'grep -A10 "\"\$status\" = \"err511\"" "$FORK" | grep -q "voucher_forward_page"'
rm -f /tmp/want.txt /tmp/got.txt

# --- 7. busy preserved ---
BUSY_OUT=$(PATH="$STUBBIN:$PATH" JSON_RESP="locked" sh "$FILE" status 10.0.0.200 "" 2>/dev/null)
check "busy-page" 'printf "%s" "$BUSY_OUT" | grep -qi "busy"'

# --- 8. navigation layering: instant JS + meta fallback, nothing else ---
check "forward-instant-nav" 'printf "%s" "$PREAUTH_OUT" | grep -q "location.replace"'
check "forward-single-script" '[ "$(printf "%s" "$PREAUTH_OUT" | grep -o "<script>" | wc -l)" -eq 1 ]'
check "forward-meta-fallback" 'printf "%s" "$PREAUTH_OUT" | grep "refresh" | grep -q "url=http://status.client/login"'
check "forward-no-href" '! printf "%s" "$PREAUTH_OUT" | grep -qi "href"'
check "status-no-href" '! printf "%s" "$AUTHED_OUT" | grep -qi "href"'
check "status-single-script" '[ "$(printf "%s" "$AUTHED_OUT" | grep -o "<script>" | wc -l)" -eq 1 ]'
check "status-inline-css" 'printf "%s" "$AUTHED_OUT" | grep -q "connection-status"'

# --- 9. inline scripts are real syntax (node --check when available) ---
# Forward page now legitimately carries one script (load-time navigation),
# so the check counts scripts per page instead of assuming absence.
if command -v node >/dev/null 2>&1; then
	printf '%s' "$AUTHED_OUT $PREAUTH_OUT" | grep -o "<script>.*</script>" | sed "s|<script>||;s|</script>||" > /tmp/jsblocks.txt
	JSN=0; JSFAIL=0
	while IFS= read -r jsline; do
		[ -z "$jsline" ] && continue
		JSN=$((JSN + 1))
		printf '%s' "$jsline" > /tmp/jsblock.js
		node --check /tmp/jsblock.js 2>/dev/null || JSFAIL=$((JSFAIL + 1))
	done < /tmp/jsblocks.txt
	rm -f /tmp/jsblocks.txt /tmp/jsblock.js
	check "inline-js-syntax-ok" '[ "$JSN" -ge 1 ] && [ "$JSFAIL" -eq 0 ]'
else
	echo "SKIP: node absent, inline-js-syntax-ok not run"
fi

rm -rf "$STUBBIN" /tmp/ndscids/ndsinfo
echo "---- client_params_voucher: PASS=$PASS FAIL=$FAIL ----"
[ "$FAIL" -eq 0 ]
