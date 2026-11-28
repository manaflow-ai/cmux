#!/usr/bin/env bash
# cmux-mobile-ffi.yml's repin job: pins the release this run just published
# (cmux-mobile-ffi-$SOURCE) in Packages/Shared/CmuxMobileFFI, the package
# ios/CmuxiOS links. The mobile counterpart of publish-app-ffi-repin.sh and
# pin-app-ffi-on-base.sh, smaller: one release per run, never backwards.
#
# - Never backwards: a pin already at SOURCE, or at a commit SOURCE is on the
#   history of, is left alone (an older run that finishes late pins nothing).
#   SOURCE must be on feat-cmux-next's history.
# - On the base (BASE_PIN_ENABLED=true with BASE_TOKEN, the base autofix's push
#   identity, as the app FFI pin): only when the new bindings keep every public
#   declaration of the pinned ones (mobile_ffi_pin.py additive), so no Swift
#   caller can break, and check-mobile-ffi-pin.sh --verify-release passes on the
#   pinned tree. A tip that moves during the push is re-read, 5 times.
# - Otherwise, and for the first pin (it adds the link to ios/CmuxiOS): the
#   mobile-ffi-repin branch, force-pushed with APP_TOKEN, and its pull request
#   opened or updated with GH_TOKEN, whose iOS build proves the change.
#
# Environment: SOURCE, CHECKSUM (the apple job's outputs), APP_TOKEN, GH_TOKEN
# (may be empty: the branch is still pushed and the job prints the compare link),
# BASE_TOKEN, BASE_PIN_ENABLED, GITHUB_REPOSITORY.
set -euo pipefail

main() {
: "${SOURCE:?SOURCE}" "${CHECKSUM:?CHECKSUM}"
[[ "$SOURCE" =~ ^[0-9a-f]{40}$ ]] || { echo "error: SOURCE must be a 40-character sha, got '$SOURCE'" >&2; exit 2; }
branch=feat-cmux-next
pr_branch=mobile-ffi-repin
remote="https://github.com/${GITHUB_REPOSITORY:?GITHUB_REPOSITORY}.git"
package=Packages/Shared/CmuxMobileFFI
pin_file="$package/mobile-ffi-pin.json"
bindings="$package/Sources/CmuxMobileFFI/CmuxMobileFFI.swift"
tag="cmux-mobile-ffi-$SOURCE"

say() { echo "$*"; [[ -z "${GITHUB_STEP_SUMMARY:-}" ]] || echo "$*" >> "$GITHUB_STEP_SUMMARY"; }
push_with() { # push_with TOKEN REFSPEC [--force]
  local auth
  auth="$(printf 'x-access-token:%s' "$1" | base64 | tr -d '\n')"
  [[ -n "${GITHUB_ACTIONS:-}" ]] && echo "::add-mask::$auth"
  GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0="http.https://github.com/.extraheader" GIT_CONFIG_VALUE_0="" \
    GIT_CONFIG_KEY_1="http.https://github.com/.extraheader" GIT_CONFIG_VALUE_1="AUTHORIZATION: basic $auth" \
    git push --quiet ${3:+"$3"} "$remote" "$2"
}
commit_pin() { # commit_pin MESSAGE
  git add -- "$package"
  git -c user.name="github-actions[bot]" -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
    commit --quiet -m "chore(next): pin CmuxMobileFFIFFI to $tag" -m "$1" \
    -m "scripts/cmux-next/publish-mobile-ffi-repin.sh${GITHUB_RUN_ID:+: $GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID}"
}

route=pr
why=""
for attempt in 1 2 3 4 5; do
  git fetch --quiet "$remote" "+refs/heads/$branch:refs/remotes/pin-base/$branch"
  git checkout --quiet --force --detach "refs/remotes/pin-base/$branch"
  tip="$(git rev-parse HEAD)"
  git merge-base --is-ancestor "$SOURCE" "$tip" \
    || { say "mobile FFI pin: $tag is not on $branch's history (${tip:0:12}); nothing pinned"; return 0; }
  pinned="$(python3 -I scripts/cmux-next/mobile_ffi_pin.py read "$pin_file")"
  old_bindings=""
  if [[ "$pinned" != unpinned ]]; then
    pinned="${pinned%% *}"
    [[ "$pinned" == "$SOURCE" ]] && { say "mobile FFI pin: ${tip:0:12} already pins $tag"; return 0; }
    if git merge-base --is-ancestor "$SOURCE" "$pinned" 2>/dev/null; then
      say "mobile FFI pin: the pin ${pinned:0:12} is already newer than $tag; nothing pinned"
      return 0
    fi
    old_bindings="$(mktemp)"
    cp "$bindings" "$old_bindings"
  fi
  bash scripts/cmux-next/repin-mobile-ffi.sh "$SOURCE" "$CHECKSUM"
  # A year of grace: the tip may be ahead of this release by design; the newer push's run pins its own.
  bash scripts/cmux-next/check-mobile-ffi-pin.sh --verify-release --stale-grace 31536000
  if [[ -z "$old_bindings" ]]; then
    why="the first pin adds the cmux-mobile-ffi link to ios/CmuxiOS, so its iOS build proves it in the pull request"
  elif ! python3 -I scripts/cmux-next/mobile_ffi_pin.py additive "$old_bindings" "$bindings"; then
    why="the new bindings drop or change a public declaration of ${pinned:0:12}'s, so the pull request's iOS build proves the Swift callers first"
  elif [[ "${BASE_PIN_ENABLED:-}" != true || -z "${BASE_TOKEN:-}" ]]; then
    why="pinning on the base is off (CMUX_NEXT_BASE_AUTOFIX is not 1, or the base pin token did not mint)"
  else
    route=base
  fi
  commit_pin "The release of ${SOURCE:0:12} (checksum $CHECKSUM), on the tip ${tip:0:12}${why:+; through the pull request: $why}."
  [[ "$route" == pr ]] && break
  if push_with "$BASE_TOKEN" "HEAD:refs/heads/$branch"; then
    say "mobile FFI pin on $branch: pushed $(git rev-parse --short HEAD) on ${tip:0:12}"
    return 0
  fi
  echo "$branch moved (attempt $attempt); re-applying the pin on the new tip"
  why="$branch kept moving under the base pin"
done

if [[ "$route" == base ]]; then
  # Five refused base pushes: the pull request carries the pin.
  commit="$(git rev-parse HEAD)"
fi
push_with "${APP_TOKEN:?APP_TOKEN}" "HEAD:refs/heads/$pr_branch" --force
say "mobile FFI pin: pushed $pr_branch ($(git rev-parse --short HEAD)): $why"
if [[ -z "${GH_TOKEN:-}" ]]; then
  say "no pull-request token minted; open it: https://github.com/$GITHUB_REPOSITORY/compare/$branch...$pr_branch"
  return 0
fi
body="Pins Packages/Shared/CmuxMobileFFI (the package ios/CmuxiOS links) to [$tag](https://github.com/$GITHUB_REPOSITORY/releases/tag/$tag), checksum \`$CHECKSUM\`, with the bindings generated from the same build. Through this pull request because $why. Opened by cmux-mobile-ffi.yml's repin job (scripts/cmux-next/publish-mobile-ffi-repin.sh)."
existing="$(gh pr list --repo "$GITHUB_REPOSITORY" --head "$pr_branch" --base "$branch" --state open --json number --jq '.[0].number // empty')"
if [[ -n "$existing" ]]; then
  gh pr edit "$existing" --repo "$GITHUB_REPOSITORY" --title "chore(next): pin CmuxMobileFFIFFI to $tag" --body "$body"
  say "updated https://github.com/$GITHUB_REPOSITORY/pull/$existing"
else
  gh pr create --repo "$GITHUB_REPOSITORY" --base "$branch" --head "$pr_branch" \
    --title "chore(next): pin CmuxMobileFFIFFI to $tag" --body "$body"
fi
}
main "$@"
exit
