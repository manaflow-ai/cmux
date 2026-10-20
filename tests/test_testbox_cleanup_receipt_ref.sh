#!/usr/bin/env bash
# The Testbox inventory always shows the warmup ref, which the broker lane pins
# to main, while the receipt also records the branch being benchmarked. Cleanup
# must compare the inventory against the warmup ref. Comparing it against the
# benchmarked branch made every receipt-bound cleanup exit 66, which pushed
# operators toward a bare `blacksmith testbox stop` and away from the ownership
# check.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cleanup="$root/scripts/blacksmith-testbox-cleanup.sh"
test -x "$cleanup"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

tbx="tbx_01testfixture0000000000000"
token="0123456789abcdef0123456789abcdef"
workflow=".github/workflows/cmux-tui-testbox-warmup.yml"
job="cmux-tui-rust"
sha="1111111111111111111111111111111111111111"
tree="2222222222222222222222222222222222222222"
ghostty="3333333333333333333333333333333333333333"

evidence="$work/evidence"
mkdir -p "$evidence"
cat >"$evidence/testbox-receipt.json" <<JSON
{
  "schema": 2,
  "testbox_id": "$tbx",
  "confirmation_token": "$token",
  "workflow": "$workflow",
  "job": "$job",
  "warmup_ref": "main",
  "source_ref": "feature-branch-under-test",
  "source_sha": "$sha",
  "source_tree_sha": "$tree",
  "ghostty_gitlink_sha": "$ghostty"
}
JSON

# Stub CLI: the inventory and status rows carry the warmup ref, exactly as the
# real `blacksmith testbox list` does for a box warmed with --ref main.
stub="$work/bin"
mkdir -p "$stub"
cat >"$stub/blacksmith" <<STUB
#!/usr/bin/env bash
case "\$2" in
  list)
    echo "ID STATUS REPO WORKFLOW JOB REF CREATED"
    echo "$tbx stopped cmux $workflow $job main 2026-08-18T00:00:00.000000Z"
    ;;
  status)
    echo "ID STATUS REPO WORKFLOW JOB REF CREATED"
    echo "$tbx stopped cmux $workflow $job main 2026-08-18T00:00:00.000000Z"
    ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$stub/blacksmith"

set +e
PATH="$stub:$PATH" "$cleanup" "$tbx" "$evidence" "$token" PREVIEW >"$work/preview.log" 2>&1
status=$?
set -e

if (( status == 66 )); then
  echo "FAIL: cleanup rejected its own receipt; it is comparing the inventory" >&2
  echo "      against the benchmarked branch instead of the warmup ref." >&2
  sed -n '1,20p' "$work/preview.log" >&2
  exit 1
fi
# 75 is the preview's own "reviewed nothing yet, rerun with STOP:<sha>" exit.
if (( status != 75 )); then
  echo "FAIL: cleanup preview exited $status, expected 75" >&2
  sed -n '1,20p' "$work/preview.log" >&2
  exit 1
fi
grep -q 'ref=main' "$work/preview.log" || {
  echo "FAIL: preview did not report the warmup ref it validated against" >&2
  exit 1
}
test -s "$evidence/cleanup-preview.json" || {
  echo "FAIL: preview produced no cleanup-preview.json" >&2
  exit 1
}
# The destruction record must not pair the warmup ref with the benchmarked SHA.
python3 - "$evidence/cleanup-preview.json" <<'PYCHK'
import json
import pathlib
import sys

record = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
errors = []
if record.get("warmup_ref") != "main":
    errors.append(f"warmup_ref is {record.get('warmup_ref')!r}, expected 'main'")
if record.get("source_ref") != "feature-branch-under-test":
    errors.append(f"source_ref is {record.get('source_ref')!r}, expected the benchmarked branch")
if errors:
    for error in errors:
        print(f"FAIL: {error}", file=sys.stderr)
    raise SystemExit(1)
PYCHK
echo "ok: receipt-bound cleanup preview accepts a main-warmed box benchmarked from a branch"
