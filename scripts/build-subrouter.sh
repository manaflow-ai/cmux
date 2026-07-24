#!/usr/bin/env bash
# Build the subrouter Go binary (daemon + sr CLI in one executable) from the
# pinned submodule and place it, gzip-compressed, into the app bundle at
# Resources/bin/subrouter.gz. The app and CLI extract it on demand and route
# `sr` / `subrouter` invocations to it, so cmux works without a separately
# installed ~/bin/sr.
#
# Results are cached per (submodule SHA, arch set) under ~/.cache/cmux-subrouter
# so incremental app builds don't pay the Go build. Set
# CMUX_SKIP_SUBROUTER_BUNDLE=1 to skip bundling entirely (the app then relies
# on `sr` from PATH, matching the pre-bundling behavior).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUBMODULE_DIR="${ROOT}/subrouter"
OUT_DIR="${TARGET_BUILD_DIR:-/tmp}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:-Resources}/bin"
OUT_PATH="${OUT_DIR}/subrouter.gz"

if [[ "${CMUX_SKIP_SUBROUTER_BUNDLE:-0}" == "1" ]]; then
  echo "note: CMUX_SKIP_SUBROUTER_BUNDLE=1; not bundling subrouter" >&2
  rm -f "$OUT_PATH"
  exit 0
fi

if [[ ! -f "${SUBMODULE_DIR}/go.mod" ]]; then
  echo "error: subrouter submodule is not initialized; run: git submodule update --init subrouter" >&2
  echo "       (or set CMUX_SKIP_SUBROUTER_BUNDLE=1 to build without the bundled sr)" >&2
  exit 1
fi

# Xcode build phases do not inherit a login-shell PATH.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/local/go/bin:${HOME}/go/bin:${PATH}"

if ! command -v go >/dev/null 2>&1; then
  if [[ "${CI:-}" == "true" ]]; then
    # CI test builds don't exercise the bundled binary; reload-build.yml
    # installs Go explicitly for the builds that ship it.
    echo "warning: no Go toolchain on this CI runner; skipping the subrouter bundle" >&2
    rm -f "$OUT_PATH"
    exit 0
  fi
  echo "error: the Go toolchain is required to bundle subrouter (brew install go)," >&2
  echo "       or set CMUX_SKIP_SUBROUTER_BUNDLE=1 to build without it" >&2
  exit 1
fi

requested_archs="${CMUX_SUBROUTER_ARCHS:-${ARCHS:-}}"
if [[ -z "$requested_archs" ]]; then
  case "$(uname -m)" in
    arm64|aarch64) requested_archs="arm64" ;;
    x86_64) requested_archs="x86_64" ;;
    *) echo "error: cannot infer Go target for host arch $(uname -m)" >&2; exit 1 ;;
  esac
fi

SUBMODULE_SHA="$(git -C "$SUBMODULE_DIR" rev-parse HEAD)"
ARCH_KEY="$(echo "$requested_archs" | tr ' ' '-')"
CACHE_DIR="${CMUX_SUBROUTER_CACHE_DIR:-${HOME}/.cache/cmux-subrouter}"
CACHE_PATH="${CACHE_DIR}/subrouter-${SUBMODULE_SHA}-${ARCH_KEY}.gz"

mkdir -p "$OUT_DIR"
if [[ -f "$CACHE_PATH" ]]; then
  cp -f "$CACHE_PATH" "$OUT_PATH"
  echo "bundled subrouter ${SUBMODULE_SHA:0:12} (${ARCH_KEY}, cached)"
  exit 0
fi

WORK_DIR="$(mktemp -d /tmp/cmux-subrouter-build.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

go_arch_for() {
  case "$1" in
    arm64|arm64e) echo "arm64" ;;
    x86_64) echo "amd64" ;;
    *) echo "error: unsupported Go macOS arch $1" >&2; return 1 ;;
  esac
}

SLICES=()
for arch in $requested_archs; do
  go_arch="$(go_arch_for "$arch")"
  slice="${WORK_DIR}/subrouter-${arch}"
  # CGO with external linking matches the subrouter Makefile's macOS build;
  # clang cross-compiles the non-host slice via -arch.
  (cd "$SUBMODULE_DIR" && \
    CGO_ENABLED=1 GOOS=darwin GOARCH="$go_arch" CC="clang -arch ${arch}" \
    go build -trimpath -ldflags='-linkmode external -s -w' -o "$slice" ./cmd/subrouter)
  SLICES+=("$slice")
done

BINARY="${WORK_DIR}/subrouter"
if [[ "${#SLICES[@]}" -gt 1 ]]; then
  lipo -create -output "$BINARY" "${SLICES[@]}"
else
  cp "${SLICES[0]}" "$BINARY"
fi

# Ad-hoc sign before compression: the signature travels with the file, so
# the runtime-extracted copy is immediately executable.
codesign -s - -f "$BINARY"
gzip -9 -n -c "$BINARY" > "${WORK_DIR}/subrouter.gz"

mkdir -p "$CACHE_DIR"
cp -f "${WORK_DIR}/subrouter.gz" "$CACHE_PATH"
cp -f "${WORK_DIR}/subrouter.gz" "$OUT_PATH"
echo "bundled subrouter ${SUBMODULE_SHA:0:12} (${ARCH_KEY}, $(du -h "$OUT_PATH" | cut -f1 | tr -d ' '))"
