#!/usr/bin/env bash
# The broker warmup records which Ghostty source it hydrated. cmux-tui builds
# libghostty-vt from the ghostty-next gitlink, so the marker names that gitlink
# (ghostty_next_gitlink_sha). A broker on main that predates the switch still
# writes the classic ghostty_gitlink_sha; the stage accepts that record for one
# transition so a box warmed from main keeps working.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
helper="$root/scripts/blacksmith-testbox-setup-identity.py"
test -x "$helper"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

tbx="tbx_01testfixture0000000000000"
run_id="123456789"
commit="1111111111111111111111111111111111111111"
tree="2222222222222222222222222222222222222222"
gitlink="3333333333333333333333333333333333333333"
other="4444444444444444444444444444444444444444"

# write_marker <path> <ghostty field prefix or "none"> <gitlink> <head>
write_marker() {
  python3 - "$@" "$tbx" "$run_id" "$commit" "$tree" <<'PY'
import json
import pathlib
import sys

path, prefix, gitlink, head, tbx, run_id, commit, tree = sys.argv[1:]
source = {"ref": "refs/heads/main", "commit_sha": commit, "tree_sha": tree}
if prefix != "none":
    source[f"{prefix}_gitlink_sha"] = gitlink
    source[f"{prefix}_head_sha"] = head
record = {
    "schema": 4 if prefix == "ghostty_next" else 3,
    "source": source,
    "testbox": {"id": tbx, "setup_workflow_run_id": run_id},
    "runner": {"label": "blacksmith-32vcpu-ubuntu-2404", "arch": "X64", "cpu_count": 32},
    "toolchain": {"rust_toolchain": "1.95.0", "rustc": "rustc 1.95.0", "cargo": "cargo 1.95.0", "zig": "0.15.2"},
}
pathlib.Path(path).write_text(json.dumps(record), encoding="utf-8")
PY
}

failures=0
# expect <name> <exit> <stderr substring or ""> <marker>
expect() {
  local name="$1" want="$2" needle="$3" marker="$4" status
  set +e
  python3 "$helper" "$marker" "$tbx" "$run_id" >"$work/out" 2>"$work/err"
  status=$?
  set -e
  if (( status != want )); then
    echo "FAIL: $name: exit $status, expected $want" >&2
    sed -n '1,10p' "$work/err" >&2
    failures=$((failures + 1))
    return
  fi
  if [[ -n "$needle" ]] && ! grep -qF -- "$needle" "$work/err"; then
    echo "FAIL: $name: stderr does not name '$needle'" >&2
    sed -n '1,10p' "$work/err" >&2
    failures=$((failures + 1))
    return
  fi
  echo "ok: $name"
}

write_marker "$work/next.json" ghostty_next "$gitlink" "$gitlink"
expect "ghostty-next marker is accepted" 0 "" "$work/next.json"

write_marker "$work/classic.json" ghostty "$gitlink" "$gitlink"
expect "classic marker from a pre-switch main broker is accepted" 0 "" "$work/classic.json"

write_marker "$work/next-mismatch.json" ghostty_next "$gitlink" "$other"
expect "ghostty-next checkout that differs from its gitlink is refused" 66 "ghostty-next" "$work/next-mismatch.json"

write_marker "$work/classic-mismatch.json" ghostty "$gitlink" "$other"
expect "classic checkout that differs from its gitlink is refused" 66 "Ghostty" "$work/classic-mismatch.json"

write_marker "$work/none.json" none "$gitlink" "$gitlink"
expect "marker without any Ghostty gitlink is refused" 66 "ghostty-next" "$work/none.json"

(( failures == 0 )) || { echo "$failures setup identity case(s) failed" >&2; exit 1; }
