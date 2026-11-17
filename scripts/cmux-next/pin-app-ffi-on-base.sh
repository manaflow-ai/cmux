#!/usr/bin/env bash
# Pins a just-published app FFI release straight on feat-cmux-next, the way the
# base autofix pins GhosttyKit, instead of through the app-ffi-repin pull request.
#
#   scripts/cmux-next/pin-app-ffi-on-base.sh <release source sha> <checksum>
#
# Why: the re-pin pull request ran the whole cmux-next CI (over an hour), and an
# FFI change landing meanwhile made its pin stale before it could land
# (2026-11-10: cmux#39863 re-pinned 011dae20, 3894ad7a, 1818fd17 and never
# landed), so base stayed red on "Check the app FFI pin" for every pull request.
# Here the pin lands within minutes of the release, on top of the tip.
#
# It pins only when all of these hold, and otherwise prints `result=` and leaves
# the pull request (scripts/cmux-next/publish-app-ffi-repin.sh) to the caller:
#  - the tip's FFI sources are the release's (content, not commit: an unrelated
#    commit on top changes nothing; a newer FFI change gives result=newer, and
#    the run of the push that made it pins its own release);
#  - the tip's C headers keep every declaration of the current pin's
#    (scripts/cmux-next/app_ffi_additive.py): a removed or changed declaration
#    can break the Swift build, so result=pr and the pull request's app compile
#    proves it first;
#  - scripts/cmux-next/check-app-ffi-pin.sh --verify-release passes on the
#    pinned tree (the sources match and the release carries the checksum).
# A tip that moves during the push is re-read and the pin re-applied, 5 times.
#
# Environment: TOKEN, a token that may push feat-cmux-next (the base autofix's
# manaflow-cmux-pr-autofix App: the branch requires a check this commit cannot
# have yet, and that App is the ruleset's bypass actor); ENABLED=true to push
# (otherwise result=dry-run); PIN_BASE_REMOTE (default this repository on
# GitHub); PIN_BASE_BRANCH (default feat-cmux-next). Writes result= to
# GITHUB_OUTPUT: pinned, already, newer, pr or dry-run.
set -euo pipefail

# One function, parsed whole before it runs: the checkouts below rewrite this
# file on disk while bash would still be reading it line by line.
main() {
sha="${1:-}"
checksum="${2:-}"
[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || { echo "error: the release source must be a 40-character sha, got '$sha'" >&2; exit 2; }
[[ "$checksum" =~ ^[0-9a-f]{64}$ ]] || { echo "error: the checksum must be 64 hex characters, got '$checksum'" >&2; exit 2; }
branch="${PIN_BASE_BRANCH:-feat-cmux-next}"
remote="${PIN_BASE_REMOTE:-https://github.com/${GITHUB_REPOSITORY:?GITHUB_REPOSITORY or PIN_BASE_REMOTE}.git}"
manifest=Packages/macOS/CmuxNext/Package.swift
pin_file=Packages/macOS/CmuxNext/app-ffi-pin.json
tag="cmux-app-ffi-$sha"

say() {
  echo "$*"
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then echo "$*" >> "$GITHUB_STEP_SUMMARY"; fi
}
finish() { # finish RESULT MESSAGE
  echo "result=$1" >> "${GITHUB_OUTPUT:-/dev/null}"
  say "app FFI pin on $branch: $1: $2"
  exit 0
}
# A push token replaces the checkout's own credentials (an empty extraheader
# resets the list), through the environment, never the command line.
push() {
  if [[ -z "${TOKEN:-}" ]]; then git push --quiet "$remote" "HEAD:refs/heads/$branch"; return; fi
  local auth
  auth="$(printf 'x-access-token:%s' "$TOKEN" | base64 | tr -d '\n')"
  [[ -n "${GITHUB_ACTIONS:-}" ]] && echo "::add-mask::$auth"
  GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0="http.https://github.com/.extraheader" GIT_CONFIG_VALUE_0="" \
    GIT_CONFIG_KEY_1="http.https://github.com/.extraheader" GIT_CONFIG_VALUE_1="AUTHORIZATION: basic $auth" \
    git push --quiet "$remote" "HEAD:refs/heads/$branch"
}
# The pin the tree holds, in either form, through the canonical reader.
current_pin() {
  if [[ -f "$pin_file" ]]; then
    python3 -I scripts/ci/app_ffi_pin.py read-pin-file "$pin_file" "$manifest"
  else
    python3 -I scripts/ci/app_ffi_pin.py read "$manifest"
  fi | awk '{print $1}'
}
have() { git cat-file -e "$1^{commit}" 2>/dev/null || git fetch --quiet "$remote" "$1"; }

have "$sha" || { echo "error: the release source $sha is not available from $remote" >&2; exit 1; }
for attempt in 1 2 3 4 5; do
  git fetch --quiet "$remote" "+refs/heads/$branch:refs/remotes/pin-base/$branch"
  git checkout --quiet --force --detach "refs/remotes/pin-base/$branch"
  tip="$(git rev-parse HEAD)"
  inputs=()
  while IFS= read -r path; do inputs+=("$path"); done < <(bash scripts/cmux-next/check-app-ffi-pin.sh --list-inputs)
  if ! git diff --quiet "$sha" "$tip" -- "${inputs[@]}"; then
    finish newer "the FFI sources at ${tip:0:12} are not those of $tag; the release of the push that changed them is pinned by its own run"
  fi
  if ! pinned="$(current_pin 2>&1)" || [[ ! "$pinned" =~ ^[0-9a-f]{40}$ ]]; then
    finish pr "the pin at ${tip:0:12} is not canonical (${pinned:-empty}); the re-pin pull request rewrites it"
  fi
  [[ "$pinned" == "$sha" ]] && finish already "${tip:0:12} already pins $tag"
  have "$pinned" || finish pr "the current pin's source $pinned is not available, so its headers cannot be compared"
  rc=0; additive="$(python3 -I scripts/cmux-next/app_ffi_additive.py "$pinned" "$sha" -- "${inputs[@]}" 2>&1)" || rc=$?
  echo "$additive"
  (( rc == 0 )) || finish pr "the headers are not additive over the current pin ${pinned:0:12}; the re-pin pull request's app compile proves them first"
  bash scripts/cmux-next/repin-app-ffi.sh "$sha" "$checksum"
  bash scripts/cmux-next/check-app-ffi-pin.sh --verify-release
  paths=("$manifest")
  [[ -f "$pin_file" ]] && paths+=("$pin_file")
  git add -- "${paths[@]}"
  git -c user.name="github-actions[bot]" -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
    commit --quiet -m "chore(next): pin CCmuxAppFFI to $tag" \
    -m "The release of ${sha:0:12}, whose FFI sources the tip ${tip:0:12} has (checksum $checksum). Its headers keep every declaration of the pin before, ${pinned:0:12}." \
    -m "scripts/cmux-next/pin-app-ffi-on-base.sh${GITHUB_RUN_ID:+: $GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID}"
  if [[ "${ENABLED:-}" != true ]]; then
    finish dry-run "would push $(git rev-parse --short HEAD) on ${tip:0:12} (the repository variable CMUX_NEXT_BASE_AUTOFIX is not 1)"
  fi
  if push; then
    finish pinned "pushed $(git rev-parse --short HEAD) on ${tip:0:12}"
  fi
  echo "$branch moved (attempt $attempt); re-applying the pin on the new tip"
done
echo "error: $branch kept moving; the re-pin pull request carries the pin" >&2
exit 1
}
main "$@"
exit
