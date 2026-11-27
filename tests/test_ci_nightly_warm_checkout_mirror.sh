#!/usr/bin/env bash
# The warm nightly-next builder's checkout (nightly.yml, "Checkout build ref (warm nightly-next
# builder)") takes a commit the fleet mirror holds from the mirror, never from github.com.
# Run 45744507889 (11-26 03:09Z) borrowed the mirror and still fetched from origin: 429 x4, then 403.
# The step's own script is extracted from the workflow and run against a fake mirror and an origin
# that refuses every request.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

python3 - "$ROOT/.github/workflows/nightly.yml" "$TMP/step.sh" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
for job in wf["jobs"].values():
    for step in job.get("steps", []):
        if step.get("name") == "Checkout build ref (warm nightly-next builder)":
            open(sys.argv[2], "w").write(step["run"])
            sys.exit(0)
sys.exit("warm builder checkout step not found")
PY

git_q() { git -c user.email=t@t -c user.name=t -c commit.gpgsign=false "$@"; }
git init -q "$TMP/src"
echo one > "$TMP/src/a"; git_q -C "$TMP/src" add a; git_q -C "$TMP/src" commit -qm one
echo two > "$TMP/src/a"; git_q -C "$TMP/src" commit -qam two
SHA="$(git -C "$TMP/src" rev-parse HEAD)"
mkdir -p "$TMP/git"
git clone -q --bare "$TMP/src" "$TMP/git/cmux.git"
touch "$TMP/git/cmux.git/glaeda-verified"

# A curl that fails (no raw.githubusercontent.com download of git_fetch_retry.py).
mkdir -p "$TMP/bin"
printf '#!/bin/sh\nexit 22\n' > "$TMP/bin/curl"; chmod +x "$TMP/bin/curl"

run_step() {
  local ws="$1" sha="$2"
  mkdir -p "$ws" "$TMP/runner"
  ( cd "$ws" && PATH="$TMP/bin:$PATH" GITHUB_WORKSPACE="$ws" RUNNER_TEMP="$TMP/runner" \
      BUILD_SHA="$sha" REPO_URL="file://$TMP/refuses-like-a-403" WORKFLOW_SHA="$sha" \
      GITHUB_REPOSITORY=none/none GITHUB_SERVER_URL=https://github.com GLAEDA_GIT_MIRROR_DIR="$TMP/git" FETCH_TOKEN=test-token \
      CHECKOUT_MIRROR_WAIT_SECONDS=1 CHECKOUT_FETCH_BACKOFF_SECONDS=0 GLAEDA_GIT_MIRROR_TOOL="$TMP/no-mirror-tool" \
      bash -e "$TMP/step.sh" ) >"$TMP/out" 2>&1
}

# 1. Cold slot, commit in the mirror, origin refuses: checks out from the mirror.
if ! run_step "$TMP/ws1" "$SHA"; then cat "$TMP/out"; echo "FAIL: cold slot did not check out from the mirror"; exit 1; fi
[ "$(git -C "$TMP/ws1" rev-parse HEAD)" = "$SHA" ] || { echo "FAIL: wrong HEAD"; exit 1; }
[ "$(cat "$TMP/ws1/a")" = two ] || { echo "FAIL: wrong tree"; exit 1; }
grep -q "is in the fleet mirror" "$TMP/out" || { cat "$TMP/out"; echo "FAIL: did not say it used the mirror"; exit 1; }

# 2. Commit the mirror lacks: still asks origin (and fails here, since origin refuses).
echo three > "$TMP/src/a"; git_q -C "$TMP/src" commit -qam three
NEW="$(git -C "$TMP/src" rev-parse HEAD)"
if run_step "$TMP/ws2" "$NEW"; then echo "FAIL: a commit missing from the mirror skipped origin"; exit 1; fi
grep -q "is in the fleet mirror" "$TMP/out" && { echo "FAIL: claimed the mirror held a missing commit"; exit 1; }

echo "PASS: warm nightly checkout takes mirror commits from the mirror and fetches only what it lacks"
