#!/usr/bin/env bash
set -euo pipefail

repo=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
bun=${BUN_BIN:-$(command -v bun || true)}
[ -n "$bun" ] || { echo 'code-mode-catalog-bench: bun is required' >&2; exit 2; }
out=${FAST_CHECKS_OUT:-$repo/.code-mode-catalog-bench}
mkdir -p "$out"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/cmux-code-mode-catalog-bench.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/build"
TARGET_BUILD_DIR="$tmp/build" UNLOCALIZED_RESOURCES_FOLDER_PATH=Resources SRCROOT="$repo" \
  bash "$repo/scripts/cmux-next/bundle-cli-resources.sh" > "$out/package.log"
python3 - "$repo/scripts/cmux-next/code-mode-catalog-bench.mjs" "$repo" "$tmp/build/Resources/code-mode" "$out/results.json" "$bun" <<'PY'
import json
import pathlib
import statistics
import subprocess
import sys

bench, repo, packaged, output, bun = sys.argv[1:]
def run(paths):
    rows = []
    for _ in range(20):
        rows.append(json.loads(subprocess.check_output([bun, bench, *paths], text=True)))
    result = {}
    for key in ('loaded_ms', 'lookup_ms', 'total_ms'):
        values = sorted(row[key] for row in rows)
        result[key + '_median'] = statistics.median(values)
        result[key + '_p95'] = values[max(0, int(len(values) * .95) - 1)]
    result['operation_count'] = rows[0]['operation_count']
    result['found'] = rows[0]['found']
    result['bytes'] = sum(pathlib.Path(path).stat().st_size for path in paths)
    return result

before_paths = [
    f'{repo}/cmux-tui/spec/resource-operations-v2.json',
    f'{repo}/backend/catalog/cloud-operations.json',
    f'{repo}/backend/catalog/cloud-relay-operations.json',
]
after_paths = [
    f'{packaged}/resource-operations-v2.json',
    f'{packaged}/cloud-operations.json',
    f'{packaged}/cloud-relay-operations.json',
]
result = {'before': run(before_paths), 'after': run(after_paths)}
assert result['before']['operation_count'] == result['after']['operation_count']
assert result['before']['found'] == result['after']['found']
pathlib.Path(output).write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
print(json.dumps(result, indent=2))
PY
