#!/usr/bin/env bash
# Run the same upward-anchor browser harness against two production commits.
# The base result is expected to be red; the final result controls this script's exit status.
set -euo pipefail

if (( $# != 2 )); then
  echo "usage: $0 BASE_SHA FINAL_SHA" >&2
  exit 2
fi

base_sha=$1
final_sha=$2
sha_re='^[0-9a-f]{40}$'
if [[ ! $base_sha =~ $sha_re || ! $final_sha =~ $sha_re ]]; then
  echo "paired-upward-anchor: arguments must be full commit SHAs" >&2
  exit 2
fi

webviews_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
repo_root=$(cd "$webviews_root/.." && pwd)
harness_trace="$webviews_root/test/support/upwardAnchorTrace.ts"
harness_test="$webviews_root/test/transcript-upward-anchor.test.ts"
if [[ ! -f $harness_trace || ! -f $harness_test || ! -d $webviews_root/node_modules ]]; then
  echo "paired-upward-anchor: harness or runner dependencies are missing" >&2
  exit 3
fi

trace_hash=$(sha256sum "$harness_trace" | awk '{print $1}')
test_hash=$(sha256sum "$harness_test" | awk '{print $1}')
printf 'paired-upward-anchor: harness trace=%s test=%s\n' "$trace_hash" "$test_hash"

git fetch --no-tags --depth=1 origin "$base_sha"
git fetch --no-tags --depth=1 origin "$final_sha"

worktrees=()
cleanup() {
  local dir
  for dir in "${worktrees[@]}"; do
    git worktree remove --force "$dir" >/dev/null 2>&1 || true
    rm -rf "$dir"
  done
}
trap cleanup EXIT INT TERM

final_status=0
run_case() {
  local label=$1
  local sha=$2
  local dir log raw_line raw_file status
  dir=$(mktemp -d "${TMPDIR:-/tmp}/cmux-paired-anchor.XXXXXX")
  worktrees+=("$dir")
  git worktree add --detach "$dir" "$sha" >/dev/null
  mkdir -p "$dir/webviews/test/support"
  cp "$harness_trace" "$dir/webviews/test/support/upwardAnchorTrace.ts"
  cp "$harness_test" "$dir/webviews/test/transcript-upward-anchor.test.ts"
  ln -s "$webviews_root/node_modules" "$dir/webviews/node_modules"

  log="$dir/$label-chromium.log"
  raw_file="$dir/$label-chromium.json"
  printf 'paired-upward-anchor: case=%s source=%s\n' "$label" "$(git -C "$dir" rev-parse HEAD)"
  printf 'paired-upward-anchor: case=%s harness trace=%s test=%s\n' "$label" \
    "$(sha256sum "$dir/webviews/test/support/upwardAnchorTrace.ts" | awk '{print $1}')" \
    "$(sha256sum "$dir/webviews/test/transcript-upward-anchor.test.ts" | awk '{print $1}')"

  set +e
  (cd "$dir/webviews" && CMUX_BROWSER_TESTS=1 CMUX_SCROLL_ENGINE=chromium bun test test/transcript-upward-anchor.test.ts) >"$log" 2>&1
  status=$?
  set -e
  cat "$log"

  raw_line=$(grep -F 'transcript-upward-anchor: {' "$log" | tail -n 1 || true)
  if [[ -z $raw_line ]]; then
    echo "paired-upward-anchor: case=$label produced no raw trace" >&2
    return 3
  fi
  printf '%s\n' "${raw_line#*transcript-upward-anchor: }" >"$raw_file"
  if ! python3 - "$raw_file" "$label" "$sha" <<'PY'
import json
import sys

path, label, expected_sha = sys.argv[1:]
with open(path, encoding="utf-8") as stream:
    result = json.load(stream)
assert result["engine"] == "chromium", (label, result.get("engine"))
assert result["sourceRows"] == 9000, (label, result.get("sourceRows"))
assert result["turns"] == 3000, (label, result.get("turns"))
assert result["shownRows"] >= 9000, (label, result.get("shownRows"))
assert result["frames"] == 264, (label, result.get("frames"))
assert len(result["samples"]) == 264, (label, len(result.get("samples", [])))
print(json.dumps({
    "case": label,
    "source": expected_sha,
    "engine": result["engine"],
    "devicePixelRatio": result["calibration"]["devicePixelRatio"],
    "calibrationMaxAbsDelta": result["calibration"]["maxAbsDelta"],
    "frames": result["frames"],
    "compared": result["compared"],
    "blankFrames": result["blankFrames"],
    "maxDrift": result["maxDrift"],
    "maxAbsReadbackQuantization": result["maxAbsReadbackQuantization"],
    "status": "raw-validated",
}, separators=(",", ":")))
PY
  then
    echo "paired-upward-anchor: case=$label raw trace validation failed" >&2
    return 3
  fi
  printf 'paired-upward-anchor: case=%s raw=' "$label"
  cat "$raw_file"
  printf 'paired-upward-anchor: case=%s test_status=%s\n' "$label" "$status"
  if [[ $label == final && $status -ne 0 ]]; then
    final_status=$status
  fi
}

run_case base "$base_sha"
run_case final "$final_sha"
exit "$final_status"
