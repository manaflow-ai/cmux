#!/usr/bin/env bash
# resolve-acpmux.sh: the cache first; a Cargo build only where build-acpmux.sh allows it; anywhere else the
# published acpmux of the checkout's tree (pin-cmux-tui.sh fetch-acpmux, looking once), and a clear failure when
# nothing has it. Regression: a fleet measurement Mac that never runs Cargo stopped every launch-ready.sh dmg=build
# run with "no cached acpmux for this checkout" although the tree's acpmux was published.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# A checkout whose build-acpmux.sh and pin-cmux-tui.sh are stubs driven by files in its state/ folder.
repo="$TMP/repo"; mkdir -p "$repo/scripts/cmux-next" "$repo/state"
cat > "$repo/scripts/cmux-next/build-acpmux.sh" <<'STUB'
#!/usr/bin/env bash
s="$(cd "$(dirname "$0")/../.." && pwd)/state"
[[ "$PWD" == "$(dirname "$s")" ]] || { echo "build-acpmux.sh ran outside its checkout" >&2; exit 9; }
case "${1:-}" in
  --cached-only) [[ -f "$s/cached" ]] && { cat "$s/cached"; exit 0; }
    [[ -f "$s/not-taken" ]] && echo "warning: not using the same-tree acpmux: it has architectures x86_64" >&2; exit 1 ;;
  --check-build-allowed) [[ -f "$s/allow" ]] ;;
  "") echo cargo >> "$s/log"; echo /cache/built/acpmux > "$s/cached"; echo "acpmux built" ;;
esac
STUB
cat > "$repo/scripts/cmux-next/pin-cmux-tui.sh" <<'STUB'
#!/usr/bin/env bash
s="$(cd "$(dirname "$0")/../.." && pwd)/state"
[[ "$1" == fetch-acpmux ]] || exit 2
echo "fetch wait=${CMUX_TUI_TREE_WAIT_SECONDS:-unset}" >> "$s/log"
[[ -f "$s/published" ]] || { echo "error: tree has no verified acpmux companion" >&2; exit 1; }
[[ -f "$s/not-taken" ]] || echo /cache/tree/acpmux > "$s/cached"
STUB
chmod +x "$repo/scripts/cmux-next/"*.sh
# The copy launch-ready.sh takes before a base checkout: it runs from outside the checkout, with --repo.
cp "$ROOT/scripts/cmux-next/resolve-acpmux.sh" "$TMP/resolve-acpmux.sh"
resolve() { (cd "$TMP" && "$TMP/resolve-acpmux.sh" --repo "$repo" 2>"$TMP/err") }
reset() { rm -f "$repo/state/"*; }

# Cached: that path, and neither Cargo nor a fetch.
reset; echo /cache/hit/acpmux > "$repo/state/cached"
[[ "$(resolve)" == /cache/hit/acpmux ]] || fail "cache hit: $(cat "$TMP/err")"
[[ ! -f "$repo/state/log" ]] || fail "cache hit ran: $(cat "$repo/state/log")"

# A build host's miss: Cargo, and the build's own output stays off stdout.
reset; touch "$repo/state/allow"
[[ "$(resolve)" == /cache/built/acpmux ]] || fail "build host: $(cat "$TMP/err")"
[[ "$(cat "$repo/state/log")" == cargo ]] || fail "build host log: $(cat "$repo/state/log")"

# The regression: a miss where Cargo never runs, the tree's acpmux published: fetched, looking once.
reset; touch "$repo/state/published"
[[ "$(resolve)" == /cache/tree/acpmux ]] || fail "published tree: $(cat "$TMP/err")"
[[ "$(cat "$repo/state/log")" == "fetch wait=0" ]] || fail "published tree log: $(cat "$repo/state/log")"

# The caller's wait wins over the default.
reset; touch "$repo/state/published"
out="$(cd "$TMP" && CMUX_TUI_TREE_WAIT_SECONDS=120 "$TMP/resolve-acpmux.sh" --repo "$repo" 2>/dev/null)"
[[ "$out" == /cache/tree/acpmux && "$(cat "$repo/state/log")" == "fetch wait=120" ]] || fail "caller wait: $(cat "$repo/state/log")"

# Nothing published, no Cargo: exit 1, the reason on stderr, nothing on stdout, never Cargo.
reset
if out="$(resolve)"; then fail "no acpmux anywhere resolved to '$out'"; fi
[[ -z "$out" ]] || fail "stdout on failure: $out"
grep -q "no published acpmux of its cmux-tui tree" "$TMP/err" || fail "failure reason: $(cat "$TMP/err")"
! grep -q cargo "$repo/state/log" || fail "ran Cargo where it is not allowed"

# Fetched, but build-acpmux.sh would not take it (air-blue, 2026-11-21): the error names that step and its reason,
# never "could not be fetched".
reset; touch "$repo/state/published" "$repo/state/not-taken"
if out="$(resolve)"; then fail "an untaken fetch resolved to '$out'"; fi
grep -q "was fetched, but build-acpmux.sh cannot use it" "$TMP/err" || fail "untaken fetch reason: $(cat "$TMP/err")"
grep -q "architectures x86_64" "$TMP/err" || fail "untaken fetch lost build-acpmux's reason: $(cat "$TMP/err")"
! grep -q "could not be fetched" "$TMP/err" || fail "untaken fetch blamed the fetch: $(cat "$TMP/err")"

echo "resolve-acpmux.test.sh: ok"
