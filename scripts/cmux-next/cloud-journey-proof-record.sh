#!/usr/bin/env bash
# Appends one Cloud journey verdict to proofs/<ENV>.json on the branch cloud-journey-proofs of this repository,
# so NOW's cloud_deploy_gate (cmuxterm-hq tools/fleet-reconcilers/now_cloud_deploy_gate.py) can read what each
# deploy proved without an API call. GitHub's secondary rate limit on the bot identity NOW shares refused every
# run list NOW reads for about 4 minutes on 2026-11-15 (08:38 to 08:42Z), and the goal cloud-deploy-checked read
# two good cmux-vm deploys unproven. A reader needs only git:
#   git fetch origin cloud-journey-proofs && git show FETCH_HEAD:proofs/staging.json
#
#   TOKEN=... cloud-journey-proof-record.sh ENV RESULT AT
#
# ENV is staging or production, RESULT pass|red|regressed|not-run, AT the verdict's UTC time. The entry names
# this run's head commit (GITHUB_SHA: the commit the run deployed), run id and URL. Each file keeps the newest
# KEEP entries (the gate reads two hours). TOKEN is a contents: write token (the job's GITHUB_TOKEN: its push
# starts no workflow); it reaches git only as an extra header in the environment, never argv or a log. A push
# that loses a race reads the branch again, at most 5 times (the same way the cmux-vm image roll records its rolls).
set -euo pipefail
env_name="${1:?usage: cloud-journey-proof-record.sh ENV RESULT AT}"
result="${2:?usage: cloud-journey-proof-record.sh ENV RESULT AT}"
at="${3:?usage: cloud-journey-proof-record.sh ENV RESULT AT}"
[[ "$env_name" =~ ^(staging|production)$ ]] || { echo "cloud-journey-proof-record: bad environment" >&2; exit 2; }
[[ "$result" =~ ^(pass|red|regressed|not-run)$ ]] || { echo "cloud-journey-proof-record: bad result" >&2; exit 2; }
[[ "$at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || { echo "cloud-journey-proof-record: bad time" >&2; exit 2; }
: "${TOKEN:?TOKEN is required}"
repo="${GITHUB_REPOSITORY:?}"
sha="${GITHUB_SHA:?}"
run="${GITHUB_RUN_ID:?}"
branch="${CMUX_JOURNEY_PROOF_BRANCH:-cloud-journey-proofs}"
server="${GITHUB_SERVER_URL:-https://github.com}"
keep="${CMUX_JOURNEY_PROOF_KEEP:-60}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0="http.${server}/.extraheader"
GIT_CONFIG_VALUE_0="AUTHORIZATION: basic $(printf 'x-access-token:%s' "$TOKEN" | base64 -w0)"
export GIT_CONFIG_VALUE_0

git -C "$work" init -q
git -C "$work" config user.name "github-actions[bot]"
git -C "$work" config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git -C "$work" remote add origin "${server}/${repo}.git"
file="proofs/${env_name}.json"
entry="$(jq -nc --arg sha "$sha" --arg result "$result" --arg at "$at" --arg run "$run" \
  --arg url "${server}/${repo}/actions/runs/${run}" \
  '{commit: $sha, result: $result, at: $at, run: ($run | tonumber), run_url: $url}')"
attempts="${CMUX_JOURNEY_PROOF_ATTEMPTS:-8}"
for attempt in $(seq 1 "$attempts"); do
  if [ "$attempt" -gt 1 ]; then
    # Staging, production and cmux-vm append to the same branch within seconds of each other: back off with
    # jitter so the writers stop colliding (2026-11-26 00:24Z: five back-to-back attempts in 2 s all lost).
    sleep "$(( attempt + RANDOM % (attempt * 2) ))"
  fi
  # ls-remote tells "no branch yet" apart from a failed fetch. A fetch failure used to read as the first proof
  # ever, start an orphan and lose every push as non-fast-forward.
  if ! heads="$(git -C "$work" ls-remote --heads origin "refs/heads/${branch}")"; then
    echo "cloud journey proof: could not read ${branch} (attempt ${attempt})"
    continue
  fi
  if [ -n "$heads" ]; then
    if ! git -C "$work" fetch -q --depth 1 origin "refs/heads/${branch}"; then
      echo "cloud journey proof: fetch of ${branch} failed (attempt ${attempt})"
      continue
    fi
    git -C "$work" checkout -q -f -B "$branch" FETCH_HEAD
  else
    # The first proof ever: the branch starts as an orphan with only proofs on it.
    git -C "$work" checkout -q --orphan "$branch"
    git -C "$work" rm -rqf . 2> /dev/null || true
  fi
  mkdir -p "$work/proofs"
  if [ -f "$work/$file" ]; then current="$work/$file"; else current=/dev/null; fi
  jq -n --slurpfile cur "$current" --argjson entry "$entry" --argjson keep "$keep" \
    '(($cur[0] // []) + [$entry]) | .[-$keep:]' > "$work/$file.next"
  mv "$work/$file.next" "$work/$file"
  git -C "$work" add "$file"
  git -C "$work" commit -q -m "cloud journey proof: ${env_name} ${sha:0:12} ${result}"
  if git -C "$work" push -q origin "HEAD:refs/heads/${branch}"; then
    echo "cloud journey proof: ${env_name} ${sha:0:12} ${result} written (${branch}:${file})"
    exit 0
  fi
  echo "cloud journey proof: the proof branch moved; appending again (attempt ${attempt})"
done
echo "cloud-journey-proof-record: ${file} was not written after ${attempts} attempts (the branch kept moving or could not be read)" >&2
exit 1
