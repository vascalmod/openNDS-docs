#!/bin/sh
# client_params_voucher.sh — unified portal entry for status.client
#
# Fork of stock client_params.sh (openNDS 10.3.1): same MHD calling
# convention, same helpers, same busy behavior. Changed branches:
#   - `status` unauthenticated/preauth/expired/unknown -> automatic forward
#     into the standard login flow (zero clicks, browser-friendly);
#   - `status` authenticated + live session -> custom status UI (CONNECTED +
#     remaining + own code + Logout), never the stock dump;
#   - `err511` (captive entry for browsers AND CPD probes) -> same automatic
#     forward; HTTP 511 + daemon redirect semantics untouched (MHD-owned),
#     manual Continue button kept as fallback, so CPD clients are unaffected.
# Render-only: no auth, no firewall, no grant capability. The sole grant
# path stays ThemeSpec -> auth_log -> BinAuth -> backend (see theme_voucher.sh
# and custombinauth.voucher.sh).
#
status=$1
clientip=$2
b64query=$3

do_ndsctl () {
	local timeout=4

	for tic in $(seq $timeout); do
		ndsstatus="ready"
		ndsctlout=$(eval ndsctl "$ndsctlcmd")

		for keyword in $ndsctlout; do

			if [ $keyword = "locked" ]; then
				ndsstatus="busy"
				sleep 1
				break
			fi
		done

		if [ "$ndsstatus" = "ready" ]; then
			break
		fi
	done
}

get_client_zone () {
	# Gets the client zone, (if we don't already have it) ie the connection the client is using, such as:
	# local interface (br-lan, wlan0, wlan0-1 etc.,
	# or remote mesh node mac address

	failcheck=$(echo "$clientif" | grep "get_client_interface")

	if [ -z $failcheck ]; then
		client_if=$(echo "$clientif" | awk '{printf $1}')
		client_meshnode=$(echo "$clientif" | awk '{printf $2}' | awk -F ':' '{print $1$2$3$4$5$6}')
		local_mesh_if=$(echo "$clientif" | awk '{printf $3}')

		if [ ! -z "$client_meshnode" ]; then
			client_zone="MeshZone: $client_meshnode"
		else
			client_zone="LocalZone: $client_if"
		fi
	else
		client_zone=""
	fi
}

htmlentityencode() {
	entitylist="
		s/\"/\&quot;/g
		s/>/\&gt;/g
		s/</\&lt;/g
		s/%/\&#37;/g
		s/'/\&#39;/g
		s/\`/\&#96;/g
	"
	local buffer="$1"

	for entity in $entitylist; do
		entityencoded=$(echo "$buffer" | sed "$entity")
		buffer=$entityencoded
	done

	entityencoded=$(echo "$buffer" | awk '{ gsub(/\$/, "\\&#36;"); print }')
}


parse_variables() {
	# Parse for variables in $query from the list in $queryvarlist:

	for var in $queryvarlist; do
		evalstr=$(echo "$query" | awk -F"$var=" '{print $2}' | awk -F', ' '{print $1}')
		evalstr=$(printf "${evalstr//%/\\x}")

		# sanitise $evalstr to prevent code injection
		htmlentityencode "$evalstr"
		evalstr=$entityencoded

		if [ -z "$evalstr" ]; then
			continue
		fi

		eval $var=$(echo "\"$evalstr\"")
		evalstr=""
	done
	query=""
}

parse_parameters() {

	if [ "$status" = "status" ]; then
		ndsctlcmd="json $clientip"
		do_ndsctl

		if [ "$ndsstatus" = "ready" ]; then
			param_str=$ndsctlout

			for param in gatewayname gatewayaddress gatewayfqdn mac version ip client_type clientif session_start session_end \
				last_active token state custom upload_rate_limit_threshold download_rate_limit_threshold \
				upload_packet_rate upload_bucket_size download_packet_rate download_bucket_size \
				upload_quota download_quota upload_this_session download_this_session upload_session_avg download_session_avg
			do
				val=$(echo "$param_str" | grep "\"$param\":" | awk -F'"' '{printf "%s", $4}')

				if [ "$val" = "null" ]; then
					val="Unlimited"
				fi

				if [ -z "$val" ]; then
					eval $param=$(echo "Unavailable")
				else
					eval $param=$(echo "\"$val\"")
				fi
			done

			# url decode and html entity encode gatewayname
			gatewayname_dec=$(printf "${gatewayname//%/\\x}")
			htmlentityencode "$gatewayname_dec"
			gatewaynamehtml=$entityencoded

			# Get client_zone from clientif
			get_client_zone

			# Get human readable times:
			sessionstart=$(date -d @$session_start)

			if [ "$session_end" = "Unlimited" ]; then
				sessionend=$session_end
			else
				sessionend=$(date -d @$session_end)
			fi

			lastactive=$(date -d @$last_active)
		fi
	else
		mountpoint=$(/usr/lib/opennds/libopennds.sh tmpfs)
		. $mountpoint/ndscids/ndsinfo
	fi
}

header() {
# Define a common header html for every page served
	header="<!DOCTYPE html>
		<html>
		<head>
		<meta http-equiv=\"Cache-Control\" content=\"no-cache, no-store, must-revalidate\">
		<meta http-equiv=\"Pragma\" content=\"no-cache\">
		<meta http-equiv=\"Expires\" content=\"0\">
		<meta charset=\"utf-8\">
		<meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">
		<link rel=\"shortcut icon\" href=\"$url/$imagepath\" type=\"image/x-icon\">
		<link rel=\"stylesheet\" type=\"text/css\" href=\"$url/splash.css\">
		<title>$gatewaynamehtml Client Session Status</title>
		</head>
		<body>
		<div class=\"offset\">
		<big-red>
			Session Status<br>
		</big-red>
		<med-blue>
			$gatewaynamehtml
		</med-blue><br>
		<div class=\"insert\" style=\"max-width:100%;\">
	"
	echo "$header"
}

footer() {
	# Define a common footer html for every page served
	year=$(date +'%Y')
	echo "
		<hr>
		<div style=\"font-size:0.5em;\">
			<br>
			<img style=\"height:60px; float:left;\" src=\"$url/$imagepath\" alt=\"Splash Page: For access to the Internet.\">
			&copy; Portal: BlueWave Projects and Services 2015 - $year<br>
			<br>
			Portal Version: $version
			<br><br><br><br>
		</div>
		</div>
		</div>
		</body>
		</html>
	"
}

body() {
	if [ "$ndsstatus" = "busy" ]; then
		pagebody="
			<hr>
			<b>The Portal is busy, please click or tap \"Refresh\"<br><br></b>
			<form>
				<input type=\"button\" VALUE=\"Refresh\" onClick=\"history.go(0);return true;\">
			</form>
		"
	else
		exit 1
	fi

	echo "$pagebody"
}

# --- unified-entry additions (status + err511 branches; busy untouched) ---

# voucher_session_active: true (0) only for a live voucher session:
# Authenticated state AND (Unlimited end OR numeric end in the future).
# Anything else (preauth, unknown, expired, unparseable) -> login-forward.
# Sets vrem (seconds remaining) when numeric, else empty.
voucher_session_active() {
	vrem=""
	[ "$state" = "Authenticated" ] || return 1
	case "$session_end" in
		Unlimited)
			return 0
			;;
	esac
	case "$session_end" in
		""|*[!0-9]*)
			return 1
			;;
	esac
	vnow=$(date +%s)
	vrem=$((session_end - vnow))
	vnow=""
	[ "$vrem" -gt 0 ]
}

# voucher_code: decode the ndsctl custom field (b64 "voucher=CODE" as set by
# the ThemeSpec) to the display code, or "-" when absent/invalid. Strict
# allowlist mirrors the rest of the system; nothing unvalidated is reflected.
voucher_code() {
	vcode="-"
	case "$custom" in
		""|Unavailable|Unlimited)
			;;
		*)
			vraw=$(ndsctl b64decode "$custom" 2>/dev/null | tr -d '\r\n')
			case "$vraw" in
				voucher=*)
					vcode=${vraw#voucher=}
					vlen=${#vcode}
					if [ "$vlen" -lt 4 ] || [ "$vlen" -gt 20 ]; then
						vcode="-"
					else
						case "$vcode" in
							*[!A-Z0-9-]*)
								vcode="-"
								;;
						esac
					fi
					vlen=""
					;;
			esac
			vraw=""
			;;
	esac
	printf '%s' "$vcode"
	vcode=""
}

# voucher_forward_page: unauthenticated browsers go straight into the standard
# login flow with zero clicks. Paint FIRST, navigate SECOND: the loading state
# below renders immediately (spinner + text), and navigation fires on window
# load — a head-parse script could navigate before first paint, leaving a
# blank (black in dark mode) gap during the multi-second login render.
# Meta-refresh survives underneath for no-JS clients; no manual button by
# owner decision (CPD ignores page bodies entirely). The target is the stock
# fresh FAS query for the ThemeSpec — no voucher data is fabricated here.
# CPD clients ignore page bodies (protocol is MHD's 511 + redirect), so this
# changes nothing for them.
voucher_forward_page() {
	echo "<!DOCTYPE html>
		<html lang=\"en\">
		<head>
		<meta http-equiv=\"Cache-Control\" content=\"no-cache, no-store, must-revalidate\">
		<meta http-equiv=\"Pragma\" content=\"no-cache\">
		<meta http-equiv=\"Expires\" content=\"0\">
		<meta charset=\"utf-8\">
		<meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">
		<meta http-equiv=\"refresh\" content=\"0;url=$url/login\">
		<meta name=\"color-scheme\" content=\"light\">
		<title>WI-FI E-VOUCHER</title>
		<style>
		* { box-sizing: border-box; margin: 0; padding: 0; }
		body { min-height: 100vh; font-family: Arial, Helvetica, sans-serif; background: #f4f6f8; color: #17202a; display: flex; align-items: center; justify-content: center; padding: 20px; }
		.container { width: 100%; max-width: 420px; }
		.card { background: #ffffff; border: 1px solid #e5e9ed; border-radius: 18px; padding: 30px 24px; box-shadow: 0 10px 30px rgba(0, 0, 0, 0.06); text-align: center; }
		.brand-icon { width: 58px; height: 58px; margin: 0 auto 16px; border-radius: 16px; background: #1677ff; color: #ffffff; display: flex; align-items: center; justify-content: center; font-size: 13px; font-weight: bold; }
		.brand h1 { font-size: 21px; letter-spacing: 0.5px; }
		.brand p { margin-top: 7px; font-size: 12px; color: #7b8794; letter-spacing: 1px; }
		.note { margin-top: 16px; text-align: center; font-size: 11px; color: #7b8794; line-height: 1.5; }
		html { background: #f4f6f8; }
		.load-spinner { width: 34px; height: 34px; margin: 22px auto 6px; border: 3px solid #e5e9ed; border-top-color: #1677ff; border-radius: 50%; animation: vspin 0.8s linear infinite; }
		@keyframes vspin { to { transform: rotate(360deg); } }
		</style>
		</head>
		<body>
		<main class=\"container\">
		<section class=\"card\">
			<div class=\"brand\">
				<div class=\"brand-icon\">WiFi</div>
				<h1>WI-FI E-VOUCHER</h1>
				<p>CREATING SESSION</p>
			</div>
			<div class=\"load-spinner\"></div>
			<p class=\"note\">Preparing your secure login&hellip;</p>
		</section>
		</main>
		<script>window.addEventListener(\"load\",function(){window.location.replace(\"$url/login\");});</script>
		</body>
		</html>
	"
}

# Live countdown snippet (progressive enhancement ONLY): ticks the sibling
# .timer[data-remaining] once per second from a frozen deadline, so background
# throttling self-corrects and no client clock is trusted. Where JS is blocked
# the static server-rendered text remains. ES5 syntax for old webviews.
# Twin in theme_voucher.sh.
voucher_countdown_js() {
	echo "<script>(function(){var el=document.querySelector('.timer[data-remaining]');if(!el){return;}var rem=parseInt(el.getAttribute('data-remaining'),10);if(isNaN(rem)||rem<0){rem=0;}var end=Date.now()+rem*1000;function pad(n){n=Math.floor(n);return (n<10?'0':'')+n;}function tick(){var s=Math.max(0,Math.round((end-Date.now())/1000));el.textContent=pad(s/3600)+':'+pad((s%3600)/60)+':'+pad(s%60);if(s<=0){clearInterval(iv);}}var iv=setInterval(tick,1000);tick();})();</script>"
}

# voucher_status_page: authenticated voucher session status (self-contained,
# no external CSS/images). Timer omitted when the end is Unlimited rather
# than fabricating one. No account dump, no stock Session Status text.
voucher_status_page() {
	if [ -n "$vrem" ]; then
		# $vrem is digit-guarded by voucher_session_active: safe to embed.
		vremsecs="$vrem"
		vtimer=$(printf "%02d:%02d:%02d" $((vrem/3600)) $(((vrem%3600)/60)) $((vrem%60)))
		vjsct=$(voucher_countdown_js)
		vtimerblock="
			<div class=\"timer-section\">
				<span class=\"timer-label\">REMAINING</span>
				<div class=\"timer\" data-remaining=\"$vremsecs\">$vtimer</div>
				$vjsct
			</div>
		"
	else
		vtimerblock=""
	fi
	vtimer=""
	vremsecs=""
	vjsct=""
	vcode=$(voucher_code)
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
		body { min-height: 100vh; font-family: Arial, Helvetica, sans-serif; background: #f4f6f8; color: #17202a; display: flex; align-items: center; justify-content: center; padding: 20px; }
		.container { width: 100%; max-width: 420px; }
		.card { background: #ffffff; border: 1px solid #e5e9ed; border-radius: 18px; padding: 30px 24px; box-shadow: 0 10px 30px rgba(0, 0, 0, 0.06); }
		.brand { text-align: center; margin-bottom: 30px; }
		.brand-icon { width: 58px; height: 58px; margin: 0 auto 16px; border-radius: 16px; background: #1677ff; color: #ffffff; display: flex; align-items: center; justify-content: center; font-size: 13px; font-weight: bold; }
		.brand h1 { font-size: 21px; letter-spacing: 0.5px; }
		.connection-status { display: inline-flex; align-items: center; gap: 7px; margin-top: 12px; padding: 7px 11px; border-radius: 20px; background: #eaf8ef; color: #16a34a; font-size: 11px; font-weight: bold; }
		.status-dot { width: 7px; height: 7px; border-radius: 50%; background: #16a34a; }
		.timer-section { text-align: center; padding: 24px 0; border-top: 1px solid #e5e9ed; border-bottom: 1px solid #e5e9ed; }
		.timer-label { display: block; color: #7b8794; font-size: 11px; font-weight: bold; letter-spacing: 1px; }
		.timer { margin-top: 8px; font-size: 38px; font-weight: 700; letter-spacing: 2px; font-variant-numeric: tabular-nums; }
		.voucher-info { padding: 8px 0; }
		.info-row { display: flex; justify-content: space-between; align-items: center; padding: 14px 0; border-bottom: 1px solid #e5e9ed; font-size: 13px; }
		.info-row:last-child { border-bottom: 0; }
		.info-row span { color: #7b8794; }
		.active-text { color: #16a34a; }
		.logout-form button { width: 100%; height: 50px; margin-top: 14px; border: 0; border-radius: 10px; background: #17202a; color: #ffffff; font-size: 14px; font-weight: bold; cursor: pointer; }
		.hint { margin-top: 13px; text-align: center; color: #7b8794; font-size: 11px; line-height: 1.5; }
		@media (max-width: 400px) {
			body { padding: 12px; }
			.card { padding: 25px 18px; border-radius: 15px; }
			.timer { font-size: 32px; }
		}
		</style>
		</head>
		<body>
		<main class=\"container\">
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
					<strong>$vcode</strong>
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
			<form class=\"logout-form\" action=\"$url/opennds_deny/\" method=\"get\">
				<button type=\"submit\">Logout</button>
			</form>
			<p class=\"hint\">
				Your connection is active. You may close this window.
			</p>
		</section>
		</main>
		</body>
		</html>
	"
	vtimerblock=""
	vcode=""
	vrem=""
}

# Start generating the html:
if [ -z "$clientip" ]; then
	exit 1
fi

# Download remote resources eg. images and html if not already present
# Images and data files are defined in the openNDS config file using fas_custom_images_list and fas_custom_files_list
# This is the same set of resources that are used in ThemeSpec PreAuth scripts.
# Default logo is the openNDS splash image (/etc/opennds/htdocs/images/splash.jpg)
#
# An example logo can be found in the git repository (https://raw.githubusercontent.com/openNDS/openNDS/master/resources/avatar.png)
# In the OpenWrt UCI config file for openNDS, add the line:
# 	list fas_custom_images_list 'logo_png=https://raw.githubusercontent.com/openNDS/openNDS/master/resources/avatar.png'
#
# For more details see:
# https://opennds.readthedocs.io/en/stable/customparams.html
#
# Do the download(s):

# This default status.client page can by example show a custom logo:
/usr/lib/opennds/libopennds.sh download "/usr/lib/opennds/download_resources.sh" "" "" "0" "" &>/dev/null

if [ -e "/etc/opennds/htdocs/ndsremote/logo.png" ]; then
	imagepath="ndsremote/logo.png"
else
	imagepath="images/splash.jpg"
fi

if [ "$status" = "status" ] || [ "$status" = "err511" ]; then
	parse_parameters

	if [ -z "$gatewayfqdn" ] || [ "$gatewayfqdn" = "disable" ] || [ "$gatewayfqdn" = "disabled" ]; then
		url="http://$gatewayaddress"
	else
		url="http://$gatewayfqdn"
	fi

	querystr=""

	if [ ! -z "$b64query" ]; then
		ndsctlcmd="b64decode $b64query"
		do_ndsctl
		querystr=$ndsctlout	
		# strip off leading "?" character
		querystr=${querystr:1:1024}
		queryvarlist=""

		for element in $querystr; do
			htmlentityencode "$element"
			element=$entityencoded
			varname=$(echo "$element" | awk -F'=' '$2!="" {printf "%s", $1}')
			queryvarlist="$queryvarlist $varname"
		done

		query=$querystr
		parse_variables
	fi

	if [ "$status" = "err511" ]; then
		# Captive-portal entry (browsers AND CPD probes): forward straight
		# into the standard login flow. HTTP 511 status + daemon redirect
		# behavior is unchanged (protocol set by MHD, not this body), so CPD
		# clients are unaffected; human browsers skip the extra Continue tap
		# via meta-refresh, with the manual button as fallback.
		voucher_forward_page
		exit 0
	fi

	# status branch: busy keeps the stock busy page; otherwise branch on the
	# live voucher session (never the stock account dump).
	if [ "$ndsstatus" = "busy" ]; then
		header
		body
		footer
		exit 0
	fi

	if voucher_session_active; then
		voucher_status_page
		exit 0
	fi

	voucher_forward_page
	exit 0
else
	exit 1
fi
