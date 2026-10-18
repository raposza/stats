#!/usr/bin/env bash
# test.sh - static checks of install-goatcounter.sh: the script parses, the
# Python and JavaScript it installs compile, and it carries no credential.
# Runs unprivileged out of a temporary directory that is removed on exit.
# Copyright 2026 bentzn
# SPDX-License-Identifier: Apache-2.0
# Author Claude/bentzn
set -euo pipefail
cd "$(dirname "$0")"

fileInst=install-goatcounter.sh
dirTmp=$(mktemp -d)
trap 'rm -rf "$dirTmp"' EXIT
fail=0

ok()  { printf 'ok    %s\n' "$*"; }
red() { printf 'FAIL  %s\n' "$*"; fail=1; }

# the body of a quoted heredoc: the lines between "cat <<'<tag>'" and "<tag>"
extract() { awk -v strOpen="cat <<'$1'" -v strClose="$1" '$0==strOpen{f=1;next} $0==strClose{f=0} f' "$fileInst"; }

bash -n "$fileInst" && ok "$fileInst parses" || red "$fileInst does not parse"

extract GHPYEOF >"$dirTmp/gh-traffic.py"
if [ ! -s "$dirTmp/gh-traffic.py" ]; then
  red "gh-traffic.py not found in $fileInst"
elif python3 -I -m py_compile "$dirTmp/gh-traffic.py"; then
  ok "gh-traffic.py compiles"
else
  red "gh-traffic.py does not compile"
fi

extract JSEOF >"$dirTmp/dates.js"
if [ ! -s "$dirTmp/dates.js" ]; then
  red "the date-field script not found in $fileInst"
elif ! command -v node >/dev/null; then
  printf 'info  node absent; the date-field script was not syntax-checked\n'
elif node --check "$dirTmp/dates.js"; then
  ok "the date-field script parses"
else
  red "the date-field script does not parse"
fi

extract CSSEOF >"$dirTmp/css"
grep -q -- '--rz-accent' "$dirTmp/css" && ok "vars.css maps to the Raposza tokens" || red "vars.css not found or not mapped"

if grep -nE '^[A-Z_]*(PASS|PASSWORD|SECRET|TOKEN)=[^$]' "$fileInst"; then
  red "$fileInst assigns a literal credential"
else
  ok "$fileInst assigns no literal credential"
fi

[ "$fail" -eq 0 ] && { echo "test.sh: GREEN"; exit 0; } || { echo "test.sh: RED"; exit 1; }
