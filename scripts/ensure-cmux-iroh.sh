#!/usr/bin/env bash
# Builds CmuxIrohFFI.xcframework from Native/cmux-iroh and symlinks it at the
# repo root, mirroring scripts/ensure-ghosttykit.sh: content-hash cache under
# ~/.cache/cmux/cmux-iroh (override with CMUX_IROH_CACHE_DIR), mkdir lock with
# stale timeout, atomic install. Slices: macOS arm64+x86_64 (the release app
# is universal), iOS device arm64, iOS simulator arm64.
#
# Requires rustup (the pinned toolchain + targets in
# Native/cmux-iroh/rust-toolchain.toml are installed automatically). CI uses
# scripts/install-rust-ci.sh; fleet builders need rustup once.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

CRATE_DIR="$PROJECT_DIR/Native/cmux-iroh"
CRATE_REL="Native/cmux-iroh"
LIB_NAME="libcmux_iroh_ffi.a"
FRAMEWORK_NAME="CmuxIrohFFI.xcframework"
# Bump when the xcframework layout (slices, headers) changes without a crate
# source change.
LAYOUT_VERSION="v1"

hash_stdin() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    sha256sum | awk '{print $1}'
  fi
}

hash_file() {
  local path="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print $1}'
  else
    sha256sum "$path" | awk '{print $1}'
  fi
}

if [[ ! -d "$CRATE_DIR" ]]; then
  echo "error: $CRATE_REL is missing." >&2
  exit 1
fi

# Content key: tracked blob SHAs + dirty diff + untracked file hashes of the
# crate, plus this script, the layout version, and the active Apple toolchain
# (ring, via cc, compiles C/asm with the selected Xcode's clang and SDKs, so
# the static libs are not toolchain-independent; an Xcode or SDK change must
# not reuse a cache entry built by another toolchain). Mirrors
# ensure-ghosttykit's clean/dirty keying so a dirty crate never reuses a
# clean cache entry.
UNTRACKED_FILES="$(git -C "$PROJECT_DIR" ls-files --others --exclude-standard -- "$CRATE_REL")"
IROH_KEY="$(
  {
    printf 'layout=%s\n' "$LAYOUT_VERSION"
    printf '%s\n' '--script--'
    hash_file "$SCRIPT_DIR/ensure-cmux-iroh.sh"
    printf '%s\n' '--apple-toolchain--'
    xcodebuild -version 2>/dev/null || true
    xcrun --sdk macosx --show-sdk-build-version 2>/dev/null || true
    xcrun --sdk iphoneos --show-sdk-build-version 2>/dev/null || true
    xcrun --sdk iphonesimulator --show-sdk-build-version 2>/dev/null || true
    printf '%s\n' '--tracked--'
    git -C "$PROJECT_DIR" ls-files -s -- "$CRATE_REL"
    printf '%s\n' '--dirty--'
    git -C "$PROJECT_DIR" diff --binary HEAD -- "$CRATE_REL"
    if [[ -n "$UNTRACKED_FILES" ]]; then
      printf '\n%s\n' '--untracked--'
      while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        printf 'path=%s\n' "$path"
        hash_file "$PROJECT_DIR/$path"
      done <<< "$UNTRACKED_FILES"
    fi
  } | hash_stdin
)"

CACHE_ROOT="${CMUX_IROH_CACHE_DIR:-$HOME/.cache/cmux/cmux-iroh}"
CACHE_DIR="$CACHE_ROOT/$IROH_KEY"
CACHE_XCFRAMEWORK="$CACHE_DIR/$FRAMEWORK_NAME"
LOCK_DIR="$CACHE_ROOT/$IROH_KEY.lock"

mkdir -p "$CACHE_ROOT"

echo "==> cmux-iroh build key: $IROH_KEY"

# Owner-aware lock: a cold four-target cargo build can legitimately exceed any
# fixed timeout, so a lock whose owner process is still alive is never broken
# (unlike a bare mkdir+timeout lock, which could delete a live builder's lock
# and race the cache install). Only pid-less or dead-owner locks go stale.
LOCK_TIMEOUT=600
LOCK_START=$SECONDS
while ! mkdir "$LOCK_DIR" 2>/dev/null; do
  OWNER_PID="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
  if [[ -n "$OWNER_PID" ]] && kill -0 "$OWNER_PID" 2>/dev/null; then
    # Owner is alive: wait for it however long its build takes.
    LOCK_START=$SECONDS
    echo "==> Waiting for cmux-iroh cache lock (held by pid $OWNER_PID)..."
  elif [[ -n "$OWNER_PID" ]]; then
    echo "==> Lock owner (pid $OWNER_PID) is gone, removing stale lock..."
    rm -rf "$LOCK_DIR"
    continue
  elif (( SECONDS - LOCK_START > LOCK_TIMEOUT )); then
    echo "==> Lock has no live owner after ${LOCK_TIMEOUT}s, removing..."
    rm -rf "$LOCK_DIR"
    continue
  else
    echo "==> Waiting for cmux-iroh cache lock for $IROH_KEY..."
  fi
  sleep 1
done
echo "$$" > "$LOCK_DIR/pid"
trap 'rm -rf "$LOCK_DIR" >/dev/null 2>&1 || true' EXIT

if [[ -d "$CACHE_XCFRAMEWORK" ]]; then
  echo "==> Reusing cached $FRAMEWORK_NAME"
else
  if ! command -v rustup >/dev/null 2>&1; then
    echo "error: rustup is required to build $FRAMEWORK_NAME." >&2
    echo "Install via ./scripts/install-rust-ci.sh (CI/fleet) or https://rustup.rs," >&2
    echo "then re-run; $CRATE_REL/rust-toolchain.toml pins the toolchain and targets." >&2
    exit 1
  fi
  if ! command -v xcodebuild >/dev/null 2>&1; then
    echo "error: xcodebuild is required to assemble $FRAMEWORK_NAME." >&2
    exit 1
  fi

  # Slice matrix deliberately mirrors GhosttyKit.xcframework, which the same
  # iOS app graph already links: macOS universal (the release app is
  # arm64+x86_64), iOS device arm64, iOS simulator arm64 ONLY. Intel-host iOS
  # simulator builds are already unsupported repo-wide (GhosttyKit ships no
  # x86_64 simulator slice), so adding one here would not make them work.
  RUST_TARGETS=(
    aarch64-apple-darwin
    x86_64-apple-darwin
    aarch64-apple-ios
    aarch64-apple-ios-sim
  )

  # Run from the crate dir so rustup honors rust-toolchain.toml (pinned
  # channel + targets are installed on demand).
  (
    cd "$CRATE_DIR"
    rustup target add "${RUST_TARGETS[@]}"
    for target in "${RUST_TARGETS[@]}"; do
      echo "==> cargo build --release --locked --target $target"
      cargo build --release --locked --target "$target"
    done
  )

  for target in "${RUST_TARGETS[@]}"; do
    lib="$CRATE_DIR/target/$target/release/$LIB_NAME"
    if [[ ! -f "$lib" ]]; then
      echo "error: expected staticlib at $lib" >&2
      exit 1
    fi
  done

  TMP_DIR="$(mktemp -d "$CACHE_ROOT/.cmux-iroh-tmp.XXXXXX")"
  cleanup_tmp() {
    rm -rf "$TMP_DIR"
    rm -rf "$LOCK_DIR" >/dev/null 2>&1 || true
  }
  trap cleanup_tmp EXIT

  echo "==> lipo macOS universal staticlib"
  mkdir -p "$TMP_DIR/macos-universal"
  lipo -create \
    "$CRATE_DIR/target/aarch64-apple-darwin/release/$LIB_NAME" \
    "$CRATE_DIR/target/x86_64-apple-darwin/release/$LIB_NAME" \
    -output "$TMP_DIR/macos-universal/$LIB_NAME"

  # No -headers: the xcframework is a pure binary. The hand-maintained C
  # header (and the SwiftPM-generated module) live in Packages/Shared/CmuxIrohFFI;
  # shipping headers here would collide with GhosttyKit's module.modulemap in
  # the shared BUILT_PRODUCTS_DIR/include/ copy step.
  echo "==> xcodebuild -create-xcframework"
  xcodebuild -create-xcframework \
    -library "$TMP_DIR/macos-universal/$LIB_NAME" \
    -library "$CRATE_DIR/target/aarch64-apple-ios/release/$LIB_NAME" \
    -library "$CRATE_DIR/target/aarch64-apple-ios-sim/release/$LIB_NAME" \
    -output "$TMP_DIR/$FRAMEWORK_NAME"

  mkdir -p "$CACHE_DIR"
  rm -rf "$CACHE_XCFRAMEWORK"
  mv "$TMP_DIR/$FRAMEWORK_NAME" "$CACHE_XCFRAMEWORK"
  echo "==> Cached $FRAMEWORK_NAME at $CACHE_XCFRAMEWORK"
fi

echo "==> Creating symlink for $FRAMEWORK_NAME..."
ln -sfn "$CACHE_XCFRAMEWORK" "$FRAMEWORK_NAME"
