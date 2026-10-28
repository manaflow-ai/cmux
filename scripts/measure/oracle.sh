#!/usr/bin/env bash
# Fleet entry for one shard of the oracle's app run (plans/cmux-next/chrome-parity/p15-oracle.md, task 050): builds a
# tagged cmux-next app at this checkout in the bench configuration (reload.sh --config bench: Release optimization
# with the debug.* control commands kept), then runs `fleet.py step`, which runs `oracle.py run --product app` for
# the shard against that app and packs its run directory into the step's artifact.
# Submitted by scripts/cmux-next/oracle/fleet.py, one step per shard (never by hand, never through maclease):
#   cmux-ci run --class exclusive --label measure --no-supersede --script scripts/measure/oracle.sh --ref <sha> \
#     --key oracle-<run>-<side>-s<i>of<N> --artifact artifacts/oracle/<key>.tar.gz \
#     --arg=--shard=<i>/<N> --arg=--artifact=artifacts/oracle/<key>.tar.gz [--arg=--suite=S] [--arg=--config=bench]
# The controller runs a scripts/measure/ script only as class exclusive (alone on a worker with a console), which a
# GUI app launch needs; it refuses this script until hq lists it (cmuxterm-hq build-fleet/cmd/controller/ci_step.go
# measureScripts) and the worker runs only the version on main or feat-cmux-next (cmd/worker/step_reviewed.go).
#
# Options this script reads (the rest go to fleet.py step and from there to oracle.py run):
#   --shard=I/N       the shard (required)
#   --artifact=PATH   the step's --artifact, a relative artifacts/oracle/<name>.tar.gz (required)
#   --config=C        bench (default) or debug: reload.sh --config and oracle.py --build
#   --dry-run         plan the shard and write its receipt; build and launch nothing
#   --mutant=PATH     a seeded fault, tests/oracle/mutants/app/<name>.patch of this checkout:
#                     applied to the checkout before the build and reverted on exit; a dry run only checks it applies
# The checkout is the worker's reused one, so a build runs only on clean product sources (no tracked change under
# Packages or cmux-tui), and fleet-step.json records the sha256 of what was built over HEAD ("none" when clean).
# The files a mutant changes are journaled in the git dir before `git apply`. The exit trap restores them from
# HEAD and fails the step when it cannot; a step killed past its traps leaves the journal, and the next build in
# this checkout restores those files first (Chrome's bot_update likewise resets the checkout before it applies a
# patch: depot_tools recipes/recipe_modules/bot_update/resources/bot_update.py).
# On exit, TERM, INT or HUP (a cancelled step) the script ends the tag's app and daemons
# (scripts/cmux-next/tag_teardown.py, exact PIDs of the app bundle). It never touches /Applications/cmux.app.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
shard="" artifact="" config=bench dry_run=0 mutant="" args=()
for arg in "$@"; do
  case "$arg" in
    --shard=*) shard="${arg#--shard=}" ;;
    --artifact=*) artifact="${arg#--artifact=}" ;;
    --config=*) config="${arg#--config=}" ;;
    --dry-run) dry_run=1 ;;
    --mutant=*) mutant="${arg#--mutant=}" ;;
    *) args+=("$arg") ;;
  esac
done
if [[ -z "$shard" || -z "$artifact" ]]; then
  echo "oracle.sh: --shard=I/N and --artifact=PATH are required (fleet.py run passes them)" >&2
  exit 2
fi
case "$config" in
  bench | debug) ;;
  *) echo "oracle.sh: --config=$config: bench or debug" >&2; exit 2 ;;
esac
mutant_id=""
if [[ -n "$mutant" ]]; then
  if [[ "$mutant" != tests/oracle/mutants/app/*.patch || "$mutant" == *..* ]]; then
    echo "oracle.sh: --mutant=$mutant: a tests/oracle/mutants/app/<name>.patch of this checkout" >&2
    exit 2
  fi
  mutant_id="$(python3 -I scripts/cmux-next/oracle/patch_mutants.py validate "$mutant" --product app)" || exit 2
  if ! git apply --check "$mutant"; then
    echo "oracle.sh: $mutant does not apply at $(git rev-parse HEAD)" >&2
    exit 1
  fi
fi
tag="oracle"
sha="$(git rev-parse HEAD)"
work="$(mktemp -d "${TMPDIR:-/tmp}/oracle-step.XXXXXX")"
app=""
mutant_applied=0
guarded=(Packages cmux-tui)
journal="$(git rev-parse --git-path oracle-mutant-files)"
# Restores the journaled mutant files from HEAD and drops the journal; fails, keeping it, when one does not restore.
restore_mutant_files() {
  [[ -f "$journal" ]] || return 0
  local file failed=0
  while IFS= read -r file; do
    [[ -z "$file" ]] || git checkout -q HEAD -- "$file" || failed=1
  done <"$journal"
  [[ "$failed" == 0 ]] || return 1
  rm -f "$journal"
}
# shellcheck disable=SC2329 # run by the traps below
cleanup() {
  trap - EXIT TERM INT HUP
  if [[ -n "$app" ]]; then
    python3 scripts/cmux-next/tag_teardown.py "$app" || true
  fi
  if [[ "$mutant_applied" == 1 ]]; then
    if ! restore_mutant_files; then
      echo "oracle.sh: could not revert mutant $mutant_id; the checkout keeps it (journal $journal)" >&2
      return 1
    fi
    echo "oracle.sh: reverted mutant $mutant_id"
  fi
}
# shellcheck disable=SC2329 # run by the traps below
on_signal() {
  echo "oracle.sh: signal $1; ending the tag's app and daemons" >&2
  cleanup || true
  exit $((128 + $2))
}
trap 'cleanup || exit 1' EXIT
trap 'on_signal TERM 15' TERM
trap 'on_signal INT 2' INT
trap 'on_signal HUP 1' HUP

step=(python3 -I scripts/cmux-next/oracle/fleet.py step --ref "$sha" --tag "$tag" --config "$config"
  --shard "$shard" --artifact "$artifact" --work "$work")
if [[ -n "$mutant_id" ]]; then
  step+=(--mutant "$mutant_id")
fi
if [[ "$dry_run" == 1 ]]; then
  exec "${step[@]}" --dry-run ${args[@]+"${args[@]}"}
fi

if [[ -f "$journal" ]]; then
  if ! restore_mutant_files; then
    echo "oracle.sh: the files a killed mutant step left changed ($journal) do not restore from HEAD" >&2
    exit 1
  fi
  echo "oracle.sh: restored the files a killed mutant step left changed"
fi
dirty="$(git diff --name-only HEAD -- "${guarded[@]}")"
if [[ -n "$dirty" ]]; then
  echo "oracle.sh: refusing to build $sha: tracked product sources differ from HEAD:" >&2
  echo "$dirty" >&2
  exit 1
fi
if [[ -n "$mutant" ]]; then
  git apply --numstat "$mutant" | cut -f3 >"$journal"
  mutant_applied=1
  git apply "$mutant"
  echo "oracle.sh: applied mutant $mutant_id at $sha"
fi
source_diff="$(git diff HEAD -- "${guarded[@]}" | python3 -I -c '
import hashlib, sys
diff = sys.stdin.buffer.read()
print(hashlib.sha256(diff).hexdigest() if diff else "none")')"
step+=(--source-diff "$source_diff")
build_start=$SECONDS
# The checkout is reused: a submodule an earlier step initialized stays at that step's commit, so it is moved to
# this commit's gitlink whenever it differs (fleet.py refuses a build whose submodules are off their gitlinks).
for sub in ghostty ghostty-next; do
  if [ ! -e "$sub/.git" ] || [ "$(git -C "$sub" rev-parse HEAD)" != "$(git rev-parse "HEAD:$sub")" ]; then
    git submodule update --init --depth 1 "$sub"
  fi
done
if [ ! -f GhosttyKit.xcframework/Info.plist ]; then
  rm -rf GhosttyKit.xcframework
  if [ -z "${GHOSTTYKIT_ARCHIVE_CACHE_DIR:-}" ] && [ -n "${CI_SHARED_CACHE_DIR:-}" ]; then
    export GHOSTTYKIT_ARCHIVE_CACHE_DIR="$CI_SHARED_CACHE_DIR/ghosttykit-archives"
  fi
  ./scripts/download-prebuilt-ghosttykit.sh
fi
CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" --config "$config" 2>&1 | tee "$work/reload.log" | tail -n 40
built="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$work/reload.log" | tail -n 1)"
if [[ -z "$built" || ! -d "$built" ]]; then
  echo "oracle.sh: the tagged reload printed no app path" >&2
  grep -E "error:|BUILD FAILED" "$work/reload.log" | head -n 60 >&2 || true
  build_log="$(sed -n 's/^==> log: //p' "$work/reload.log" | tail -n 1)"
  if [[ -n "$build_log" && -f "$build_log" ]]; then
    grep -E "\.swift:[0-9]+:[0-9]+: error|error: |Stack dump|signal" "$build_log" | head -n 40 >&2 || true
  fi
  exit 1
fi
app="$built"
echo "oracle.sh: built $app at $sha ($config) in $((SECONDS - build_start)) s"
"${step[@]}" --app "$app" --build-seconds "$((SECONDS - build_start))" ${args[@]+"${args[@]}"}
