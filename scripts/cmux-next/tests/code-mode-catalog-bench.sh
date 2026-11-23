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
# Verify the packaged bytes still decode to exactly the source catalogs before timing.
bash "$repo/scripts/cmux-next/tests/compact-json.test.sh" > "$out/semantic-test.log"
python3 - "$repo/scripts/cmux-next/code-mode-catalog-bench.mjs" "$repo" "$tmp/build/Resources/code-mode" "$out/results.json" "$bun" <<'PY'
import json
import pathlib
import statistics
import subprocess
import sys

bench, repo, packaged, output, bun = sys.argv[1:]

def digest(path):
    import hashlib
    h = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()

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
samples = []
for index in range(20):
    # Interleave arms so runner/cache drift cannot bias one side.
    for label, paths in (("before", before_paths), ("after", after_paths)):
        started = __import__("time").monotonic_ns()
        raw = subprocess.check_output([bun, bench, *paths], text=True)
        process_ms = (__import__("time").monotonic_ns() - started) / 1_000_000
        row = json.loads(raw)
        row["process_ms"] = process_ms
        row["arm"] = label
        row["sample"] = index
        row["paths"] = paths
        row["sha256"] = {path: digest(path) for path in paths}
        row["bytes"] = sum(pathlib.Path(path).stat().st_size for path in paths)
        samples.append(row)

def summarize(label):
    rows = [row for row in samples if row["arm"] == label]
    result = {"samples": rows}
    for key in ('loaded_ms', 'lookup_ms', 'total_ms', 'process_ms'):
        values = sorted(row[key] for row in rows)
        result[key + '_median'] = statistics.median(values)
        result[key + '_p95'] = values[max(0, int(len(values) * .95) - 1)]
    result['operation_count'] = rows[0]['operation_count']
    result['found'] = rows[0]['found']
    result['bytes'] = rows[0]['bytes']
    return result

result = {"bun_version": subprocess.check_output([bun, "--version"], text=True).strip(), "before": summarize("before"), "after": summarize("after")}
assert result['before']['operation_count'] == result['after']['operation_count']
assert result['before']['found'] == result['after']['found']
pathlib.Path(output).write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
print(json.dumps({key: value for key, value in result.items() if key not in ('before', 'after')} | {"before": {key: value for key, value in result['before'].items() if key != 'samples'}, "after": {key: value for key, value in result['after'].items() if key != 'samples'}}, indent=2))
PY
