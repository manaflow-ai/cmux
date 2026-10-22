#!/usr/bin/env bash
# Point cmux-tui/channels/<channel>.json at a published, daemon-tested tree:
# {"key", "commit", "binaries": {"cmux-tui-acpmux-<target>": sha256}}. Linux
# hosts read it to keep their daemon on the newest build by themselves
# (`acpmux host self-update`, run by their acpmux-update.timer). A tree without
# the daemon-tests.json marker is not pointed at, and the pointer only moves
# forward: a commit behind the one it names leaves it alone.
#
# Usage: cmux-tui-point-channel.sh <channel> <tree key>
# Env: R2_ENDPOINT and the R2 AWS_* credentials; GITHUB_SHA, GITHUB_RUN_ID,
# GITHUB_API_URL, GITHUB_REPOSITORY and GH_TOKEN (the forward-only check).
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

if fetch "$base/channels/$channel.json" "$tmp/current.json" 2>/dev/null; then
  current="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("commit", ""))' "$tmp/current.json" 2>/dev/null || true)"
  if [[ "$current" =~ ^[0-9a-f]{40}$ && "$current" != "$GITHUB_SHA" ]]; then
    status="$(curl -fsSL --proto '=https' --max-time 30 -H "Authorization: Bearer $GH_TOKEN" \
        -H 'Accept: application/vnd.github+json' \
        "$GITHUB_API_URL/repos/$GITHUB_REPOSITORY/compare/$current...$GITHUB_SHA" |
      python3 -c 'import json,sys; print(json.load(sys.stdin).get("status", ""))' 2>/dev/null || true)"
    if [[ "$status" == behind ]]; then
      echo "The $channel channel names $current, which is newer than $GITHUB_SHA; left as it is."
      exit 0
    fi
  fi
fi

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
python3 "$script_dir/upload-r2-object.py" --file "$tmp/channel.json" --endpoint-url "$R2_ENDPOINT" \
  --bucket cmux-binaries --key "cmux-tui/channels/$channel.json" \
  --cache-control "no-cache, no-store, must-revalidate" --content-type application/json
echo "The $channel channel now names tree $key (commit $GITHUB_SHA)."
