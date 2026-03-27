#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cmux-remote-assets-test.XXXXXX")"
trap 'rm -rf "$OUTPUT_DIR"' EXIT

"$ROOT_DIR/scripts/build_remote_daemon_release_assets.sh" \
  --version "0.62.0-test" \
  --release-tag "v0.62.0-test" \
  --repo "manaflow-ai/cmux" \
  --output-dir "$OUTPUT_DIR" >/dev/null

for asset in \
  cmuxd-remote-darwin-arm64 \
  cmuxd-remote-darwin-amd64 \
  cmuxd-remote-linux-arm64 \
  cmuxd-remote-linux-amd64 \
  cmuxd-remote-checksums.txt \
  cmuxd-remote-manifest.json
do
  if [[ ! -f "$OUTPUT_DIR/$asset" ]]; then
    echo "FAIL: missing asset $asset" >&2
    exit 1
  fi
done

python3 - <<'PY' "$OUTPUT_DIR/cmuxd-remote-manifest.json" "$OUTPUT_DIR/cmuxd-remote-checksums.txt"
import json
import sys
from pathlib import Path

manifest_path = Path(sys.argv[1])
checksums_path = Path(sys.argv[2])
manifest = json.loads(manifest_path.read_text(encoding="utf-8"))

expected_targets = {
    ("darwin", "arm64"),
    ("darwin", "amd64"),
    ("linux", "arm64"),
    ("linux", "amd64"),
}
actual_targets = {(entry["goOS"], entry["goArch"]) for entry in manifest["entries"]}
if actual_targets != expected_targets:
    raise SystemExit(f"FAIL: manifest targets {sorted(actual_targets)} != {sorted(expected_targets)}")

if manifest["appVersion"] != "0.62.0-test":
    raise SystemExit(f"FAIL: unexpected appVersion {manifest['appVersion']}")
if manifest["releaseTag"] != "v0.62.0-test":
    raise SystemExit(f"FAIL: unexpected releaseTag {manifest['releaseTag']}")
if not manifest["checksumsURL"].endswith("/cmuxd-remote-checksums.txt"):
    raise SystemExit(f"FAIL: unexpected checksumsURL {manifest['checksumsURL']}")

checksum_lines = [line for line in checksums_path.read_text(encoding="utf-8").splitlines() if line.strip()]
if len(checksum_lines) != 4:
    raise SystemExit(f"FAIL: expected 4 checksum lines, got {len(checksum_lines)}")

for entry in manifest["entries"]:
    if not entry["downloadURL"].endswith("/" + entry["assetName"]):
        raise SystemExit(f"FAIL: downloadURL mismatch for {entry['assetName']}")
    if len(entry["sha256"]) != 64:
        raise SystemExit(f"FAIL: invalid sha256 for {entry['assetName']}")

print("PASS: remote daemon release assets include all targets and manifest entries")
PY

# ------------------------------------------------------------------
# Test with --asset-suffix (nightly-style immutable asset names)
# ------------------------------------------------------------------
SUFFIX_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cmux-remote-assets-suffix-test.XXXXXX")"
trap 'rm -rf "$OUTPUT_DIR" "$SUFFIX_DIR"' EXIT

"$ROOT_DIR/scripts/build_remote_daemon_release_assets.sh" \
  --version "0.62.0-nightly.123456" \
  --release-tag "nightly" \
  --repo "manaflow-ai/cmux" \
  --output-dir "$SUFFIX_DIR" \
  --asset-suffix "123456" >/dev/null

for asset in \
  cmuxd-remote-darwin-arm64-123456 \
  cmuxd-remote-darwin-amd64-123456 \
  cmuxd-remote-linux-arm64-123456 \
  cmuxd-remote-linux-amd64-123456 \
  cmuxd-remote-checksums-123456.txt \
  cmuxd-remote-manifest-123456.json
do
  if [[ ! -f "$SUFFIX_DIR/$asset" ]]; then
    echo "FAIL: missing suffixed asset $asset" >&2
    exit 1
  fi
done

python3 - <<'PY' "$SUFFIX_DIR/cmuxd-remote-manifest-123456.json"
import json
import sys
from pathlib import Path

manifest = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))

for entry in manifest["entries"]:
    if not entry["assetName"].endswith("-123456"):
        raise SystemExit(f"FAIL: suffixed asset name missing suffix: {entry['assetName']}")
    if not entry["downloadURL"].endswith("/" + entry["assetName"]):
        raise SystemExit(f"FAIL: downloadURL mismatch for {entry['assetName']}")

print("PASS: --asset-suffix produces correctly suffixed assets and manifest entries")
PY
