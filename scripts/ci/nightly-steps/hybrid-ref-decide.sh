#!/usr/bin/env bash
# nightly.yml build-nightly-app: "Decide the Linux build's REF capture".
# Kept out of the workflow to keep nightly.yml under GitHub's workflow file size
# limit; the step's env: sets every input.
set -euo pipefail
skip() { echo "::notice::REF capture skipped: $1"; echo "capture=false" >> "$GITHUB_OUTPUT"; exit 0; }
case "${RUNNER_NAME:-}" in
  *-glaeda | *-glaeda-[0-9]*) ;;
  *) skip "$RUNNER_NAME is not an owned mini" ;;
esac
# The job's HOME need not be the build user's, where the fleet installs cmux-ci.
client="${CMUX_CI_CLIENT:-$HOME/.local/bin/cmux-ci}"
[ -x "$client" ] || client="$(python3 -c 'import os, pwd; print(pwd.getpwuid(os.getuid()).pw_dir)')/.local/bin/cmux-ci"
[ -x "$client" ] || skip "no cmux-ci on $RUNNER_NAME"
# The start of this job bounds the capture (see "Finish the Linux build's REF capture").
# Unknown, it is taken as 30 minutes ago, more than this job ever spends before here, so
# the capture's deadline only comes earlier.
started="$(gh api --paginate "repos/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID/attempts/$GITHUB_RUN_ATTEMPT/jobs?per_page=100" \
  --jq '.jobs[] | select(.runner_name == env.RUNNER_NAME and .status == "in_progress") | .started_at' | head -1)" || started=""
started="$(date -j -u -f %Y-%m-%dT%H:%M:%SZ "$started" +%s 2>/dev/null)" || started=""
if [ -z "$started" ]; then
  started=$(( $(date +%s) - 30 * 60 ))
  echo "::warning title=REF capture::this job's start is unknown; the capture's deadline counts from 30 minutes ago"
fi
key="$(python3 -I scripts/cmux-next/hybrid_ref_capture.py key .)"
# As the DEV compile decides (cmux-next.yml): readable complete captures of the key
# (unexpired, under 13 days old: the store keeps the packs 14 days), and incomplete ones of
# the last day. compile=true makes the product lookup miss so there is a build to capture,
# unless a capture of this key came out incomplete in the last day (then only a build that
# compiles anyway captures, and a key that never captures whole cannot turn reuse off for
# every nightly). A lookup that fails captures and compiles anyway and fails this step, so
# the run shows it (DEV run 40428066457 lost its capture to a silent rate limit).
if have="$(python3 -I scripts/cmux-next/hybrid_ref_capture.py have --key "$key" --repo "$GITHUB_REPOSITORY" --budget 30)"; then
  complete="$(sed -n 's/^complete=//p' <<< "$have")" incomplete="$(sed -n 's/^recent_incomplete=//p' <<< "$have")"
  capture=false compile=false
  [[ "$complete" == 0 ]] && capture=true
  [[ "$capture" == true && "$incomplete" == 0 ]] && compile=true
  echo "REF key $key: readable complete captures $complete, incomplete today $incomplete, capture $capture, compile $compile"
  printf 'key=%s\ncapture=%s\ncompile=%s\nclient=%s\nstarted=%s\n' "$key" "$capture" "$compile" "$client" "$started" >> "$GITHUB_OUTPUT"
  exit 0
fi
printf 'key=%s\ncapture=true\ncompile=true\nclient=%s\nstarted=%s\n' "$key" "$client" "$started" >> "$GITHUB_OUTPUT"
echo "::error title=REF capture lookup failed::the capture artifact lookup for REF key $key failed (log above); compiling and capturing anyway"
exit 1
