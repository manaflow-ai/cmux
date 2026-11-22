#!/usr/bin/env bash
# Sign a payload of scripts/ci/cmux-machine-channel.py and move its channel pointer to it, unless
# the channel already names this build or a newer one (scripts/cmux-next/web-ota-pointer.py newer).
# The payload's purpose names the files:
#
#   cmux-cloud-machine-update  cmux-tui/channels/cloud-machine.json
#   cmux-linux-release         cmux-tui/<commit>/release.json, written once, then
#                              cmux-tui/channels/linux-<channel>.json (the same signed file); a payload
#                              naming a tree_key (cmux-machine-channel.py --tree-key, or alias) is first
#                              written once to cmux-tui/tree/<tree_key>/release.json too, where a file of
#                              another commit of the same tree with the same files is kept (an alias)
#   cmux-mac-live-update       cmux-tui/<commit>/mac-live.json, written once (`cmux app try` reads it),
#                              then cmux-tui/channels/mac-live.json (the same signed file)
#
# Used by point-machine-channel-early, point-machine-channel and sign-linux-release in
# .github/workflows/cmux-tui-artifacts.yml.
#
# usage: scripts/ci/cmux-machine-channel-point.sh PAYLOAD DIR [--same-tree | --commit-only]
#
# --commit-only (a payload with a per-commit file): write that file and leave the channel alone. A PR
# head's Mac live update file (`cmux app try PR`) is published this way; only feat-cmux-next moves
# the nightly-live channel.
#
# --same-tree (the Cloud machine channel only): keep the channel when the commit it names has the
# same source tree key (scripts/ci/cmux_tui_tree_key.py --version v2, both keys computed here by
# this checkout's script) as the payload's commit: the same code, so no machine updates. A push that
# adopts an earlier commit's tree used to move the channel from that commit's thin machine/ build to
# its fat cmux-tui/<sha>/ build, and every Cloud machine updated to identical code. A key that
# cannot be computed (the commit is not fetchable) keeps the old rule: the channel moves.
#
# DIR is a private scratch directory (mode 700). Reads SIGNING_KEY, R2_ENDPOINT and the R2
# credentials (AWS_*) from the environment. A compare-and-swap on the bytes compared (as
# cmux-tui-point-channel.sh): a run that finds the channel moved under it reads and compares again.
set -euo pipefail
payload=$1 dir=$2 same_tree="" commit_only=""
case "${3:-}" in
  "") ;;
  --same-tree) same_tree=--same-tree ;;
  --commit-only) commit_only=1 ;;
  *) echo "::error::unknown option $3"; exit 1 ;;
esac
ptr=scripts/cmux-next/web-ota-pointer.py
keys=Packages/macOS/CmuxNext/Sources/CmuxNextUpdater/Resources/web-update-keys.json
read -r purpose channel commit release_tree < <(python3 -c '
import json, sys
p = json.load(open(sys.argv[1]))
print(p["purpose"], p["channel"], p["commit"], p.get("tree_key") or "-")' "$payload")
[[ "$release_tree" == - ]] && release_tree=""
if [[ -n "$release_tree" && ( "$purpose" != cmux-linux-release || ! "$release_tree" =~ ^[0-9a-f]{40}$ ) ]]; then
  echo "::error::$payload names tree_key $release_tree: only a Linux release payload names a tree, by its 40-hex key"
  exit 1
fi
case "$purpose" in
  cmux-cloud-machine-update) object=cmux-tui/channels/cloud-machine.json label="Cloud machine channel" ;;
  cmux-linux-release) object="cmux-tui/channels/linux-$channel.json" label="Linux release channel $channel"
    once="cmux-tui/$commit/release.json" once_label="Linux release file" ;;
  cmux-mac-live-update) object=cmux-tui/channels/mac-live.json label="Mac live update channel"
    once="cmux-tui/$commit/mac-live.json" once_label="Mac live update file" ;;
  *) echo "::error::$payload has the unknown purpose $purpose"; exit 1 ;;
esac
if [[ -n "$same_tree" && "$purpose" != cmux-cloud-machine-update ]]; then
  echo "::error::--same-tree is for the Cloud machine channel, not $purpose"
  exit 1
fi
if [[ -n "$commit_only" && -z "${once:-}" ]]; then
  echo "::error::--commit-only needs a per-commit file; $purpose has none"
  exit 1
fi
tree_key_of() { # COMMIT: its v2 tree key, fetching the commit when this checkout lacks it; empty when unknown
  local tk=scripts/ci/cmux_tui_tree_key.py key
  key="$(scripts/ci/timeout.sh 90 python3 "$tk" --version v2 "$1" 2>/dev/null)" || key=""
  if [[ ! "$key" =~ ^[0-9a-f]{40}$ ]]; then
    local depth=()  # --depth only in an already-shallow checkout, so a full clone stays full
    [[ "$(git rev-parse --is-shallow-repository 2>/dev/null)" == true ]] && depth=(--depth=1)
    scripts/ci/timeout.sh 60 git fetch --no-tags ${depth[@]+"${depth[@]}"} origin "$1" >/dev/null 2>&1 || true
    key="$(scripts/ci/timeout.sh 90 python3 "$tk" --version v2 "$1" 2>/dev/null)" || key=""
  fi
  [[ "$key" =~ ^[0-9a-f]{40}$ ]] && printf '%s' "$key"
  return 0
}
tree_key=""
if [[ -n "$same_tree" ]]; then
  tree_key="$(tree_key_of "$commit")"
  [[ -n "$tree_key" ]] || echo "::warning::no tree key for $commit; the channel moves by commit time alone"
fi
if [[ -z "${SIGNING_KEY:-}" ]]; then
  echo "::error::CMUX_WEB_OTA_SIGNING_KEY is required to sign the $label"
  exit 1
fi
signed="$dir/signed.json"
trap 'rm -f "$dir/key.pem"' EXIT
(umask 077; printf '%s\n' "$SIGNING_KEY" > "$dir/key.pem")
python3 "$ptr" sign --payload "$payload" --key "$dir/key.pem" --keys "$keys" --out "$signed"
rm -f "$dir/key.pem"
upload() { # KEY CACHE-CONTROL MODE...
  local key=$1 cache=$2
  shift 2
  python3 scripts/ci/upload-r2-object.py --endpoint-url "$R2_ENDPOINT" --bucket cmux-binaries \
    --cache-control "$cache" --file "$signed" --key "$key" --content-type application/json \
    --conflict-exit-code 9 "$@"
}

# A file written once. A file already there of the same build (another run or attempt signed it at
# another time) is kept; one of another build is an error: an installer that asked for this version by
# name would install other bytes. SAME-BUILD-ARGS: --same-tree for the tree's file, which another commit
# of the tree may have written first.
write_once() { # OBJECT LABEL [SAME-BUILD-ARGS...]
  local release=$1 label=$2 code rc attempt
  shift 2
  for attempt in 1 2 3; do
    rm -f "$dir/release-current.json"
    code="$(curl -sS -o "$dir/release-current.json" -w '%{http_code}' --max-time 60 "https://files.cmux.com/$release?release=$GITHUB_RUN_ID-$attempt" || true)"
    case "$code" in
      200)
        python3 "$ptr" same-build --pointer "$signed" --current "$dir/release-current.json" --keys "$keys" "$@" || {
          echo "::error title=immutable-r2-conflict::$release already holds another build; it is never replaced"
          exit 1
        }
        # A Linux release file's sequence and version are the signing run's (same-build ignores them):
        # the channel gets the kept file's bytes, so it never names a version the commit's file lacks.
        if [[ "$purpose" == cmux-linux-release ]]; then
          cp "$dir/release-current.json" "$signed"
          echo "kept $release; the channel gets its bytes"
        fi
        break ;;
      404)
        rc=0
        upload "$release" "public, max-age=31536000, immutable" --write-once || rc=$?
        [[ $rc == 0 ]] && break
        [[ $rc == 9 ]] || exit "$rc"
        echo "Another run wrote $release first; reading it again." ;;
      *) echo "::error::$release could not be read (HTTP $code)"; exit 1 ;;
    esac
    [[ $attempt == 3 ]] && { echo "::error::$release kept changing under this run"; exit 1; }
  done
  curl -fsS --retry 3 --max-time 60 -o "$dir/release-check.json" "https://files.cmux.com/$release?check=$GITHUB_RUN_ID"
  python3 "$ptr" verify --pointer "$dir/release-check.json" --keys "$keys" --purpose "$purpose" --channel "$channel" \
    --allow-expired >/dev/null
  echo "$label -> $release" | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
}

if [[ -n "$release_tree" ]]; then
  # Before the commit's file and the channel, so neither names a tree without its signed release file.
  write_once "cmux-tui/tree/$release_tree/release.json" "Linux release file of tree ${release_tree:0:12}" --same-tree
fi
if [[ -n "${once:-}" ]]; then
  write_once "$once" "$once_label"
  [[ -z "$commit_only" ]] || exit 0
fi

for attempt in 1 2 3 4 5; do
  rm -f "$dir/current.json"
  code="$(curl -sS -o "$dir/current.json" -w '%{http_code}' --max-time 60 "https://files.cmux.com/$object?pointer=$GITHUB_RUN_ID-$attempt" || true)"
  case "$code" in
    200) mode=(--replace-sha256 "$(sha256sum "$dir/current.json" | cut -d' ' -f1)") ;;
    404) rm -f "$dir/current.json"; mode=(--write-once) ;;
    *) echo "::error::the $label could not be read (HTTP $code)"; exit 1 ;;
  esac
  tree_args=()
  if [[ -n "$tree_key" && -f "$dir/current.json" ]]; then
    # The commit the published file names, from its verified payload only (an unsigned file names nothing).
    current_commit="$(python3 "$ptr" verify --pointer "$dir/current.json" --keys "$keys" --purpose "$purpose" \
      --channel "$channel" --allow-expired 2>/dev/null | python3 -c 'import json, sys; print(json.load(sys.stdin)["commit"])' \
      2>/dev/null)" || current_commit=""
    if [[ "$current_commit" =~ ^[0-9a-f]{40}$ ]]; then
      current_tree_key="$(tree_key_of "$current_commit")"
      if [[ -n "$current_tree_key" ]]; then
        echo "tree key: $commit $tree_key, published $current_commit $current_tree_key"
        tree_args=(--tree-key "$tree_key" --current-tree-key "$current_tree_key")
      else
        echo "::warning::no tree key for the published $current_commit; the channel moves by commit time alone"
      fi
    fi
  fi
  rc=0
  python3 "$ptr" newer --pointer "$signed" --keys "$keys" --current "$dir/current.json" "${tree_args[@]}" || rc=$?
  [[ $rc == 3 ]] && exit 0
  [[ $rc == 0 ]] || exit "$rc"
  rc=0
  upload "$object" "public, max-age=60, must-revalidate" "${mode[@]}" || rc=$?
  [[ $rc == 0 ]] && break
  [[ $rc == 9 ]] || exit "$rc"
  echo "Another run moved the $label first; reading it again."
  [[ $attempt == 5 ]] && { echo "The channel kept changing under this run; the next push moves it."; exit 0; }
done
curl -fsS --retry 3 --max-time 60 -o "$dir/check.json" "https://files.cmux.com/$object?check=$GITHUB_RUN_ID"
python3 "$ptr" verify --pointer "$dir/check.json" --keys "$keys" --purpose "$purpose" --channel "$channel" >/dev/null
echo "$label -> ${commit:0:12}" | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
