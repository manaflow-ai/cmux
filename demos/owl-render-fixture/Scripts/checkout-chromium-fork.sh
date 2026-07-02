#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFEST="$ROOT_DIR/chromium-patches/aws-m1-ultra-verified-owl-host.json"
CHROMIUM_SRC="${CHROMIUM_SRC:-$HOME/chromium/src}"

usage() {
  cat >&2 <<EOF
usage: $0 [--chromium-src <path>] [--manifest <path>]

Fetches and checks out the manifest-pinned OWL Chromium fork commit. This
script refuses to run on a dirty Chromium tree.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --chromium-src)
      shift
      [ "$#" -gt 0 ] || { usage; exit 2; }
      CHROMIUM_SRC="$1"
      ;;
    --manifest)
      shift
      [ "$#" -gt 0 ] || { usage; exit 2; }
      MANIFEST="$1"
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
  shift
done

if [ ! -d "$CHROMIUM_SRC/.git" ]; then
  echo "missing Chromium checkout: $CHROMIUM_SRC" >&2
  exit 1
fi

read_manifest() {
  /usr/bin/python3 - "$MANIFEST" <<'PY'
import json
import pathlib
import sys

manifest = json.loads(pathlib.Path(sys.argv[1]).read_text())
print(manifest["chromiumForkRepo"])
print(manifest["chromiumForkBranch"])
print(manifest["chromiumForkCommit"])
PY
}

manifest_values_file="$(mktemp "${TMPDIR:-/tmp}/owl-chromium-fork.XXXXXX")"
read_manifest > "$manifest_values_file"
FORK_REPO="$(sed -n '1p' "$manifest_values_file")"
FORK_BRANCH="$(sed -n '2p' "$manifest_values_file")"
EXPECTED_FORK_COMMIT="$(sed -n '3p' "$manifest_values_file")"
rm -f "$manifest_values_file"

if [ -n "$(git -C "$CHROMIUM_SRC" status --porcelain)" ]; then
  echo "Chromium checkout is dirty; refusing to switch forks" >&2
  exit 1
fi

git -C "$CHROMIUM_SRC" fetch "$FORK_REPO" "$FORK_BRANCH"
actual_commit="$(git -C "$CHROMIUM_SRC" rev-parse FETCH_HEAD)"
if [ "$actual_commit" != "$EXPECTED_FORK_COMMIT" ]; then
  echo "fetched fork commit mismatch: expected $EXPECTED_FORK_COMMIT got $actual_commit" >&2
  exit 1
fi

git -C "$CHROMIUM_SRC" checkout --detach "$EXPECTED_FORK_COMMIT"
"$SCRIPT_DIR/check-chromium-patch.sh" --chromium-src "$CHROMIUM_SRC" --manifest "$MANIFEST" --mode applied
