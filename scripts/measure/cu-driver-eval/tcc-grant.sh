#!/usr/bin/env bash
# Grants Accessibility, event posting and screen capture to each executable named, in a throwaway
# macOS VM with SIP off (scripts/measure/cu-driver-bench.sh suite=input-ab). Only there: it writes
# the TCC database directly, which SIP forbids on a real Mac, and a fleet worker is never touched.
#   tcc-grant.sh PATH...
#   tcc-grant.sh --diagnose     the rows for these clients, the table's schema and tccd's recent
#                               decisions, for a run whose grants did not take
# Each PATH is granted by path, with its designated requirement when it has a signature, in the
# system database, where macOS keeps these three services. Then tccd restarts so the rows are read.
# Needs passwordless sudo. Prints one line per grant; exits 3 when SIP is on, 1 when a write fails.
set -uo pipefail
csrutil status 2>/dev/null | grep -q disabled || { echo "tcc-grant.sh: SIP is on; refusing" >&2; exit 3; }
system_db="/Library/Application Support/com.apple.TCC/TCC.db"
if [[ "${1:-}" == --diagnose ]]; then
  echo "== access rows"
  sudo -n sqlite3 "$system_db" "SELECT service, client, client_type, auth_value, auth_reason, auth_version, length(csreq), flags
    FROM access WHERE client LIKE '%cu-eval%' OR client LIKE '%bash%' OR client LIKE '%python%' OR client LIKE '%Python%'
    OR client LIKE '%driver%' OR client LIKE '%cmux-cua%' OR client LIKE 'com.cmuxterm.%';"
  echo "== schema"
  sudo -n sqlite3 "$system_db" ".schema access"
  echo "== tccd, last 10 minutes"
  sudo -n log show --last 10m --style compact --predicate 'process == "tccd"' 2>/dev/null |
    grep -i -E "attribution|responsible|requirement|csreq|AUTHREQ|cu-eval|/bin/bash|python|denied|kTCCService(Accessibility|PostEvent|ScreenCapture)" | tail -200
  exit 0
fi
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
status=0
for path in "$@"; do
  path=$(cd "$(dirname "$path")" && pwd -P)/$(basename "$path")
  [[ -x "$path" ]] || { echo "tcc-grant.sh: $path is not an executable" >&2; status=1; continue; }
  csreq=NULL
  # codesign writes the requirement among its other -d lines, on stderr on some releases: read both.
  # An ad-hoc signature's requirement is its cdhash, printed as a comment: "# designated => cdhash H"..."".
  if requirement=$(codesign -d -r- "$path" 2>&1 | sed -n 's/^\(# \)\{0,1\}designated => //p' | head -1) && [[ -n "$requirement" ]] &&
    csreq -r- -b "$work/req" <<<"$requirement" 2>/dev/null; then
    csreq="X'$(xxd -p "$work/req" | tr -d '\n')'"
  fi
  # client_type 1 is a path. An app bundle's executable is also looked up by the bundle's id
  # (client_type 0), so it gets a row under that id too.
  clients=("1:$path")
  if [[ "$path" == *.app/Contents/MacOS/* ]]; then
    bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${path%/MacOS/*}/Info.plist" 2>/dev/null)
    [[ "$bundle_id" =~ ^[A-Za-z0-9.-]+$ ]] && clients+=("0:$bundle_id")
  fi
  for entry in "${clients[@]}"; do
    client_type=${entry%%:*} client=${entry#*:}
    quoted=${client//\'/\'\'}
    for service in kTCCServiceAccessibility kTCCServicePostEvent kTCCServiceScreenCapture; do
      # auth_value 2 is allowed; auth_reason 4 is "set by the system".
      row="INSERT OR REPLACE INTO access (service, client, client_type, auth_value, auth_reason, auth_version,
        csreq, policy_id, indirect_object_identifier_type, indirect_object_identifier, flags, last_modified,
        boot_uuid, last_reminded) VALUES ('$service', '$quoted', $client_type, 2, 4, 1, $csreq, NULL, 0, 'UNUSED', 0,
        CAST(strftime('%s','now') AS INTEGER), 'UNUSED', CAST(strftime('%s','now') AS INTEGER));"
      sudo -n sqlite3 "$system_db" "$row" || { echo "tcc-grant.sh: $service for $client: system write failed" >&2; status=1; }
    done
  done
  echo "tcc-grant.sh: granted ${clients[*]} (csreq ${csreq:0:4})"
done
sudo -n launchctl kickstart -k system/com.apple.tccd >/dev/null 2>&1 || true
# The user's tccd may hold an earlier answer; from inside the login session this restarts it too.
launchctl kickstart -k "gui/$(id -u)/com.apple.tccd" >/dev/null 2>&1 || true
sleep 2 # tccd answers once it has reread the databases
exit $status
