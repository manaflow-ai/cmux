#!/usr/bin/env bash
# Prints `true` when a pull request is on the cmux NEXT line, else `false`.
#
# ci.yml skips its legacy lanes (fast guards, static preflight, guards, the
# legacy macOS route, ...) for cmux NEXT pull requests, which have their own
# workflows. Testing `base.ref == 'feat-cmux-next'` missed a stacked pull
# request: its base is the parent pull request's branch until that one merges
# and GitHub retargets it (#23442, 2026-10-21, ran the main-only static
# preflight and went red on cmux NEXT's catalogs). A base commit with
# plans/cmux-next/ is on the cmux NEXT line, whatever its branch is called; main
# has no such folder. Anything this cannot read prints `false`, so the legacy
# lanes run, as they did before.
#
# A run that is not a pull request (the hourly full tier's workflow_dispatch,
# .github/hourly-full-tier.json) is on the line when its ref is feat-cmux-next:
# it tests a feat-cmux-next commit, so it routes like a feat-cmux-next pull
# request instead of running every legacy lane no such pull request runs
# (run 45951987470, 2026-11-27: 25 of 56 jobs red, about 52 job-minutes of
# legacy guards an hour).
#
# Usage: next_line.sh EVENT_NAME BASE_REF BASE_SHA [REF_NAME]
set -uo pipefail

event="${1:-}"
base_ref="${2:-}"
base_sha="${3:-}"
ref_name="${4:-}"

if [[ "$event" != pull_request ]]; then
  if [[ "$ref_name" == feat-cmux-next ]]; then
    echo true
  else
    echo false
  fi
  exit 0
fi
if [[ "$base_ref" == feat-cmux-next ]]; then
  echo true
  exit 0
fi
if [[ ! "$base_sha" =~ ^[0-9a-f]{40}$ ]]; then
  echo false
  exit 0
fi
# Trees only: the test reads a path, never a file. --depth only in a checkout that is already
# shallow (CI's), so a full clone stays full.
if ! git cat-file -e "$base_sha^{commit}" 2>/dev/null; then
  depth=()
  [[ "$(git rev-parse --is-shallow-repository 2>/dev/null)" == true ]] && depth=(--depth=1)
  git fetch --no-recurse-submodules --quiet --no-tags ${depth[@]+"${depth[@]}"} --filter=blob:none origin "$base_sha" >/dev/null 2>&1 || true
fi
if git cat-file -e "$base_sha:plans/cmux-next" 2>/dev/null; then
  echo true
else
  echo false
fi
