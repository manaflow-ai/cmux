#!/usr/bin/env bash
# Compare identical painted-frame oracles against base and this captured source tree.
set -euo pipefail

base_sha=${1:?usage: fractional-anchor-paired.hosted.sh BASE_SHA}
[[ $base_sha =~ ^[0-9a-f]{40}$ ]] || exit 2
repo_root=$(git rev-parse --show-toplevel)
webviews_root="$repo_root/webviews"
git fetch --no-tags --depth=1 origin "$base_sha"
base_dir=$(mktemp -d /tmp/cmux-fractional-anchor-base.XXXXXXXX)
cleanup() {
  git worktree remove --force "$base_dir" >/dev/null 2>&1 || true
  rm -rf "$base_dir"
}
trap cleanup EXIT
git worktree add --detach "$base_dir" "$base_sha"
for file in test/support/upwardAnchorTrace.ts test/transcript-upward-anchor.test.ts; do
  cp "$webviews_root/$file" "$base_dir/webviews/$file"
  sha256sum "$webviews_root/$file" "$base_dir/webviews/$file"
done
ln -s "$webviews_root/node_modules" "$base_dir/webviews/node_modules"

final_status=0
for engine in webkit chromium; do
  for label in base final; do
    source_dir=$repo_root
    [[ $label != base ]] || source_dir=$base_dir
    log=$(mktemp /tmp/cmux-fractional-anchor-log.XXXXXXXX)
    printf 'fractional-anchor: label=%s engine=%s source=%s tree=%s\n' \
      "$label" "$engine" "$(git -C "$source_dir" rev-parse HEAD)" "$(git -C "$source_dir" rev-parse HEAD^{tree})"
    status=0
    (cd "$source_dir/webviews" && CMUX_BROWSER_TESTS=1 CMUX_SCROLL_ENGINE="$engine" \
      bun test test/transcript-upward-anchor.test.ts) > "$log" 2>&1 || status=$?
    cat "$log"
    python3 - "$log" "$label" "$engine" <<'PY'
import json
import sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
raw = [line.split("transcript-upward-anchor: ", 1)[1] for line in lines
       if "transcript-upward-anchor: {" in line]
assert len(raw) == 1, "missing or duplicate painted-frame trace"
result = json.loads(raw[0])
assert result["engine"] == sys.argv[3]
assert result["sourceRows"] == 9000 and result["turns"] == 3000
assert result["shownRows"] >= 9000 and result["frames"] == 264
assert len(result["samples"]) == 264
print("fractional-anchor-summary: " + json.dumps({
    "label": sys.argv[2], "engine": sys.argv[3],
    **{key: result[key] for key in ["frames", "compared", "blankFrames", "maxDrift", "totalDrift"]}
}))
if sys.argv[2] == "final":
    assert result["blankFrames"] == 0
    assert result["compared"] == result["frames"]
    assert result["maxDrift"] <= 1 / 64
PY
    rm "$log"
    if [[ $label == final && $status != 0 ]]; then final_status=$status; fi
  done
done
exit "$final_status"
