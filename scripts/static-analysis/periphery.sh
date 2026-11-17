#!/usr/bin/env bash
# Report unused Swift code (types, functions, properties, protocols, parameters) in this
# repo's SwiftPM packages with Periphery. Periphery builds each package to get its index
# store, so this needs a Swift toolchain: on macOS, Xcode's; on Linux, `swift` on PATH
# (or SA_SWIFT_DIR=/path/to/toolchain/usr). On Linux it builds Periphery from source and
# only packages that build on Linux can be scanned (no AppKit/SwiftUI); macOS-only packages
# are listed as skipped. The Xcode project (cmux.xcodeproj) needs macOS: run there with
#   SA_PERIPHERY_XCODE=1 (scans scheme ${SA_PERIPHERY_SCHEME:-cmux}).
# Report-only: exits 0 once Periphery ran on at least one package; nonzero only when
# Periphery or Swift is missing/cannot be installed, or no package could be scanned.
# Usage: bash scripts/static-analysis/periphery.sh [PACKAGE_DIR...]
#   default: every Packages/**/Package.swift
# Never runs on the person's Mac by policy: on a Mac use a fleet host (cmux-ci run).
set -uo pipefail

VERSION="3.8.0"
MAC_ZIP_SHA=a9c7bfb1483dde1f4b660bc64183161fde3b519b7392add51ec8fe8b846cf494
SRC_SHA=0732e25b366ef019897b1fd9577579f6a472671701d08b0b83ad9413bc859004
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "periphery.sh: not in a git repo" >&2; exit 2; }
cd "$ROOT" || exit 2
TOOLS_DIR="${SA_TOOLS_DIR:-$HOME/.cache/static-analysis/bin}"
OUT_DIR="${FAST_CHECKS_OUT:-${TMPDIR:-/tmp}/static-analysis-out}"
OUT="$OUT_DIR/periphery.txt"
mkdir -p "$TOOLS_DIR" "$OUT_DIR/periphery" || exit 2
START=$(date +%s)
[ -n "${SA_SWIFT_DIR:-}" ] && export PATH="$SA_SWIFT_DIR/bin:$PATH"

sha256() { (sha256sum "$1" 2>/dev/null || shasum -a 256 "$1") | awk '{print $1}'; }

if ! command -v swift >/dev/null; then
  echo "periphery.sh: no Swift toolchain (swift not on PATH; set SA_SWIFT_DIR). Periphery builds" >&2
  echo "  each package to read its index store, so it cannot run without one." >&2
  exit 2
fi

BIN="$TOOLS_DIR/periphery-$VERSION"
if [ ! -x "$BIN" ]; then
  TMP="$(mktemp -d)" || exit 2
  if [ "$(uname -s)" = Darwin ]; then
    curl -fsSL --retry 3 -o "$TMP/p.zip" "https://github.com/peripheryapp/periphery/releases/download/$VERSION/periphery-$VERSION.artifactbundle.zip" \
      || { echo "periphery.sh: download failed" >&2; rm -rf "$TMP"; exit 2; }
    [ "$(sha256 "$TMP/p.zip")" = "$MAC_ZIP_SHA" ] || { echo "periphery.sh: sha256 mismatch" >&2; rm -rf "$TMP"; exit 2; }
    unzip -q "$TMP/p.zip" -d "$TMP" || exit 2
    mkdir -p "$TOOLS_DIR/periphery-$VERSION.d" || exit 2
    cp "$TMP/periphery-$VERSION.artifactbundle/periphery-$VERSION-macos/bin/"* "$TOOLS_DIR/periphery-$VERSION.d/" || exit 2
    ln -sf "$TOOLS_DIR/periphery-$VERSION.d/periphery" "$BIN"
  else
    # No Linux release binary: build the pinned tag with the local toolchain (about 5 min).
    curl -fsSL --retry 3 -o "$TMP/src.tgz" "https://github.com/peripheryapp/periphery/archive/refs/tags/$VERSION.tar.gz" \
      || { echo "periphery.sh: source download failed" >&2; rm -rf "$TMP"; exit 2; }
    [ "$(sha256 "$TMP/src.tgz")" = "$SRC_SHA" ] || { echo "periphery.sh: source sha256 mismatch" >&2; rm -rf "$TMP"; exit 2; }
    mkdir -p "$TMP/src" && tar -xzf "$TMP/src.tgz" -C "$TMP/src" --strip-components=1 || exit 2
    (cd "$TMP/src" && swift build -c release --product periphery) >"$OUT_DIR/periphery/build-periphery.log" 2>&1 \
      || { echo "periphery.sh: building Periphery failed (see $OUT_DIR/periphery/build-periphery.log)" >&2; rm -rf "$TMP"; exit 2; }
    install -m 0755 "$(cd "$TMP/src" && swift build -c release --show-bin-path)/periphery" "$BIN" || exit 2
  fi
  rm -rf "$TMP"
fi

if [ "$#" -gt 0 ]; then
  PKGS=("$@")
else
  mapfile -t PKGS < <(git ls-files 'Packages/*Package.swift' | xargs -n1 dirname | sort -u)
fi

: >"$OUT"
SCANNED=0; SKIPPED=0; FINDINGS=0
scan() { # label, log, periphery args...
  local label="$1" log="$2"; shift 2
  "$BIN" scan --disable-update-check --format xcode "$@" >"$log.out" 2>"$log"
  local rc=$?
  # Periphery exits 0 with results; a build failure is nonzero with a build log.
  if [ "$rc" -ne 0 ] && ! grep -q ': warning: ' "$log.out"; then
    echo "## $label: skipped (build or scan failed, exit $rc; see $log)" >>"$OUT"
    SKIPPED=$((SKIPPED + 1)); return
  fi
  local n; n=$(grep -c ': warning: ' "$log.out" || true)
  FINDINGS=$((FINDINGS + n)); SCANNED=$((SCANNED + 1))
  { echo "## $label: $n"; sed "s|^$ROOT/||" "$log.out" | grep ': warning: '; echo; } >>"$OUT"
}

for pkg in "${PKGS[@]}"; do
  pkg="${pkg%/}"; safe="${pkg//\//__}"
  echo "periphery: $pkg" >&2
  # --retain-public: a package's public API is used by the app target, which this run
  # does not index, so only internal/private declarations are reported.
  (cd "$pkg" && scan "$pkg" "$OUT_DIR/periphery/$safe.log" --retain-public --relative-results)
done
# The subshells above cannot update the counters; recount from the report.
SCANNED=$(grep -cE '^## .*: [0-9]+$' "$OUT" || true)
SKIPPED=$(grep -c ': skipped ' "$OUT" || true)
FINDINGS=$(grep -c ': warning: ' "$OUT" || true)

if [ -n "${SA_PERIPHERY_XCODE:-}" ] && [ "$(uname -s)" = Darwin ]; then
  scan "cmux.xcodeproj (${SA_PERIPHERY_SCHEME:-cmux})" "$OUT_DIR/periphery/xcodeproj.log" \
    --project cmux.xcodeproj --schemes "${SA_PERIPHERY_SCHEME:-cmux}"
  SCANNED=$(grep -cE '^## .*: [0-9]+$' "$OUT" || true)
  FINDINGS=$(grep -c ': warning: ' "$OUT" || true)
fi

grep -E '^## ' "$OUT"
echo "Full report: $OUT (scanned $SCANNED, skipped $SKIPPED)"
[ "${SCANNED:-0}" -gt 0 ] || { echo "periphery.sh: no package could be scanned" >&2; exit 2; }
echo "SA_SUMMARY tool=periphery findings=${FINDINGS:-0} seconds=$(( $(date +%s) - START ))"
exit 0
