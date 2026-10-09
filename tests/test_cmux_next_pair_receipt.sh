#!/usr/bin/env bash
# Exercises the exact-head validator against the real readiness receipt writer.
# It uses temporary bundles and plists only; no simulator, phone, or app launch.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib/mobile-attach.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/cmux-pair-receipt.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

sha="cff9e2e9cff22df187c664b542c8047deba34d8b"
tag="nxd3"
bundle="dev.cmux.ios.nxd3"
target_id="SIM-PAIR-RECEIPT"
app="$tmp/cmux.app"
mkdir -p "$app"
cat >"$app/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$bundle</string>
<key>CFBundleExecutable</key><string>cmux</string>
<key>CMUXGitSHA</key><string>$sha</string>
<key>CMUXDevTag</key><string>$tag</string>
</dict></plist>
PLIST
printf 'installed executable bytes\n' >"$app/cmux"

metadata="$(CMUX_INSTALLED_APP_PATH="$app" \
  cmux_attach_installed_bundle_metadata \
  simulator_injection "$target_id" "$bundle")"
event='{"name":"mobile.rpc.ready","payload":{"connection_id":"c","client_id":"i","stream_id":"s","transport":"iroh","workspace_count":1}}'
receipt="$tmp/readiness.json"
export CMUX_DEV_AUTH_PROFILE=agent
export CMUX_DEV_AUTH_ACCOUNT=pair-receipt@example.invalid
cmux_attach_write_readiness_receipt \
  "$receipt" "$sha" "$tag" "$bundle" \
  simulator_injection "$target_id" "$tag" /tmp/cmux-debug-nxd3.sock \
  12 1 "$event" "$metadata"

mac_info="$tmp/mac-Info.plist"
cp "$app/Info.plist" "$mac_info"
python3 - "$ROOT" "$receipt" "$mac_info" "$sha" "$tag" "$bundle" <<'PY'
import json
import subprocess
import sys
from pathlib import Path

root, receipt, mac_info, sha, tag, bundle = sys.argv[1:]
subprocess.run(
    [
        "python3",
        str(Path(root) / "scripts/cmux-next/validate-dogfood-pair-receipt.py"),
        "--receipt",
        receipt,
        "--mac-info-plist",
        mac_info,
        "--expected-sha",
        sha,
        "--expected-tag",
        tag,
        "--expected-bundle-id",
        bundle,
    ],
    check=True,
)
value = json.loads(Path(receipt).read_text())
value["installed_bundle"]["metadata_source"] = "legacy_receipt_writer"
Path(receipt).write_text(json.dumps(value))
PY

if python3 "$ROOT/scripts/cmux-next/validate-dogfood-pair-receipt.py" \
  --receipt "$receipt" --mac-info-plist "$mac_info" \
  --expected-sha "$sha" --expected-tag "$tag" --expected-bundle-id "$bundle"; then
  echo "validator accepted legacy receipt provenance" >&2
  exit 1
fi

echo "cmux-next exact-head pair receipt: PASS"
