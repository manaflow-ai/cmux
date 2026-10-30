#!/usr/bin/env bash
# nightly.yml sign-nightly-identity-legacy: "Check out the build's own source for the bundle checks". Moved out of the workflow to keep
# nightly.yml under GitHub's workflow file size limit; the step's env: still sets every input.
set -euo pipefail
short="$(/usr/libexec/PlistBuddy -c 'Print :CMUXCommit' "legacy-app/cmux NIGHTLY.app/Contents/Info.plist")"
[[ "$short" =~ ^[0-9a-f]{7,40}$ ]] || { echo "invalid CMUXCommit '$short'" >&2; exit 1; }
sha="$(gh api "repos/$GITHUB_REPOSITORY/commits/$short" --jq .sha)"
[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || { echo "could not resolve CMUXCommit $short" >&2; exit 1; }
# Ancestry from git first, the compare API as fallback (the script; the API refused a
# big diff under load in run 40340830337). Exit 3: a required commit is missing.
rc=0
# shellcheck disable=SC2086 # REQUIRED is a space-separated SHA list
check="$(./scripts/ci/nightly-next-legacy-requirement.sh --commit "$GITHUB_REPOSITORY" "$sha" $REQUIRED)" || rc=$?
case "$rc" in
  0) ;;
  3) echo "build commit $sha lacks a required commit ($check); refusing before any Apple submission" >&2
     : > "$RUNNER_TEMP/legacy-requirement-refused"; exit 1 ;;
  *) echo "could not check the build commit $sha's required commits ($check)" >&2; exit 1 ;;
esac
# A depth flag only in an already-shallow checkout: in a full clone it would make every worktree shallow.
depth=()
[[ "$(git rev-parse --is-shallow-repository)" == true ]] && depth=(--depth=1)
git fetch --no-tags ${depth[@]+"${depth[@]}"} origin "$sha"
git worktree add --detach "$RUNNER_TEMP/build-src" "$sha"
(cd "$RUNNER_TEMP/build-src" && bash scripts/ci/init-submodule.sh ghostty-next)
echo "CMUX_VERIFY_LICENSES_TOOL=$RUNNER_TEMP/build-src/scripts/verify-app-bundle-licenses.sh" >> "$GITHUB_ENV"
echo "build_sha=$sha" >> "$GITHUB_OUTPUT"
echo "bundle checks run from $sha (CMUXCommit $short)"
