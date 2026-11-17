#!/usr/bin/env bash
# launch-ready.sh's machines=N writes N Cloud machine sections into every sidebar snapshot of a home before a
# launch, keeps the sections it did not write (the local machine's), and writes the same N again after a quit
# saved its own, so every launch reads N, never 2N.
set -euo pipefail

seed="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/launch-ready-machines.py"
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
dir="$root/h/Library/Application Support/cmux-next/builds/k"
mkdir -p "$dir"
printf '%s' '{"schemaVersion":1,"windows":[{"windowID":"w","snapshot":{"sections":[{"isCollapsed":false,"nodes":[],"machineKind":"local","machineName":"This Mac","machineID":"local"}],"profiles":[]}}]}' \
  >"$dir/sidebar-snapshot-v1.json"

count() { python3 -I -c 'import json,sys; s=json.load(open(sys.argv[1]))["windows"][0]["snapshot"]["sections"]; print(len(s), sum(x.get("machineKind")=="cloud" for x in s), s[0]["machineID"])' "$dir/sidebar-snapshot-v1.json"; }

line="$(python3 -I "$seed" "$root" 27)"
[[ "$line" == "LR-MACHINES "* ]] || { echo "launch-ready machines: printed '$line', want an LR-MACHINES line" >&2; exit 1; }
[[ "$(count)" == "28 27 local" ]] || { echo "launch-ready machines: sections '$(count)' after the seed, want 28 27 local" >&2; exit 1; }

python3 -I "$seed" "$root" 27 >/dev/null
[[ "$(count)" == "28 27 local" ]] || { echo "launch-ready machines: sections '$(count)' after a second seed, want 28 27 local" >&2; exit 1; }

empty="$(mktemp -d)"
if python3 -I "$seed" "$empty" 27 >/dev/null; then rm -rf "$empty"; echo "launch-ready machines: a home with no snapshot passed" >&2; exit 1; fi
rm -rf "$empty"
echo "launch-ready machines: ok"
