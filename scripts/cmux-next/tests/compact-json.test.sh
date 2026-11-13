#!/usr/bin/env bash
set -euo pipefail

repo=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/cmux-compact-json.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
source="$tmp/source.json"
dest="$tmp/dest.json"
printf '{\n  "operations": { "one": { "class": "read" } },\n  "unicode": "✓"\n}\n' > "$source"
python3 "$repo/scripts/cmux-next/compact-json.py" "$source" "$dest" >/dev/null
python3 - "$source" "$dest" <<'PY'
import json
import pathlib
import sys
source, dest = map(pathlib.Path, sys.argv[1:])
assert json.loads(source.read_text(encoding="utf-8")) == json.loads(dest.read_text(encoding="utf-8"))
assert dest.read_text(encoding="utf-8") == '{"operations":{"one":{"class":"read"}},"unicode":"✓"}\n'
assert dest.stat().st_size < source.stat().st_size
assert dest.stat().st_mode & 0o777 == source.stat().st_mode & 0o777
PY
for source in \
  "$repo/cmux-tui/spec/resource-operations-v2.json" \
  "$repo/backend/catalog/cloud-operations.json" \
  "$repo/backend/catalog/cloud-relay-operations.json"; do
  out="$tmp/$(basename "$source")"
  python3 "$repo/scripts/cmux-next/compact-json.py" "$source" "$out" >/dev/null
  python3 - "$source" "$out" <<'PY'
import json
import pathlib
import sys
source, out = map(pathlib.Path, sys.argv[1:])
assert json.loads(source.read_text(encoding="utf-8")) == json.loads(out.read_text(encoding="utf-8"))
PY
done
printf 'compact-json: pass\n'
