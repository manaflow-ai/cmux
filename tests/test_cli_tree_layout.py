#!/usr/bin/env python3
"""
Regression test: `cmux --json tree` emits a `layout` field per workspace that
carries the split geometry (direction + ratio + nesting) the flat `panes`
array cannot express.

The pane leaves reference the same pane `ref`s as the flat `panes` array, so a
consumer can recreate the real layout instead of guessing. This exercises the
round trip: a workspace is created with a KNOWN `--layout` and the emitted
`layout` is asserted to match it — the shape `--layout` accepts and the shape
`tree` emits are one schema.

Requires a running cmux app (socket up), like the other socket tests. Locate
the CLI via CMUX_CLI_BIN or the newest DerivedData Debug build.

Usage:
    python3 tests/test_cli_tree_layout.py
"""

from __future__ import annotations

import glob
import json
import os
import shutil
import subprocess
import time


def resolve_cmux_cli() -> str:
    explicit = os.environ.get("CMUX_CLI_BIN") or os.environ.get("CMUX_CLI")
    if explicit and os.path.exists(explicit) and os.access(explicit, os.X_OK):
        return explicit

    candidates: list[str] = []
    candidates.extend(
        glob.glob(os.path.expanduser("~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/*.app/Contents/Resources/bin/cmux"))
    )
    candidates.extend(glob.glob(os.path.expanduser("~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/cmux")))
    candidates = [p for p in candidates if os.path.exists(p) and os.access(p, os.X_OK)]
    if candidates:
        candidates.sort(key=os.path.getmtime, reverse=True)
        return candidates[0]

    in_path = shutil.which("cmux")
    if in_path:
        return in_path

    raise RuntimeError("Unable to find cmux CLI binary. Set CMUX_CLI_BIN.")


def run(cli_path: str, *args: str, timeout: float = 10.0) -> tuple[int, str, str]:
    env = dict(os.environ, CMUX_QUIET="1")
    try:
        proc = subprocess.run(
            [cli_path, *args],
            text=True,
            capture_output=True,
            check=False,
            timeout=timeout,
            env=env,
        )
    except subprocess.TimeoutExpired:
        return 124, "", f"timed out after {timeout:.1f}s"
    return proc.returncode, proc.stdout.strip(), proc.stderr.strip()


def _workspace_from_tree(tree_json: str, title: str) -> dict | None:
    tree = json.loads(tree_json)
    for window in tree.get("windows", []):
        for ws in window.get("workspaces", []):
            if ws.get("title") == title:
                return ws
    return None


def _wait_for_workspaces(cli_path: str, titles: list[str], timeout: float = 10.0) -> None:
    """Poll `tree` until each title materializes.

    `workspace create` returns before the workspace is queryable in the tree,
    so a fixed sleep is racy under CI load. Poll until every title appears (or
    the timeout lapses — the per-workspace assertions below then surface the
    missing one).
    """
    deadline = time.monotonic() + timeout
    pending = list(titles)
    while pending and time.monotonic() < deadline:
        code, out, _ = run(cli_path, "--json", "tree")
        if code == 0:
            pending = [t for t in pending if _workspace_from_tree(out, t) is None]
            if not pending:
                return
        time.sleep(0.1)


def _pane_refs(node: dict) -> list[str]:
    """In-order pane refs of a layout subtree."""
    if "pane" in node:
        return [node["pane"].get("ref")]
    refs: list[str] = []
    for child in node.get("children", []):
        refs.extend(_pane_refs(child))
    return refs


def main() -> int:
    try:
        cli = resolve_cmux_cli()
    except Exception as exc:
        print(f"FAIL: {exc}")
        return 1

    # A single-pane workspace's layout is a bare pane leaf; a nested
    # horizontal-over-vertical workspace must round-trip both directions.
    single_title = f"__cl_tree_layout_single_{os.getpid()}__"
    nested_title = f"__cl_tree_layout_nested_{os.getpid()}__"
    nested_layout = json.dumps(
        {
            "direction": "horizontal",
            "split": 0.6,
            "children": [
                {"pane": {"surfaces": [{"type": "terminal"}]}},
                {
                    "direction": "vertical",
                    "split": 0.5,
                    "children": [
                        {"pane": {"surfaces": [{"type": "terminal"}]}},
                        {"pane": {"surfaces": [{"type": "terminal"}]}},
                    ],
                },
            ],
        }
    )

    created: list[str] = []
    failures: list[str] = []

    def create(title: str, *extra: str) -> str | None:
        code, out, err = run(cli, "workspace", "create", "--name", title, "--focus", "false", *extra)
        if code != 0:
            failures.append(f"create {title!r} failed (exit {code}): {err or out}")
            return None
        ref = next((tok for tok in out.replace("\n", " ").split() if tok.startswith("workspace:")), None)
        if ref:
            created.append(ref)
        return ref

    try:
        single_ref = create(single_title)
        nested_ref = create(nested_title, "--layout", nested_layout)
        _wait_for_workspaces(
            cli,
            [t for t, r in ((single_title, single_ref), (nested_title, nested_ref)) if r],
        )

        # --- single pane: layout is a bare pane leaf ---
        if single_ref:
            code, out, err = run(cli, "--json", "tree", "--workspace", single_ref)
            ws = _workspace_from_tree(out, single_title) if code == 0 else None
            if ws is None:
                failures.append(f"single-pane workspace not found in tree (exit {code}): {err}")
            elif "layout" not in ws:
                failures.append("single-pane workspace has no `layout` field")
            else:
                layout = ws["layout"] or {}
                if "pane" not in layout:
                    failures.append(f"single-pane layout is not a bare pane leaf: {json.dumps(layout)}")
                else:
                    flat = [p.get("ref") for p in ws.get("panes", [])]
                    if _pane_refs(layout) != flat:
                        failures.append(
                            f"single-pane layout ref {_pane_refs(layout)} != flat panes {flat}"
                        )

        # --- nested H-over-V: both directions + nesting + ratios round-trip ---
        if nested_ref:
            code, out, err = run(cli, "--json", "tree", "--workspace", nested_ref)
            ws = _workspace_from_tree(out, nested_title) if code == 0 else None
            if ws is None:
                failures.append(f"nested workspace not found in tree (exit {code}): {err}")
            elif not ws.get("layout"):
                failures.append("nested workspace has no `layout` field")
            else:
                layout = ws["layout"]
                if layout.get("direction") != "horizontal":
                    failures.append(f"outer direction != horizontal: {layout.get('direction')}")
                if abs(float(layout.get("split", 0)) - 0.6) > 0.01:
                    failures.append(f"outer split != 0.6: {layout.get('split')}")
                children = layout.get("children", [])
                if len(children) != 2:
                    failures.append(f"outer split has {len(children)} children, want 2")
                else:
                    # child[0] is a leaf, child[1] is the nested vertical split
                    if "pane" not in children[0]:
                        failures.append("outer child[0] is not a pane leaf")
                    inner = children[1]
                    if inner.get("direction") != "vertical":
                        failures.append(f"inner direction != vertical: {inner.get('direction')}")
                    if len(inner.get("children", [])) != 2:
                        failures.append("inner vertical split does not have 2 children")

                # Every layout pane ref must appear in the flat panes array.
                flat = {p.get("ref") for p in ws.get("panes", [])}
                leaves = set(_pane_refs(layout))
                if leaves != flat:
                    failures.append(f"layout pane refs {sorted(leaves)} != flat panes {sorted(flat)}")
                if len(leaves) != 3:
                    failures.append(f"expected 3 pane leaves, got {len(leaves)}")
    finally:
        for ref in created:
            run(cli, "workspace", "close", ref)

    if failures:
        print("FAIL: tree --json layout")
        for f in failures:
            print(f"  - {f}")
        return 1

    print("PASS: tree --json emits faithful `layout` (single leaf + nested H/V, refs join to panes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
