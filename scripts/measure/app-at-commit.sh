#!/usr/bin/env bash
# Sourced by a measure script whose bench builds a tagged cmux-next app (chat-open.sh, cef-tab.sh): with
# --build-at=SHA the app is built at SHA, a pull request's head or a base, while the bench itself is this
# checkout's. The fleet controller runs an unlisted scripts/measure script only at a commit on feat-cmux-next or
# main, so before this a pull request's head could not be an arm of these benches (cmux#44487's first Chromium
# page, the CMUX-571 chat-open A/B, 2026-11-17). launch-ready.sh's head=SHA does the same for its DMG builds.
#
#   measure_app_at_commit SHA TAG DIR [reload.sh args...]
# checks SHA out whole into the scratch worktree DIR (under the caller's scratch folder, which its EXIT trap
# removes), runs that commit's own scripts/reload.sh --tag TAG there, and prints the app's path on stdout (the
# build's log goes to stderr and DIR.reload.log). The build's DerivedData is this checkout's
# .build/DerivedData/cmux-measure-at-<sha12> (arm-derived-data.sh): one DerivedData per commit, as two commits built
# in one tree meet a stale precompiled module. Returns non-zero when the commit cannot be fetched or its build prints no app.
# When it returns, built or failed, it caps those per-commit caches, as a warm checkout keeps its .build between steps
# (measure_prune_derived_data: the 3 most recently used and any a live run marked stay; DERIVED-DATA-PRUNE on stderr).
# A wrapper rather than a trap: callers own their EXIT traps, and every return path goes through it.
. "$(dirname "${BASH_SOURCE[0]}")/arm-derived-data.sh"

measure_app_at_commit() {
  local status=0
  _measure_app_at_commit_build "$@" || status=$?
  measure_prune_derived_data || true
  return "$status"
}

_measure_app_at_commit_build() {
  local sha="$1" tag="$2" tree="$3" root full status=0 app
  shift 3
  root="$(git rev-parse --show-toplevel)"
  # A depth only in a checkout that is already shallow (a fleet step's): never turn a full clone shallow.
  local depth=()
  [[ "$(git -C "$root" rev-parse --is-shallow-repository)" == true ]] && depth=(--depth=1)
  git -C "$root" cat-file -e "$sha^{commit}" 2>/dev/null \
    || git -C "$root" fetch -q --no-tags --no-recurse-submodules ${depth[@]+"${depth[@]}"} origin "$sha" \
    || git -C "$root" fetch -q --no-tags --no-recurse-submodules ${depth[@]+"${depth[@]}"} "${CMUX_MEASURE_FETCH_URL:-https://github.com/manaflow-ai/cmux.git}" "$sha" \
    || { echo "app-at-commit: cannot fetch $sha" >&2; return 1; }
  full="$(git -C "$root" rev-parse "$sha^{commit}")" || return 1
  # A worktree an earlier step left registered (its folder gone with that step's scratch folder) is dropped first.
  git -C "$root" worktree prune
  git -C "$root" worktree add -q --detach "$tree" "$full" || return 1
  echo "app-at-commit: building $full ($(git -C "$root" log -1 --format=%s "$full" | cut -c1-80))" >&2
  # As the callers do for their own checkout: a step has empty submodules, and the build needs Ghostty's headers,
  # the ghostty-next tree and GhosttyKit.xcframework (a prebuilt download).
  local sub
  for sub in ghostty ghostty-next; do
    grep -q "path = $sub\$" "$tree/.gitmodules" 2>/dev/null || continue
    git -C "$tree" submodule update --init --depth 1 "$sub" >&2 || return 1
  done
  if [[ ! -f "$tree/GhosttyKit.xcframework/Info.plist" && -x "$tree/scripts/download-prebuilt-ghosttykit.sh" ]]; then
    if [[ -z "${GHOSTTYKIT_ARCHIVE_CACHE_DIR:-}" && -n "${CI_SHARED_CACHE_DIR:-}" ]]; then
      export GHOSTTYKIT_ARCHIVE_CACHE_DIR="$CI_SHARED_CACHE_DIR/ghosttykit-archives"
    fi
    (cd "$tree" && ./scripts/download-prebuilt-ghosttykit.sh) >&2 || return 1
  fi
  local derived
  derived="$(measure_arm_derived_data "at-${full:0:12}")" || return 1
  measure_derived_data_in_use "$derived" || return 1
  mkdir -p "$root/.build/DerivedData"
  (cd "$tree" && CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" \
    --derived-data "$derived" "$@") 2>&1 | tee "$tree.reload.log" >&2 || status=$?
  [[ "$status" == 0 ]] || return "$status"
  app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$tree.reload.log" | tail -n 1)"
  if [[ -z "$app" || ! -d "$app" ]]; then
    echo "app-at-commit: the tagged reload at $full printed no app path" >&2
    grep -E "error:|BUILD FAILED" "$tree.reload.log" | head -n 60 >&2 || true
    return 1
  fi
  echo "app-at-commit: app of $full: $app" >&2
  printf '%s\n' "$app"
}
