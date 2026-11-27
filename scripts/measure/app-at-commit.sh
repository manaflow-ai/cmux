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
# .build/DerivedData/cmux-measure-at, which a fleet worker keeps between steps, so a second commit near the first
# builds incrementally. Returns non-zero when the commit cannot be fetched or its build prints no app.

#   measure_remove_scratch DIR
# removes a measure script's scratch folder DIR in its EXIT trap (`trap 'measure_remove_scratch "$out"' EXIT`). A build
# at a commit leaves Go's module cache under DIR, which Go writes read-only: a plain rm -rf failed on it, and as the
# trap's last command its status became the step's (every --build-at bench ended exit 1, 2026-11-18). Never changes the
# status of a step whose body failed.

# A progress line while a build runs. The controller stops a measurement that prints nothing for 45 minutes
# (CMUX_CI_MEASURE_SILENT_MAX), and callers send this function's stderr to a file (relaunch-restore.sh's
# 2>"$out/reload-base.log"), so the cold Release builds of a base=SHA head=SHA pair printed nothing past that limit
# and the step was stopped as hung before its first round (cmux#58024's bench, 2026-11-26). Sourcing saves the
# step's own stdout as fd 9; measure_app_at_commit writes "still building" there every MEASURE_BUILD_PROGRESS_S
# seconds (300 by default), whatever its caller redirected.
exec 9>&1

measure_remove_scratch() {
  chmod -R u+w "$1" 2>/dev/null || true
  rm -rf -- "$1"
}

measure_app_at_commit() {
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
  # git worktree add copies a sparse checkout's patterns into the new worktree, so a sparse harness checkout (an agent's
  # wt checkout) built a partial tree: no webviews/, and the build failed at its web bundles (air-blue, 2026-11-21).
  if [[ "$(git -C "$tree" config --bool core.sparseCheckout 2>/dev/null)" == true ]]; then
    git -C "$tree" sparse-checkout disable >&2 || return 1
  fi
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
  mkdir -p "$root/.build/DerivedData"
  : >"$tree.reload.log"
  # The progress loop's stdout and stderr are /dev/null and its sleep closes fd 9, so a sleep it leaves behind holds
  # no pipe: a caller that sourced this file inside a $(...) (fd 9 is then that pipe) would otherwise wait for it.
  local every="${MEASURE_BUILD_PROGRESS_S:-300}" started progress
  started="$(date +%s)"
  (
    while sleep "$every" 9>&-; do
      echo "app-at-commit: still building $tag at ${full:0:12}, $(( $(date +%s) - started ))s: $(tail -n 1 "$tree.reload.log" 2>/dev/null | cut -c1-120)" >&9
    done
  ) >/dev/null 2>&1 &
  progress=$!
  (cd "$tree" && CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" \
    --derived-data "$root/.build/DerivedData/cmux-measure-at" "$@") 2>&1 | tee "$tree.reload.log" >&2 || status=$?
  kill "$progress" 2>/dev/null || true
  wait "$progress" 2>/dev/null || true
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
