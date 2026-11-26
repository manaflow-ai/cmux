#!/usr/bin/env bash
# Put the Debug cmux DEV app the build fleet built for this head (the build fleet's
# `cmux` recipe, read through compile-checks phase scheme-debug) where the cmux
# scheme compile's own product goes: DERIVED_DATA/Build/Products/Debug/cmux DEV*.app.
# The steps after the compile (app personalities, the crash gate, the dogfood
# artifact) then read it unchanged.
#
#   fleet-scheme-app.sh JOB_ID DERIVED_DATA
#
# Needs vars.CMUX_FLEET_CONTROLLER (CONTROLLER) and an owned runner the controller
# admits (the client is fetched from the controller and checked by sha256, as
# cmux-next-batch.yml does). Exit 0: the app is in place. Anything else: no app;
# the caller compiles on this Mac instead (the logged fallback).
set -euo pipefail
job="${1:?usage: fleet-scheme-app.sh JOB_ID DERIVED_DATA}"
derived_data="${2:?usage: fleet-scheme-app.sh JOB_ID DERIVED_DATA}"
[[ "$job" =~ ^[A-Za-z0-9._:-]+$ ]] || { echo "fleet-scheme-app: bad job id" >&2; exit 2; }
[[ -n "${CONTROLLER:-}" ]] || { echo "fleet-scheme-app: CMUX_FLEET_CONTROLLER is not set" >&2; exit 2; }
work="$(mktemp -d "${TMPDIR:-/tmp}/fleet-scheme-app.XXXXXX")"
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/client"
curl -fsS -m 30 "$CONTROLLER/v1/client/manifest" -o "$work/client/manifest.json"
python3 -I - "$work/client" "$CONTROLLER" <<'PY'
import hashlib, json, sys, urllib.request
from pathlib import Path
root, controller = Path(sys.argv[1]), sys.argv[2]
for name, digest in json.loads((root / "manifest.json").read_text())["files"].items():
    if "/" in name or name.startswith("."):
        raise SystemExit(f"bad client file name {name!r}")
    data = urllib.request.urlopen(f"{controller}/v1/client/files/{name}", timeout=30).read()
    if hashlib.sha256(data).hexdigest() != digest:
        raise SystemExit(f"{name}: sha256 mismatch")
    (root / name).write_bytes(data)
PY
CMUX_CI_CONTROLLER="$CONTROLLER" python3 "$work/client/ci-client.py" artifact "$job" "$work/cmux.app.zip"
products="$derived_data/Build/Products/Debug"
rm -rf -- "$products"
mkdir -p "$products"
/usr/bin/ditto -x -k "$work/cmux.app.zip" "$products"
app="$(find "$products" -maxdepth 1 -type d -name 'cmux DEV*.app' -print -quit)"
[[ -d "$app" ]] || { echo "fleet-scheme-app: job $job's zip holds no cmux DEV*.app at its root" >&2; exit 1; }
/usr/bin/codesign --verify --deep --strict "$app"
echo "fleet-scheme-app: $app from build fleet job $job"
