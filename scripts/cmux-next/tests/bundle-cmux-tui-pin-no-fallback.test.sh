#!/usr/bin/env bash
# Pin mode (the Release default) of bundle-cmux-tui.sh bundles only the pinned
# cmux-tui. No pin, a malformed pin, a host other than arm64, a pin that is not
# downloaded or one with another sha256 fails the build and leaves no bundled
# client, the way tree mode fails; it never falls back to CMUX_TUI_CLIENT_LOCAL
# or a release installer cache slice (an old client runs an old daemon in the
# new app). Deferred mode (the job installs the client after the build) bundles
# none and exits 0. Ports the bundling half of #16506.
# No network, no daemon: fake binaries, CONFIGURATION=Release skips the
# capability check.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
sha() { shasum -a 256 "$1" | awk '{print $1}'; }

pin_commit=$(printf '1%.0s' {1..40})
stale_commit=$(printf 'a%.0s' {1..40})
fake_tui() { # <path> <commit>
  mkdir -p "$(dirname "$1")"
  printf '#!/bin/sh\necho "cmux-tui 0.1.0 (%s)"\n' "$2" > "$1"
  chmod 755 "$1"
}

# A checkout with the pin and the scripts the phase runs; no cmux-tui fetched.
src="$TMP/src"
mkdir -p "$src/scripts/cmux-next"
cp "$ROOT/scripts/cmux-next/write-daemon-capabilities.sh" "$src/scripts/cmux-next/"
pinned="$src/cmux-tui/target/hosted/$pin_commit/cmux-tui"
write_pin() { # <sha256>
  printf 'commit=%s\nurl=https://files.cmux.com/cmux-tui/%s/cmux-tui-aarch64-apple-darwin\nrun=1\nsha256=%s\n' \
    "$pin_commit" "$pin_commit" "$1" > "$src/scripts/cmux-next/cmux-tui.pin"
}
write_pin "$(printf '2%.0s' {1..64})"

# The stale clients the old pin mode fell back to: a CMUX_TUI_CLIENT_LOCAL and
# the newest release installer cache slice.
fake_tui "$TMP/client-local/cmux-tui" "$stale_commit"
fake_tui "$TMP/cache/$stale_commit/cmux-tui-aarch64-apple-darwin" "$stale_commit"

bin="$TMP/app/Contents/Resources/bin"
# A client an earlier build bundled must not survive a failed pin-mode run.
seed_stale_bundle() {
  mkdir -p "$bin"
  cp "$TMP/client-local/cmux-tui" "$bin/cmux"
  ln -sf cmux "$bin/cmux-tui"
  printf 'source=release-cache\n' > "$bin/cmux-tui.version"
}
run_bundle() { # <mode> [extra env...]; sets status, output in $TMP/out
  local mode="$1"; shift
  set +e
  env -u CMUX_NEXT_TUI_BIN -u CMUX_NEXT_APP_HOST_BIN -u CMUX_NEXT_CLOUD_SERVER_BIN -u CMUX_NEXT_BROWSER_HOST_BIN \
    -u CMUX_NEXT_AGENT_SCREEN_DETECTION_BIN -u CMUX_NEXT_TERMINAL_HOST_BIN -u CMUX_NEXT_HOLDER_BIN -u CMUX_TUI_TREE_KEY \
    TARGET_BUILD_DIR="$TMP/app" UNLOCALIZED_RESOURCES_FOLDER_PATH=Contents/Resources TARGET_TEMP_DIR="$TMP/temp" \
    SRCROOT="$src" CONFIGURATION=Release CMUX_NEXT_TUI_MODE="$mode" NATIVE_ARCH_ACTUAL=arm64 \
    CMUX_TUI_CLIENT_LOCAL="$TMP/client-local/cmux-tui" CMUX_TUI_CLIENT_CACHE="$TMP/cache" HOME="$TMP/home" \
    "$@" bash "$ROOT/scripts/cmux-next/bundle-cmux-tui.sh" >"$TMP/out" 2>&1
  status=$?
  set -e
}
expect_pin_failure() { # <case> <error text> [extra env...]
  local name="$1" want="$2"; shift 2
  seed_stale_bundle
  run_bundle pin "$@"
  (( status != 0 )) || { cat "$TMP/out" >&2; fail "$name: pin mode exited 0"; }
  grep -qF "$want" "$TMP/out" || { cat "$TMP/out" >&2; fail "$name: no error naming '$want'"; }
  grep -qF 'pin-cmux-tui.sh fetch --pin' "$TMP/out" || { cat "$TMP/out" >&2; fail "$name: the error does not say how to fetch the pin"; }
  ! grep -q "$stale_commit" "$TMP/out" || { cat "$TMP/out" >&2; fail "$name: pin mode reached for a stale client"; }
  [[ ! -e "$bin/cmux" && ! -L "$bin/cmux-tui" && ! -e "$bin/cmux-tui.version" ]] \
    || fail "$name: a failed pin-mode run left a bundled client: $(ls -la "$bin")"
  [[ ! -e "$TMP/temp/bundle-cmux-tui.stamp" ]] || fail "$name: a failed run wrote the phase stamp"
  echo "ok: $name"
}

# The pin is not downloaded (the release cache and CMUX_TUI_CLIENT_LOCAL hold a client).
expect_pin_failure "pin not downloaded" "the pinned cmux-tui $pin_commit is not downloaded"
# Another arch: the pin is published for arm64 only.
expect_pin_failure "x86_64 host" "published for arm64 only, not x86_64" NATIVE_ARCH_ACTUAL=x86_64
# A downloaded pin binary with another sha256.
fake_tui "$pinned" "$pin_commit"
expect_pin_failure "sha256 mismatch" "but $src/scripts/cmux-next/cmux-tui.pin pins"
# A malformed pin.
printf 'commit=%s\nsha256=short\n' "$pin_commit" > "$src/scripts/cmux-next/cmux-tui.pin"
expect_pin_failure "malformed pin" "cmux-tui.pin is malformed"
# No pin at all.
rm "$src/scripts/cmux-next/cmux-tui.pin"
expect_pin_failure "no pin" "no cmux-tui pin at"
# No pin and no mode: Release defaults to pin mode, so it fails too.
seed_stale_bundle
run_bundle ""
(( status != 0 )) || { cat "$TMP/out" >&2; fail "a Release build with no mode and no pin exited 0"; }
echo "ok: Release defaults to pin mode"

# The downloaded pin with its sha256 is bundled.
write_pin "$(sha "$pinned")"
run_bundle pin
(( status == 0 )) || { cat "$TMP/out" >&2; fail "pin mode failed with the pin downloaded"; }
cmp -s "$pinned" "$bin/cmux" || fail "pin mode did not bundle the pinned cmux-tui"
grep -qx 'source=pinned-hosted' "$bin/cmux-tui.version" || fail "cmux-tui.version: $(cat "$bin/cmux-tui.version")"
grep -qx "commit=$pin_commit" "$bin/cmux-tui.version" || fail "cmux-tui.version: $(cat "$bin/cmux-tui.version")"
echo "ok: the downloaded pin is bundled"

# Deferred mode bundles none, takes no stale client, clears what an earlier build left, exits 0.
run_bundle deferred
(( status == 0 )) || { cat "$TMP/out" >&2; fail "deferred mode failed"; }
[[ ! -e "$bin/cmux" && ! -L "$bin/cmux-tui" && ! -e "$bin/cmux-tui.version" ]] \
  || fail "deferred mode left a bundled client: $(ls -la "$bin")"
[[ -f "$TMP/temp/bundle-cmux-tui.stamp" ]] || fail "deferred mode wrote no phase stamp"
echo "ok: deferred mode bundles none"

echo "bundle-cmux-tui-pin-no-fallback: ok"
