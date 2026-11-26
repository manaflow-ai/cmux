#!/usr/bin/env bash
# media_build_app.sh builds cmux-tui on the Mac when the app's tree is not
# published (the tour's base, the previous nightly-next tip, is never
# published: runs 45115317828 and 45120545271 waited 45 min in reload.sh and
# recorded no clip), and leaves a published or stand-in tree to reload.sh.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../media_build_app.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

make_source() { # DIR PROBE_STATE
  local d="$1"
  mkdir -p "$d/scripts/cmux-next"
  cat > "$d/scripts/cmux-next/pin-cmux-tui.sh" <<STUB
#!/usr/bin/env bash
[ "\$1" = probe ] && echo "cmux-tui tree abc: $2 (stub)"
STUB
  cat > "$d/scripts/cmux-next/build-cmux-tui-client.sh" <<'STUB'
#!/usr/bin/env bash
echo "target=$CMUX_TUI_CLIENT_TARGET_DIR" > "$PWD/client-built"
echo "building" >&2
echo "$PWD/client/cmux-tui"
STUB
  cat > "$d/scripts/reload.sh" <<'STUB'
#!/usr/bin/env bash
echo "local=${CMUX_TUI_CLIENT_LOCAL:-}" > "$PWD/reload-env"
mkdir -p "$PWD/Out.app"
echo "App path:"; echo "  $PWD/Out.app"
STUB
  chmod +x "$d"/scripts/cmux-next/*.sh "$d/scripts/reload.sh"
}

run() { # DIR [ENV...]
  local d="$1"; shift
  env HOME="$tmp/home" GITHUB_OUTPUT="$tmp/out" RUNNER_NAME=r1 "$@" \
    bash "$script" "$d" t "$d/log" app >/dev/null 2>&1 || fail "media_build_app.sh failed for $d"
}

# Unpublished tree: the client set is built here and handed to reload.sh.
make_source "$tmp/none" none
run "$tmp/none"
grep -qx "local=$tmp/none/client/cmux-tui" "$tmp/none/reload-env" || fail "reload.sh did not get the local build: $(cat "$tmp/none/reload-env")"
grep -q "cmux-ci-media/cmux-tui-client-target/r1" "$tmp/none/client-built" || fail "no per-runner Cargo target"

# Published tree: no local build.
make_source "$tmp/ready" ready
run "$tmp/ready"
[ ! -e "$tmp/ready/client-built" ] || fail "built cmux-tui for a published tree"
grep -qx "local=" "$tmp/ready/reload-env" || fail "set CMUX_TUI_CLIENT_LOCAL for a published tree"

# A stand-in tree (CMUX_TUI_TREE_KEY) is published: no local build.
make_source "$tmp/standin" none
run "$tmp/standin" CMUX_TUI_TREE_KEY="$(printf "a%.0s" {1..40})"
[ ! -e "$tmp/standin/client-built" ] || fail "built cmux-tui despite a stand-in tree"

# An explicit binary wins.
make_source "$tmp/bin" none
run "$tmp/bin" CMUX_NEXT_TUI_BIN=/x/cmux-tui
[ ! -e "$tmp/bin/client-built" ] || fail "built cmux-tui despite CMUX_NEXT_TUI_BIN"

# A Swift package resolution failure (GitHub 403, job 139577219503) is retried;
# the build shares a per-runner SourcePackages dir.
make_source "$tmp/spm" ready
cat > "$tmp/spm/scripts/reload.sh" <<'STUB'
#!/usr/bin/env bash
echo "spm=${CMUX_SOURCE_PACKAGES_DIR:-}" > "$PWD/reload-env"
n=$(( $(cat "$PWD/tries" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$PWD/tries"
if [ "$n" -lt 2 ]; then echo "xcodebuild: error: Could not resolve package dependencies:"; exit 74; fi
mkdir -p "$PWD/Out.app"; echo "App path:"; echo "  $PWD/Out.app"
STUB
chmod +x "$tmp/spm/scripts/reload.sh"
run "$tmp/spm" MEDIA_SPM_RETRY_SECONDS=0
[ "$(cat "$tmp/spm/tries")" = 2 ] || fail "resolution failure not retried once: $(cat "$tmp/spm/tries")"
grep -qx "spm=$tmp/home/Library/Caches/cmux-ci-media/source-packages/r1" "$tmp/spm/reload-env" || fail "no per-runner SourcePackages: $(cat "$tmp/spm/reload-env")"

# Any other build failure is not retried.
make_source "$tmp/bad" ready
cat > "$tmp/bad/scripts/reload.sh" <<'STUB'
#!/usr/bin/env bash
n=$(( $(cat "$PWD/tries" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$PWD/tries"
echo "error: compile failed"; exit 65
STUB
chmod +x "$tmp/bad/scripts/reload.sh"
if env HOME="$tmp/home" GITHUB_OUTPUT="$tmp/out" RUNNER_NAME=r1 MEDIA_SPM_RETRY_SECONDS=0 \
  bash "$script" "$tmp/bad" t "$tmp/bad/log" app >/dev/null 2>&1; then fail "a compile failure passed"; fi
[ "$(cat "$tmp/bad/tries")" = 1 ] || fail "a compile failure was retried"

# Resolution that keeps failing gives up after MEDIA_SPM_TRIES.
make_source "$tmp/down" ready
cat > "$tmp/down/scripts/reload.sh" <<'STUB'
#!/usr/bin/env bash
n=$(( $(cat "$PWD/tries" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$PWD/tries"
echo "xcodebuild: error: Could not resolve package dependencies:"; exit 74
STUB
chmod +x "$tmp/down/scripts/reload.sh"
if env HOME="$tmp/home" GITHUB_OUTPUT="$tmp/out" RUNNER_NAME=r1 MEDIA_SPM_RETRY_SECONDS=0 \
  bash "$script" "$tmp/down" t "$tmp/down/log" app >/dev/null 2>&1; then fail "endless resolution failure passed"; fi
[ "$(cat "$tmp/down/tries")" = 3 ] || fail "gave up after $(cat "$tmp/down/tries") tries, not 3"

echo "media-build-app-local-tui: ok"
