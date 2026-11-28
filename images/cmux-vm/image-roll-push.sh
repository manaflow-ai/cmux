#!/usr/bin/env bash
# Lands one Cloud VM image roll change as bot commits: the roll (pin the lock, put the baked image first
# in production) or its rollback (take it back out). Run from a checkout of this repository. In platform
# mode, pass --platform-checkout for a cmux-platform checkout on main; its Wrangler change is pushed
# before cmux's lock-only commit. Each attempt starts from the newest tip and makes the change again there,
# so a moved tip is never overwritten; at most 5 attempts.
#
#   TOKEN=... images/cmux-vm/image-roll-push.sh roll --candidate F --revision R --run ID --attempt N [--pin SHA] [--message-file M] [--dry-run]
#   TOKEN=... images/cmux-vm/image-roll-push.sh rollback --image ID --message-file M [--dry-run]
#
# TOKEN pushes cmux (the manaflow-cmux-pr-autofix App's token, so the push starts cmux-vm.yml's production
# deploy; it pushes straight to feat-cmux-next, so a ruleset there that the App cannot bypass stops the roll:
# that refusal exits 3 with GitHub's reason, never retried as a moved tip). PLATFORM_TOKEN pushes cmux-platform
# main in platform mode. Tokens reach git only as extra headers in the environment. --dry-run makes the
# commits and prints them, and pushes nothing.
# Prints `pushed <sha>`, `nothing <reason>` or `dry-run <sha>` as its last line; the step output
# `result` and `sha` (GITHUB_OUTPUT) say the same.
set -euo pipefail
action="${1:?usage: image-roll-push.sh roll|rollback ...}"; shift
candidate="" revision="" run="" attempt="" pin="" image="" message_file="" dry_run="" platform_checkout="" platform_wrangler=""
while [ $# -gt 0 ]; do
  case "$1" in
    --candidate) candidate="$2"; shift 2 ;;
    --revision) revision="$2"; shift 2 ;;
    --run) run="$2"; shift 2 ;;
    --attempt) attempt="$2"; shift 2 ;;
    --pin) pin="$2"; shift 2 ;;
    --image) image="$2"; shift 2 ;;
    --message-file) message_file="$2"; shift 2 ;;
    --platform-checkout) platform_checkout="$2"; shift 2 ;;
    # cmux-platform's root wrangler.jsonc: its CLOUD_VM_API_IMAGE pins stay in every list (auto-roll.ts platformPins).
    --platform-wrangler) platform_wrangler="$2"; shift 2 ;;
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
git_with_token() {
  local token="$1"; shift
  GIT_CONFIG_COUNT=1 \
  GIT_CONFIG_KEY_0="http.${server}/.extraheader" \
  GIT_CONFIG_VALUE_0="AUTHORIZATION: basic $(printf 'x-access-token:%s' "$token" | base64 -w0)" \
    git "$@"
}

pins_args=()
if [ -n "$platform_wrangler" ]; then
  [ -s "$platform_wrangler" ] || { echo "image-roll-push: --platform-wrangler $platform_wrangler is missing or empty" >&2; exit 2; }
  pins_args=(--platform-wrangler "$platform_wrangler")
fi

platform_mode=0
if [ -n "$platform_checkout" ]; then
  platform_mode=1
  [ -d "$platform_checkout/.git" ] || { echo "image-roll-push: --platform-checkout is not a git checkout" >&2; exit 2; }
  : "${PLATFORM_TOKEN:?PLATFORM_TOKEN is required in platform mode}"
fi
platform_done=0

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
      if [ -n "$pin" ]; then
        # Never back: a roll that landed while this one baked may pin a newer cmux-tui (auto-roll.ts behindTip).
        set +e
        bun images/cmux-vm/auto-roll.ts behind --pin "$pin" > "$RUNNER_TEMP/behind.json"
        rc=$?
        set -e
        if [ "$rc" = 3 ]; then report nothing "$(jq -r .reason "$RUNNER_TEMP/behind.json")" ""; exit 0; fi
        [ "$rc" = 0 ] || exit "$rc"
        bun images/cmux-vm/pin-cmux-tui.ts --commit "$pin" --write > /dev/null
      fi
      if [ "$platform_done" = 0 ]; then
        if [ "$platform_mode" = 1 ]; then
          if [ "$(git -C "$platform_checkout" rev-parse --is-shallow-repository)" = true ]; then
            git_with_token "${PLATFORM_TOKEN:-}" -C "$platform_checkout" fetch -q --depth 50 origin refs/heads/main
          else
            git_with_token "${PLATFORM_TOKEN:-}" -C "$platform_checkout" fetch -q origin refs/heads/main
          fi
          git -C "$platform_checkout" checkout -q --detach FETCH_HEAD
          git -C "$platform_checkout" reset -q --hard FETCH_HEAD
          set +e
          bun images/cmux-vm/auto-roll.ts approve --candidate "$candidate" --revision "$revision" --run "$run" --attempt "$attempt" \
            --wrangler "$platform_checkout/workers/cmux-vm/wrangler.jsonc" --lock "$PWD/images/cmux-vm/inputs.lock.json" "${pins_args[@]}" > "$RUNNER_TEMP/approve.json"
          rc=$?
          set -e
          if [ "$rc" = 4 ]; then report nothing "the tip moved the image inputs since the bake; the next roll bakes them" ""; exit 0; fi
          [ "$rc" = 0 ] || exit "$rc"
          cat "$RUNNER_TEMP/approve.json"
          git -C "$platform_checkout" config user.name "github-actions[bot]"
          git -C "$platform_checkout" config user.email "41898282+github-actions[bot]@users.noreply.github.com"
          git -C "$platform_checkout" add workers/cmux-vm/wrangler.jsonc
          git -C "$platform_checkout" commit -q -F "$message_file"
          platform_sha="$(git -C "$platform_checkout" rev-parse HEAD)"
          if [ -n "$dry_run" ]; then
            git -C "$platform_checkout" diff HEAD~1 HEAD > "$RUNNER_TEMP/platform-image-roll.diff"
          else
            git_with_token "$PLATFORM_TOKEN" -C "$platform_checkout" push -q origin HEAD:refs/heads/main
          fi
          platform_done=1
        else
          set +e
          bun images/cmux-vm/auto-roll.ts approve --candidate "$candidate" --revision "$revision" --run "$run" --attempt "$attempt" "${pins_args[@]}" > "$RUNNER_TEMP/approve.json"
          rc=$?
          set -e
          if [ "$rc" = 4 ]; then report nothing "the tip moved the image inputs since the bake; the next roll bakes them" ""; exit 0; fi
          [ "$rc" = 0 ] || exit "$rc"
          cat "$RUNNER_TEMP/approve.json"
          git add workers/cmux-vm/wrangler.jsonc images/cmux-vm/inputs.lock.json
        fi
      fi
      if [ "$platform_mode" = 1 ]; then
        git add images/cmux-vm/inputs.lock.json
      fi
      ;;
    rollback)
      rollback_wrangler="workers/cmux-vm/wrangler.jsonc"
      rollback_repo="."
      if [ "$platform_mode" = 1 ] && [ "$platform_done" = 0 ]; then
        git_with_token "$PLATFORM_TOKEN" -C "$platform_checkout" fetch -q origin refs/heads/main
        git -C "$platform_checkout" checkout -q --detach FETCH_HEAD
        git -C "$platform_checkout" reset -q --hard FETCH_HEAD
        rollback_wrangler="$platform_checkout/workers/cmux-vm/wrangler.jsonc"
        rollback_repo="$platform_checkout"
      fi
      bun images/cmux-vm/auto-roll.ts rollback --image "$image" --wrangler "$rollback_wrangler" "${pins_args[@]}" > "$RUNNER_TEMP/rollback.json"
      cat "$RUNNER_TEMP/rollback.json"
      if [ "$(jq -r .rolledBack "$RUNNER_TEMP/rollback.json")" != true ]; then
        report nothing "$(jq -r .reason "$RUNNER_TEMP/rollback.json")" ""
        exit 0
      fi
      git -C "$rollback_repo" config user.name "github-actions[bot]"
      git -C "$rollback_repo" config user.email "41898282+github-actions[bot]@users.noreply.github.com"
      if [ "$platform_mode" = 1 ]; then
        git -C "$platform_checkout" add workers/cmux-vm/wrangler.jsonc
        git -C "$platform_checkout" commit -q -F "$message_file"
        platform_sha="$(git -C "$platform_checkout" rev-parse HEAD)"
        if [ -n "$dry_run" ]; then
          git -C "$platform_checkout" diff HEAD~1 HEAD > "$RUNNER_TEMP/platform-image-roll.diff"
        else
          git_with_token "$PLATFORM_TOKEN" -C "$platform_checkout" push -q origin HEAD:refs/heads/main
        fi
        platform_done=1
        if [ -n "$dry_run" ]; then
          report dry-run "$platform_sha (not pushed)" "$platform_sha"
        else
          report pushed "$platform_sha" "$platform_sha"
        fi
        exit 0
      fi
      git add workers/cmux-vm/wrangler.jsonc
      ;;
    *) echo "image-roll-push: unknown action $action" >&2; exit 2 ;;
  esac
  if git diff --cached --quiet; then
    if [ "$platform_mode" = 1 ]; then
      if [ -n "$dry_run" ]; then
        report dry-run "${platform_sha:-platform change} (not pushed; cmux lock unchanged)" "${platform_sha:-}"
      else
        report pushed "${platform_sha:-platform change}; cmux lock unchanged" "${platform_sha:-}"
      fi
    else
      report nothing "the tip already has this change" ""
    fi
    exit 0
  fi
  git commit -q -F "$message_file"
  sha="$(git rev-parse HEAD)"
  if [ -n "$dry_run" ]; then
    git show --stat --format='%H%n%B' HEAD
    git diff HEAD~1 HEAD > "$RUNNER_TEMP/image-roll.diff"
    report dry-run "$sha (not pushed)" "$sha"
    exit 0
  fi
  push_err="${RUNNER_TEMP:-/tmp}/image-roll-push.err"
  if git push -q origin "HEAD:refs/heads/${branch}" 2>"$push_err"; then cat "$push_err" >&2; report pushed "$sha" "$sha"; exit 0; fi
  cat "$push_err" >&2
  # A ruleset or protection refusal never clears on a retry: name it and stop, so the run reads as the
  # refusal it is, not as a tip that kept moving.
  if grep -qE 'GH013|GH006|declined due to repository rule|protected branch' "$push_err"; then
    echo "image-roll-push: GitHub refused the push to ${branch} by a repository rule, not a moved tip; nothing landed." >&2
    echo "::error title=Image roll push refused::${branch} has a ruleset or branch protection the roll's App token cannot pass (see the remote lines above); nothing landed." >&2
    exit 3
  fi
  echo "feat-cmux-next moved under the push; making the change again on the new tip (attempt ${push_try})"
done
echo "image-roll-push: feat-cmux-next kept moving; nothing landed" >&2
exit 1
