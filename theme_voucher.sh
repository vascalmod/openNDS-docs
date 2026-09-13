#!/bin/sh
# theme_voucher.sh — Stage 2 local OpenNDS ThemeSpec (voucher login UI + validation)
#
# STAGE 2 — REAL VALIDATION (via custombinauth.voucher.sh + voucher backend).
# - This ThemeSpec proves/carries data flow:
#   form -> FAS -> $voucher -> binauth_custom -> encode_custom -> custom -> BinAuth.
# - "PORTAL-TEST" is retired: it is NOT seeded in the backend and MUST deny.
#   Use a labeled TEST-* code from backend/seed.sql for local/manual tests.
#   No code is hard-coded as valid here; any non-empty voucher reaches BinAuth
#   and the backend decides (exitlevel=1 denies).
# - Rates/session/quotas are set by custombinauth.voucher.sh from the backend
#   response, not here (quotas below stay 0 = defaults until BinAuth overrides).
# - Pause/resume, custom status page and port-80 changes remain Stage 3.
#
# Privacy (per task adjustment 1):
# - The raw voucher / custom values are NEVER rendered as visible page text.
# - They appear ONLY where the FAS protocol requires them:
#   (a) login input value="$voucher" (preserved re-serve, entity-encoded by core),
#   (b) hidden fas / voucher / custom fields between thankyou -> landing.
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
	# Stage 1 gate: non-empty voucher proceeds to thankyou (encode) path,
	# mirroring stock "both fields present -> thankyou_page" logic.
	# This is a presence gate for flow testing, NOT voucher authorization.
	if [ ! -z "$voucher" ]; then
		thankyou_page
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
		@media (max-width: 400px) {
			body { padding: 12px; }
			.card { padding: 25px 18px; border-radius: 15px; }
			.plan-item strong { font-size: 12px; }
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
			Stage 1 test page &middot; $year
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

landing_page() {
	originurl=$(printf "${originurl//%/\\x}")
	gatewayurl=$(printf "${gatewayurl//%/\\x}")

	configure_log_location
	. $mountpoint/ndscids/ndsinfo

	# Marker only — voucher value deliberately NOT added to userinfo.
	userinfo="$userinfo, stage2-validation"

	# Stage 2: performs the standard auth call so BinAuth receives the custom
	# string and custombinauth.voucher.sh validates it against the backend.
	# Deny (exitlevel=1) renders the generic fail page below. No approval here.
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

# Do NOT set/encode binauth_custom here; thankyou_page() sets and encodes it
# per-submission so each voucher value flows independently.
#binauth_custom=""
#encode_custom

# Log marker only (see privacy note above).
userinfo="$title, stage2-validation"
