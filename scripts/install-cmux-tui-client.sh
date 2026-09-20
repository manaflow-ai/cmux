#!/usr/bin/env bash
# Installs the cmux-tui client into an app bundle as Contents/Resources/bin/cmux-tui,
# the same way the Ghostty CLI helper is bundled: the app carries the exact client
# that talks to cmux Cloud machines, so the Machines panel needs no separate install.
#
# The build comes from the artifacts manifest the cmux-tui-artifacts workflow publishes
# (rolling `latest` by default; a commit-addressed manifest pins one build). Both
# darwin slices are downloaded, sha256-verified against the manifest, and lipo'd into
# one universal binary. Downloads are cached per commit under CMUX_TUI_CLIENT_CACHE.
#
#   scripts/install-cmux-tui-client.sh <app-path> [--manifest-url <url>] [--cache-dir <dir>]
#     [--manifest-file <path>] [--expected-commit <sha>] [--require-capability <name>]...
#     [--attest-signer-workflow <owner/repo/.github/workflows/name.yml>] [--allow-unattested]
#   scripts/install-cmux-tui-client.sh --print-source-identity [--manifest-url <url>]
#     [--save-manifest <path>]
#
# --print-source-identity installs nothing. It prints a value that changes whenever the
# client this script would install changes: the sha256 of the local binary, or of the
# manifest currently served at the manifest URL (which pins the binaries). Callers use
# it to decide whether an earlier install is still current. It fails when the source
# cannot be read.
#
# A rolling manifest can be republished between that identity and the install.
# --save-manifest keeps the manifest the identity was computed from, and
# --manifest-file installs from such a copy instead of fetching the URL again, so the
# identity describes the client that gets installed. The copy is authenticated like a
# fetched manifest, and --manifest-url still locates the binaries.
#
# Every remote install authenticates the downloaded manifest before any value in it is
# trusted: `gh attestation verify` must find a Sigstore build-provenance attestation for
# the manifest bytes, signed by the publishing workflow in its repository (default
# manaflow-ai/cmux/.github/workflows/cmux-tui-artifacts.yml; override with
# --attest-signer-workflow) and, with --expected-commit, built from that source commit.
# The manifest's sha256 pins then cover the binaries, so an artifact host cannot
# substitute a build. Only --allow-unattested skips this, for local development on a
# machine without an authenticated gh; CI never passes it. A CMUX_TUI_CLIENT_LOCAL
# binary is not downloaded and is not subject to it.
#
# Env: CMUX_TUI_CLIENT_MANIFEST_URL overrides the manifest, CMUX_TUI_CLIENT_LOCAL points at
# a prebuilt universal binary to install instead of downloading (offline/dev builds).
set -euo pipefail

usage() { sed -n '2,37p' "$0"; }

APP_PATH=""
MANIFEST_URL="${CMUX_TUI_CLIENT_MANIFEST_URL:-https://files.cmux.com/cmux-tui/latest/manifest.json}"
CACHE_DIR="${CMUX_TUI_CLIENT_CACHE:-$HOME/Library/Caches/cmux/cmux-tui-client}"
MANIFEST_FILE=""
SAVE_MANIFEST=""
EXPECTED_COMMIT=""
ATTEST_SIGNER_WORKFLOW="manaflow-ai/cmux/.github/workflows/cmux-tui-artifacts.yml"
ALLOW_UNATTESTED=0
PRINT_SOURCE_IDENTITY=0
REQUIRED_CAPABILITIES=()
while (( $# )); do
  case "$1" in
    --manifest-url) shift; MANIFEST_URL="${1:?--manifest-url needs a value}" ;;
    --manifest-file) shift; MANIFEST_FILE="${1:?--manifest-file needs a value}" ;;
    --save-manifest) shift; SAVE_MANIFEST="${1:?--save-manifest needs a value}" ;;
    --cache-dir) shift; CACHE_DIR="${1:?--cache-dir needs a value}" ;;
    --expected-commit) shift; EXPECTED_COMMIT="${1:?--expected-commit needs a value}" ;;
    --attest-signer-workflow) shift; ATTEST_SIGNER_WORKFLOW="${1:?--attest-signer-workflow needs a value}" ;;
    --allow-unattested) ALLOW_UNATTESTED=1 ;;
    --print-source-identity) PRINT_SOURCE_IDENTITY=1 ;;
    --require-capability) shift; REQUIRED_CAPABILITIES+=("${1:?--require-capability needs a value}") ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "unknown option: $1" >&2; usage >&2; exit 64 ;;
    *) APP_PATH="$1" ;;
  esac
  shift
done
sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }

if (( PRINT_SOURCE_IDENTITY )); then
  if [[ -n "${CMUX_TUI_CLIENT_LOCAL:-}" ]]; then
    [[ -f "$CMUX_TUI_CLIENT_LOCAL" ]] || { echo "error: CMUX_TUI_CLIENT_LOCAL not found: $CMUX_TUI_CLIENT_LOCAL" >&2; exit 1; }
    printf 'local:%s\n' "$(sha256_of "$CMUX_TUI_CLIENT_LOCAL")"
    exit 0
  fi
  IDENTITY_MANIFEST="$(mktemp "${TMPDIR:-/tmp}/cmux-tui-manifest.XXXXXX")"
  trap 'rm -f "$IDENTITY_MANIFEST"' EXIT
  # One bounded attempt: a caller that cannot resolve the identity falls back to a
  # full install, which retries and reports the network error.
  curl --proto '=https' --tlsv1.2 -fsSL --connect-timeout 5 --max-time 15 "$MANIFEST_URL" -o "$IDENTITY_MANIFEST" || {
    echo "error: could not fetch the cmux-tui manifest at $MANIFEST_URL" >&2
    exit 1
  }
  if [[ -n "$SAVE_MANIFEST" ]]; then
    mkdir -p "$(dirname "$SAVE_MANIFEST")"
    cp "$IDENTITY_MANIFEST" "$SAVE_MANIFEST.tmp.$$"
    mv -f "$SAVE_MANIFEST.tmp.$$" "$SAVE_MANIFEST"
  fi
  printf 'manifest:%s\n' "$(sha256_of "$IDENTITY_MANIFEST")"
  exit 0
fi

[[ -n "$APP_PATH" && -d "$APP_PATH/Contents" ]] || { echo "error: app bundle not found at '${APP_PATH:-<missing>}'" >&2; exit 1; }
[[ "$ATTEST_SIGNER_WORKFLOW" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/\.github/workflows/[A-Za-z0-9._-]+\.ya?ml$ ]] || {
  echo "error: --attest-signer-workflow must look like owner/repo/.github/workflows/name.yml: $ATTEST_SIGNER_WORKFLOW" >&2
  exit 64
}
DEST_DIR="$APP_PATH/Contents/Resources/bin"
DEST="$DEST_DIR/cmux-tui"
mkdir -p "$DEST_DIR"

# Fail closed: without a valid attestation nothing from the manifest is used, so
# no binary it names is downloaded or executed.
verify_manifest_attestation() {
  local repo="${ATTEST_SIGNER_WORKFLOW%%/.github/*}"
  local -a args=(--repo "$repo" --signer-workflow "$ATTEST_SIGNER_WORKFLOW")
  command -v gh >/dev/null 2>&1 || {
    echo "error: verifying the cmux-tui manifest attestation needs the GitHub CLI (gh); pass --allow-unattested only for local development" >&2
    exit 1
  }
  [[ -n "$EXPECTED_COMMIT" ]] && args+=(--source-digest "$EXPECTED_COMMIT")
  gh attestation verify "$MANIFEST" "${args[@]}" >&2 || {
    echo "error: no valid build-provenance attestation for the cmux-tui manifest at $MANIFEST_URL (signer $ATTEST_SIGNER_WORKFLOW)" >&2
    exit 1
  }
}

verify_probe() {
  local probe capability
  probe="$("$DEST" remote-probe --json 2>/dev/null || true)"
  [[ "$probe" == *'"app":"cmux-tui"'* ]] || {
    echo "error: installed binary does not probe as cmux-tui: $probe" >&2
    exit 1
  }
  # Bash 3.2 treats an empty array as unset under nounset. Expand no arguments
  # when there are no requirements, while preserving each supplied capability.
  for capability in ${REQUIRED_CAPABILITIES[@]+"${REQUIRED_CAPABILITIES[@]}"}; do
    if ! python3 - "$capability" "$probe" <<'PY'
import json
import sys

capability = sys.argv[1]
probe = json.loads(sys.argv[2])
raise SystemExit(0 if capability in probe.get("capabilities", []) else 1)
PY
    then
      echo "error: required cmux-tui capability is missing: $capability" >&2
      exit 1
    fi
  done
}

if [[ -n "${CMUX_TUI_CLIENT_LOCAL:-}" ]]; then
  [[ -f "$CMUX_TUI_CLIENT_LOCAL" ]] || { echo "error: CMUX_TUI_CLIENT_LOCAL not found: $CMUX_TUI_CLIENT_LOCAL" >&2; exit 1; }
  install -m 755 "$CMUX_TUI_CLIENT_LOCAL" "$DEST"
  verify_probe
  echo "Installed local cmux-tui client at $DEST"
  exit 0
fi

mkdir -p "$CACHE_DIR"
if [[ -n "$MANIFEST_FILE" ]]; then
  [[ -f "$MANIFEST_FILE" ]] || { echo "error: --manifest-file not found: $MANIFEST_FILE" >&2; exit 1; }
  MANIFEST="$MANIFEST_FILE"
else
  MANIFEST="$CACHE_DIR/manifest.$(printf '%s' "$MANIFEST_URL" | shasum -a 256 | cut -c1-12).json"
  curl --proto '=https' --tlsv1.2 -fsSL --retry 5 --retry-delay 3 --retry-all-errors --retry-connrefused "$MANIFEST_URL" -o "$MANIFEST"
fi
if (( ALLOW_UNATTESTED )); then
  echo "warning: installing an unattested cmux-tui manifest from $MANIFEST_URL (--allow-unattested)" >&2
else
  verify_manifest_attestation
fi
COMMIT="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["commit"])' "$MANIFEST")"
[[ "$COMMIT" =~ ^[0-9a-f]{40}$ ]] || { echo "error: manifest at $MANIFEST_URL has no commit" >&2; exit 1; }
if [[ -n "$EXPECTED_COMMIT" && "$COMMIT" != "$EXPECTED_COMMIT" ]]; then
  echo "error: cmux-tui manifest commit mismatch (expected $EXPECTED_COMMIT, got $COMMIT)" >&2
  exit 1
fi
BASE="${MANIFEST_URL%/manifest.json}"
# The rolling latest/ prefix is rewritten on every main push, so a slice fetched
# a moment after the manifest can belong to a newer build and fail its checksum.
# The publisher also stores every build under its commit, immutably; fetch the
# slices from there whenever the manifest came from the rolling prefix.
if [[ "$BASE" == */latest ]]; then
  BASE="${BASE%/latest}/$COMMIT"
fi
BUILD_DIR="$CACHE_DIR/$COMMIT"
mkdir -p "$BUILD_DIR"

fetch_slice() { # <artifact-name> -> path
  local name="$1" want got out
  want="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["binaries"].get(sys.argv[2], ""))' "$MANIFEST" "$name")"
  [[ "$want" =~ ^[0-9a-f]{64}$ ]] || { echo "error: manifest lacks $name" >&2; exit 1; }
  out="$BUILD_DIR/$name"
  if [[ -f "$out" ]] && [[ "$(sha256_of "$out")" == "$want" ]]; then
    printf '%s' "$out"; return
  fi
  curl --proto '=https' --tlsv1.2 -fsSL --retry 5 --retry-delay 3 --retry-all-errors --retry-connrefused "$BASE/$name" -o "$out.tmp"
  got="$(sha256_of "$out.tmp")"
  [[ "$got" == "$want" ]] || { echo "error: sha256 mismatch for $name (want $want, got $got)" >&2; rm -f "$out.tmp"; exit 1; }
  mv -f "$out.tmp" "$out"
  printf '%s' "$out"
}

ARM="$(fetch_slice cmux-tui-aarch64-apple-darwin)"
X64="$(fetch_slice cmux-tui-x86_64-apple-darwin)"
UNIVERSAL="$BUILD_DIR/cmux-tui-universal"
if [[ ! -f "$UNIVERSAL" ]]; then
  lipo -create "$ARM" "$X64" -output "$UNIVERSAL.tmp"
  mv -f "$UNIVERSAL.tmp" "$UNIVERSAL"
fi
install -m 755 "$UNIVERSAL" "$DEST"
# One arch per invocation: some lipo builds (Xcode 27 beta 4) consume only one
# arch after -verify_arch and read the second as an extra input file, failing
# with "requires exactly one input file".
for arch in arm64 x86_64; do lipo "$DEST" -verify_arch "$arch"; done
verify_probe
echo "Installed universal cmux-tui client (commit ${COMMIT:0:10}) at $DEST"
