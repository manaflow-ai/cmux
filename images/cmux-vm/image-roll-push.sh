#!/usr/bin/env bash
# Lands one Cloud VM image roll change on feat-cmux-next as a bot commit: the roll (pin the lock, put the
# baked image first in production) or its rollback (take it back out). Run from a checkout of this
# repository. Each attempt starts from the newest tip and makes the change again there, so a moved
# tip is never overwritten; at most 5 attempts.
#
#   TOKEN=... images/cmux-vm/image-roll-push.sh roll --candidate F --revision R --run ID --attempt N [--pin SHA] [--message-file M] [--dry-run]
#   TOKEN=... images/cmux-vm/image-roll-push.sh rollback --image ID --message-file M [--dry-run]
#
# TOKEN pushes (the manaflow-cmux-pr-autofix App's token, so the push starts cmux-vm.yml's production
# deploy; no ruleset or branch protection applies to feat-cmux-next). It reaches git only as an extra
# header in the environment. --dry-run makes the commit and prints it, and pushes nothing.
# Prints `pushed <sha>`, `nothing <reason>` or `dry-run <sha>` as its last line; the step output
# `result` and `sha` (GITHUB_OUTPUT) say the same.
set -euo pipefail
action="${1:?usage: image-roll-push.sh roll|rollback ...}"; shift
candidate="" revision="" run="" attempt="" pin="" image="" message_file="" dry_run=""
while [ $# -gt 0 ]; do
  case "$1" in
    --candidate) candidate="$2"; shift 2 ;;
    --revision) revision="$2"; shift 2 ;;
    --run) run="$2"; shift 2 ;;
    --attempt) attempt="$2"; shift 2 ;;
    --pin) pin="$2"; shift 2 ;;
    --image) image="$2"; shift 2 ;;
    --message-file) message_file="$2"; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    *) echo "image-roll-push: unknown argument $1" >&2; exit 2 ;;
  esac
done
branch="${CMUX_IMAGE_ROLL_TARGET:-feat-cmux-next}"
out="${GITHUB_OUTPUT:-/dev/null}"
server="${GITHUB_SERVER_URL:-https://github.com}"
if [ -z "$dry_run" ]; then
  : "${TOKEN:?TOKEN is required}"
  export GIT_CONFIG_COUNT=1
  export GIT_CONFIG_KEY_0="http.${server}/.extraheader"
  GIT_CONFIG_VALUE_0="AUTHORIZATION: basic $(printf 'x-access-token:%s' "$TOKEN" | base64 -w0)"
  export GIT_CONFIG_VALUE_0
fi
git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
report() { echo "$1 $2"; { echo "result=$1"; echo "sha=$3"; } >> "$out"; }

# `push_try` is the push retry counter; `attempt` is the workflow run attempt that names the image.
for push_try in 1 2 3 4 5; do
  # A depth only bounds the download of an already shallow (CI) checkout; never make a full clone shallow.
  if [ "$(git rev-parse --is-shallow-repository)" = true ]; then
    git fetch -q --depth 50 origin "refs/heads/${branch}"
  else
    git fetch -q origin "refs/heads/${branch}"
  fi
  git checkout -q --detach FETCH_HEAD
  git reset -q --hard FETCH_HEAD
  case "$action" in
    roll)
      if [ -n "$pin" ]; then bun images/cmux-vm/pin-cmux-tui.ts --commit "$pin" --write > /dev/null; fi
      set +e
      bun images/cmux-vm/auto-roll.ts approve --candidate "$candidate" --revision "$revision" --run "$run" --attempt "$attempt" > "$RUNNER_TEMP/approve.json"
      rc=$?
      set -e
      if [ "$rc" = 4 ]; then report nothing "the tip moved the image inputs since the bake; the next roll bakes them" ""; exit 0; fi
      [ "$rc" = 0 ] || exit "$rc"
      cat "$RUNNER_TEMP/approve.json"
      git add workers/cmux-vm/wrangler.jsonc images/cmux-vm/inputs.lock.json
      ;;
    rollback)
      bun images/cmux-vm/auto-roll.ts rollback --image "$image" > "$RUNNER_TEMP/rollback.json"
      cat "$RUNNER_TEMP/rollback.json"
      if [ "$(jq -r .rolledBack "$RUNNER_TEMP/rollback.json")" != true ]; then
        report nothing "$(jq -r .reason "$RUNNER_TEMP/rollback.json")" ""
        exit 0
      fi
      git add workers/cmux-vm/wrangler.jsonc
      ;;
    *) echo "image-roll-push: unknown action $action" >&2; exit 2 ;;
  esac
  if git diff --cached --quiet; then report nothing "the tip already has this change" ""; exit 0; fi
  git commit -q -F "$message_file"
  sha="$(git rev-parse HEAD)"
  if [ -n "$dry_run" ]; then
    git show --stat --format='%H%n%B' HEAD
    git diff HEAD~1 HEAD > "$RUNNER_TEMP/image-roll.diff"
    report dry-run "$sha (not pushed)" "$sha"
    exit 0
  fi
  if git push -q origin "HEAD:refs/heads/${branch}"; then report pushed "$sha" "$sha"; exit 0; fi
  echo "feat-cmux-next moved under the push; making the change again on the new tip (attempt ${push_try})"
done
echo "image-roll-push: feat-cmux-next kept moving; nothing landed" >&2
exit 1
