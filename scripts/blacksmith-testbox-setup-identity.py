#!/usr/bin/env python3
"""Check the Testbox setup identity marker that the broker warmup writes.

The broker hydrates main, while a stage benchmarks whatever revision the
operator synchronized onto the box. Those two commits are deliberately allowed
to differ, so the marker is checked for VM identity, runner class, and
toolchain completeness, not for source equality.

usage: blacksmith-testbox-setup-identity.py <marker-path> <testbox-id> <setup-run-id>
"""
import json
import pathlib
import re
import sys

path, expected_testbox, expected_run_id = sys.argv[1:]
try:
    record = json.loads(pathlib.Path(path).read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError) as error:
    raise SystemExit(f"invalid setup identity marker: {error}")
source = record.get("source", {})
testbox = record.get("testbox", {})
runner = record.get("runner", {})
toolchain = record.get("toolchain", {})
errors = []
if not re.fullmatch(r"[0-9a-f]{40}", str(source.get("commit_sha", ""))):
    errors.append("setup hydration commit is missing or malformed")
if not re.fullmatch(r"[0-9a-f]{40}", str(source.get("tree_sha", ""))):
    errors.append("setup hydration tree is missing or malformed")
# cmux-tui builds libghostty-vt from the ghostty-next gitlink, and the broker
# records it as ghostty_next_gitlink_sha. A broker on main from before that
# switch records the classic ghostty_gitlink_sha instead. Accept that record
# for one transition; drop the fallback when the classic submodule is removed
# (CMUX-TUI-TREE-KEY-V2 B3).
if "ghostty_next_gitlink_sha" in source:
    label, gitlink_field, head_field = "ghostty-next", "ghostty_next_gitlink_sha", "ghostty_next_head_sha"
elif "ghostty_gitlink_sha" in source:
    label, gitlink_field, head_field = "classic Ghostty", "ghostty_gitlink_sha", "ghostty_head_sha"
    print("note: setup marker predates the ghostty-next switch; reading ghostty_gitlink_sha", file=sys.stderr)
else:
    label, gitlink_field, head_field = "ghostty-next", "ghostty_next_gitlink_sha", "ghostty_next_head_sha"
if not re.fullmatch(r"[0-9a-f]{40}", str(source.get(gitlink_field, ""))):
    errors.append(f"setup hydration {label} gitlink ({gitlink_field}) is missing or malformed")
elif source.get(head_field) != source.get(gitlink_field):
    errors.append(f"setup hydration {label} checkout does not match its own gitlink")
if source.get("ref") != "refs/heads/main":
    errors.append(f"setup hydration ref {source.get('ref')!r} is not refs/heads/main")
if testbox.get("id") != expected_testbox:
    errors.append("setup Testbox ID mismatch")
if str(testbox.get("setup_workflow_run_id")) != expected_run_id:
    errors.append("setup workflow run ID mismatch")
if runner.get("label") != "blacksmith-32vcpu-ubuntu-2404" or runner.get("arch") != "X64" or runner.get("cpu_count") != 32:
    errors.append("setup runner identity mismatch")
if not toolchain.get("rust_toolchain") or not toolchain.get("rustc") or not toolchain.get("cargo") or not toolchain.get("zig"):
    errors.append("setup toolchain identity is incomplete")
if errors:
    for error in errors:
        print(error, file=sys.stderr)
    raise SystemExit(66)
