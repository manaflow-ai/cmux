#!/usr/bin/env bash
# Times the git-side stages for one fixture repo (plans/cmux-next/diff-perf.md):
# full patch generation (to /dev/null), patch write (to a file), the sidecar's whole
# sessionOpen RPC, and the summary-first / lazy-hunk alternatives.
# Usage: git-stages.sh <repo> <sidecar> [runs]   (Linux; prints one JSON line)
set -euo pipefail
repo="$1"
sidecar="$2"
runs="${3:-5}"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
mb="$(git -C "$repo" merge-base HEAD HEAD~1)"
diff_args=(-C "$repo" diff --no-ext-diff --no-color --binary "$mb" --)

# Median wall ms of a command over $runs runs.
median_ms() {
  local samples=()
  for _ in $(seq 1 "$runs"); do
    local start end
    start=$(date +%s%N)
    "$@" >/dev/null 2>&1
    end=$(date +%s%N)
    samples+=($(( (end - start) / 1000000 )))
  done
  printf '%s\n' "${samples[@]}" | sort -n | awk '{a[NR]=$1} END {print a[int((NR+1)/2)]}'
}

gen_ms=$(median_ms /usr/bin/git "${diff_args[@]}")
write_to_file() { /usr/bin/git "${diff_args[@]}" >"$out/p.patch"; }
write_ms=$(median_ms write_to_file)
patch_bytes=$(stat -c %s "$out/p.patch")
rss_kb=$( { /usr/bin/time -f '%M' /usr/bin/git "${diff_args[@]}" >/dev/null; } 2>&1 | tail -1)

# Summary-first candidates: raw (tree compare only), numstat (needs content diffs), both.
raw_ms=$(median_ms /usr/bin/git -C "$repo" diff --no-ext-diff --raw -z -M "$mb" --)
numstat_ms=$(median_ms /usr/bin/git -C "$repo" diff --no-ext-diff --numstat -z -M "$mb" --)
raw_numstat_ms=$(median_ms /usr/bin/git -C "$repo" diff --no-ext-diff --raw --numstat -z -M "$mb" --)
files=$(/usr/bin/git -C "$repo" diff --name-only "$mb" -- | wc -l)

# Lazy hunks: one small file, the first 40 files (a viewport and its overscan), the largest file.
first=$(/usr/bin/git -C "$repo" diff --numstat "$mb" -- | awk '$1+$2 < 200 && !done {print $3; done=1}')
mapfile -t first40 < <(/usr/bin/git -C "$repo" diff --name-only "$mb" -- | head -40)
largest=$(/usr/bin/git -C "$repo" diff --numstat "$mb" -- | awk '{print $1+$2, $3}' | sort -rn | awk 'NR==1 {print $2}')
one_ms=$(median_ms /usr/bin/git "${diff_args[@]}" "$first")
forty_ms=$(median_ms /usr/bin/git "${diff_args[@]}" "${first40[@]}")
largest_ms=$(median_ms /usr/bin/git "${diff_args[@]}" "$largest")
attr_ms=$(median_ms sh -c "/usr/bin/git -C '$repo' diff --name-only -z '$mb' -- | /usr/bin/git -C '$repo' check-attr -z --stdin linguist-generated diff")

# The sidecar's whole sessionOpen (rev-parse, merge-base, diff to file, check-attr, manifest).
root="$out/root"
mkdir -m 700 "$root"
token="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
printf '{"token":"%s","groupID":"perf","allowedRepoRoots":["%s"]}' "$token" "$(realpath "$repo")" >"$root/.branch-session-perf.json"
printf '<!doctype html>\n' >"$root/viewer.html"
printf '{"token":"%s","files":[{"request_path":"/viewer.html","file_path":"%s/viewer.html","mime_type":"text/html","remote_url":null}]}' "$token" "$root" >"$root/.manifest-$token.json"
protocol=$("$sidecar" handshake | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["value"]["protocolVersion"])')
request=$(printf '{"id":"perf","version":%s,"method":"sessionOpen","params":{"capabilityToken":"%s","source":{"kind":"branch","repoRoot":"%s","baseRef":"HEAD~1"}}}' "$protocol" "$token" "$(realpath "$repo")")
open_session() { printf '%s' "$request" | "$sidecar" rpc --root "$root" --cmux /bin/false; }
open_session | head -c 400 >"$out/open.json"
session_ms=$(median_ms open_session)

printf '{"repo":"%s","files":%s,"patchMB":%.1f,"gitDiffMs":%s,"gitDiffToFileMs":%s,"gitDiffRssMB":%.0f,"rawMs":%s,"numstatMs":%s,"rawNumstatMs":%s,"onePatchMs":%s,"first40PatchMs":%s,"largestPatchMs":%s,"largest":"%s","checkAttrMs":%s,"sidecarSessionOpenMs":%s,"openReply":%s}\n' \
  "$(basename "$repo")" "$files" "$(echo "$patch_bytes / 1048576" | bc -l)" "$gen_ms" "$write_ms" "$(echo "$rss_kb / 1024" | bc -l)" \
  "$raw_ms" "$numstat_ms" "$raw_numstat_ms" "$one_ms" "$forty_ms" "$largest_ms" "$largest" "$attr_ms" "$session_ms" \
  "$(python3 -c 'import json,sys; s=open(sys.argv[1]).read(); print(json.dumps(s[:200]))' "$out/open.json")"
