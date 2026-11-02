#!/usr/bin/env bash
# Point cmux-tui/channels/<channel>.json at a published, daemon-tested tree:
# {"key", "commit", "binaries": {"cmux-tui-acpmux-<target>": sha256}}. Linux
# hosts read it to keep their daemon on the newest build by themselves
# (`acpmux host self-update`, run by their acpmux-update.timer). A tree without
# the daemon-tests.json marker is not pointed at.
#
# The pointer only moves forward, and fails closed: it moves when GitHub's
# compare says this commit is ahead of the one it names, or there is no file
# yet; behind, identical, diverged, a compare or read that fails, or a file that
# names no commit (not JSON, no or a malformed "commit") leaves it, exit 0. Every feat-cmux-next push runs this, several at
# once, so the write is a compare-and-swap on the bytes that were compared
# (upload-r2-object.py --replace-sha256, or --write-once for the first file):
# when another run wrote first, the pointer is read and compared again. No
# concurrency group serializes the runs: GitHub replaces a group's pending job
# with the next one to queue, which may be an older push's.
#
# Usage: cmux-tui-point-channel.sh <channel> <tree key>
# Env: R2_ENDPOINT and the R2 AWS_* credentials; GITHUB_SHA, GITHUB_RUN_ID,
# GITHUB_API_URL, GITHUB_REPOSITORY and GH_TOKEN (the compare).
# Caller: cmux-tui-artifacts.yml point-feat-channel.
set -euo pipefail

channel="${1:-}"
key="${2:-}"
[[ "$channel" =~ ^[a-z0-9-]+$ ]] || { echo "error: the channel is lowercase letters, digits and -" >&2; exit 2; }
[[ "$key" =~ ^[0-9a-f]{40}$ ]] || { echo "error: the tree key must be 40 lowercase hex characters" >&2; exit 2; }
script_dir="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
base="https://files.cmux.com/cmux-tui"
fetch() { # <url> <file>
  curl -fsSL --proto '=https' --connect-timeout 20 --max-time 60 -o "$2" "$1?channel=$GITHUB_RUN_ID"
}

if ! curl --head --fail --silent --proto '=https' --connect-timeout 20 --max-time 60 -o /dev/null \
    "$base/tree/$key/daemon-tests.json?channel=$GITHUB_RUN_ID"; then
  echo "Tree $key has no daemon-tests marker yet; the $channel channel stays where it is."
  exit 0
fi
fetch "$base/tree/$key/completion.json" "$tmp/completion.json"

python3 - "$key" "$tmp/completion.json" > "$tmp/channel.json" <<'PY'
import json, os, re, sys
key, path = sys.argv[1], sys.argv[2]
completion = json.load(open(path))
if completion.get("key") != key or not isinstance(completion.get("binaries"), dict):
    raise SystemExit(f"error: the completion.json of tree {key} names another key or no binaries")
binaries = {
    name: digest
    for name, digest in completion["binaries"].items()
    if name.startswith("cmux-tui-acpmux-") and isinstance(digest, str) and re.fullmatch(r"[0-9a-f]{64}", digest)
}
if not binaries:
    raise SystemExit(f"error: tree {key} lists no acpmux binaries")
print(json.dumps({"key": key, "commit": os.environ["GITHUB_SHA"], "binaries": binaries}, indent=2, sort_keys=True))
PY

# The channel's current file, read again on every attempt (a new query, so no
# cache answers it): "absent", "ok" with $tmp/current.json, or "unreadable".
read_current() { # <attempt>
  local code
  rm -f "$tmp/current.json"
  code="$(curl -sSL --proto '=https' --connect-timeout 20 --max-time 60 -o "$tmp/current.json" -w '%{http_code}' \
    "$base/channels/$channel.json?channel=$GITHUB_RUN_ID-$1" 2>/dev/null)" || code=000
  case "$code" in
    200) echo ok ;;
    404) echo absent ;;
    *) echo "unreadable ($code)" ;;
  esac
}

# What GitHub's compare says of this commit against <commit>: ahead, behind,
# identical, diverged, or empty when it could not be asked.
compare_status() { # <commit>
  curl -fsSL --proto '=https' --connect-timeout 20 --max-time 30 -H "Authorization: Bearer $GH_TOKEN" \
      -H 'Accept: application/vnd.github+json' \
      "$GITHUB_API_URL/repos/$GITHUB_REPOSITORY/compare/$1...$GITHUB_SHA" 2>/dev/null |
    python3 -c 'import json,sys; print(json.load(sys.stdin).get("status", ""))' 2>/dev/null || true
}

upload=(python3 "$script_dir/upload-r2-object.py" --file "$tmp/channel.json" --endpoint-url "$R2_ENDPOINT"
  --bucket cmux-binaries --key "cmux-tui/channels/$channel.json"
  --cache-control "no-cache, no-store, must-revalidate" --content-type application/json --conflict-exit-code 3)
for attempt in 1 2 3 4 5; do
  state="$(read_current "$attempt")"
  case "$state" in
    absent) mode=(--write-once) ;;
    ok)
      current="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("commit", ""))' "$tmp/current.json" 2>/dev/null || true)"
      if [[ ! "$current" =~ ^[0-9a-f]{40}$ ]]; then
        echo "The $channel channel names no commit this run can compare with; left as it is."
        exit 0
      fi
      if [[ "$current" == "$GITHUB_SHA" ]]; then
        echo "The $channel channel already names $GITHUB_SHA."
        exit 0
      fi
      status="$(compare_status "$current")"
      if [[ "$status" != ahead ]]; then
        echo "The $channel channel names $current, and $GITHUB_SHA is not ahead of it (compare: ${status:-unavailable}); left as it is."
        exit 0
      fi
      mode=(--replace-sha256 "$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$tmp/current.json")")
      ;;
    *)
      echo "The $channel channel could not be read ($state); left as it is."
      exit 0
      ;;
  esac
  rc=0
  "${upload[@]}" "${mode[@]}" || rc=$?
  if [[ "$rc" == 0 ]]; then
    echo "The $channel channel now names tree $key (commit $GITHUB_SHA)."
    exit 0
  fi
  [[ "$rc" == 3 ]] || exit "$rc"
  echo "Another run moved the $channel channel first; reading it again."
done
echo "The $channel channel kept changing under this run; left as it is (the next push moves it)."
