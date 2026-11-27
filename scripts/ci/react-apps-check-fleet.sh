#!/usr/bin/env bash
# shellcheck disable=SC2317 # the lane bodies below run through lane()
# react-apps-check on the fleet: the ci/steps.toml step `react-apps-check` (pr-pipeline.yml's web-browser job) for a
# feat-cmux-next pull request whose shard pick runs only touched tests (scripts/ci/react_apps_fleet.py says which;
# ci-web.yml's react-apps-check-shard matrix asks the same function and skips itself for those heads).
#
#   bash scripts/ci/react-apps-check-fleet.sh        from the merge commit's checkout (HEAD^1 is the base tip)
#
# What ci-web.yml's shard 1 and react-apps-base-check do across 2 to 3 runners, on one: the source checks, the web
# bundles, the PR-scoped webview rules (against the base, beside the build: they read no bundle), the bundle merge
# driver and post-edit hook, Oxlint/Oxfmt/source rules, then the touched tests, whose reds that the base has too are
# replayed on a base worktree and judged by guards_new_reds.py (webviews-tests-new-reds.sh), so no base job runs.
# Leo, 2026-11-25: "github actions is just there at the start and end or whatever maybe i guess, but we own the
# in-between. all of it". Off: the repository variable CI_REACT_APPS_FLEET=0 (ci-web.yml runs every head again).
set -euo pipefail

root="$(git rev-parse --show-toplevel)"
cd "$root"
out="${RUNNER_TEMP:-$root/.ci-tmp}/react-apps-check"
rm -rf "$out"
mkdir -p "$out/logs"
fleet=scripts/ci/react_apps_fleet.py

# The rules that need no pick first: an audit head, full-ci, the switch, another event or base run on Actions.
if [ "$(python3 "$fleet" decide --before-pick)" != fleet ]; then
  echo "react-apps-check: ci-web.yml's shards run this head; nothing to do here"
  exit 0
fi

(cd webviews && flock "${CI_TOOLS:-$out}/bun-install.lock" bun install --frozen-lockfile)

# The same pick ci-web.yml's web-subarea-scope makes (its environment comes from pr-pipeline.yml). The duration
# manifest moves only which shard a touched test is in, never the class or which shards get a touched-test list.
printf '{}\n' > "$out/manifest.json"
export CI_WEBVIEWS_PR_BASE="${CI_PR_BASE_REF:-}" CMUX_WEB_TEST_DURATIONS="$out/manifest.json"
if ! picked="$(CMUX_WEB_TEST_JOBS=8 CMUX_WEB_TEST_DEV_JOBS=4 CMUX_WEB_TEST_SHARD_HEAD_START=1:120 \
  bash scripts/ci/timeout.sh 150 python3 scripts/ci/webviews_pr_shards.py --base HEAD^1 --head HEAD --count 8 \
  --direct-out "$out/direct.json" --summary "$out/pick.md" --class-out "$out/class")"; then
  echo "::error title=react-apps-check::the shard pick failed here, so this head ran no react-apps-check; re-run the job, or add the full-ci label"
  exit 1
fi
class="$(cat "$out/class" 2> /dev/null || true)"
if [ "$(python3 "$fleet" decide --class "$class" --matrix "$picked" --direct "$out/direct.json")" != fleet ]; then
  echo "react-apps-check: the pick runs whole shards, which ci-web.yml's matrix runs; nothing to do here"
  exit 0
fi
python3 "$fleet" tests --direct "$out/direct.json" > "$out/tests"
git diff --name-only --no-renames HEAD^1 HEAD > "$out/changed"
echo "react-apps-check on the fleet: class $class, $(grep -c . "$out/tests" || true) touched tests"

# One lane's log and status: lane NAME CMD..., in the background; a lane's body chains its commands with &&.
lane() {
  local name="$1"
  shift
  {
    local status=0
    "$@" > "$out/logs/$name.log" 2>&1 || status=$?
    echo "$status" > "$out/logs/$name.status"
  } &
}
ok() { [ "$(cat "$out/logs/$1.status" 2> /dev/null)" = 0 ]; }

build() { ./scripts/build-webviews-app.sh --check --skip-typecheck && ./scripts/cmux-next/build-web-bundles.sh --force; }
engines() {
  local try
  # Another web-browser step's Chrome install can hold apt's lock: one more try a little later.
  for try in 1 2; do
    (cd webviews && ./node_modules/.bin/playwright install --with-deps webkit) &&
      ./scripts/ci/ensure-system-chrome.sh && ./scripts/ci/pin-browser-test-font.sh && return 0
    [ "$try" = 2 ] || sleep 30
  done
  return 1
}
hooks() {
  if ! grep -qE '^(scripts/|tests/|\.gitattributes|\.claude/|\.codex/|\.github/workflows/ci-web\.yml|webviews/[^/]+$)' "$out/changed"; then
    echo "no input of the merge driver or post-edit hook checks changed: skipped"
    return 0
  fi
  python3 tests/test_install_git_hooks.py && python3 tests/test_format_post_edit.py
}
pr_scoped() {
  local check=scripts/tests/test_pr_scoped_webviews_checks.py base="$out/pr-scoped-base"
  python3 scripts/ci/unittest_results.py "$check" "$out/pr-scoped-head.json" && return 0
  git worktree add --detach "$base" HEAD^1 &&
    ln -s "$root/webviews/node_modules" "$base/webviews/node_modules" || return 1
  if [ -f "$base/$check" ]; then
    python3 scripts/ci/unittest_results.py "$base/$check" "$out/pr-scoped-base.json" || true
  fi
  git worktree remove --force "$base" > /dev/null 2>&1 || true
  python3 scripts/ci/guards_new_reds.py --label "PR-scoped webview rule" "$out/pr-scoped-head.json" "$out/pr-scoped-base.json"
}
source_rules() {
  (cd webviews && CMUX_NEXT_STYLE_GUARDS=warn python3 ../scripts/ci/fast_gate_webviews_checks.py --no-install --repo .. \
    --base HEAD^1 --skip typecheck)
}
# Warn-only on feat-cmux-next, as on ci-web.yml's shard 1 (its Fail on the gate checks step).
style() {
  node ./scripts/check-webviews-diff-budget.mjs || echo "::warning title=diff viewer eager JS budget::see the log"
  ./scripts/check-webviews-react-compiler.mjs || echo "::warning title=React Compiler::see the log"
}
tests() {
  if [ "$class" = fast ] || [ ! -s "$out/tests" ]; then
    echo "no touched test: the checks were this head's run (webviews_pr_shards.py --direct-out)"
    return 0
  fi
  (cd webviews && env -u CMUX_WEB_TEST_SHARD_HEAD_START CMUX_WEB_TEST_FILES="$(cat "$out/tests")" \
    CMUX_WEB_TEST_SHARD=1 CMUX_WEB_TEST_SHARD_COUNT=1 CMUX_WEB_TEST_SKIP_BASE=0 \
    CMUX_WEB_TEST_RESULTS="$out/head-results.json" CMUX_WEB_TEST_RAW_LOG_DIR="$out/raw-logs" \
    CMUX_PR_CHANGED_FILES="$out/changed" CMUX_NEXT_STYLE_GUARDS=warn BASE_REF=HEAD^1 \
    CMUX_WEB_TEST_JOBS=8 CMUX_WEB_TEST_DEV_JOBS=4 CMUX_WEB_TEST_SIZED_FOR_VCPU=16 \
    CMUX_WEB_TEST_RETRY_POOL=3 CMUX_WEB_TEST_RETRY_BREAKER=5 \
    CMUX_WEB_TEST_RETRY_DEADLINE=900 CMUX_WEB_TEST_RETRY_BUDGET=900 \
    ../scripts/ci/webviews-tests-new-reds.sh HEAD^1)
}

lane build build
build_pid=$!
lane engines engines
engines_pid=$!
lane pr-scoped-rules pr_scoped
lane hooks hooks
wait "$build_pid" || true
if ok build; then
  lane source-rules source_rules
  lane style style
  wait "$engines_pid" || true
  if ok engines; then lane tests tests; fi
fi
wait

status=0
for name in build engines pr-scoped-rules hooks source-rules style tests; do
  if [ ! -f "$out/logs/$name.status" ]; then
    echo "== $name: not run (the build or the engines failed)"
    status=1
    continue
  fi
  echo "::group::$name (exit $(cat "$out/logs/$name.status"))"
  cat "$out/logs/$name.log"
  echo "::endgroup::"
  ok "$name" || { echo "::error title=react-apps-check $name::failed; see its group above"; status=1; }
done
exit "$status"
