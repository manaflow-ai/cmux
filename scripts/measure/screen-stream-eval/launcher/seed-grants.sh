#!/usr/bin/env bash
# Writes the two console grants CmuxScreenEvalLauncher.app needs (Screen Recording, Accessibility) into the
# system TCC database, the rows a person's click in System Settings makes, keyed to this exact signed binary
# (its designated requirement as csreq). For a dedicated fleet Mac only: screen-stream-eval.sh calls it with
# seed-grants=1 inside a fleet console step (CMUX_CI_CONSOLE_SESSION=1 and CMUX_CI_STEP_KEY), after
# person_guard.py has refused a person's Mac. The same write the zero-touch screen-share probe makes for the
# app's Mac Screen helper (cmuxterm-hq tools/fleet-reconcilers/two_mac_flows.py seed_screen_recording).
# A grant already held is left alone. Prints one JSON line, each service "held", "seeded" or "refused: WHY";
# exits 0 when both are held or seeded, 1 otherwise.
#   seed-grants.sh APP
set -uo pipefail
app="${1:?usage: seed-grants.sh APP}"
tcc="${CMUX_SCREEN_EVAL_TCC_DB:-/Library/Application Support/com.apple.TCC/TCC.db}"
json() { python3 -I -c 'import json,sys; print(json.dumps(dict(zip(sys.argv[1::2], sys.argv[2::2]))))' "$@"; }
one_line() { tr '\n' ' ' | tr -s ' ' | cut -c1-200; }
ident=$(python3 -I -c 'import plistlib,sys; print(plistlib.load(open(sys.argv[1], "rb")).get("CFBundleIdentifier", ""))' \
  "$app/Contents/Info.plist" 2>/dev/null)
if [[ ! "$ident" =~ ^[A-Za-z0-9.-]+$ ]]; then
  json app "$app" screen_recording "refused: no bundle id in $app" accessibility "refused: no bundle id in $app"
  exit 1
fi
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
csreq_hex=""
csreq_why=""
req=$(codesign -d -r- "$app" 2>&1)
designated=$(sed -n 's/^designated => //p' <<<"$req" | head -1)
if [[ -z "$designated" ]]; then
  csreq_why="codesign gave no designated requirement ($(one_line <<<"$req"))"
elif ! said=$(csreq -r- -b "$work/app.csreq" <<<"$designated" 2>&1) || [[ ! -s "$work/app.csreq" ]]; then
  csreq_why="csreq: $(one_line <<<"$said")"
else
  csreq_hex=$(od -An -v -tx1 "$work/app.csreq" | tr -d ' \n')
fi
ok=0
results=(app "$app")
for pair in screen_recording:kTCCServiceScreenCapture accessibility:kTCCServiceAccessibility; do
  key="${pair%%:*}" service="${pair#*:}"
  held=$(sudo -n sqlite3 "$tcc" "SELECT auth_value FROM access WHERE service='$service' AND client='$ident' AND client_type=0;" 2>&1)
  read_status=$?
  if [[ "$read_status" == 0 ]] && grep -qx 2 <<<"$held"; then
    results+=("$key" held)
    continue
  fi
  if [[ "$read_status" != 0 ]]; then
    results+=("$key" "refused: sudo -n sqlite3 TCC.db read exit $read_status: $(one_line <<<"$held")")
    ok=1
    continue
  fi
  if [[ -z "$csreq_hex" ]]; then
    results+=("$key" "refused: $csreq_why")
    ok=1
    continue
  fi
  sql="INSERT OR REPLACE INTO access (service, client, client_type, auth_value, auth_reason, auth_version, csreq, policy_id, indirect_object_identifier_type, indirect_object_identifier, indirect_object_code_identity, flags, last_modified) VALUES ('$service','$ident',0,2,4,1,X'$csreq_hex',NULL,0,'UNUSED',NULL,0,CAST(strftime('%s','now') AS INTEGER));"
  if ! said=$(sudo -n sqlite3 "$tcc" "$sql" 2>&1); then
    results+=("$key" "refused: sudo -n sqlite3 TCC.db write: $(one_line <<<"$said")")
    ok=1
    continue
  fi
  back=$(sudo -n sqlite3 "$tcc" "SELECT auth_value FROM access WHERE service='$service' AND client='$ident' AND client_type=0;" 2>/dev/null)
  if grep -qx 2 <<<"$back"; then
    results+=("$key" seeded)
  else
    results+=("$key" "refused: the row it wrote does not read back")
    ok=1
  fi
done
json "${results[@]}"
exit "$ok"
