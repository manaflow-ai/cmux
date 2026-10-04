#!/usr/bin/env bash
# Times the lazy-hunks prototype's three sidecar calls (stdio RPC, the way the page calls them)
# on one fixture. Usage: lazy-stages.sh <repo> <sidecar-with-lazy-hunks> [runs]
set -euo pipefail
repo="$(realpath "$1")"
sidecar="$2"
runs="${3:-5}"
root="$(mktemp -d)"
chmod 700 "$root"
trap 'rm -rf "$root"' EXIT
token="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
printf '{"token":"%s","groupID":"perf","allowedRepoRoots":["%s"]}' "$token" "$repo" >"$root/.branch-session-perf.json"
call() { printf '%s' "$1" | "$sidecar" rpc --root "$root" --cmux /bin/false; }
median_ms() {
  local samples=()
  for _ in $(seq 1 "$runs"); do
    local start end
    start=$(date +%s%N); call "$1" >/dev/null; end=$(date +%s%N)
    samples+=($(( (end - start) / 1000000 )))
  done
  printf '%s\n' "${samples[@]}" | sort -n | awk '{a[NR]=$1} END {print a[int((NR+1)/2)]}'
}
summary_req=$(printf '{"id":"s","version":1,"method":"lazySummary","params":{"capabilityToken":"%s","repoRoot":"%s","baseRef":"HEAD~1"}}' "$token" "$repo")
summary=$(call "$summary_req")
base=$(printf '%s' "$summary" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["base"])')
files=$(printf '%s' "$summary" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["result"]["files"]))')
stats_req=$(printf '{"id":"t","version":1,"method":"lazyStats","params":{"capabilityToken":"%s","repoRoot":"%s","base":"%s"}}' "$token" "$repo" "$base")
paths=$(printf '%s' "$summary" | python3 -c 'import json,sys; print(json.dumps([f["path"] for f in json.load(sys.stdin)["result"]["files"] if not f["path"].startswith("big/") and "generated" not in f["path"]][:24]))')
patches_req=$(printf '{"id":"p","version":1,"method":"lazyPatches","params":{"capabilityToken":"%s","repoRoot":"%s","base":"%s","paths":%s}}' "$token" "$repo" "$base" "$paths")
patch_reply_bytes=$(call "$patches_req" | wc -c)
printf '{"repo":"%s","files":%s,"summaryMs":%s,"statsMs":%s,"patches24Ms":%s,"patches24ReplyKB":%s,"summaryReplyKB":%s}\n' "$(basename "$repo")" "$files" \
  "$(median_ms "$summary_req")" "$(median_ms "$stats_req")" "$(median_ms "$patches_req")" "$((patch_reply_bytes / 1024))" "$(( ${#summary} / 1024 ))"
