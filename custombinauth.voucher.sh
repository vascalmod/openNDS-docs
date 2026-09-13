#!/bin/sh
# custombinauth.voucher.sh — Stage 2 real voucher validation + initial session auth
#
# DEPLOY: copy to /usr/lib/opennds/custombinauth.sh (backup the stub first).
#   Sourced by binauth_log.sh AFTER it sets:
#     action, $1..$8 positionals, $custom, session_length/upload_rate/
#     download_rate/upload_quota/download_quota, exitlevel
#   (see opennds/binauth_log.sh:277-298). We may override those six values.
#   Parent echoes them and exits with $exitlevel (300-309).
#
# SCOPE (Stage 2): initial authorization only.
#   - Act ONLY on action=auth_client. All deauth/accounting callbacks fall
#     through untouched (time accrual is Stage 3; schema already carries the
#     columns so history exists).
#   - Fail CLOSED: any validation/backend/parse failure => exitlevel=1 (deny).
#     The stock REQUEST FAILED page is generic (no invalid-vs-expired oracle).
#   - Single DB + single validation function live in the backend (Ubuntu +
#     PostgreSQL). This script is a thin EAP-side claimant: it NEVER validates
#     locally, NEVER branches per browser (CPD vs Chrome identical).
#   - MAC/IP/token are transient metadata for the claim, NEVER identity.
#     Re-entry with a new (randomized) MAC rebinds by voucher code; backend
#     may name an EVICT mac which we deauth best-effort via the documented
#     libopennds daemon_deauth hook (meant to be called from binauth scripts).
#
# PRIVACY: voucher/custom never echoed to pages (ThemeSpec rule). Here the
#   value only travels EAP->backend in the claim POST body. Local syslog (if
#   any) carries a MASKED voucher fingerprint only, never the PSK.
#
# SAFETY: plain assignments only. No eval, no backticks, no unquoted
#   expansions of client data, no client data inside awk/sed programs.
#   Inside BinAuth only `ndsctl b64encode/b64decode` may be used
#   (binauth_log.sh:170-174); all other openNDS calls go through the async
#   libopennds daemon hooks, best-effort, never fatal.
#
# Config (EAP-local, set via environment or UCI; NOT in this repo):
#   VOUCHER_API_URL   full claim URL, e.g. https://voucher.lan/claim
#                     (empty/unset => deny; fail-closed forces configuration)
#   VOUCHER_PSK_FILE  file holding the API PSK, mode 0600 (default below)
#   VOUCHER_TIMEOUT   seconds per claim attempt (default 5, one attempt only)
#   VOUCHER_UCI_URL / VOUCHER_UCI_PSKFILE: optional UCI option names (defaults below)

# --- defaults (no secrets here) ---
VOUCHER_API_URL="${VOUCHER_API_URL:-}"
VOUCHER_PSK_FILE="${VOUCHER_PSK_FILE:-/etc/opennds/voucher_psk}"
VOUCHER_TIMEOUT="${VOUCHER_TIMEOUT:-5}"
# Hook path override is for local tests only; production is always the path below.
VOUCHER_LIBOPENDS="${VOUCHER_LIBOPENDS:-/usr/lib/opennds/libopennds.sh}"

if [ -z "$VOUCHER_API_URL" ] && command -v uci >/dev/null 2>&1; then
	VOUCHER_API_URL=$(uci get opennds.@opennds[0].voucher_api_url 2>/dev/null)
fi
if [ ! -f "$VOUCHER_PSK_FILE" ] && command -v uci >/dev/null 2>&1; then
	_uci_pskfile=$(uci get opennds.@opennds[0].voucher_psk_file 2>/dev/null)
	if [ -n "$_uci_pskfile" ]; then
		VOUCHER_PSK_FILE="$_uci_pskfile"
	fi
	_uci_pskfile=""
fi

if [ "$action" = "auth_client" ]; then
	vdeny=""

	# --- 1. decode custom (only ndsctl verb allowed here) ---
	vdecoded=""
	if [ -z "$vdeny" ]; then
		vdecoded=$(ndsctl b64decode "$custom" 2>/dev/null)
		if [ -z "$vdecoded" ]; then
			vdeny="bad_custom"
		fi
	fi

	# --- 2. extract voucher field (format "voucher=<code>", comma-separated) ---
	vraw=""
	if [ -z "$vdeny" ]; then
		vraw=$(printf '%s' "$vdecoded" | tr ',' '\n' | grep '^voucher=' | head -n 1)
		vraw=${vraw#voucher=}
		vraw=$(printf '%s' "$vraw" | tr -d '\r\n' | sed 's/^ *//;s/ *$//')
		if [ -z "$vraw" ]; then
			vdeny="missing_voucher"
		fi
	fi

	# --- 3. normalize + strict allowlist (hyphens significant, uppercase) ---
	# Entity-encoded smuggling (e.g. &#59;) can never match: & # ; are outside
	# the set, so such input falls into DENY below. No entity-decoding here.
	vnorm=""
	if [ -z "$vdeny" ]; then
		vnorm=$(printf '%s' "$vraw" | tr 'a-z' 'A-Z')
		vlen=${#vnorm}
		if [ "$vlen" -lt 4 ] || [ "$vlen" -gt 20 ]; then
			vdeny="bad_length"
		else
			case "$vnorm" in
				*[!A-Z0-9-]*)
					vdeny="bad_charset"
					;;
			esac
		fi
	fi

	# --- 4. client metadata from BinAuth positionals (transient, not identity) ---
	# auth_client: $2 mac, $5 ip, $6 token (binauth_log.sh:160-168).
	# Nothing here is trusted: every field is allowlisted before it may enter
	# the claim POST body, so no value can inject extra form fields
	# (&, =, %, CR, LF and friends are all outside the allowed sets).
	vmac="$2"
	vip="$5"
	vtoken="$6"

	# MAC: strict XX:XX:XX:XX:XX:XX (six hex octets) else empty-and-continue.
	# An absent/unparseable MAC never fails the claim; it is metadata only.
	case "$vmac" in
		??:??:??:??:??:??)
			case "$vmac" in
				*[!0-9a-fA-F:]*)
					vmac=""
					;;
			esac
			;;
		*)
			vmac=""
			;;
	esac

	# IP: strict IPv4 dotted quad (covers 10.0.0.0/24 LAN). Malformed => deny
	# here, before any network call, so it can never reach the POST body.
	if [ -z "$vdeny" ]; then
		vip_ok=1
		case "$vip" in
			*.*.*.*)
				case "$vip" in
					*[!0-9.]*)
						vip_ok=0
						;;
					*)
						vo_rest="$vip"
						vo_parts=0
						while [ -n "$vo_rest" ] && [ "$vip_ok" -eq 1 ]; do
							vo_parts=$((vo_parts + 1))
							case "$vo_rest" in
								*.*)
									vo_oct=${vo_rest%%.*}
									vo_rest=${vo_rest#*.}
									;;
								*)
									vo_oct=$vo_rest
									vo_rest=""
									;;
							esac
							case "$vo_oct" in
								""|*[!0-9]*|????*)
									vip_ok=0
									;;
								*)
									if [ "$vo_oct" -gt 255 ] 2>/dev/null; then
										vip_ok=0
									fi
									;;
							esac
						done
						if [ "$vo_parts" -ne 4 ]; then
							vip_ok=0
						fi
						vo_rest=""
						vo_parts=0
						vo_oct=""
						;;
				esac
				;;
			*)
				vip_ok=0
				;;
		esac
		if [ "$vip_ok" -ne 1 ]; then
			vdeny="bad_ip"
		fi
		vip_ok=""
	fi

	# Token: restricted to the OpenNDS-token-safe set, 1..128 chars.
	# Empty or anything outside [A-Za-z0-9._:-] (notably & = % CR LF) => deny.
	if [ -z "$vdeny" ]; then
		vtoklen=${#vtoken}
		if [ "$vtoklen" -lt 1 ] || [ "$vtoklen" -gt 128 ]; then
			vdeny="bad_token"
		else
			case "$vtoken" in
				*[!A-Za-z0-9._:-]*)
					vdeny="bad_token"
					;;
			esac
		fi
		vtoklen=""
	fi

	# --- 5. config present? (fail-closed forces operator configuration) ---
	vpsk=""
	if [ -z "$vdeny" ]; then
		if [ -z "$VOUCHER_API_URL" ]; then
			vdeny="no_api_url"
		elif [ ! -f "$VOUCHER_PSK_FILE" ]; then
			vdeny="no_psk_file"
		else
			vpsk=$(cat "$VOUCHER_PSK_FILE" 2>/dev/null)
			if [ -z "$vpsk" ]; then
				vdeny="no_psk"
			fi
		fi
	fi

	# --- 6. claim against backend (router egress; browser never calls it) ---
	# Every body value passed the gates above (allowlisted voucher; strict or
	# empty MAC; strict IPv4; token-safe charset; operator PSK), so no value
	# can alter the form structure (&, =, %, CR, LF cannot occur).
	vresp=""
	if [ -z "$vdeny" ]; then
		vpost="voucher=$vnorm&mac=$vmac&ip=$vip&token=$vtoken&psk=$vpsk"
		vpsk=""
		if command -v uclient-fetch >/dev/null 2>&1; then
			vresp=$(uclient-fetch -q -T "$VOUCHER_TIMEOUT" -O - --post-data="$vpost" "$VOUCHER_API_URL" 2>/dev/null)
		elif command -v wget >/dev/null 2>&1; then
			vresp=$(wget -q -T "$VOUCHER_TIMEOUT" -O - --post-data="$vpost" "$VOUCHER_API_URL" 2>/dev/null)
		else
			vdeny="no_http_client"
		fi
		vpost=""
	fi

	# --- 7. parse line response (strict shape, validated numerics) ---
	# Accept ONLY:
	#   ALLOW <remaining_seconds> <up_kbps> <down_kbps>
	#   ALLOW <remaining_seconds> <up_kbps> <down_kbps> EVICT <oldmac>
	# Anything else (bare ALLOW, non-numeric/negative/oversized values,
	# wrong field count, bad EVICT) => DENY. First line only.
	vremaining=""
	vup=""
	vdown=""
	vevict=""
	if [ -z "$vdeny" ]; then
		vline=$(printf '%s' "$vresp" | head -n 1)
		vdecision=$(printf '%s' "$vline" | awk '{print $1}')
		vnf=$(printf '%s' "$vline" | awk '{print NF}')
		vline=""
		if [ "$vdecision" = "ALLOW" ]; then
			case "$vnf" in
				4|6)
					;;
				*)
					vdeny="bad_reply"
					;;
			esac
			if [ -z "$vdeny" ]; then
				vremaining=$(printf '%s' "$vresp" | awk 'NR==1{print $2}')
				vup=$(printf '%s' "$vresp" | awk 'NR==1{print $3}')
				vdown=$(printf '%s' "$vresp" | awk 'NR==1{print $4}')
				case "$vremaining" in ""|*[!0-9]*) vdeny="bad_reply";; esac
				case "$vup" in ""|*[!0-9]*) vdeny="bad_reply";; esac
				case "$vdown" in ""|*[!0-9]*) vdeny="bad_reply";; esac
				# Bounds: remaining <= 9999999 (~115 days, far above any plan);
				# rates <= 1000000 kb/s. openNDS session cap applied below.
				if [ -z "$vdeny" ]; then
					if [ "${#vremaining}" -gt 7 ] || [ "${#vup}" -gt 7 ] || [ "${#vdown}" -gt 7 ]; then
						vdeny="bad_reply"
					elif [ "$vup" -gt 1000000 ] 2>/dev/null || [ "$vdown" -gt 1000000 ] 2>/dev/null; then
						vdeny="bad_reply"
					fi
				fi
				if [ -z "$vdeny" ] && [ "$vremaining" -le 0 ] 2>/dev/null; then
					vdeny="no_remaining"
				fi
			fi
			if [ -z "$vdeny" ] && [ "$vnf" -eq 6 ]; then
				vfifth=$(printf '%s' "$vresp" | awk 'NR==1{print $5}')
				vsixth=$(printf '%s' "$vresp" | awk 'NR==1{print $6}')
				if [ "$vfifth" != "EVICT" ]; then
					vdeny="bad_reply"
				else
					case "$vsixth" in
						??:??:??:??:??:??)
							case "$vsixth" in
								*[!0-9a-fA-F:]*)
									vdeny="bad_reply"
									;;
								*)
									vevict="$vsixth"
									;;
							esac
							;;
						*)
							vdeny="bad_reply"
							;;
					esac
				fi
				vfifth=""
				vsixth=""
			fi
		elif [ "$vdecision" = "DENY" ]; then
			vdeny="backend_deny"
		else
			vdeny="bad_reply"
		fi
		vdecision=""
		vnf=""
	fi
	vresp=""

	# --- 8. apply decision to parent contract (fail-closed) ---
	if [ -n "$vdeny" ]; then
		exitlevel=1
		session_length=0
		upload_rate=0
		download_rate=0
		upload_quota=0
		download_quota=0
	else
		# ceil(remaining_secs/60): openNDS session granularity is minutes.
		session_length=$(( (vremaining + 59) / 60 ))
		if [ "$session_length" -gt 1440 ]; then
			session_length=1440
		fi
		upload_rate="$vup"
		download_rate="$vdown"
		upload_quota=0
		download_quota=0
		exitlevel=0

		# Best-effort single-session eviction of the superseded device.
		# Async daemon hook (documented for binauth callers); never fatal:
		# a failed evict leaves the old record to expire naturally.
		if [ -n "$vevict" ] && [ "$vevict" != "$vmac" ]; then
			if [ -x "$VOUCHER_LIBOPENDS" ]; then
				("$VOUCHER_LIBOPENDS" daemon_deauth "$vevict" >/dev/null 2>&1 &)
			fi
		fi
	fi

	# --- 9. masked syslog (no voucher value, no PSK, no custom) ---
	if command -v logger >/dev/null 2>&1; then
		if [ -n "$vdeny" ]; then
			logger -t opennds-voucher "decision=deny reason=$vdeny mac=$vmac" 2>/dev/null
		else
			vpre=$(printf '%s' "$vnorm" | cut -c1-2)
			vpost_mask=$(printf '%s' "$vnorm" | rev | cut -c1-2 | rev)
			logger -t opennds-voucher "decision=allow voucher=${vpre}***${vpost_mask} mac=$vmac sess_min=$session_length" 2>/dev/null
			vpre=""
			vpost_mask=""
		fi
	fi

	vnorm=""
	vraw=""
	vdecoded=""
	vmac=""
	vip=""
	vtoken=""
	vremaining=""
	vup=""
	vdown=""
	vevict=""
	vdeny=""
else
	# Non-auth_client (deauth/accounting callbacks): leave parent defaults.
	# Time accrual is Stage 3; nothing to enforce here.
	:
fi

# Fall off the end WITHOUT exit/return so binauth_log.sh continues to
# echo the quotas and exit with $exitlevel (binauth_log.sh:300-309).
