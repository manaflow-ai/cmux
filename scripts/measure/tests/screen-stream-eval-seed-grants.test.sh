#!/usr/bin/env bash
# seed-grants.sh against a real sqlite TCC table and fake sudo/codesign/csreq: it writes both rows, keyed to the
# app's designated requirement, leaves a held grant alone, and names what refused it. screen-stream-eval.sh calls
# it only with seed-grants=1 inside a fleet console step.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
seed="$root/screen-stream-eval/launcher/seed-grants.sh"
harness="$root/screen-stream-eval.sh"
fail=0
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
mkdir -p "$t/bin" "$t/App.app/Contents"
cat >"$t/App.app/Contents/Info.plist" <<'P'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>ai.manaflow.cmux-screen-eval-launcher</string></dict></plist>
P
printf '#!/bin/sh\n[ "$1" = -n ] && shift\nexec "$@"\n' >"$t/bin/sudo"
printf '#!/bin/sh\necho "Executable=/x"\necho "designated => cdhash H\\"abc123\\""\n' >"$t/bin/codesign"
# csreq -r- -b FILE: compiles the requirement on stdin into FILE.
printf '#!/bin/sh\ncat >"$3"\n' >"$t/bin/csreq"
# sqlite3 DB SQL, on Python's sqlite3 (the same engine), so the test needs no sqlite3 binary.
cat >"$t/bin/sqlite3" <<'S'
#!/usr/bin/env python3
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
for row in con.execute(sys.argv[2]) if sys.argv[2].count(";") <= 1 else con.executescript(sys.argv[2]):
    print("|".join("" if v is None else v.hex().upper() if isinstance(v, bytes) else str(v) for v in row))
con.commit()
S
chmod +x "$t/bin/"*
db="$t/TCC.db"
"$t/bin/sqlite3" "$db" "CREATE TABLE access (service TEXT, client TEXT, client_type INTEGER, auth_value INTEGER, auth_reason INTEGER,
  auth_version INTEGER, csreq BLOB, policy_id INTEGER, indirect_object_identifier_type INTEGER,
  indirect_object_identifier TEXT, indirect_object_code_identity BLOB, flags INTEGER, last_modified INTEGER,
  PRIMARY KEY (service, client, client_type, indirect_object_identifier));"
run() { PATH="$t/bin:$PATH" CMUX_SCREEN_EVAL_TCC_DB="$db" bash "$seed" "$t/App.app"; }

out=$(run) || { echo "FAIL: seeding an empty table exited non-zero: $out"; fail=1; }
[[ "$out" == *'"screen_recording": "seeded"'* && "$out" == *'"accessibility": "seeded"'* ]] ||
  { echo "FAIL: both grants not seeded: $out"; fail=1; }
rows=$("$t/bin/sqlite3" "$db" "SELECT service, auth_value, hex(csreq) FROM access WHERE client='ai.manaflow.cmux-screen-eval-launcher' ORDER BY service;")
want_hex=$(printf 'cdhash H"abc123"\n' | od -An -v -tx1 | tr -d ' \n' | tr a-f A-F)
[[ "$rows" == "kTCCServiceAccessibility|2|$want_hex"$'\n'"kTCCServiceScreenCapture|2|$want_hex" ]] ||
  { echo "FAIL: rows not keyed to the designated requirement: $rows"; fail=1; }

out=$(run) || { echo "FAIL: a second run exited non-zero: $out"; fail=1; }
[[ "$out" == *'"screen_recording": "held"'* && "$out" == *'"accessibility": "held"'* ]] ||
  { echo "FAIL: held grants not left alone: $out"; fail=1; }

"$t/bin/sqlite3" "$db" "DELETE FROM access;"
printf '#!/bin/sh\necho "sudo: a password is required" >&2\nexit 1\n' >"$t/bin/sudo"
if out=$(run); then echo "FAIL: a refused sudo exited 0: $out"; fail=1; fi
[[ "$out" == *'"screen_recording": "refused: sudo -n sqlite3 TCC.db read'*'a password is required'* ]] ||
  { echo "FAIL: refusal does not name sudo: $out"; fail=1; }

# The harness seeds only on seed-grants=1 inside a fleet console step.
block=$(sed -n '/^  if \[\[ "$install_status" == 0 && "$seed_grants" == 1 \]\]; then$/,/^  fi$/p' "$harness")
[[ "$block" == *'"${CMUX_CI_CONSOLE_SESSION:-}" == 1 && -n "${CMUX_CI_STEP_KEY:-}"'* &&
   "$block" == *'launcher/seed-grants.sh" "$app"'* ]] ||
  { echo "FAIL: screen-stream-eval.sh does not gate seed-grants.sh on a fleet console step"; fail=1; }
grep -q '^    seed-grants=\*) seed_grants=' "$harness" || { echo "FAIL: seed-grants= is not parsed"; fail=1; }
[[ "$fail" == 0 ]] && echo "PASS: screen-stream-eval seed-grants"
exit "$fail"
