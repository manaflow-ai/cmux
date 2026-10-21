#!/usr/bin/env bash
# Probes this Mac's Objective-C runtime for every `super` call key of the CmuxNext sources
# (scripts/cmux-next/check-objc-selectors.py) and prints the table rows for this macOS:
#   cmux-ci run --class exclusive --script scripts/measure/objc-selector-probe.sh --ref SHA --timeout 600
# Read-only: no build, no app launch. Copy the OBJC-SELECTOR-TABLE line's JSON into
# scripts/cmux-next/objc-selector-table.json (or run --probe --write on that macOS yourself).
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/scripts/cmux-next"
cp "$root/scripts/cmux-next/objc-selector-table.json" "$work/scripts/cmux-next/"
cp "$root/scripts/cmux-next/check-objc-selectors.py" "$work/scripts/cmux-next/"
ln -s "$root/Packages" "$work/Packages"
sw_vers
python3 -I "$work/scripts/cmux-next/check-objc-selectors.py" --root "$work" --probe --write
python3 -I - "$work/scripts/cmux-next/objc-selector-table.json" <<'PY'
import json, platform, sys
table = json.load(open(sys.argv[1]))
version = platform.mac_ver()[0]
rows = {key: answers[version] for key, answers in table["keys"].items() if version in answers}
print("OBJC-SELECTOR-TABLE " + json.dumps({"macos": version, "keys": rows}, sort_keys=True))
missing = sorted(k for k, v in rows.items() if v is False)
print("OBJC-SELECTOR-NOT-ANSWERED " + json.dumps(missing))
PY
