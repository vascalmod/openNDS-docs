#!/bin/sh
# tests/custombinauth_test.sh — local harness for custombinauth.voucher.sh
# Stubs ndsctl/uclient-fetch/logger/daemon-hook; no network, no EAP, no secrets.
# Run: sh tests/custombinauth_test.sh
cd "$(dirname "$0")/.." || exit 1

PASS=0
FAIL=0
STUB_RESP=""
EVICT_LOG=""

STUBBIN=$(mktemp -d)
CALLFILE=$(mktemp)
RESPFILE=$(mktemp)
printf '#!/bin/sh\necho call >> "$CALLFILE"\ncat "$RESPFILE"\n' > "$STUBBIN/uclient-fetch"
chmod +x "$STUBBIN/uclient-fetch"
PATH="$STUBBIN:$PATH"
export CALLFILE RESPFILE
fetch_calls() { wc -l < "$CALLFILE" | tr -d ' '; }

ndsctl() {
	# only verb the script may use: b64decode <b64>
	if [ "$1" = "b64decode" ]; then
		printf '%s' "$2" | base64 -d 2>/dev/null
	fi
}
logger() { :; }

HOOK="$PWD/tests/stub_libopennds.sh"
printf '#!/bin/sh\necho "$@" >> "$EVICT_FILE"\n' > "$HOOK"
chmod +x "$HOOK"

b64() { printf '%s' "$1" | base64 2>/dev/null | tr -d '\n'; }

PSKFILE=$(mktemp)
printf 'dummy-psk' > "$PSKFILE"
export VOUCHER_API_URL="http://test.invalid/claim"
export VOUCHER_PSK_FILE="$PSKFILE"
export VOUCHER_TIMEOUT=5
export VOUCHER_LIBOPENDS="$HOOK"
export EVICT_FILE=$(mktemp)

# run_case <name> <action> <mac> <ip> <token> <custom-plain> <stub-resp> <want-exit> [want-sess]
run_case() {
	name="$1"; action="$2"; mac="$3"; ip="$4"; token="$5"; plain="$6"
	STUB_RESP="$7"; want_exit="$8"; want_sess="$9"
	printf '%s' "$STUB_RESP" > "$RESPFILE"
	: > "$CALLFILE"
	: > "$EVICT_FILE"
	(
		action="$action"
		custom=$(b64 "$plain")
		session_length=0; upload_rate=0; download_rate=0
		upload_quota=0; download_quota=0; exitlevel=0
		set -- "$action" "$mac" "redir" "ua" "$ip" "$token" "$custom"
		. "$PWD/custombinauth.voucher.sh"
		echo "$exitlevel|$session_length|$upload_rate|$download_rate"
	) > /tmp/cb_out.txt
	got=$(cat /tmp/cb_out.txt)
	got_exit=$(printf '%s' "$got" | cut -d'|' -f1)
	got_sess=$(printf '%s' "$got" | cut -d'|' -f2)
	if [ "$got_exit" = "$want_exit" ] && { [ -z "$want_sess" ] || [ "$got_sess" = "$want_sess" ]; }; then
		PASS=$((PASS + 1)); echo "PASS: $name (exit=$got_exit sess=$got_sess calls=$(fetch_calls))"
	else
		FAIL=$((FAIL + 1)); echo "FAIL: $name got=[$got] want_exit=$want_exit want_sess=$want_sess"
	fi
}

run_case "allow-fresh" auth_client AA:BB:CC:DD:EE:01 10.0.0.200 tok1 \
	"voucher=TEST-6H" "ALLOW 21600 10240 10240" 0 360
run_case "deny-unknown" auth_client AA:BB:CC:DD:EE:01 10.0.0.200 tok1 \
	"voucher=NOPE-1234" "DENY unknown" 1 0
run_case "deny-bad-charset" auth_client AA:BB:CC:DD:EE:01 10.0.0.200 tok1 \
	"voucher=A;B" "" 1 0
run_case "deny-entity-smuggle" auth_client AA:BB:CC:DD:EE:01 10.0.0.200 tok1 \
	"voucher=A&#59;B" "" 1 0
run_case "deny-backend-down" auth_client AA:BB:CC:DD:EE:01 10.0.0.200 tok1 \
	"voucher=TEST-6H" "" 1 0
run_case "deny-bad-reply" auth_client AA:BB:CC:DD:EE:01 10.0.0.200 tok1 \
	"voucher=TEST-6H" "ALLOW lots fast faster" 1 0
run_case "ceil-21601-to-361" auth_client AA:BB:CC:DD:EE:01 10.0.0.200 tok1 \
	"voucher=TEST-6H" "ALLOW 21601 10240 10240" 0 361
run_case "deauth-passthrough" deauth AA:BB:CC:DD:EE:01 10.0.0.200 tok1 \
	"voucher=TEST-6H" "" 0 0
run_case "lowercase-normalized" auth_client AA:BB:CC:DD:EE:01 10.0.0.200 tok1 \
	"voucher=test-6h" "ALLOW 21600 10240 10240" 0 360

# evict hook: different old MAC must be passed to daemon_deauth exactly once
: > "$EVICT_FILE"
printf '%s' "ALLOW 18000 10240 10240 EVICT AA:BB:CC:DD:EE:09" > "$RESPFILE"
(
	action="auth_client"
	custom=$(b64 "voucher=TEST-6H")
	session_length=0; upload_rate=0; download_rate=0
	upload_quota=0; download_quota=0; exitlevel=0
	set -- auth_client AA:BB:CC:DD:EE:02 redir ua 10.0.0.201 tok2 "$custom"
	. "$PWD/custombinauth.voucher.sh"
	echo "$exitlevel|$session_length"
) > /tmp/cb_out.txt
sleep 1
if grep -q "daemon_deauth AA:BB:CC:DD:EE:09" "$EVICT_FILE" 2>/dev/null \
	&& [ "$(cat /tmp/cb_out.txt)" = "0|300" ]; then
	PASS=$((PASS + 1)); echo "PASS: evict-hook (deauth old MAC, sess=300)"
else
	FAIL=$((FAIL + 1)); echo "FAIL: evict-hook out=[$(cat /tmp/cb_out.txt)] evict=[$(cat "$EVICT_FILE" 2>/dev/null)]"
fi

# unconfigured API URL must fail closed
(
	VOUCHER_API_URL=""
	action="auth_client"
	custom=$(b64 "voucher=TEST-6H")
	session_length=0; upload_rate=0; download_rate=0
	upload_quota=0; download_quota=0; exitlevel=0
	set -- auth_client AA:BB:CC:DD:EE:01 redir ua 10.0.0.200 tok1 "$custom"
	. "$PWD/custombinauth.voucher.sh"
	echo "$exitlevel"
) > /tmp/cb_out.txt
if [ "$(cat /tmp/cb_out.txt)" = "1" ]; then
	PASS=$((PASS + 1)); echo "PASS: no-api-url-fail-closed"
else
	FAIL=$((FAIL + 1)); echo "FAIL: no-api-url got=[$(cat /tmp/cb_out.txt)]"
fi

rm -f "$PSKFILE" "$EVICT_FILE" "$CALLFILE" "$RESPFILE" /tmp/cb_out.txt "$HOOK"
rmdir "$STUBBIN" 2>/dev/null
echo "---- custombinauth: PASS=$PASS FAIL=$FAIL ----"
[ "$FAIL" -eq 0 ]
