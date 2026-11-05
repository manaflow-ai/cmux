#!/usr/bin/env bash
# Tests scripts/ci/ios-sim-fetch-commit.sh with real git repositories (no network):
# a checkout with no origin takes a commit from the mirror, from the host reference
# or from the remote URL, keeps one it has, and names every source when none has it.
# Run: bash scripts/ci/tests/ios-sim-fetch-commit.test.sh
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fetch="$here/../ios-sim-fetch-commit.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

fail() { echo "FAIL: $*" >&2; exit 1; }

# upstream: main, plus a commit only on a side branch (as a base graft is).
git init -q -b main "$tmp/up"
git -C "$tmp/up" commit -q --allow-empty -m one
git -C "$tmp/up" checkout -q -b side
git -C "$tmp/up" commit -q --allow-empty -m graft
graft="$(git -C "$tmp/up" rev-parse HEAD)"
# Not a branch tip: a mirror serves it only through protocol v2.
git -C "$tmp/up" commit -q --allow-empty -m after-graft
git -C "$tmp/up" checkout -q main
git -C "$tmp/up" commit -q --allow-empty -m two
head="$(git -C "$tmp/up" rev-parse HEAD)"
git clone -q --bare "$tmp/up" "$tmp/fleet/cmux.git"

# A step checkout: its own repository, no remote, holding the head only.
step() {
  rm -rf "$tmp/step"
  git init -q "$tmp/step"
  git -C "$tmp/step" fetch -q --no-tags "$tmp/up" "$head"
  git -C "$tmp/step" checkout -q --detach "$head"
  git -C "$tmp/step" cat-file -e "$graft^{commit}" 2>/dev/null && fail "fixture already has the graft"
  true
}
none="$tmp/no-mirror"
unreachable="$tmp/no-remote.git"

# 1. From glaeda's mirror, with no origin and no reachable remote.
step
out="$(cd "$tmp/step" && CMUX_CI_STEP_GLAEDA_MIRROR_DIR="$tmp/fleet" CMUX_IOS_SIM_COMMIT_REMOTE="$unreachable" "$fetch" "$graft")"
[[ "$out" == "commit $graft: fetched from $tmp/fleet/cmux.git" ]] || fail "mirror: $out"
git -C "$tmp/step" cat-file -e "$graft^{commit}" || fail "mirror: graft not readable"

# 2. From the host reference when there is no mirror.
step
out="$(cd "$tmp/step" && CMUX_CI_STEP_GLAEDA_MIRROR_DIR="$none" CMUX_CI_STEP_REFERENCE="$tmp/fleet/cmux.git" CMUX_IOS_SIM_COMMIT_REMOTE="$unreachable" "$fetch" "$graft")"
[[ "$out" == "commit $graft: fetched from $tmp/fleet/cmux.git" ]] || fail "reference: $out"

# 3. From the remote URL when neither is there.
step
out="$(cd "$tmp/step" && CMUX_CI_STEP_GLAEDA_MIRROR_DIR="$none" CMUX_IOS_SIM_COMMIT_REMOTE="$tmp/up" "$fetch" "$graft")"
[[ "$out" == "commit $graft: fetched from $tmp/up" ]] || fail "remote: $out"

# 4. A commit already readable needs no source.
out="$(cd "$tmp/step" && CMUX_CI_STEP_GLAEDA_MIRROR_DIR="$none" CMUX_IOS_SIM_COMMIT_REMOTE="$unreachable" "$fetch" "$graft")"
[[ "$out" == "commit $graft: already in the checkout" ]] || fail "present: $out"

# 5. A commit no source has: exit 1, naming every source tried.
step
missing="$(printf 'f%.0s' {1..40})"
set +e
err="$(cd "$tmp/step" && CMUX_CI_STEP_GLAEDA_MIRROR_DIR="$tmp/fleet" CMUX_IOS_SIM_COMMIT_REMOTE="$tmp/up" "$fetch" "$missing" 2>&1 >/dev/null)"
status=$?
set -e
[[ $status -eq 1 ]] || fail "missing: exit $status"
[[ "$err" == "error: commit $missing is in none of: $tmp/fleet/cmux.git $tmp/up" ]] || fail "missing: $err"

# 6. Not a SHA: exit 2 before any fetch.
set +e
(cd "$tmp/step" && "$fetch" main >/dev/null 2>&1)
status=$?
set -e
[[ $status -eq 2 ]] || fail "bad sha: exit $status"

echo "ios-sim-fetch-commit: 6 cases passed"
