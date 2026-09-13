#!/bin/sh
# theme_voucher.sh — Stage 2 local OpenNDS ThemeSpec (voucher login + status UI)
#
# STAGE 2 — REAL VALIDATION (voucher backend authoritative).
# - Flow (no intermediate Continue tap; CPD-friendly):
#   login form (CONNECT) -> FAS -> $voucher -> backend pre-validation
#   -> on ALLOW only: encode_custom -> auth_log (explicit quotas in request)
#   -> custom status page (CONNECTED + remaining). On DENY/failure the auth
#   call is SKIPPED entirely: no call, no grant possible (fail closed by
#   construction — enforced here because this daemon honors request quotas
#   and may skip BinAuth on the FAS path).
# - Legacy thankyou -> landing two-step kept as fallback, hardened identically
#   (presence gate + pre-validation + re-encoded custom).
# - "PORTAL-TEST" is retired: it is NOT seeded in the backend and MUST deny.
#   Use a labeled TEST-* code from backend/seed.sql for local/manual tests.
#   No code is hard-coded as valid here; any non-empty voucher reaches BinAuth
#   and the backend decides (exitlevel=1 denies).
# - Rates/session/quotas are set by custombinauth.voucher.sh from the backend
#   response, not here (quotas below stay 0 = defaults until BinAuth overrides).
# - PAUSE/RESUME actions, unified status.client entrypoint and port-80 changes
#   remain Stage 3. The legacy thankyou/landing two-step is kept only as a
#   compatible fallback and is no longer the primary flow.
#
# Privacy:
# - The raw voucher / custom values are NEVER rendered except where the approved
#   UI requires them:
#   (a) login input value="$voucher" (preserved re-serve, entity-encoded by core),
#   (b) hidden fas / voucher / custom fields of the legacy thankyou -> landing
#       fallback (FAS protocol requirement),
#   (c) the status page shows the user their OWN active voucher code, exactly as
#       the approved status.html mockup does (entity-encoded by core).
# - userinfo intentionally does NOT contain the voucher value (marker only).
#
# Constraints honoured:
# - Does NOT modify libopennds.sh, binauth_log.sh, client_params.sh or config.
# - No port 80 / LuCI / firewall / DHCP / statuspath changes.
# - Inline CSS only (CPD-safe). No JavaScript, no external files, no CDN.
# - Visuals adapted from ~/portal_eap/index.html + index.css (fence line removed).

title="theme_voucher"

# functions:

generate_splash_sequence() {
	voucher_login
}

voucher_login() {
	# Direct path: a submitted voucher authenticates immediately and renders
	# the custom status page — no intermediate Continue tap (CPD-friendly).
	# Presence gate only, NOT authorization: the backend decides via BinAuth.
	if [ ! -z "$voucher" ]; then
		voucher_status_page
		footer
	fi

	login_form
	footer
}

header() {
	echo "<!DOCTYPE html>
		<html lang=\"en\">
		<head>
		<meta http-equiv=\"Cache-Control\" content=\"no-cache, no-store, must-revalidate\">
		<meta http-equiv=\"Pragma\" content=\"no-cache\">
		<meta http-equiv=\"Expires\" content=\"0\">
		<meta charset=\"utf-8\">
		<meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">
		<title>WI-FI E-VOUCHER</title>
		<style>
		* { box-sizing: border-box; margin: 0; padding: 0; }
		:root {
			--background: #f4f6f8;
			--card: #ffffff;
			--text: #17202a;
			--muted: #7b8794;
			--line: #e5e9ed;
			--primary: #1677ff;
			--primary-dark: #0f62d6;
			--success: #16a34a;
			--success-light: #eaf8ef;
		}
		body {
			min-height: 100vh;
			font-family: Arial, Helvetica, sans-serif;
			background: var(--background);
			color: var(--text);
			display: flex;
			align-items: center;
			justify-content: center;
			padding: 20px;
		}
		.container { width: 100%; max-width: 420px; }
		.card {
			background: var(--card);
			border: 1px solid var(--line);
			border-radius: 18px;
			padding: 30px 24px;
			box-shadow: 0 10px 30px rgba(0, 0, 0, 0.06);
		}
		.brand { text-align: center; margin-bottom: 30px; }
		.brand-icon {
			width: 58px; height: 58px;
			margin: 0 auto 16px;
			border-radius: 16px;
			background: var(--primary);
			color: #ffffff;
			display: flex;
			align-items: center;
			justify-content: center;
			font-size: 13px;
			font-weight: bold;
		}
		.brand h1 { font-size: 21px; letter-spacing: 0.5px; }
		.brand p { margin-top: 7px; font-size: 12px; color: var(--muted); letter-spacing: 1px; }
		.voucher-form { display: flex; flex-direction: column; }
		.voucher-form label { font-size: 13px; font-weight: 600; margin-bottom: 8px; }
		.voucher-form input {
			width: 100%; height: 50px;
			padding: 0 15px;
			border: 1px solid var(--line);
			border-radius: 10px;
			outline: none;
			font-size: 15px;
		}
		.voucher-form input:focus { border-color: var(--primary); }
		.voucher-form input::placeholder { color: #a6afb8; }
		.voucher-form button {
			width: 100%; height: 50px;
			margin-top: 14px;
			border: 0; border-radius: 10px;
			background: var(--primary); color: #ffffff;
			font-size: 14px; font-weight: bold;
			cursor: pointer;
		}
		.plan {
			display: grid;
			grid-template-columns: repeat(3, 1fr);
			margin-top: 24px;
			border-top: 1px solid var(--line);
			padding-top: 20px;
		}
		.plan-item { text-align: center; border-right: 1px solid var(--line); }
		.plan-item:last-child { border-right: 0; }
		.plan-item strong { display: block; font-size: 14px; }
		.plan-item span { display: block; margin-top: 5px; font-size: 10px; color: var(--muted); letter-spacing: 0.5px; }
		.note { margin-top: 16px; text-align: center; font-size: 11px; color: var(--muted); line-height: 1.5; }
		.connection-status {
			display: inline-flex;
			align-items: center;
			gap: 7px;
			margin-top: 12px;
			padding: 7px 11px;
			border-radius: 20px;
			background: var(--success-light);
			color: var(--success);
			font-size: 11px;
			font-weight: bold;
		}
		.status-dot { width: 7px; height: 7px; border-radius: 50%; background: var(--success); }
		.timer-section {
			text-align: center;
			padding: 24px 0;
			border-top: 1px solid var(--line);
			border-bottom: 1px solid var(--line);
		}
		.timer-label { display: block; color: var(--muted); font-size: 11px; font-weight: bold; letter-spacing: 1px; }
		.timer { margin-top: 8px; font-size: 38px; font-weight: 700; letter-spacing: 2px; font-variant-numeric: tabular-nums; }
		.voucher-info { padding: 8px 0; }
		.info-row {
			display: flex;
			justify-content: space-between;
			align-items: center;
			padding: 14px 0;
			border-bottom: 1px solid var(--line);
			font-size: 13px;
		}
		.info-row:last-child { border-bottom: 0; }
		.info-row span { color: var(--muted); }
		.active-text { color: var(--success); }
		.hint { margin-top: 13px; text-align: center; color: var(--muted); font-size: 11px; line-height: 1.5; }
		@media (max-width: 400px) {
			body { padding: 12px; }
			.card { padding: 25px 18px; border-radius: 15px; }
			.plan-item strong { font-size: 12px; }
			.timer { font-size: 32px; }
		}
		</style>
		</head>
		<body>
		<main class=\"container\">
	"
}

footer() {
	year=$(date +'%Y')
	echo "
		<div class=\"note\">
			WI-FI E-VOUCHER &middot; $year
		</div>
		</main>
		</body>
		</html>
	"

	exit 0
}

login_form() {
	# $voucher here is entity-encoded by libopennds parse_variables; safe to
	# reflect inside the quoted value attribute for re-serve preservation.
	echo "
		<section class=\"card\">
			<div class=\"brand\">
				<div class=\"brand-icon\">WiFi</div>
				<h1>WI-FI E-VOUCHER</h1>
				<p>CONNECT TO INTERNET</p>
			</div>
			<form class=\"voucher-form\" action=\"/opennds_preauth/\" method=\"get\">
				<input type=\"hidden\" name=\"fas\" value=\"$fas\">
				<label for=\"voucher\">Voucher Code</label>
				<input
					type=\"text\"
					id=\"voucher\"
					name=\"voucher\"
					placeholder=\"ABCD-1234\"
					autocomplete=\"off\"
					maxlength=\"20\"
					value=\"$voucher\"
				>
				<button type=\"submit\">CONNECT</button>
			</form>
			<div class=\"plan\">
				<div class=\"plan-item\"><strong>&#8369;5</strong><span>PRICE</span></div>
				<div class=\"plan-item\"><strong>6 HOURS</strong><span>TIME</span></div>
				<div class=\"plan-item\"><strong>10 Mbps</strong><span>SPEED</span></div>
			</div>
		</section>
	"
}

thankyou_page() {
	# Encode voucher for BinAuth WITHOUT displaying it as visible text.
	# binauth_custom assignment is a plain (non-eval) assignment; encode_custom
	# runs quoted ndsctl b64encode (libopennds.sh). No shell interpretation
	# of the voucher content occurs here.
	binauth_custom="voucher=$voucher"
	encode_custom

	if [ -z "$custom" ]; then
		customhtml=""
	else
		customhtml="<input type=\"hidden\" name=\"custom\" value=\"$custom\">"
	fi

	# voucher/custom travel ONLY as hidden protocol fields (required by FAS).
	echo "
		<section class=\"card\">
			<div class=\"brand\">
				<div class=\"brand-icon\">WiFi</div>
				<h1>WI-FI E-VOUCHER</h1>
				<p>VOUCHER RECEIVED</p>
			</div>
			<form class=\"voucher-form\" action=\"/opennds_preauth/\" method=\"get\">
				<input type=\"hidden\" name=\"fas\" value=\"$fas\">
				<input type=\"hidden\" name=\"voucher\" value=\"$voucher\">
				$customhtml
				<input type=\"hidden\" name=\"landing\" value=\"yes\">
				<button type=\"submit\">Continue</button>
			</form>
			<p class=\"note\">If this page closes automatically, reopen your browser to continue.</p>
		</section>
	"
}

voucher_status_page() {
	# Direct path used by voucher_login(): pre-validate through the backend,
	# then authenticate and render the custom status UI immediately.
	#
	# WHY HERE: this daemon honors the quotas carried IN the auth request and
	# may skip BinAuth on the FAS path, so validation MUST happen here before
	# the auth call — skipping that call on deny IS the enforcement (no call,
	# no grant possible: fail closed by construction). Same contract as the
	# BinAuth claimant (kept inline: self-contained ThemeSpec, no new files).
	configure_log_location
	. $mountpoint/ndscids/ndsinfo

	# Marker only — voucher value deliberately NOT added to userinfo.
	userinfo="$userinfo, stage2-validation"

	voucher_api_claim

	if [ "$vallow" = "1" ]; then
		binauth_custom="voucher=$voucher"
		encode_custom
		auth_log

		if [ "$ndsstatus" = "authenticated" ]; then
			voucher_status_connected
		else
			voucher_status_denied
		fi
	else
		voucher_status_denied
	fi

	footer
}

# EAP-side voucher pre-validation for the ThemeSpec paths.
# Twin of the BinAuth claimant gates: strict allowlist, fail-closed config,
# strict reply shape, bounded numerics, ceil(remaining/60) capped at 1440.
# Sets: vallow (0/1), and on allow also session_length/upload_rate/
# download_rate/upload_quota/download_quota + rebuilt $quotas for auth_log.
# Never exits; never grants (granting is auth_log's job on allow only).
voucher_api_claim() {
	vallow=0
	vsession_min=0
	vup=0
	vdown=0
	vcode=$(printf '%s' "$voucher" | tr -d '\r\n' | sed 's/^ *//;s/ *$//')
	vcode=$(printf '%s' "$vcode" | tr 'a-z' 'A-Z')
	vok=1
	vlen=${#vcode}
	if [ "$vlen" -lt 4 ] || [ "$vlen" -gt 20 ]; then
		vok=0
	else
		case "$vcode" in
			*[!A-Z0-9-]*)
				vok=0
				;;
		esac
	fi
	vlen=""
	if [ "$vok" -ne 1 ]; then
		vcode=""
		return
	fi
	if [ -z "$VOUCHER_API_URL" ] && command -v uci >/dev/null 2>&1; then
		VOUCHER_API_URL=$(uci get opennds.@opennds[0].voucher_api_url 2>/dev/null)
	fi
	vpsk=""
	vpskfile="${VOUCHER_PSK_FILE:-/etc/opennds/voucher_psk}"
	if [ -z "$VOUCHER_API_URL" ] || [ ! -f "$vpskfile" ]; then
		vcode=""
		vpskfile=""
		return
	fi
	vpsk=$(cat "$vpskfile" 2>/dev/null)
	vpskfile=""
	if [ -z "$vpsk" ]; then
		vcode=""
		return
	fi
	vresp=""
	if command -v uclient-fetch >/dev/null 2>&1; then
		vresp=$(uclient-fetch -q -T 5 -O - --post-data="voucher=$vcode&mac=$clientmac&ip=$clientip&token=&psk=$vpsk" "$VOUCHER_API_URL" 2>/dev/null)
	elif command -v wget >/dev/null 2>&1; then
		vresp=$(wget -q -T 5 -O - --post-data="voucher=$vcode&mac=$clientmac&ip=$clientip&token=&psk=$vpsk" "$VOUCHER_API_URL" 2>/dev/null)
	fi
	vpsk=""
	if [ -z "$vresp" ]; then
		vcode=""
		return
	fi
	vline=$(printf '%s' "$vresp" | head -n 1)
	vdecision=$(printf '%s' "$vline" | awk '{print $1}')
	vnf=$(printf '%s' "$vline" | awk '{print NF}')
	vline=""
	if [ "$vdecision" != "ALLOW" ]; then
		vresp=""
		vdecision=""
		vnf=""
		vcode=""
		return
	fi
	case "$vnf" in
		4|6)
			;;
		*)
			vresp=""
			vdecision=""
			vnf=""
			vcode=""
			return
			;;
	esac
	vrem=$(printf '%s' "$vresp" | awk 'NR==1{print $2}')
	vup=$(printf '%s' "$vresp" | awk 'NR==1{print $3}')
	vdown=$(printf '%s' "$vresp" | awk 'NR==1{print $4}')
	vresp=""
	vdecision=""
	vnf=""
	case "$vrem" in ""|*[!0-9]*) vrem=""; ;; esac
	case "$vup" in ""|*[!0-9]*) vup=""; ;; esac
	case "$vdown" in ""|*[!0-9]*) vdown=""; ;; esac
	if [ -z "$vrem" ] || [ -z "$vup" ] || [ -z "$vdown" ]; then
		vrem=""
		vup=0
		vdown=0
		vcode=""
		return
	fi
	if [ "${#vrem}" -gt 7 ] || [ "${#vup}" -gt 7 ] || [ "${#vdown}" -gt 7 ]; then
		vrem=""
		vup=0
		vdown=0
		vcode=""
		return
	fi
	if [ "$vup" -gt 1000000 ] 2>/dev/null || [ "$vdown" -gt 1000000 ] 2>/dev/null; then
		vrem=""
		vup=0
		vdown=0
		vcode=""
		return
	fi
	if [ "$vrem" -le 0 ] 2>/dev/null; then
		vrem=""
		vup=0
		vdown=0
		vcode=""
		return
	fi
	vsession_min=$(( (vrem + 59) / 60 ))
	if [ "$vsession_min" -gt 1440 ]; then
		vsession_min=1440
	fi
	vrem=""
	session_length="$vsession_min"
	upload_rate="$vup"
	download_rate="$vdown"
	upload_quota=0
	download_quota=0
	quotas="$session_length $upload_rate $download_rate $upload_quota $download_quota"
	vcode=""
	vallow=1
}

voucher_status_connected() {
	# Best-effort remaining-time lookup for DISPLAY ONLY (never authorization:
	# the decision above already happened in auth_log/BinAuth). Same parse
	# pattern as stock client_params.sh; absent/unparseable end time simply
	# omits the timer block instead of fabricating one.
	vtimer=""
	vnow=$(date +%s)
	vend=$(ndsctl json "$clientip" 2>/dev/null | grep '"session_end":' | awk -F'"' '{printf "%s", $4}' | head -n 1)
	case "$vend" in
		""|*[!0-9]*)
			;;
		*)
			vrem=$((vend - vnow))
			if [ "$vrem" -lt 0 ]; then
				vrem=0
			fi
			vtimer=$(printf "%02d:%02d:%02d" $((vrem/3600)) $(((vrem%3600)/60)) $((vrem%60)))
			;;
	esac
	vend=""
	vnow=""
	vrem=""

	if [ -n "$vtimer" ]; then
		vtimerblock="
			<div class=\"timer-section\">
				<span class=\"timer-label\">REMAINING</span>
				<div class=\"timer\">$vtimer</div>
			</div>
		"
	else
		vtimerblock=""
	fi
	vtimer=""

	# $voucher is entity-encoded by libopennds parse_variables, so reflecting
	# the user's OWN active code here matches the approved status.html mockup
	# without introducing HTML injection.
	echo "
		<section class=\"card\">
			<div class=\"brand\">
				<div class=\"brand-icon\">WiFi</div>
				<h1>WI-FI E-VOUCHER</h1>
				<div class=\"connection-status\">
					<span class=\"status-dot\"></span>
					CONNECTED
				</div>
			</div>
			$vtimerblock
			<div class=\"voucher-info\">
				<div class=\"info-row\">
					<span>Voucher</span>
					<strong>$voucher</strong>
				</div>
				<div class=\"info-row\">
					<span>Speed</span>
					<strong>10 Mbps</strong>
				</div>
				<div class=\"info-row\">
					<span>Status</span>
					<strong class=\"active-text\">Active</strong>
				</div>
			</div>
			<p class=\"hint\">
				Your connection is active. You may close this window.
			</p>
		</section>
	"
	vtimerblock=""
}

voucher_status_denied() {
	# Generic failure: no voucher/custom values, no backend detail, no oracle.
	echo "
		<section class=\"card\">
			<div class=\"brand\">
				<div class=\"brand-icon\">WiFi</div>
				<h1>WI-FI E-VOUCHER</h1>
				<p>REQUEST FAILED</p>
			</div>
			<p class=\"note\">Something went wrong or the request timed out. Please try again.</p>
			<form class=\"voucher-form\" action=\"http://$gatewayfqdn\" method=\"get\">
				<button type=\"submit\">Try again</button>
			</form>
		</section>
	"
}

landing_page() {
	originurl=$(printf "${originurl//%/\\x}")
	gatewayurl=$(printf "${gatewayurl//%/\\x}")
	configure_log_location
	. $mountpoint/ndscids/ndsinfo

	# Marker only — voucher value deliberately NOT added to userinfo.
	userinfo="$userinfo, stage2-validation"

	# Legacy fallback path, same enforcement as the direct path: a missing
	# voucher never reaches the auth call, and a denied/failed claim renders
	# the generic fail page with no grant possible.
	if [ -z "$voucher" ]; then
		voucher_status_denied
		footer
	fi

	voucher_api_claim

	if [ "$vallow" != "1" ]; then
		voucher_status_denied
		footer
	fi

	# Re-encode here (authoritative for this request) rather than trusting any
	# client-supplied custom field carried by the legacy two-step forms.
	binauth_custom="voucher=$voucher"
	encode_custom

	auth_log

	# No voucher / custom values rendered below (browser-privacy requirement).
	# Verification happens server-side: binauthlog.log + ndsctl json (see test proc).
	auth_success="
		<section class=\"card\">
			<div class=\"brand\">
				<div class=\"brand-icon\">WiFi</div>
				<h1>WI-FI E-VOUCHER</h1>
				<p>REQUEST SENT</p>
			</div>
			<p class=\"note\">Your request was processed. You can use your browser as normal if access was granted.</p>
			<form class=\"voucher-form\" action=\"$gatewayurl\" method=\"get\">
				<button type=\"submit\">Continue</button>
			</form>
		</section>
	"
	auth_fail="
		<section class=\"card\">
			<div class=\"brand\">
				<div class=\"brand-icon\">WiFi</div>
				<h1>WI-FI E-VOUCHER</h1>
				<p>REQUEST FAILED</p>
			</div>
			<p class=\"note\">Something went wrong or the request timed out. Please try again.</p>
			<form class=\"voucher-form\" action=\"http://$gatewayfqdn\" method=\"get\">
				<button type=\"submit\">Try again</button>
			</form>
		</section>
	"

	if [ "$ndsstatus" = "authenticated" ]; then
		echo "$auth_success"
	else
		echo "$auth_fail"
	fi

	footer
}

#### end of functions ####


#################################################
#						#
#  Start - Main entry point for this Theme	#
#						#
#  Parameters set here overide those		#
#  set in libopennds.sh			#
#						#
#################################################

# Quotas and Data Rates (Stage 1: defaults; real rates/quotas are Stage 2)
# session_length in minutes; 0 = global sessiontimeout value.
session_length="0"

# rates in kb/s, quotas in kB; 0 = global value.
upload_rate="0"
download_rate="0"
upload_quota="0"
download_quota="0"

quotas="$session_length $upload_rate $download_rate $upload_quota $download_quota"

# NDS portal parameters expected from openNDS ($ndsparamlist base is set in libopennds.sh).
# Stage 1 needs no portal-wide custom params/images/files.
ndscustomparams=""
ndscustomimages=""
ndscustomfiles=""

ndsparamlist="$ndsparamlist $ndscustomparams $ndscustomimages $ndscustomfiles"

# FAS dialogue variables for this theme. "voucher" is the ONLY addition and is
# what makes libopennds get_arguments/parse_variables populate $voucher.
additionalthemevars="voucher"

fasvarlist="$fasvarlist $additionalthemevars"

# Do NOT set/encode binauth_custom here; voucher_status_page() (primary) and
# thankyou_page() (legacy fallback) set and encode it per-submission so each
# voucher value flows independently.
#binauth_custom=""
#encode_custom

# Log marker only (see privacy note above).
userinfo="$title, stage2-validation"
