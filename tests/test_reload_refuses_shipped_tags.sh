#!/usr/bin/env bash
# Per-build isolation (cx-is1kf.4): a DEV tag that a shipped build owns
# (nightly, rc, staging, cmux-next) gets names of its build key, not the
# tag's, so `scripts/reload.sh --tag <owned>` wrote a CMUX_SOCKET_PATH and a
# marker that no app listens on. reload.sh must refuse such a tag before it
# cleans, builds or launches anything.
#
# The probe arguments (`--build-only --name "cmux DEV"`) make reload.sh stop
# at its next argument check, so a tag that passes the new check ends there
# with that other error and nothing is built.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cmux-reload-owned-tags.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

run_reload() {
  local tag="$1"
  set +e
  HOME="$TMP_DIR/home" bash "$ROOT_DIR/scripts/reload.sh" --tag "$tag" --build-only --name "cmux DEV" \
    >"$TMP_DIR/out" 2>"$TMP_DIR/err" </dev/null
  local status=$?
  set -e
  echo "$status"
}

for tag in nightly rc staging cmux-next Cmux.Next NIGHTLY; do
  status="$(run_reload "$tag")"
  [[ "$status" -ne 0 ]] || fail "reload.sh --tag $tag exited 0"
  grep -q "is the name of a shipped cmux build" "$TMP_DIR/err" \
    || fail "reload.sh --tag $tag did not refuse the owned tag: $(cat "$TMP_DIR/err")"
  echo "PASS: reload.sh refuses --tag $tag"
done

# An explicit DEV bundle id with an owned suffix is refused the same way.
set +e
HOME="$TMP_DIR/home" bash "$ROOT_DIR/scripts/reload.sh" --tag hq6dpbisoprobe --bundle-id com.cmuxterm.app.debug.cmux.next \
  --build-only --name "cmux DEV" >"$TMP_DIR/out" 2>"$TMP_DIR/err" </dev/null
status=$?
set -e
[[ "$status" -ne 0 ]] && grep -q "is the name of a shipped cmux build" "$TMP_DIR/err" \
  || fail "reload.sh kept --bundle-id com.cmuxterm.app.debug.cmux.next: $(cat "$TMP_DIR/err")"
echo "PASS: reload.sh refuses --bundle-id com.cmuxterm.app.debug.cmux.next"

for tag in hq6dpbisoprobe nightly2 cmux-next-x; do
  status="$(run_reload "$tag")"
  [[ "$status" -ne 0 ]] || fail "reload.sh --tag $tag probe exited 0"
  grep -q "is the name of a shipped cmux build" "$TMP_DIR/err" \
    && fail "reload.sh refused the DEV tag $tag"
  grep -q -- "--build-only cannot use --name" "$TMP_DIR/err" \
    || fail "reload.sh --tag $tag did not reach the next check: $(cat "$TMP_DIR/err")"
  echo "PASS: reload.sh keeps the DEV tag $tag"
done
