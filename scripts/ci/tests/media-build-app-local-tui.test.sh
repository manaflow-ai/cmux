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
run "$tmp/standin" CMUX_TUI_TREE_KEY=0123456789abcdef0123456789abcdef01234567
[ ! -e "$tmp/standin/client-built" ] || fail "built cmux-tui despite a stand-in tree"

# An explicit binary wins.
make_source "$tmp/bin" none
run "$tmp/bin" CMUX_NEXT_TUI_BIN=/x/cmux-tui
[ ! -e "$tmp/bin/client-built" ] || fail "built cmux-tui despite CMUX_NEXT_TUI_BIN"

echo "media-build-app-local-tui: ok"
