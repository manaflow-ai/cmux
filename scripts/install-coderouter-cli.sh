#!/usr/bin/env bash
# Installs the CodeRouter CLI into an app bundle as Contents/Resources/bin/coderouter,
# the same way the cmux-tui client is bundled: a fresh Mac gets `cmux coderouter ...`
# and `cmux cr ...` with no separate install, no Node, and no PATH setup.
#
# The build comes from the public manaflow-ai/coderouter-releases GitHub release named
# in scripts/coderouter-cli-version (or CMUX_CODEROUTER_CLI_VERSION). The release's
# manifest.json is verified against the digest pinned in
# scripts/coderouter-cli-manifest.sha256 (or CMUX_CODEROUTER_CLI_MANIFEST_SHA256), both
# darwin slices are sha256-verified against that manifest, and lipo'd into one
# universal binary. Downloads are cached per version. Bump the version and the
# manifest digest together (the digest is in the release's SHA256SUMS).
#
#   scripts/install-coderouter-cli.sh <app-path> [--version <x.y.z>] [--cache-dir <dir>]
#
# Env: CMUX_CODEROUTER_CLI_VERSION overrides the pinned version, CMUX_CODEROUTER_CLI_LOCAL
# points at a prebuilt binary to install instead of downloading (offline/dev builds),
# CMUX_CODEROUTER_CLI_BASE_URL overrides the release download base (tests, mirrors).
set -euo pipefail

usage() { sed -n '2,18p' "$0"; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_PATH=""
VERSION="${CMUX_CODEROUTER_CLI_VERSION:-}"
CACHE_DIR="${CMUX_CODEROUTER_CLI_CACHE:-$HOME/Library/Caches/cmux/coderouter-cli}"
while (( $# )); do
  case "$1" in
    --version) shift; VERSION="${1:?--version needs a value}" ;;
    --cache-dir) shift; CACHE_DIR="${1:?--cache-dir needs a value}" ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "unknown option: $1" >&2; usage >&2; exit 64 ;;
    *) APP_PATH="$1" ;;
  esac
  shift
done
[[ -n "$APP_PATH" && -d "$APP_PATH/Contents" ]] || { echo "error: app bundle not found at '${APP_PATH:-<missing>}'" >&2; exit 1; }
if [[ -z "$VERSION" ]]; then
  VERSION="$(tr -d '[:space:]' < "$SCRIPT_DIR/coderouter-cli-version")"
fi
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?$ ]] || { echo "error: invalid coderouter version '$VERSION'" >&2; exit 1; }
DEST_DIR="$APP_PATH/Contents/Resources/bin"
DEST="$DEST_DIR/coderouter"
mkdir -p "$DEST_DIR"

sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }

# `coderouter capabilities --json` needs no login and no network; it is the
# credential-free probe the CLI documents for scripts. The command must exit 0
# and print JSON whose product is coderouter.
verify_probe() {
  local probe
  if ! probe="$("$DEST" capabilities --json 2>/dev/null)"; then
    echo "error: installed binary does not probe as coderouter (capabilities --json failed): $probe" >&2
    exit 1
  fi
  if ! python3 -c 'import json,sys; sys.exit(0 if json.loads(sys.argv[1]).get("product") == "coderouter" else 1)' "$probe" 2>/dev/null; then
    echo "error: installed binary does not probe as coderouter: $probe" >&2
    exit 1
  fi
}

if [[ -n "${CMUX_CODEROUTER_CLI_LOCAL:-}" ]]; then
  [[ -f "$CMUX_CODEROUTER_CLI_LOCAL" ]] || { echo "error: CMUX_CODEROUTER_CLI_LOCAL not found: $CMUX_CODEROUTER_CLI_LOCAL" >&2; exit 1; }
  install -m 755 "$CMUX_CODEROUTER_CLI_LOCAL" "$DEST"
  verify_probe
  echo "Installed local coderouter CLI at $DEST"
  exit 0
fi

BASE="${CMUX_CODEROUTER_CLI_BASE_URL:-https://github.com/manaflow-ai/coderouter-releases/releases/download}/v$VERSION"
BUILD_DIR="$CACHE_DIR/$VERSION"
mkdir -p "$BUILD_DIR"
MANIFEST="$BUILD_DIR/manifest.json"

fetch() { # <url> <out>
  curl --proto '=https,file' --tlsv1.2 -fsSL --retry 3 --retry-delay 2 \
    --connect-timeout 20 --max-time 300 "$1" -o "$2"
}

# The manifest and the binaries come from the same host, so the manifest's own
# digest is pinned in the repo (scripts/coderouter-cli-manifest.sha256) as the
# independent trust root. A version that is not the pinned one needs its digest
# through CMUX_CODEROUTER_CLI_MANIFEST_SHA256.
MANIFEST_SHA256="${CMUX_CODEROUTER_CLI_MANIFEST_SHA256:-}"
if [[ -z "$MANIFEST_SHA256" && "$VERSION" == "$(tr -d '[:space:]' < "$SCRIPT_DIR/coderouter-cli-version")" ]]; then
  MANIFEST_SHA256="$(tr -d '[:space:]' < "$SCRIPT_DIR/coderouter-cli-manifest.sha256")"
fi
[[ "$MANIFEST_SHA256" =~ ^[0-9a-f]{64}$ ]] || {
  echo "error: no pinned manifest digest for coderouter $VERSION; set CMUX_CODEROUTER_CLI_MANIFEST_SHA256 or bump scripts/coderouter-cli-version and scripts/coderouter-cli-manifest.sha256 together" >&2
  exit 1
}

if [[ ! -f "$MANIFEST" ]] || [[ "$(sha256_of "$MANIFEST")" != "$MANIFEST_SHA256" ]]; then
  fetch "$BASE/manifest.json" "$MANIFEST.tmp"
  got="$(sha256_of "$MANIFEST.tmp")"
  [[ "$got" == "$MANIFEST_SHA256" ]] || {
    echo "error: sha256 mismatch for manifest.json (want $MANIFEST_SHA256, got $got)" >&2
    rm -f "$MANIFEST.tmp"
    exit 1
  }
  mv -f "$MANIFEST.tmp" "$MANIFEST"
fi
MANIFEST_VERSION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$MANIFEST")"
[[ "$MANIFEST_VERSION" == "$VERSION" ]] || {
  echo "error: coderouter manifest version mismatch (expected $VERSION, got $MANIFEST_VERSION)" >&2
  exit 1
}

fetch_slice() { # <artifact-name> -> path
  local name="$1" want got out
  want="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["binaries"].get(sys.argv[2], ""))' "$MANIFEST" "$name")"
  [[ "$want" =~ ^[0-9a-f]{64}$ ]] || { echo "error: manifest lacks $name" >&2; exit 1; }
  out="$BUILD_DIR/$name"
  if [[ -f "$out" ]] && [[ "$(sha256_of "$out")" == "$want" ]]; then
    printf '%s' "$out"; return
  fi
  fetch "$BASE/$name" "$out.tmp"
  got="$(sha256_of "$out.tmp")"
  [[ "$got" == "$want" ]] || { echo "error: sha256 mismatch for $name (want $want, got $got)" >&2; rm -f "$out.tmp"; exit 1; }
  mv -f "$out.tmp" "$out"
  printf '%s' "$out"
}

ARM="$(fetch_slice coderouter-darwin-arm64)"
X64="$(fetch_slice coderouter-darwin-x64)"
UNIVERSAL="$BUILD_DIR/coderouter-universal"
if [[ ! -f "$UNIVERSAL" ]]; then
  lipo -create "$ARM" "$X64" -output "$UNIVERSAL.tmp"
  mv -f "$UNIVERSAL.tmp" "$UNIVERSAL"
fi
install -m 755 "$UNIVERSAL" "$DEST"
# One arch per invocation: some lipo builds (Xcode 27 beta 4) consume only one
# arch after -verify_arch and read the second as an extra input file.
for arch in arm64 x86_64; do lipo "$DEST" -verify_arch "$arch"; done
verify_probe
echo "Installed universal coderouter CLI $VERSION at $DEST"
