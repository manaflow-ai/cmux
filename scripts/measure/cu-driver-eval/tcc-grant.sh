#!/usr/bin/env bash
# Grants Accessibility, event posting and screen capture to each executable named, in a throwaway
# macOS VM with SIP off (scripts/measure/cu-driver-bench.sh suite=input-ab). Only there: it writes
# the TCC databases directly, which SIP forbids on a real Mac, and a fleet worker is never touched.
#   tcc-grant.sh PATH...
# Each PATH is granted by path, with its designated requirement when it has a signature, in the
# system database (where macOS keeps these three services) and the user's. Then both tccd instances
# restart so the rows are read. Needs passwordless sudo. Prints one line per grant; exits 3 when
# SIP is on, 1 when a write fails.
set -uo pipefail
csrutil status 2>/dev/null | grep -q disabled || { echo "tcc-grant.sh: SIP is on; refusing" >&2; exit 3; }
system_db="/Library/Application Support/com.apple.TCC/TCC.db"
user_db="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
status=0
for path in "$@"; do
  path=$(cd "$(dirname "$path")" && pwd -P)/$(basename "$path")
  [[ -x "$path" ]] || { echo "tcc-grant.sh: $path is not an executable" >&2; status=1; continue; }
  csreq=NULL
  if requirement=$(codesign -d -r- "$path" 2>/dev/null | sed -n 's/^designated => //p') && [[ -n "$requirement" ]] &&
    csreq -r- -b "$work/req" <<<"$requirement" 2>/dev/null; then
    csreq="X'$(xxd -p "$work/req" | tr -d '\n')'"
  fi
  quoted=${path//\'/\'\'}
  for service in kTCCServiceAccessibility kTCCServicePostEvent kTCCServiceScreenCapture; do
    # client_type 1 is a path; auth_value 2 is allowed; auth_reason 4 is "set by the system".
    row="INSERT OR REPLACE INTO access (service, client, client_type, auth_value, auth_reason, auth_version,
      csreq, policy_id, indirect_object_identifier_type, indirect_object_identifier, flags, last_modified,
      boot_uuid, last_reminded) VALUES ('$service', '$quoted', 1, 2, 4, 1, $csreq, NULL, 0, 'UNUSED', 0,
      CAST(strftime('%s','now') AS INTEGER), 'UNUSED', CAST(strftime('%s','now') AS INTEGER));"
    sudo -n sqlite3 "$system_db" "$row" || { echo "tcc-grant.sh: $service for $path: system write failed" >&2; status=1; }
    [[ -f "$user_db" ]] && { sudo -n sqlite3 "$user_db" "$row" 2>/dev/null || true; }
  done
  echo "tcc-grant.sh: granted $path (csreq ${csreq:0:4})"
done
sudo -n launchctl kickstart -k system/com.apple.tccd >/dev/null 2>&1 || true
launchctl kickstart -k "gui/$(id -u)/com.apple.tccd" >/dev/null 2>&1 || true
sleep 2 # tccd answers once it has reread the databases
exit $status
