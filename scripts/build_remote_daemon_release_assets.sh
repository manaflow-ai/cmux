#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/build_remote_daemon_release_assets.sh \
  --version <app-version> \
  --release-tag <tag> \
  --repo <owner/repo> \
  --output-dir <dir>

Builds cmuxd-remote release assets for the supported remote platforms and emits:
  cmuxd-remote-<goos>-<goarch>
  cmuxd-remote-checksums.txt
  cmuxd-remote-manifest.json
EOF
}

VERSION=""
RELEASE_TAG=""
REPO=""
OUTPUT_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION="${2:-}"
      shift 2
      ;;
    --release-tag)
      RELEASE_TAG="${2:-}"
      shift 2
      ;;
    --repo)
      REPO="${2:-}"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$VERSION" || -z "$RELEASE_TAG" || -z "$REPO" || -z "$OUTPUT_DIR" ]]; then
  echo "error: --version, --release-tag, --repo, and --output-dir are required" >&2
  usage
  exit 1
fi

if ! command -v go >/dev/null 2>&1; then
  echo "error: go is required to build cmuxd-remote release assets" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DAEMON_ROOT="${REPO_ROOT}/daemon/remote"
mkdir -p "$OUTPUT_DIR"
rm -f "$OUTPUT_DIR"/cmuxd-remote-* "$OUTPUT_DIR"/cmuxd-remote-checksums.txt "$OUTPUT_DIR"/cmuxd-remote-manifest.json

RELEASE_URL="https://github.com/${REPO}/releases/download/${RELEASE_TAG}"
CHECKSUMS_ASSET_NAME="cmuxd-remote-checksums.txt"
CHECKSUMS_PATH="${OUTPUT_DIR}/${CHECKSUMS_ASSET_NAME}"
MANIFEST_PATH="${OUTPUT_DIR}/cmuxd-remote-manifest.json"

TARGETS=(
  "darwin arm64"
  "darwin amd64"
  "linux arm64"
  "linux amd64"
)

declare -a manifest_entries=()
: > "$CHECKSUMS_PATH"

for target in "${TARGETS[@]}"; do
  read -r GOOS GOARCH <<<"$target"
  ASSET_NAME="cmuxd-remote-${GOOS}-${GOARCH}"
  OUTPUT_PATH="${OUTPUT_DIR}/${ASSET_NAME}"

  (
    cd "$DAEMON_ROOT"
    GOOS="$GOOS" \
    GOARCH="$GOARCH" \
    CGO_ENABLED=0 \
    go build -trimpath -ldflags "-s -w -X main.version=${VERSION}" \
      -o "$OUTPUT_PATH" \
      ./cmd/cmuxd-remote
  )
  chmod 755 "$OUTPUT_PATH"

  SHA256="$(shasum -a 256 "$OUTPUT_PATH" | awk '{print $1}')"
  printf '%s  %s\n' "$SHA256" "$ASSET_NAME" >> "$CHECKSUMS_PATH"

  manifest_entries+=("{\"goOS\":\"${GOOS}\",\"goArch\":\"${GOARCH}\",\"assetName\":\"${ASSET_NAME}\",\"downloadURL\":\"${RELEASE_URL}/${ASSET_NAME}\",\"sha256\":\"${SHA256}\"}")
done

ENTRIES_FILE="$(mktemp "${TMPDIR:-/tmp}/cmuxd-remote-entries.XXXXXX")"
trap 'rm -f "$ENTRIES_FILE"' EXIT
printf '%s\n' "${manifest_entries[@]}" > "$ENTRIES_FILE"
ENTRIES_JSON="$(python3 - <<'PY' "$ENTRIES_FILE"
import json
import sys
from pathlib import Path

entries = [json.loads(line) for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines() if line.strip()]
print(json.dumps(entries, separators=(",", ":")))
PY
)"

python3 - <<'PY' "$VERSION" "$RELEASE_TAG" "$RELEASE_URL" "$CHECKSUMS_ASSET_NAME" "$CHECKSUMS_PATH" "$MANIFEST_PATH" "$ENTRIES_JSON"
import json
import sys
from pathlib import Path

version, release_tag, release_url, checksums_asset_name, checksums_path, manifest_path, entries_json = sys.argv[1:]
checksums_url = f"{release_url}/{checksums_asset_name}"
manifest = {
    "schemaVersion": 1,
    "appVersion": version,
    "releaseTag": release_tag,
    "releaseURL": release_url,
    "checksumsAssetName": checksums_asset_name,
    "checksumsURL": checksums_url,
    "entries": json.loads(entries_json),
}
Path(manifest_path).write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

echo "Built cmuxd-remote assets in ${OUTPUT_DIR}"
