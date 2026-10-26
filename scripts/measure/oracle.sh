#!/usr/bin/env bash
# Fleet step of the oracle's app diffs (plans/cmux-next/chrome-parity/p15-oracle.md, tasks 050 and 008): one shard,
# both sides on this one host. scripts/cmux-next/oracle/fleet.py submits it, one step per shard:
#   cmux-ci run --class isolated --script scripts/measure/oracle.sh --ref HEAD_SHA --key KEY --no-supersede \
#     --artifact artifacts/oracle/shard.tgz --arg=pair --arg=--base=BASE_SHA --arg=--shard=I/N [--arg=--suite=S ...]
#
#   oracle.sh pair (--base=SHA | --switch=NAME | --arm=launch-config) --shard=I/N [--build=bench|debug]
#                  [--suite=S]... [--filter=GLOB]... [--repeat=N] [--retry-limit=N] [--batch-limit=K] [--seed=N]
#
# Same-host pairing (task 008): it builds side A's app and side B's app here (the base commit and this checkout's
# commit; or this checkout once, for a switch's two arms or launch-config against the defaults), then runs shard I/N
# of side A and then the same shard of side B, back to back, so every case's two runs come from one host, OS version
# and display; each receipt records them (oracle.py host_info) and diff.py refuses a pair that does not match. Both
# apps carry one tag (`oracle`), so the bundle id, socket and state paths are equal and only the code differs; the
# two never run at once. Apps are built with reload.sh in the bench configuration (--build=debug: the debug one) and
# kept per commit in $CI_SHARED_CACHE_DIR/oracle-apps (the 4 newest), so the shards of one diff that land on one
# worker build once. The runs go outside the checkout (oracle.py refuses an --out inside it); the step's artifact is
# their tarball, artifacts/oracle/shard.tgz: a/ and b/ (run directories) and pair.json (the builds and run exits).
# A case failure is a result, not a step failure: the step exits 0 whenever both receipts exist.
# On exit, TERM, INT or HUP it ends the tag's app and daemons (scripts/cmux-next/tag_teardown.py, by bundle path)
# and removes the base worktree.
set -euo pipefail
if [[ -z "${CMUX_CI_STEP_KEY:-}" && -z "${CMUX_CI_JOB_VOLUME:-}" ]]; then
  echo "oracle.sh builds and drives the app and runs only on the fleet (fleet.py submits it with cmux-ci run)" >&2
  exit 2
fi
if [[ "$(uname -s)" != Darwin ]]; then
  echo "oracle.sh: the app product runs on macOS minis" >&2
  exit 2
fi
cd "$(git rev-parse --show-toplevel)"
usage() { echo "usage: oracle.sh pair (--base=SHA | --switch=NAME | --arm=launch-config) --shard=I/N [run options]" >&2; exit 2; }
[[ "${1:-}" == pair ]] || usage
shift
base="" switch="" launch_config=0 shard="" build=bench run_args=()
for arg in "$@"; do
  case "$arg" in
    --base=*) base="${arg#--base=}" ;;
    --switch=*) switch="${arg#--switch=}" ;;
    --arm=launch-config) launch_config=1 ;;
    --shard=*) shard="${arg#--shard=}" ;;
    --build=*) build="${arg#--build=}" ;;
    --suite=*|--filter=*|--repeat=*|--retry-limit=*|--batch-limit=*|--seed=*) run_args+=("$arg") ;;
    *) echo "oracle.sh: unknown argument $arg" >&2; usage ;;
  esac
done
sides=0
[[ -n "$base" ]] && sides=$((sides + 1))
[[ -n "$switch" ]] && sides=$((sides + 1))
[[ "$launch_config" == 1 ]] && sides=$((sides + 1))
[[ "$sides" == 1 ]] || { echo "oracle.sh: exactly one of --base, --switch, --arm=launch-config" >&2; usage; }
[[ "$shard" =~ ^[0-9]+/[1-9][0-9]*$ ]] || { echo "oracle.sh: --shard=I/N is required" >&2; usage; }
[[ -z "$base" || "$base" =~ ^[0-9a-f]{40}$ ]] || { echo "oracle.sh: --base must be a 40-character commit" >&2; exit 2; }
case "$build" in
  bench|debug) ;;
  *) echo "oracle.sh: --build=$build: the app builds as bench or debug" >&2; exit 2 ;;
esac

tag=oracle
head="$(git rev-parse HEAD)"
work="$(mktemp -d "${TMPDIR:-/tmp}/oracle-step.XXXXXX")"
artifact="$(pwd)/artifacts/oracle/shard.tgz"
mkdir -p "$work/runs" "$work/apps" "$(dirname "$artifact")"
rm -f "$artifact"
run_id="$(date -u +%Y%m%dT%H%M%SZ)-${shard%/*}of${shard#*/}"
cache=""
[[ -n "${CI_SHARED_CACHE_DIR:-}" ]] && cache="$CI_SHARED_CACHE_DIR/oracle-apps"
worktree="" running_app=""

# shellcheck disable=SC2329 # run by the traps below
cleanup() {
  trap - EXIT TERM INT HUP
  if [[ -n "$running_app" ]]; then
    python3 scripts/cmux-next/tag_teardown.py "$running_app" || true
  fi
  if [[ -n "$worktree" ]]; then
    git worktree remove --force "$worktree" 2>/dev/null || true
    git worktree prune || true
  fi
  rm -rf "$work"
}
# shellcheck disable=SC2329 # run by the traps below
on_signal() {
  echo "oracle.sh: signal $1; ending the tag's app and daemons" >&2
  cleanup
  exit $((128 + $2))
}
trap cleanup EXIT
trap 'on_signal TERM 15' TERM
trap 'on_signal INT 2' INT
trap 'on_signal HUP 1' HUP

# build_app SRC SHA DEST: the tagged app of SHA (checked out at SRC) at DEST, from the worker's cache or built.
# Prints "<seconds> <cached>".
build_app() {
  local src="$1" sha="$2" dest="$3" key="$2-$build" log="$work/build-$2.log" started=$SECONDS app=""
  if [[ -n "$cache" && -f "$cache/$key/ok" ]]; then
    ditto "$cache/$key/cmux DEV $tag.app" "$dest"
    touch "$cache/$key/ok"
    echo "$((SECONDS - started)) true"
    return 0
  fi
  if ! (
    cd "$src"
    for sub in ghostty ghostty-next; do
      [ -e "$sub/.git" ] || git submodule update --init --depth 1 "$sub"
    done
    if [ ! -f GhosttyKit.xcframework/Info.plist ]; then
      rm -rf GhosttyKit.xcframework
      if [ -z "${GHOSTTYKIT_ARCHIVE_CACHE_DIR:-}" ] && [ -n "${CI_SHARED_CACHE_DIR:-}" ]; then
        export GHOSTTYKIT_ARCHIVE_CACHE_DIR="$CI_SHARED_CACHE_DIR/ghosttykit-archives"
      fi
      ./scripts/download-prebuilt-ghosttykit.sh
    fi
    CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" --config "$build"
  ) > "$log" 2>&1; then
    echo "oracle.sh: the $build build of $sha failed" >&2
    grep -E "error:|BUILD FAILED" "$log" | head -n 60 >&2 || tail -n 40 "$log" >&2
    return 1
  fi
  app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$log" | tail -n 1)"
  if [[ -z "$app" || ! -d "$app" ]]; then
    echo "oracle.sh: the tagged reload of $sha printed no app path" >&2
    tail -n 40 "$log" >&2
    return 1
  fi
  ditto "$app" "$dest"
  if [[ -n "$cache" ]]; then
    mkdir -p "$cache"
    rm -rf "${cache:?}/$key.tmp"
    mkdir -p "$cache/$key.tmp"
    if ditto "$app" "$cache/$key.tmp/cmux DEV $tag.app"; then
      rm -rf "${cache:?}/$key"
      mv "$cache/$key.tmp" "$cache/$key"
      touch "$cache/$key/ok"
    fi
    # shellcheck disable=SC2012 # the directory names are <40-hex commit>-<config>
    ls -1t "$cache"/*/ok 2>/dev/null | tail -n +5 | while read -r ok; do rm -rf "$(dirname "$ok")"; done
  fi
  echo "$((SECONDS - started)) false"
}

# run_side LABEL APP SHA [oracle.py run options]: shard $shard of one side into $work/runs/LABEL; sets side_exit to
# oracle.py's exit. Called directly (no subshell), so the traps see running_app.
side_exit=""
run_side() {
  local label="$1" app="$2" sha="$3" code=0
  shift 3
  running_app="$app"
  echo "oracle.sh: side $label ($sha) shard $shard on $(hostname -s)" >&2
  python3 -I scripts/cmux-next/oracle/oracle.py run --product app --platform mac --binary "$app" --build "$build" \
    --shard "$shard" --ref "$sha" --run-id "$run_id-$label" --out "$work/runs/$label" \
    ${run_args[@]+"${run_args[@]}"} "$@" >&2 || code=$?
  python3 scripts/cmux-next/tag_teardown.py "$app" >&2 || true
  running_app=""
  if [[ ! -f "$work/runs/$label/receipt.json" ]]; then
    echo "oracle.sh: side $label wrote no receipt (oracle.py exit $code)" >&2
    return 1
  fi
  side_exit="$code"
}

app_b="$work/apps/b/cmux DEV $tag.app"
mkdir -p "$work/apps/a" "$work/apps/b"
if [[ -n "$base" ]]; then
  git cat-file -e "$base^{commit}" 2>/dev/null || git fetch --no-tags --depth=1 origin "$base"
  worktree="$work/base"
  git worktree add --detach "$worktree" "$base" >&2
  app_a="$work/apps/a/cmux DEV $tag.app"
  read -r build_a cached_a < <(build_app "$worktree" "$base" "$app_a")
  read -r build_b cached_b < <(build_app "$(pwd)" "$head" "$app_b")
  sha_a="$base" sides_a=() sides_b=()
else
  read -r build_b cached_b < <(build_app "$(pwd)" "$head" "$app_b")
  app_a="$app_b" build_a="$build_b" cached_a="$cached_b" sha_a="$head"
  if [[ -n "$switch" ]]; then
    sides_a=(--switch "$switch" --arm old) sides_b=(--switch "$switch" --arm new)
  else
    sides_a=(--arm default) sides_b=(--arm launch-config)
  fi
fi
[[ -n "${build_a:-}" && -n "${build_b:-}" ]] || exit 1
run_side a "$app_a" "$sha_a" ${sides_a[@]+"${sides_a[@]}"}
exit_a="$side_exit"
run_side b "$app_b" "$head" ${sides_b[@]+"${sides_b[@]}"}
exit_b="$side_exit"
printf '{"schema": "cmux-oracle-pair-v1", "shard": "%s", "host": "%s",\n "a": {"sha": "%s", "buildSeconds": %s, "cached": %s, "runExit": %s},\n "b": {"sha": "%s", "buildSeconds": %s, "cached": %s, "runExit": %s}}\n' \
  "$shard" "$(hostname -s)" "$sha_a" "$build_a" "$cached_a" "$exit_a" "$head" "$build_b" "$cached_b" "$exit_b" \
  > "$work/runs/pair.json"
tar -C "$work/runs" -czf "$artifact" a b pair.json
cat "$work/runs/pair.json"
echo "oracle.sh: shard $shard: both sides ran on $(hostname -s); artifact artifacts/oracle/shard.tgz"
