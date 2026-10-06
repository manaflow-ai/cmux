#!/usr/bin/env bash
# Installs the cmux-tui binary into an app bundle as Contents/Resources/bin/cmux, the
# cmux CLI, with bin/cmux-tui and bin/acpmux as relative symlinks to it (the binary
# picks its program from argv[0]; plans/cmux-next/cli.md). When the manifest publishes
# cmux-tui-app-host-<target>, the app host goes to Contents/Resources/bin/cmux-app-host,
# where the daemon looks for it; cmux-tui-cloud-server-<target> (the first-party Cloud
# app server, cmux/cloud) goes beside it as bin/cmux-cloud. The app carries the exact client that talks to cmux
# Cloud machines, so the Machines panel needs no separate install.
# cmux-tui-browser-host-<target> goes beside bin/cmux as bin/cmux-browser-host, where
# the daemon looks for it (the sibling of its own executable), but only once
# scripts/cmux-next/notices/bundle-map.json maps that path: release and nightly
# bundles fail check_bundle_notices.py on an unmapped Mach-O, and the map's test
# requires its THIRD_PARTY_LICENSES.md section. Until then it is not installed.
#
# The build comes from the artifacts manifest the cmux-tui-artifacts workflow publishes
# (rolling `latest` by default; a commit-addressed manifest pins one build). Both
# darwin slices are downloaded, sha256-verified against the manifest, and lipo'd into
# one universal binary by default. --arch selects one slice for a native dev build.
# Downloads are cached per commit under CMUX_TUI_CLIENT_CACHE.
#
#   scripts/install-cmux-tui-client.sh <app-path> [--manifest-url <url>] [--cache-dir <dir>]
#     [--expected-commit <sha>] [--require-capability <name>]... [--require-acpmux]
#     [--arch <native|arm64|x86_64|universal>]
#     [--attest-signer-workflow <owner/repo/.github/workflows/name.yml>] [--allow-unattested]
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
# acpmux is linked into the same binary, so bin/acpmux needs no separate download.
# Builds from before that lack it: `bin/acpmux --version` then does not identify as
# acpmux, which is a warning, or an error with --require-acpmux.
#
# Env: CMUX_TUI_CLIENT_MANIFEST_URL overrides the manifest, CMUX_TUI_CLIENT_LOCAL points at
# a prebuilt binary to install instead of downloading (offline/dev builds).
# CMUX_TUI_CLIENT_DOWNLOAD_ATTEMPTS (default 5) and CMUX_TUI_CLIENT_DOWNLOAD_STALL_SECONDS
# (default 60, below 1 KiB/s) bound each download attempt.
# --arch selects downloaded slices only; the local override is copied unchanged
# and still checked with remote-probe and any required capabilities.
set -euo pipefail

usage() { sed -n '2,23p' "$0"; }

APP_PATH=""
MANIFEST_URL="${CMUX_TUI_CLIENT_MANIFEST_URL:-https://files.cmux.com/cmux-tui/latest/manifest.json}"
CACHE_DIR="${CMUX_TUI_CLIENT_CACHE:-$HOME/Library/Caches/cmux/cmux-tui-client}"
EXPECTED_COMMIT=""
ARCH="universal"
ATTEST_SIGNER_WORKFLOW="manaflow-ai/cmux/.github/workflows/cmux-tui-artifacts.yml"
ALLOW_UNATTESTED=0
REQUIRE_ACPMUX=0
REQUIRED_CAPABILITIES=()
while (( $# )); do
  case "$1" in
    --manifest-url) shift; MANIFEST_URL="${1:?--manifest-url needs a value}" ;;
    --cache-dir) shift; CACHE_DIR="${1:?--cache-dir needs a value}" ;;
    --arch) shift; ARCH="${1:?--arch needs a value}" ;;
    --expected-commit) shift; EXPECTED_COMMIT="${1:?--expected-commit needs a value}" ;;
    --attest-signer-workflow) shift; ATTEST_SIGNER_WORKFLOW="${1:?--attest-signer-workflow needs a value}" ;;
    --allow-unattested) ALLOW_UNATTESTED=1 ;;
    --require-acpmux) REQUIRE_ACPMUX=1 ;;
    --require-capability) shift; REQUIRED_CAPABILITIES+=("${1:?--require-capability needs a value}") ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "unknown option: $1" >&2; usage >&2; exit 64 ;;
    *) APP_PATH="$1" ;;
  esac
  shift
done
# uname reports the process architecture under Rosetta. Prefer the Apple
# Silicon hardware capability, matching build-ghostty-cli-helper.sh.
if [[ "$ARCH" == native ]]; then
  ARCH="$(uname -m)"
  case "$ARCH" in
    aarch64) ARCH=arm64 ;;
    x86_64)
      if [[ "$(sysctl -in hw.optional.arm64 2>/dev/null || true)" == 1 ]]; then
        ARCH=arm64
      fi
      ;;
  esac
fi
case "$ARCH" in
  arm64|x86_64|universal) ;;
  *) echo "error: unsupported cmux-tui architecture '$ARCH' (expected native, arm64, x86_64, or universal)" >&2; exit 64 ;;
esac
[[ -n "$APP_PATH" && -d "$APP_PATH/Contents" ]] || { echo "error: app bundle not found at '${APP_PATH:-<missing>}'" >&2; exit 1; }
[[ "$ATTEST_SIGNER_WORKFLOW" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/\.github/workflows/[A-Za-z0-9._-]+\.ya?ml$ ]] || {
  echo "error: --attest-signer-workflow must look like owner/repo/.github/workflows/name.yml: $ATTEST_SIGNER_WORKFLOW" >&2
  exit 64
}
DEST_DIR="$APP_PATH/Contents/Resources/bin"
DEST="$DEST_DIR/cmux"
ALIASES=(cmux-tui acpmux)
mkdir -p "$DEST_DIR"

sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }

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

# Remove first: overwriting a signed Mach-O in place keeps the kernel's cached
# code signature for the old inode and the new binary dies with SIGKILL. The
# aliases are relative symlinks so the bundle stays relocatable and codesign
# treats them as links, not second copies.
install_binary() {
  local name
  rm -f "$DEST"
  install -m 755 "$1" "$DEST"
  for name in "${ALIASES[@]}"; do
    rm -rf "${DEST_DIR:?}/$name"
    ln -s cmux "$DEST_DIR/$name"
  done
}

# acpmux is linked into the binary; bin/acpmux runs it through argv[0].
check_acpmux() {
  local version
  version="$("$DEST_DIR/acpmux" --version 2>/dev/null || true)"
  [[ "$version" == acpmux\ * ]] && return 0
  if (( REQUIRE_ACPMUX )); then
    echo "error: installed binary does not run acpmux through bin/acpmux: $version" >&2
    exit 1
  fi
  echo "warning: installed binary does not run acpmux through bin/acpmux ($version); the agent chat pane falls back to acpmux on PATH" >&2
}

# The companions this bundle may carry: the browser host only once its license
# notices are mapped (see the header).
COMPANIONS=(cmux-app-host cmux-cloud)
BUNDLE_MAP="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cmux-next/notices/bundle-map.json"
if python3 -c 'import json,sys; sys.exit(0 if any(e.get("path") == "Contents/Resources/bin/cmux-browser-host" for e in json.load(open(sys.argv[1]))["entries"]) else 1)' "$BUNDLE_MAP" 2>/dev/null; then
  COMPANIONS+=(cmux-browser-host)
  SHIP_BROWSER_HOST=1
else
  SHIP_BROWSER_HOST=0
  echo "note: bin/cmux-browser-host is not installed: $BUNDLE_MAP does not map it (no license notices yet)"
fi

if [[ -n "${CMUX_TUI_CLIENT_LOCAL:-}" ]]; then
  [[ -f "$CMUX_TUI_CLIENT_LOCAL" ]] || { echo "error: CMUX_TUI_CLIENT_LOCAL not found: $CMUX_TUI_CLIENT_LOCAL" >&2; exit 1; }
  install_binary "$CMUX_TUI_CLIENT_LOCAL"
  # A local client brings its app host and app servers when they sit beside it.
  rm -f "$DEST_DIR/cmux-browser-host"
  for companion in "${COMPANIONS[@]}"; do
    rm -f "$DEST_DIR/$companion"
    if [[ -f "$(dirname "$CMUX_TUI_CLIENT_LOCAL")/$companion" ]]; then
      install -m 755 "$(dirname "$CMUX_TUI_CLIENT_LOCAL")/$companion" "$DEST_DIR/$companion"
    fi
  done
  verify_probe
  check_acpmux
  echo "Installed local cmux-tui client at $DEST"
  exit 0
fi

# A dead HTTP/2 stream holds a transfer open until the server resets it, which
# took twenty minutes per attempt on a Release job, and curl's own --retry
# reuses that connection. Bound each attempt by progress, not total time, so a
# slow but moving download of a 40 MB slice still finishes, and give each its
# own curl process, so a retry opens a fresh connection.
DOWNLOAD_ATTEMPTS="${CMUX_TUI_CLIENT_DOWNLOAD_ATTEMPTS:-5}"
DOWNLOAD_STALL_SECONDS="${CMUX_TUI_CLIENT_DOWNLOAD_STALL_SECONDS:-60}"
for budget in CMUX_TUI_CLIENT_DOWNLOAD_ATTEMPTS="$DOWNLOAD_ATTEMPTS" \
  CMUX_TUI_CLIENT_DOWNLOAD_STALL_SECONDS="$DOWNLOAD_STALL_SECONDS"; do
  [[ "${budget#*=}" =~ ^[1-9][0-9]*$ ]] \
    || { echo "error: ${budget%%=*} must be a positive integer, got '${budget#*=}'" >&2; exit 64; }
done
download() { # <url> <output>
  local attempt=1
  until curl --proto '=https' --tlsv1.2 -fsSL \
      --connect-timeout 30 \
      --speed-limit 1024 --speed-time "$DOWNLOAD_STALL_SECONDS" \
      "$1" -o "$2"; do
    if (( attempt >= DOWNLOAD_ATTEMPTS )); then
      echo "error: could not download $1 after $attempt attempts" >&2
      return 1
    fi
    attempt=$((attempt + 1))
    sleep 3
  done
}

mkdir -p "$CACHE_DIR"
MANIFEST="$CACHE_DIR/manifest.$(printf '%s' "$MANIFEST_URL" | shasum -a 256 | cut -c1-12).json"
download "$MANIFEST_URL" "$MANIFEST"
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
  download "$BASE/$name" "$out.tmp" || exit 1
  got="$(sha256_of "$out.tmp")"
  [[ "$got" == "$want" ]] || { echo "error: sha256 mismatch for $name (want $want, got $got)" >&2; rm -f "$out.tmp"; exit 1; }
  mv -f "$out.tmp" "$out"
  printf '%s' "$out"
}

case "$ARCH" in
  arm64)
    CLIENT="$(fetch_slice cmux-tui-aarch64-apple-darwin)"
    VERIFY_ARCHS=(arm64)
    ;;
  x86_64)
    CLIENT="$(fetch_slice cmux-tui-x86_64-apple-darwin)"
    VERIFY_ARCHS=(x86_64)
    ;;
  universal)
    ARM="$(fetch_slice cmux-tui-aarch64-apple-darwin)"
    X64="$(fetch_slice cmux-tui-x86_64-apple-darwin)"
    CLIENT="$BUILD_DIR/cmux-tui-universal"
    if [[ ! -f "$CLIENT" ]]; then
      lipo -create "$ARM" "$X64" -output "$CLIENT.tmp"
      mv -f "$CLIENT.tmp" "$CLIENT"
    fi
    VERIFY_ARCHS=(arm64 x86_64)
    ;;
esac
install_binary "$CLIENT"
# The app host (apps-v1) and the first-party app servers ship from the same build when
# the manifest has them. Older builds have none; then none is bundled (the app reports
# that it needs a newer cmux-tui, and the supervisor answers apps.server_missing).
manifest_has() {
  python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))["binaries"].get(sys.argv[2]) else 1)' "$MANIFEST" "$1"
}
# install_companion <artifact prefix> <installed name>: both darwin slices, lipo'd
# like the client, sha256-verified by fetch_slice.
install_companion() {
  local prefix="$1" name="$2" dest="$DEST_DIR/$2" binary arm x64 arch
  if ! { manifest_has "$prefix-aarch64-apple-darwin" && manifest_has "$prefix-x86_64-apple-darwin"; }; then
    rm -f "$dest"
    echo "note: cmux-tui ${COMMIT:0:10} publishes no $name"
    return 0
  fi
  case "$ARCH" in
    arm64) binary="$(fetch_slice "$prefix-aarch64-apple-darwin")" ;;
    x86_64) binary="$(fetch_slice "$prefix-x86_64-apple-darwin")" ;;
    universal)
      arm="$(fetch_slice "$prefix-aarch64-apple-darwin")"
      x64="$(fetch_slice "$prefix-x86_64-apple-darwin")"
      binary="$BUILD_DIR/$name-universal"
      if [[ ! -f "$binary" ]]; then
        lipo -create "$arm" "$x64" -output "$binary.tmp"
        mv -f "$binary.tmp" "$binary"
      fi
      ;;
  esac
  rm -f "$dest"
  install -m 755 "$binary" "$dest"
  for arch in "${VERIFY_ARCHS[@]}"; do lipo "$dest" -verify_arch "$arch"; done
}
install_companion cmux-tui-app-host cmux-app-host
install_companion cmux-tui-cloud-server cmux-cloud
if [[ "$SHIP_BROWSER_HOST" == 1 ]]; then
  install_companion cmux-tui-browser-host cmux-browser-host
else
  rm -f "$DEST_DIR/cmux-browser-host"
fi
# One arch per invocation: some lipo builds (Xcode 27 beta 4) consume only one
# arch after -verify_arch and read the second as an extra input file, failing
# with "requires exactly one input file".
for arch in "${VERIFY_ARCHS[@]}"; do lipo "$DEST" -verify_arch "$arch"; done
verify_probe
check_acpmux
# Bootstrap payloads share the signed client's exact build. End-user SSH hosts
# need neither Node/npm nor access to an artifact server, and the client verifies
# these hashes again before uploading the selected platform executable.
SSH_ARTIFACT_DIR="$DEST_DIR/cmux-tui-ssh"
mkdir -p "$SSH_ARTIFACT_DIR"
for target in aarch64-unknown-linux-musl x86_64-unknown-linux-musl aarch64-apple-darwin x86_64-apple-darwin; do
  artifact="$(fetch_slice "cmux-tui-$target")"
  install -m 644 "$artifact" "$SSH_ARTIFACT_DIR/cmux-tui-$target"
done
install -m 644 "$MANIFEST" "$SSH_ARTIFACT_DIR/manifest.json"
echo "Installed $ARCH cmux-tui client (commit ${COMMIT:0:10}) at $DEST"
