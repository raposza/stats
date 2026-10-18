#!/usr/bin/env bash
# install-goatcounter.sh - GoatCounter visitor counting for all Raposza sites on raposza.com,
#                          in four echelons DEV, STG, RC, PRD
# Copyright 2026 bentzn
# SPDX-License-Identifier: Apache-2.0
# Author Claude/bentzn
#
# One GoatCounter instance per echelon, each with one site and one dashboard:
#   dev  https://dev.stats.raposza.com  127.0.0.1:30810
#   stg  https://stg.stats.raposza.com  127.0.0.1:30820
#   rc   https://rc.stats.raposza.com   127.0.0.1:30830
#   prd  https://stats.raposza.com      127.0.0.1:30840
#
# Browsers never talk to a stats host to be counted: each site serves
# /_gc/count.js itself and nginx hands /_gc/count to its echelon's GoatCounter
# on loopback, so a site's CSP needs nothing beyond 'self'. The page path is
# prefixed with the site's host (net.raposza.com/api.html), which is what puts
# every site of an echelon on one dashboard.
#
# Promotion: a change is tried on DEV (and STG, RC if wanted) from any copy of
# this file. PRD is applied only from the file on main of $STR_PUBLIC_REPO:
# --echelon prd --apply refuses unless this file's sha256 is that file's. The
# GoatCounter and design versions are pinned below by sha256. Each echelon keeps
# its own binary, so an echelon only moves when it is run. Every --apply records
# the script's sha256 (and for PRD the public commit) in /opt/goatcounter/<e>/source.
#
# Report by default; --apply makes the changes. Rerun-safe.
#   sudo bash install-goatcounter.sh --echelon dev|stg|rc|prd|all [--apply] [--email <dashboard login>]
#
# Per site echelon, after its GoatCounter echelon has run green:
#   nginx, inside the site's server { } block:  include /etc/nginx/goatcounter-<echelon>.inc;
#   HTML, in every page (identical in all echelons):
#     <script data-goatcounter="/_gc/count" async src="/_gc/count.js"></script>
#
# Design: each dashboard follows github.com/raposza/design. Each echelon carries its own
# copy of com.raposza.design:raposza-design (pinned below, sha256-checked), and nginx
# serves a vars.css that maps every GoatCounter colour to the Raposza tokens, Inter and
# Hack as the fonts, the Raposza arcs, and an empty dark.css (the tokens define no
# dark neutrals, so the dashboard stays light). The dashboard's two period fields show
# the user's Date format: rz_dates_js_text is appended to the instance's own backend.js,
# which nginx serves in place of GoatCounter's.
#
# Access: DEV, STG and RC answer only with basic auth (shared file
# /etc/nginx/raposza-echelons.htpasswd, written once). The credentials are never
# in this file: they are read from $DIR_ETC/echelons.auth on the host, one line
# user:password, root 0600, which DEV, STG and RC require and PRD does not.
# PRD shows a page that says "placeholder" until STR_PRD_PAGE is switched to
# "dashboard"; counting runs either way.
#
# GitHub: every echelon runs the same gh-traffic.py daily (timer goatcounter-gh-<echelon>),
# copying the traffic of every public repo of $STR_GH_OWNER into its own dashboard, so all
# four dashboards carry the same GitHub numbers. It needs one fine-grained token with
# Repository permission "Administration: Read-only" in /etc/goatcounter/github.token;
# without that file the timer is installed but not enabled.
set -euo pipefail

STR_VERSION=v2.7.0
STR_SHA256=98d221cb9c8ef2bf76d8daa9cca647839f8d8b0bb5bc7400ff9337c5da834511
STR_URL=https://github.com/arp242/goatcounter/releases/download/${STR_VERSION}/goatcounter-${STR_VERSION}-linux-amd64.gz
STR_DOMAIN=raposza.com
STR_EMAIL=info@raposza.com
FILE_HTPASSWD=/etc/nginx/raposza-echelons.htpasswd
STR_PRD_PAGE=placeholder
STR_PUBLIC_REPO=https://github.com/raposza/stats.git
STR_PUBLIC_BRANCH=main
STR_PUBLIC_FILE=install-goatcounter.sh
STR_DESIGN_VERSION=0.4.0
STR_DESIGN_SHA256=8713317318e1c2922952a6c43409afb819b737ee03c06e19fe34ff6a5b436c8f
STR_DESIGN_URL=https://repo1.maven.org/maven2/com/raposza/design/raposza-design/${STR_DESIGN_VERSION}/raposza-design-${STR_DESIGN_VERSION}.jar
STR_SETTINGS='window.goatcounter={path:function(p){return location.host+p}};'
DIR_ETC=/etc/goatcounter
FILE_AUTH=$DIR_ETC/echelons.auth
STR_GH_OWNER=raposza
FILE_GH_TOKEN=$DIR_ETC/github.token
LST_ECHELONS="dev stg rc prd"

LST_SELECTED=""
FLAG_APPLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) FLAG_APPLY=1 ;;
    --email) shift; STR_EMAIL="${1:?--email needs a value}" ;;
    --echelon)
      shift
      case "${1:-}" in
        dev|stg|rc|prd) LST_SELECTED="$1" ;;
        all) LST_SELECTED="$LST_ECHELONS" ;;
        *) echo "--echelon must be dev, stg, rc, prd or all" >&2; exit 2 ;;
      esac ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done
[ -n "$LST_SELECTED" ] || { echo "usage: sudo bash $0 --echelon dev|stg|rc|prd|all [--apply] [--email <login>]" >&2; exit 2; }

die() { echo "FAIL [${STR_ECHELON:-}]: $*" >&2; exit 1; }
say() { echo "== [${STR_ECHELON:-}] $*"; }

[ "$(id -u)" -eq 0 ] || die "run with sudo"

FILE_SELF=$(readlink -f "${BASH_SOURCE[0]}")
STR_SELF_SHA=$(sha256sum "$FILE_SELF" | cut -d' ' -f1)
STR_AUTH=""
STR_PUBLIC_COMMIT=""
STR_PUBLIC_SHA=""

# ---------------------------------------------------------------- echelon

set_echelon() {
  STR_ECHELON="$1"
  case "$STR_ECHELON" in
    dev) N_PORT=30810 ;;
    stg) N_PORT=30820 ;;
    rc)  N_PORT=30830 ;;
    prd) N_PORT=30840 ;;
  esac
  if [ "$STR_ECHELON" = prd ]; then
    STR_VHOST=stats.$STR_DOMAIN
  else
    STR_VHOST=$STR_ECHELON.stats.$STR_DOMAIN
  fi
  STR_UNIT=goatcounter-$STR_ECHELON
  DIR_OPT=/opt/goatcounter/$STR_ECHELON
  DIR_BIN=$DIR_OPT/bin
  DIR_WEB=$DIR_OPT/web
  DIR_ACME=$DIR_OPT/acme
  DIR_DATA=/var/lib/goatcounter/$STR_ECHELON
  FILE_BIN=$DIR_BIN/goatcounter
  FILE_DB=$DIR_DATA/db.sqlite3
  FILE_PASS=$DIR_ETC/$STR_ECHELON.txt
  FILE_UNIT=/etc/systemd/system/$STR_UNIT.service
  FILE_VHOST=/etc/nginx/conf.d/$STR_VHOST.conf
  FILE_INC=/etc/nginx/goatcounter-$STR_ECHELON.inc
  FILE_COUNTJS=$DIR_WEB/count.js
  FILE_BACKENDJS=$DIR_WEB/backend.js
  DIR_DESIGN=$DIR_WEB/raposza
  DIR_PLACEHOLDER=$DIR_WEB/placeholder
  FILE_DESIGN_VERSION=$DIR_DESIGN/.version
  FILE_CERT=/etc/letsencrypt/live/$STR_VHOST/fullchain.pem
  FILE_KEY=/etc/letsencrypt/live/$STR_VHOST/privkey.pem
  FILE_API=$DIR_ETC/$STR_ECHELON.api
  FILE_ENV=$DIR_ETC/$STR_ECHELON.env
  FILE_GHPY=$DIR_BIN/gh-traffic.py
  FILE_GH_STATE=$DIR_DATA/gh-state.json
  STR_GH_UNIT=goatcounter-gh-$STR_ECHELON
  FILE_GH_SERVICE=/etc/systemd/system/$STR_GH_UNIT.service
  FILE_GH_TIMER=/etc/systemd/system/$STR_GH_UNIT.timer
  FILE_SOURCE=$DIR_OPT/source
}

# ---------------------------------------------------------------- content

unit_text() {
cat <<EOF
# Managed by install-goatcounter.sh - do not edit by hand
[Unit]
Description=GoatCounter $STR_ECHELON (visitor counting for Raposza sites, $STR_VHOST)
After=network.target

[Service]
Type=simple
User=goatcounter
Group=goatcounter
WorkingDirectory=$DIR_DATA
Environment=GOATCOUNTER_TMPDIR=$DIR_DATA/tmp
ExecStart=$FILE_BIN serve -db=sqlite+$FILE_DB -listen=127.0.0.1:$N_PORT -tls=http -automigrate
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$DIR_DATA

[Install]
WantedBy=multi-user.target
EOF
}

proxy_headers() {
cat <<'EOF'
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header X-Real-Ip $remote_addr;
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Cf-Connecting-Ip "";
        proxy_set_header Fly-Client-Ip "";
        proxy_set_header X-Azure-Socketip "";
        proxy_set_header Authorization "";
EOF
}

inc_text() {
cat <<EOF
# Managed by install-goatcounter.sh - do not edit by hand
# GoatCounter $STR_ECHELON ($STR_VHOST). Include inside a $STR_ECHELON site's server { } block:
#   include $FILE_INC;
# Page tag (identical in all echelons):
#   <script data-goatcounter="/_gc/count" async src="/_gc/count.js"></script>
location = /_gc/count.js {
    alias $FILE_COUNTJS;
    expires 1h;
    access_log off;
}
location = /_gc/count {
    proxy_pass http://127.0.0.1:$N_PORT/count;
    proxy_set_header Host $STR_VHOST;
$(proxy_headers)
    access_log off;
}
EOF
}

vhost_http_text() {
cat <<EOF
# Managed by install-goatcounter.sh - do not edit by hand
server {
    listen 80;
    server_name $STR_VHOST;
    location ^~ /.well-known/acme-challenge/ {
        root $DIR_ACME;
        default_type text/plain;
    }
    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF
}

vhost_full_text() {
vhost_http_text
cat <<EOF
server {
    listen 443 ssl;
    server_name $STR_VHOST;
    ssl_certificate     $FILE_CERT;
    ssl_certificate_key $FILE_KEY;
    add_header Strict-Transport-Security "max-age=31536000" always;
$(vhost_auth_text)
    location = /vars.css {
        alias $DIR_WEB/vars.css;
    }
    location = /dark.css {
        alias $DIR_WEB/dark.css;
    }
    location = /backend.js {
        alias $FILE_BACKENDJS;
    }
    location ^~ /raposza/ {
        alias $DIR_DESIGN/;
    }
$(vhost_root_text)
}
EOF
}

placeholder_mode() { [ "$STR_ECHELON" = prd ] && [ "$STR_PRD_PAGE" = placeholder ]; }

vhost_auth_text() {
  [ "$STR_ECHELON" = prd ] && return 0
  printf '    auth_basic "Raposza %s";\n    auth_basic_user_file %s;\n' "$STR_ECHELON" "$FILE_HTPASSWD"
}

vhost_root_text() {
  if placeholder_mode; then
cat <<EOF
    location / {
        root $DIR_PLACEHOLDER;
        try_files /index.html =404;
    }
EOF
  else
cat <<EOF
    location / {
        proxy_pass http://127.0.0.1:$N_PORT;
        proxy_set_header Host \$host;
$(proxy_headers)
    }
EOF
  fi
}

placeholder_text() {
cat <<'EOF'
<!DOCTYPE html>
<html lang="en">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Raposza</title></head>
<body>placeholder</body>
</html>
EOF
}

# The basic-auth credentials of DEV, STG and RC, from $FILE_AUTH. Never in this file.
load_auth() {
  [ -s "$FILE_AUTH" ] || die "$FILE_AUTH is missing; DEV, STG and RC need it: one line user:password, root 0600"
  STR_AUTH=$(head -1 "$FILE_AUTH")
  case "$STR_AUTH" in
    ?*:?*) ;;
    *) die "$FILE_AUTH does not hold user:password on its first line" ;;
  esac
  chown root:root "$FILE_AUTH"
  chmod 0600 "$FILE_AUTH"
}

# Shared by every echelon page on this host; written once, never rewritten
# (the apr1 salt is random, so regenerating would churn the file).
ensure_htpasswd() {
  local strUser="${STR_AUTH%%:*}"
  if ! grep -qs "^$strUser:" "$FILE_HTPASSWD"; then
    printf '%s:%s\n' "$strUser" "$(openssl passwd -apr1 "${STR_AUTH#*:}")" >>"$FILE_HTPASSWD"
  fi
  chown root:nginx "$FILE_HTPASSWD" 2>/dev/null || true
  chmod 0640 "$FILE_HTPASSWD"
}

vars_css_text() {
cat <<'CSSEOF'
/*
 * Author Claude/bentzn
 *
 * Raposza design for the GoatCounter dashboard. nginx serves this file in
 * place of GoatCounter's own /vars.css, so every colour the dashboard draws
 * comes from tokens.css (github.com/raposza/design) and nothing is written
 * as a literal. Managed by install-goatcounter.sh - do not edit by hand.
 */
@import url("/raposza/fonts.css");
@import url("/raposza/tokens.css");

:root {
    --text:              var(--rz-fg);
    --bg:                var(--rz-surface);
    --header-border:     var(--rz-border);
    --backdrop:          var(--rz-bg);
    --target-bg:         var(--rz-code-bg);
    --loading-text:      var(--rz-fg-muted);

    --link:              var(--rz-accent);
    --link-hover:        var(--rz-accent);

    --input-text:        var(--rz-fg);
    --input-bg:          var(--rz-surface);
    --input-border:      var(--rz-border);
    --input-focus:       var(--rz-accent);
    --fieldset-border:   var(--rz-border);
    --form-error-text:   var(--rz-bad);
    --input-error-border: var(--rz-bad);

    --btn-text:          var(--rz-fg);
    --btn-bg:            var(--rz-surface);
    --btn-border:        var(--rz-border);
    --btn-border-outset: var(--rz-border);
    --btn-hover-bg:      var(--rz-bg);
    --btn-active-bg:     var(--rz-code-bg);

    --code-text:         var(--rz-fg);
    --code-bg:           var(--rz-code-bg);
    --code-border:       var(--rz-border);
    --pre-border:        var(--rz-border);

    --tooltip-text:      var(--rz-fg);
    --tooltip-bg:        var(--rz-surface);
    --tooltip-border:    var(--rz-border);
    --tooltip-shadow:    var(--rz-border);

    --chart-line:        var(--rz-accent);
    --chart-fill:        var(--rz-border);
    --chart-grid:        var(--rz-border);
    --hchart-border:     var(--rz-border);
    --hchart-bar:        var(--rz-border);
    --hchart-bar-hover:  var(--rz-code-bg);

    --nav-bg:            var(--rz-surface);
    --nav-border:        var(--rz-border);
    --footer-shadow:     var(--rz-border);
    --filter-kw-text:    var(--rz-accent);

    --info-bg:           var(--rz-surface);
    --info-border:       var(--rz-accent);
    --error-bg:          var(--rz-surface);
    --error-border:      var(--rz-bad);

    --event-bg:          var(--rz-code-bg);
    --pageviews-text:    var(--rz-fg-muted);

    --datepicker-border:             var(--rz-border);
    --datepicker-shadow:             var(--rz-border);
    --datepicker-dayname-text:       var(--rz-fg-muted);
    --datepicker-day-text:           var(--rz-fg);
    --datepicker-day-bg:             var(--rz-code-bg);
    --datepicker-day-hover-bg:       var(--rz-accent);
    --datepicker-today-text:         var(--rz-accent);
    --datepicker-selected-shadow:    var(--rz-accent);
    --datepicker-selected-text:      var(--rz-accent);
    --datepicker-future-text:        var(--rz-fg-disabled);
    --datepicker-future-bg:          var(--rz-bg);
    --datepicker-outside-month-text: var(--rz-fg-disabled);

    --text-table-even-bg:      var(--rz-bg);
    --text-table-border:       var(--rz-border);
    --text-table-rank-text:    var(--rz-fg-muted);

    --widget-border:           var(--rz-border);
    --widget-dragging-border:  var(--rz-accent);
    --widget-dragging-bg:      var(--rz-code-bg);
    --widget-handle-bg:        var(--rz-bg);
    --widget-handle-text:      var(--rz-fg-muted);
    --widget-handle-hover-bg:  var(--rz-code-bg);

    --box-bg:                  var(--rz-surface);
    --box-shadow:              var(--rz-border);

    --plus:                    var(--rz-ok);
    --minus:                   var(--rz-bad);

    /* Type: Inter for the page, Hack for monospace. `:root` outranks the
       dashboard's own `html { font: ... 'Lato' }`, whatever the load order. */
    font-family: var(--rz-font-sans);
    font-size: var(--rz-font-size-large);
}

:root input, :root textarea, :root select, :root button, :root .input,
:root td.right, :root #tooltip {
    font-family: var(--rz-font-sans);
}

:root pre, :root code, :root kbd, :root samp {
    font-family: var(--rz-font-mono);
}

/* Shape: the dashboard's 3 px corners become the Raposza arcs. */
:root textarea, :root select, :root .input,
:root input:not([type="checkbox"]):not([type="file"]):not([type="image"]):not([type="radio"]):not([type="range"]):not(.unstyled) {
    border-radius: var(--rz-arc-text);
}

:root button:not(.link), :root input[type="submit"]:not(.link) {
    border-radius: var(--rz-arc);
    border-style: solid;
}

:root pre {
    border-radius: var(--rz-arc);
}

:root .hchart .bar {
    border-radius: var(--rz-arc-progress);
}
CSSEOF
}

dark_css_text() {
cat <<'CSSEOF'
/* Managed by install-goatcounter.sh - do not edit by hand.
   Served in place of GoatCounter's /dark.css: the Raposza tokens define no dark
   neutrals, so the dashboard stays light. */
CSSEOF
}

rz_dates_js_text() {
cat <<'JSEOF'
/*
 * Author Claude/bentzn
 *
 * Raposza: the dashboard's two period fields in the user's date format
 * (Settings, Preferences, Date format). GoatCounter shows them as native date
 * fields in the browser's locale, or with its own picker as yyyy-mm-dd. This
 * hides both originals, which keep yyyy-mm-dd for the form and the scripts,
 * and puts a text field with a picker in front of each that shows the user's
 * format and writes yyyy-mm-dd back into the original before the form is
 * submitted. Typed input is read as dd-mm-yyyy or yyyy-mm-dd.
 * Appended by install-goatcounter.sh to the instance's own backend.js; do not
 * edit by hand.
 */
;(function() {
	'use strict';

	$(document).ready(function() {
		if (!$('#period-start').length || !window.Pikaday)
			return

		var parse = function(str) {
			var m = /^\s*(\d{1,2})[-./](\d{1,2})[-./](\d{4})\s*$/.exec(str)
			if (m)
				return new Date(+m[3], +m[2] - 1, +m[1])
			m = /^\s*(\d{4})-(\d{1,2})-(\d{1,2})\s*$/.exec(str)
			if (m)
				return new Date(+m[1], +m[2] - 1, +m[3])
			return null
		}

		$('#period-start, #period-end').each(function(_, real) {
			var show = $('<input type="text" autocomplete="off" class="date-input rz-date">').
				attr('title', $(real).attr('title')).
				val(real.value)
			$(real).css('display', 'none').after(show)
			new Pikaday(show[0], {
				toString: function(date) {
					real.value = format_date_ymd(date)
					return format_date(date)
				},
				parse:    parse,
				firstDay: USER_SETTINGS.sunday_starts_week ? 0 : 1,
				minDate:  new Date(SITE_FIRST_HIT_AT),
			})
		})
	})
})();
JSEOF
}

gh_env_text() {
cat <<EOF
# Managed by install-goatcounter.sh - do not edit by hand
GC_URL=http://127.0.0.1:$N_PORT
GC_HOST=$STR_VHOST
GC_TOKEN_FILE=$FILE_API
GH_OWNER=$STR_GH_OWNER
GH_TOKEN_FILE=$FILE_GH_TOKEN
GH_STATE=$FILE_GH_STATE
EOF
}

gh_service_text() {
cat <<EOF
# Managed by install-goatcounter.sh - do not edit by hand
[Unit]
Description=GitHub traffic of $STR_GH_OWNER into GoatCounter $STR_ECHELON ($STR_VHOST)
After=network-online.target $STR_UNIT.service
Wants=network-online.target

[Service]
Type=oneshot
User=goatcounter
Group=goatcounter
EnvironmentFile=$FILE_ENV
ExecStart=/usr/bin/python3 -I $FILE_GHPY
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$DIR_DATA
EOF
}

gh_timer_text() {
cat <<EOF
# Managed by install-goatcounter.sh - do not edit by hand
[Unit]
Description=Daily GitHub traffic copy into GoatCounter $STR_ECHELON

[Timer]
OnCalendar=*-*-* 01:30:00 UTC
RandomizedDelaySec=15min
Persistent=true

[Install]
WantedBy=timers.target
EOF
}

gh_py_text() {
cat <<'GHPYEOF'
#!/usr/bin/env python3
# gh-traffic.py - copies GitHub traffic of every public repo of one owner into a GoatCounter echelon
# Author Claude/bentzn
#
# GitHub keeps 14 days of per-day traffic; this runs daily and copies each COMPLETED
# UTC day exactly once (state file), so up to 13 days of downtime lose nothing.
# GoatCounter counts unique visitors, so each day's `uniques` becomes that many hits
# with distinct session ids on path github.com/<owner>/<repo>; unique cloners become
# events named github.com/<owner>/<repo> clone. GitHub's total view and clone counts
# and its top-10 referrers have no place in that model and are not copied.
#
# Environment (from /etc/goatcounter/<echelon>.env):
#   GC_URL, GC_HOST, GC_TOKEN_FILE, GH_OWNER, GH_TOKEN_FILE, GH_STATE
#   GH_API (optional, default https://api.github.com)
import datetime
import json
import os
import sys
import tempfile
import urllib.error
import urllib.request

N_MAX_HITS = 500


def die(strMsg):
    print('FAIL: ' + strMsg, file=sys.stderr)
    sys.exit(1)


def env(strKey, strDefault=None):
    strValue = os.environ.get(strKey, strDefault)
    if not strValue:
        die('environment variable ' + strKey + ' is not set')
    return strValue


def read_secret(filePath):
    try:
        with open(filePath, encoding='utf-8') as fileIn:
            return fileIn.read().strip()
    except OSError as e:
        die('cannot read ' + filePath + ': ' + str(e))


def gh_get(strUrl, strToken):
    req = urllib.request.Request(strUrl, headers={
        'Authorization': 'Bearer ' + strToken,
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
        'User-Agent': 'raposza-gh-traffic'})
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as e:
        die('GET ' + strUrl + ' -> ' + str(e.code) + ' ' + e.read().decode('utf-8', 'replace')[:300])


def gh_repos(strApi, strOwner, strToken):
    lstRepos = []
    nPage = 1
    while True:
        lstPage = gh_get(strApi + '/users/' + strOwner + '/repos?type=owner&per_page=100&page=' + str(nPage), strToken)
        lstRepos.extend(objRepo['name'] for objRepo in lstPage)
        if len(lstPage) < 100:
            return sorted(lstRepos)
        nPage += 1


def gc_post(strUrl, strHost, strToken, lstHits):
    bytesBody = json.dumps({'filter': [], 'hits': lstHits}).encode('utf-8')
    req = urllib.request.Request(strUrl + '/api/v0/count', data=bytesBody, method='POST', headers={
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ' + strToken,
        'Host': strHost})
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            if resp.status != 202:
                die('GoatCounter answered ' + str(resp.status))
    except urllib.error.HTTPError as e:
        die('POST /api/v0/count -> ' + str(e.code) + ' ' + e.read().decode('utf-8', 'replace')[:300])


def load_state(fileState):
    if not os.path.exists(fileState):
        return set()
    with open(fileState, encoding='utf-8') as fileIn:
        return set(json.load(fileIn))


def save_state(fileState, setDone):
    dirState = os.path.dirname(fileState)
    nFd, fileTmp = tempfile.mkstemp(dir=dirState, prefix='.gh-state.')
    with os.fdopen(nFd, 'w', encoding='utf-8') as fileOut:
        json.dump(sorted(setDone), fileOut, indent=0)
    os.replace(fileTmp, fileState)


def hits_for(strOwner, strRepo, strKind, objDay):
    strDay = objDay['timestamp'][:10]
    strPath = 'github.com/' + strOwner + '/' + strRepo
    flagEvent = strKind == 'clones'
    if flagEvent:
        strPath += ' clone'
    lstHits = []
    for i in range(int(objDay['uniques'])):
        lstHits.append({
            'path': strPath,
            'title': strOwner + '/' + strRepo + (' (clone)' if flagEvent else ''),
            'event': flagEvent,
            'created_at': '%sT%02d:%02d:00Z' % (strDay, (i // 60) % 24, i % 60),
            'session': 'gh|%s|%s|%s|%d' % (strKind, strRepo, strDay, i)})
    return lstHits


def main():
    strGcUrl = env('GC_URL')
    strGcHost = env('GC_HOST')
    strGcToken = read_secret(env('GC_TOKEN_FILE'))
    strOwner = env('GH_OWNER')
    strGhToken = read_secret(env('GH_TOKEN_FILE'))
    fileState = env('GH_STATE')
    strApi = env('GH_API', 'https://api.github.com')

    strToday = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%d')
    setDone = load_state(fileState)
    nDays = 0
    nHits = 0
    lstRepos = gh_repos(strApi, strOwner, strGhToken)
    for strRepo in lstRepos:
        for strKind in ('views', 'clones'):
            objTraffic = gh_get(strApi + '/repos/' + strOwner + '/' + strRepo + '/traffic/' + strKind + '?per=day', strGhToken)
            lstKeys = []
            lstHits = []
            for objDay in objTraffic.get(strKind, []):
                strDay = objDay['timestamp'][:10]
                strKey = '%s|%s|%s' % (strRepo, strKind, strDay)
                if strDay >= strToday or strKey in setDone:
                    continue
                lstKeys.append(strKey)
                lstHits.extend(hits_for(strOwner, strRepo, strKind, objDay))
            for nStart in range(0, len(lstHits), N_MAX_HITS):
                gc_post(strGcUrl, strGcHost, strGcToken, lstHits[nStart:nStart + N_MAX_HITS])
            if lstKeys:
                setDone.update(lstKeys)
                save_state(fileState, setDone)
                nDays += len(lstKeys)
                nHits += len(lstHits)
    print('gh-traffic: %d repos, %d new repo-days, %d unique visitors/cloners copied' % (len(lstRepos), nDays, nHits))


if __name__ == '__main__':
    main()
GHPYEOF
}

# ---------------------------------------------------------------- helpers

# write_if_changed <file> <mode>  (content on stdin); exit 0 = changed, 1 = unchanged
write_if_changed() {
  local fileDst="$1" strMode="$2" fileTmp
  fileTmp=$(mktemp)
  cat >"$fileTmp"
  if [ -f "$fileDst" ] && cmp -s "$fileTmp" "$fileDst"; then
    rm -f "$fileTmp"
    return 1
  fi
  install -m "$strMode" "$fileTmp" "$fileDst"
  rm -f "$fileTmp"
  return 0
}

bin_version() { [ -x "$FILE_BIN" ] && "$FILE_BIN" version 2>/dev/null | sed -n 's/^version=\([^;]*\);.*/\1/p' || true; }

port_owner() { ss -ltnpH "sport = :$N_PORT" 2>/dev/null || true; }

selinux_on() { command -v getenforce >/dev/null && [ "$(getenforce)" = "Enforcing" ]; }

port_labelled() {
  semanage port -l 2>/dev/null | awk '$1=="http_port_t" && $2=="tcp"' | tr -s ', ' '\n' | grep -x "$N_PORT" >/dev/null
}

nginx_can_connect() {
  selinux_on || return 0
  [ "$(getsebool httpd_can_network_connect 2>/dev/null | awk '{print $3}')" = "on" ] && return 0
  port_labelled
}

foreign_vhost() {
  grep -rlsE "server_name[^;]*[[:space:]]$STR_VHOST([[:space:];])" /etc/nginx | grep -vx "$FILE_VHOST" || true
}

dns_ip() { getent ahostsv4 "$STR_VHOST" 2>/dev/null | awk 'NR==1{print $1}'; }

dns_state() {
  local strIp
  strIp=$(dns_ip)
  if [ -z "$strIp" ]; then
    echo "UNRESOLVED"
  elif ip -4 -o addr show | grep -q " $strIp/"; then
    echo "$strIp (this host)"
  else
    echo "$strIp (NOT an address of this host)"
  fi
}

# curl with the basic-auth credentials on DEV, STG and RC; PRD is public
curl_auth() {
  if [ "$STR_ECHELON" = prd ]; then
    curl "$@"
  else
    curl -u "$STR_AUTH" "$@"
  fi
}

wait_status() {
  local nTry
  for nTry in $(seq 1 30); do
    curl -fsS -o /dev/null -H "Host: $STR_VHOST" "http://127.0.0.1:$N_PORT/status" && return 0
    sleep 1
  done
  return 1
}

# Reads main of the public repository anonymously and compares its copy of
# this file with this file. Sets STR_PUBLIC_COMMIT and STR_PUBLIC_SHA; true
# only when the two files are byte for byte the same.
public_matches() {
  local dirTmp
  STR_PUBLIC_COMMIT=""
  STR_PUBLIC_SHA=""
  dirTmp=$(mktemp -d)
  if git clone -q --depth 1 --branch "$STR_PUBLIC_BRANCH" "$STR_PUBLIC_REPO" "$dirTmp/repo" >/dev/null 2>&1; then
    STR_PUBLIC_COMMIT=$(git -C "$dirTmp/repo" rev-parse HEAD 2>/dev/null || true)
    if [ -f "$dirTmp/repo/$STR_PUBLIC_FILE" ]; then
      STR_PUBLIC_SHA=$(sha256sum "$dirTmp/repo/$STR_PUBLIC_FILE" | cut -d' ' -f1)
    fi
  fi
  rm -rf "$dirTmp"
  [ -n "$STR_PUBLIC_SHA" ] && [ "$STR_PUBLIC_SHA" = "$STR_SELF_SHA" ]
}

report_public() {
  local strState
  STR_ECHELON=prd
  if public_matches; then
    strState="MATCHES"
  else
    strState="DIFFERS - prd --apply refuses"
  fi
  say "public $STR_PUBLIC_REPO $STR_PUBLIC_BRANCH"
  printf '  %-26s %s\n' "commit" "${STR_PUBLIC_COMMIT:-unreadable or empty}"
  printf '  %-26s %s\n' "$STR_PUBLIC_FILE" "${STR_PUBLIC_SHA:-absent}"
  printf '  %-26s %s\n' "this file" "$STR_SELF_SHA"
  printf '  %-26s %s\n' "verdict" "$strState"
  [ "$strState" = MATCHES ]
}

# ---------------------------------------------------------------- report

report() {
  local strSites
  say "report $STR_VHOST, 127.0.0.1:$N_PORT"
  printf '  %-26s %s\n' "dns" "$(dns_state)"
  printf '  %-26s %s\n' "binary" "$(bin_version) (pinned $STR_VERSION)"
  printf '  %-26s %s\n' "database" "$( [ -f "$FILE_DB" ] && echo present || echo absent)"
  printf '  %-26s %s\n' "service $STR_UNIT" "$(systemctl is-active "$STR_UNIT" 2>/dev/null || true)"
  printf '  %-26s %s\n' "port $N_PORT" "$(port_owner | awk '{print $NF}' | head -1)"
  printf '  %-26s %s\n' "nginx -> 127.0.0.1:$N_PORT" "$(nginx_can_connect && echo allowed || echo BLOCKED-by-selinux)"
  printf '  %-26s %s\n' "certificate" "$( [ -f "$FILE_CERT" ] && echo present || echo absent)"
  printf '  %-26s %s\n' "vhost" "$( [ -f "$FILE_VHOST" ] && echo present || echo absent)"
  printf '  %-26s %s\n' "include" "$( [ -f "$FILE_INC" ] && echo present || echo absent)"
  printf '  %-26s %s\n' "count.js" "$( [ -f "$FILE_COUNTJS" ] && echo present || echo absent)"
  printf '  %-26s %s\n' "backend.js (date fields)" "$( grep -s 'rz-date' "$FILE_BACKENDJS" >/dev/null && echo present || echo absent)"
  printf '  %-26s %s\n' "design package" "$(cat "$FILE_DESIGN_VERSION" 2>/dev/null || echo absent) (pinned $STR_DESIGN_VERSION)"
  printf '  %-26s %s\n' "api token (count)" "$( [ -f "$FILE_API" ] && echo present || echo absent)"
  printf '  %-26s %s\n' "timer $STR_GH_UNIT" "$(systemctl is-enabled "$STR_GH_UNIT.timer" 2>/dev/null || true)"
  printf '  %-26s %s\n' "github repo-days copied" "$( [ -f "$FILE_GH_STATE" ] && python3 -I -c 'import json,sys;print(len(json.load(open(sys.argv[1]))))' "$FILE_GH_STATE" || echo 0)"
  printf '  %-26s %s\n' "last applied from" "$( [ -f "$FILE_SOURCE" ] && tr '\n' ' ' <"$FILE_SOURCE" || echo unrecorded)"
  printf '  %-26s %s\n' "other $STR_VHOST vhost" "$(foreign_vhost | tr '\n' ' ')"
  strSites=$(grep -rlsF "include $FILE_INC" /etc/nginx --include='*.conf' || true)
  printf '  %-26s %s\n' "sites including it" "$(echo "${strSites:-none}" | tr '\n' ' ')"
}

report_host() {
  local strCmd
  STR_ECHELON=host
  say "report $(hostname -f 2>/dev/null || hostname)"
  for strCmd in curl gunzip sha256sum openssl runuser ss ip getent nginx certbot systemctl python3; do
    printf '  %-26s %s\n' "$strCmd" "$(command -v "$strCmd" || echo MISSING)"
  done
  printf '  %-26s %s\n' "user goatcounter" "$(id goatcounter 2>/dev/null || echo absent)"
  printf '  %-26s %s\n' "selinux" "$(command -v getenforce >/dev/null && getenforce || echo n/a)"
  printf '  %-26s %s\n' "semanage" "$(command -v semanage || echo absent)"
  printf '  %-26s %s\n' "letsencrypt account" "$(ls -A /etc/letsencrypt/accounts 2>/dev/null | head -1 || true)"
  printf '  %-26s %s\n' "github token" "$( [ -s "$FILE_GH_TOKEN" ] && echo present || echo "absent ($FILE_GH_TOKEN)")"
  printf '  %-26s %s\n' "basic-auth credentials" "$( [ -s "$FILE_AUTH" ] && echo present || echo "absent ($FILE_AUTH)")"
  printf '  %-26s %s\n' "git" "$(command -v git || echo MISSING)"
  printf '  %-26s %s\n' "this file sha256" "$STR_SELF_SHA"
}

# ---------------------------------------------------------------- apply

apply() {
  local strCmd flagRestart=0 flagReload strPass strToken fileTmp dirTmp strOwner

  say "preflight"
  for strCmd in curl gunzip sha256sum openssl runuser ss ip getent nginx certbot systemctl python3; do
    command -v "$strCmd" >/dev/null || die "$strCmd not installed"
  done
  [ -n "$(dns_ip)" ] || die "$STR_VHOST does not resolve; add its DNS A record first"
  [ -n "$(foreign_vhost)" ] && die "$STR_VHOST is already served by: $(foreign_vhost)"
  strOwner=$(port_owner)
  if [ -n "$strOwner" ] && ! echo "$strOwner" | grep -q goatcounter; then
    die "port $N_PORT is taken: $strOwner"
  fi
  if [ ! -f "$FILE_CERT" ] && [ -z "$(ls -A /etc/letsencrypt/accounts 2>/dev/null)" ]; then
    die "no certbot account under /etc/letsencrypt/accounts"
  fi
  if [ "$STR_ECHELON" = prd ]; then
    command -v git >/dev/null || die "git not installed; prd reads $STR_PUBLIC_REPO with it"
    public_matches || die "this file is not the one on $STR_PUBLIC_BRANCH of $STR_PUBLIC_REPO (public ${STR_PUBLIC_SHA:-absent}, this $STR_SELF_SHA)"
  else
    load_auth
  fi

  say "user and directories"
  id goatcounter >/dev/null 2>&1 || useradd --system --home-dir /var/lib/goatcounter --no-create-home --shell /sbin/nologin goatcounter
  install -d -o root -g root -m 0755 /opt/goatcounter "$DIR_OPT" "$DIR_BIN" "$DIR_WEB" "$DIR_ACME"
  install -d -o goatcounter -g goatcounter -m 0750 /var/lib/goatcounter "$DIR_DATA" "$DIR_DATA/tmp"
  install -d -o root -g goatcounter -m 0750 "$DIR_ETC"
  chown root:goatcounter "$DIR_ETC"
  chmod 0750 "$DIR_ETC"

  say "binary $STR_VERSION"
  if [ "$(bin_version)" != "$STR_VERSION" ]; then
    dirTmp=$(mktemp -d)
    curl -fsSL -o "$dirTmp/gc.gz" "$STR_URL"
    echo "$STR_SHA256  $dirTmp/gc.gz" | sha256sum -c --quiet - || die "sha256 mismatch on $STR_URL"
    gunzip "$dirTmp/gc.gz"
    install -m 0755 "$dirTmp/gc" "$FILE_BIN"
    rm -rf "$dirTmp"
    flagRestart=1
  fi
  [ "$(bin_version)" = "$STR_VERSION" ] || die "binary does not report $STR_VERSION"

  say "site $STR_VHOST"
  if [ ! -f "$FILE_DB" ]; then
    strPass=$(openssl rand -base64 18)
    ( cd "$DIR_DATA" && runuser -u goatcounter -- "$FILE_BIN" db create site -createdb \
        -db="sqlite+$FILE_DB" -vhost="$STR_VHOST" -user.email="$STR_EMAIL" -password="$strPass" )
    ( umask 077
      printf 'url      https://%s\nlogin    %s\npassword %s\n' "$STR_VHOST" "$STR_EMAIL" "$strPass" >"$FILE_PASS" )
  fi

  say "systemd unit $STR_UNIT"
  if unit_text | write_if_changed "$FILE_UNIT" 0644; then
    systemctl daemon-reload
    flagRestart=1
  fi
  systemctl enable "$STR_UNIT" >/dev/null 2>&1
  if [ "$flagRestart" -eq 1 ] || ! systemctl is-active -q "$STR_UNIT"; then
    systemctl restart "$STR_UNIT"
  fi
  wait_status || die "$STR_UNIT does not answer /status on 127.0.0.1:$N_PORT (journalctl -u $STR_UNIT)"

  say "count.js (settings + the instance's own count.js)"
  fileTmp=$(mktemp)
  curl -fsS -H "Host: $STR_VHOST" "http://127.0.0.1:$N_PORT/count.js" -o "$fileTmp"
  grep -q 'window.goatcounter' "$fileTmp" || die "count.js from the instance looks wrong"
  { printf '%s\n' "$STR_SETTINGS"; cat "$fileTmp"; } | write_if_changed "$FILE_COUNTJS" 0644 || true
  rm -f "$fileTmp"

  say "backend.js (the instance's own backend.js + the Raposza date fields)"
  fileTmp=$(mktemp)
  curl -fsS -H "Host: $STR_VHOST" "http://127.0.0.1:$N_PORT/backend.js" -o "$fileTmp"
  grep 'page_dashboard' "$fileTmp" >/dev/null || die "backend.js from the instance looks wrong"
  { cat "$fileTmp"; printf '\n'; rz_dates_js_text; } | write_if_changed "$FILE_BACKENDJS" 0644 || true
  rm -f "$fileTmp"

  say "design raposza-design $STR_DESIGN_VERSION"
  if [ "$(cat "$FILE_DESIGN_VERSION" 2>/dev/null || true)" != "$STR_DESIGN_VERSION" ]; then
    dirTmp=$(mktemp -d)
    curl -fsSL -o "$dirTmp/design.jar" "$STR_DESIGN_URL"
    echo "$STR_DESIGN_SHA256  $dirTmp/design.jar" | sha256sum -c --quiet - || die "sha256 mismatch on $STR_DESIGN_URL"
    python3 -I -c 'import os, shutil, sys, zipfile
strPrefix = "META-INF/resources/raposza/"
with zipfile.ZipFile(sys.argv[1]) as zipJar:
    for strName in zipJar.namelist():
        if strName.startswith(strPrefix) and strName.endswith((".css", ".svg", ".woff2", ".md", ".txt")):
            fileDst = os.path.join(sys.argv[2], strName[len(strPrefix):])
            os.makedirs(os.path.dirname(fileDst), exist_ok=True)
            with zipJar.open(strName) as fileIn, open(fileDst, "wb") as fileOut:
                shutil.copyfileobj(fileIn, fileOut)' "$dirTmp/design.jar" "$dirTmp/raposza"
    for strNeeded in fonts.css tokens.css fonts/InterVariable.woff2 fonts/hack-regular.woff2; do
      [ -f "$dirTmp/raposza/$strNeeded" ] || die "raposza-design $STR_DESIGN_VERSION has no $strNeeded"
    done
    printf '%s\n' "$STR_DESIGN_VERSION" >"$dirTmp/raposza/.version"
    chmod -R u=rwX,go=rX "$dirTmp/raposza"
    rm -rf "$DIR_DESIGN"
    mv "$dirTmp/raposza" "$DIR_DESIGN"
    rm -rf "$dirTmp"
  fi
  vars_css_text | write_if_changed "$DIR_WEB/vars.css" 0644 || true
  install -d -m 0755 "$DIR_PLACEHOLDER"
  placeholder_text | write_if_changed "$DIR_PLACEHOLDER/index.html" 0644 || true
  dark_css_text | write_if_changed "$DIR_WEB/dark.css" 0644 || true

  say "github traffic $STR_GH_UNIT"
  [ -x /usr/bin/python3 ] || die "/usr/bin/python3 not found"
  if [ ! -s "$FILE_API" ]; then
    ( cd "$DIR_DATA" && runuser -u goatcounter -- "$FILE_BIN" db create apitoken \
        -db="sqlite+$FILE_DB" -user=1 -name=github-traffic -perm=count )
    strToken=$(python3 -I -c 'import sqlite3,sys
c = sqlite3.connect("file:" + sys.argv[1] + "?mode=ro", uri=True)
r = c.execute("select token from api_tokens where name = ? order by api_token_id desc limit 1", ("github-traffic",)).fetchone()
print(r[0] if r else "")' "$FILE_DB")
    [ -n "$strToken" ] || die "API token github-traffic not found in $FILE_DB"
    ( umask 077; printf '%s\n' "$strToken" >"$FILE_API" )
  fi
  chown root:goatcounter "$FILE_API"
  chmod 0640 "$FILE_API"
  gh_py_text | write_if_changed "$FILE_GHPY" 0755 || true
  gh_env_text | write_if_changed "$FILE_ENV" 0640 || true
  chown root:goatcounter "$FILE_ENV"
  flagReload=0
  gh_service_text | write_if_changed "$FILE_GH_SERVICE" 0644 && flagReload=1
  gh_timer_text | write_if_changed "$FILE_GH_TIMER" 0644 && flagReload=1
  [ "$flagReload" -eq 1 ] && systemctl daemon-reload
  if [ -s "$FILE_GH_TOKEN" ]; then
    chown root:goatcounter "$FILE_GH_TOKEN"
    chmod 0640 "$FILE_GH_TOKEN"
    systemctl enable --now "$STR_GH_UNIT.timer" >/dev/null 2>&1
    systemctl start "$STR_GH_UNIT.service" \
      || die "$STR_GH_UNIT failed (journalctl -u $STR_GH_UNIT)"
    journalctl -u "$STR_GH_UNIT" -n 1 -o cat --no-pager | sed 's/^/  /'
  else
    echo "  $FILE_GH_TOKEN absent: timer installed, not enabled"
  fi

  if selinux_on; then
    say "selinux"
    if command -v semanage >/dev/null; then
      semanage fcontext -l | grep -F "/opt/goatcounter/[^/]+/(web|acme)(/.*)?" >/dev/null \
        || semanage fcontext -a -t httpd_sys_content_t "/opt/goatcounter/[^/]+/(web|acme)(/.*)?"
      restorecon -R "$DIR_WEB" "$DIR_ACME"
    else
      chcon -R -t httpd_sys_content_t "$DIR_WEB" "$DIR_ACME"
    fi
    if ! nginx_can_connect; then
      command -v semanage >/dev/null || die "nginx may not connect to port $N_PORT and semanage is absent (dnf install policycoreutils-python-utils)"
      semanage port -a -t http_port_t -p tcp "$N_PORT"
    fi
  fi

  [ "$STR_ECHELON" = prd ] || ensure_htpasswd

  say "nginx include $FILE_INC"
  inc_text | write_if_changed "$FILE_INC" 0644 || true

  say "nginx vhost $STR_VHOST"
  if [ ! -f "$FILE_CERT" ]; then
    vhost_http_text | write_if_changed "$FILE_VHOST" 0644 || true
    nginx -t
    systemctl reload nginx
    certbot certonly --webroot -w "$DIR_ACME" -d "$STR_VHOST" --non-interactive --agree-tos \
      --deploy-hook "systemctl reload nginx"
  fi
  if vhost_full_text | write_if_changed "$FILE_VHOST" 0644; then
    nginx -t
    systemctl reload nginx
    # an old worker can still answer right after a reload; measured 2026-10-17 on dev
    sleep 3
  fi

  say "control"
  if placeholder_mode; then
    curl -fsS --resolve "$STR_VHOST:443:127.0.0.1" "https://$STR_VHOST/" | grep -q 'placeholder' \
      || die "https://$STR_VHOST/ does not serve the placeholder"
    echo "  https://$STR_VHOST/ serves the placeholder"
  else
    if [ "$STR_ECHELON" != prd ]; then
      strCode=$(curl -sS -o /dev/null -w '%{http_code}' --resolve "$STR_VHOST:443:127.0.0.1" "https://$STR_VHOST/status" || true)
      [ "$strCode" = 401 ] || die "https://$STR_VHOST/status without credentials answered $strCode, wanted 401"
      echo "  https://$STR_VHOST/ refuses without basic auth"
    fi
    curl_auth -fsS -o /dev/null --resolve "$STR_VHOST:443:127.0.0.1" "https://$STR_VHOST/status" \
      || die "https://$STR_VHOST/status does not answer through nginx"
    curl_auth -fsS --resolve "$STR_VHOST:443:127.0.0.1" "https://$STR_VHOST/count.js" | grep -q 'window.goatcounter' \
      || die "https://$STR_VHOST/count.js does not answer through nginx"
    echo "  https://$STR_VHOST/status OK"
  fi
  curl_auth -fsS --resolve "$STR_VHOST:443:127.0.0.1" "https://$STR_VHOST/backend.js" | grep 'rz-date' >/dev/null \
    || die "https://$STR_VHOST/backend.js does not carry the Raposza date fields"
  echo "  https://$STR_VHOST/backend.js carries the date fields"

  say "source $FILE_SOURCE"
  {
    printf 'script_sha256=%s\n' "$STR_SELF_SHA"
    if [ "$STR_ECHELON" = prd ]; then
      printf 'public_commit=%s\n' "$STR_PUBLIC_COMMIT"
    fi
    printf 'applied=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } | write_if_changed "$FILE_SOURCE" 0644 || true
  sed 's/^/  /' "$FILE_SOURCE"
  cat "$FILE_PASS"
}

# ---------------------------------------------------------------- main

report_host
case " $LST_SELECTED " in
  *" prd "*)
    if ! report_public && [ "$FLAG_APPLY" -eq 1 ]; then
      die "this file is not the one on $STR_PUBLIC_BRANCH of $STR_PUBLIC_REPO; nothing was applied"
    fi ;;
esac
for STR_ECHELON_ARG in $LST_SELECTED; do
  set_echelon "$STR_ECHELON_ARG"
  report
  if [ "$FLAG_APPLY" -eq 1 ]; then
    apply
    say "GREEN"
    report
  fi
done
[ "$FLAG_APPLY" -eq 1 ] || { STR_ECHELON=host; say "report only; rerun with --apply"; }
