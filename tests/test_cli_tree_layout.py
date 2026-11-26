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

from collections import Counter
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


def _wait_for_workspaces(
    cli_path: str, titles: list[str], timeout: float = 10.0
) -> dict[str, dict]:
    """Poll `tree` until each title materializes.

    `workspace create` returns before the workspace is queryable in the tree,
    so a fixed sleep is racy under CI load. Poll until every title appears (or
    the timeout lapses — the per-workspace assertions below then surface the
    missing one).
    """
    deadline = time.monotonic() + timeout
    found: dict[str, dict] = {}
    while len(found) < len(titles) and time.monotonic() < deadline:
        code, out, _ = run(cli_path, "--json", "--id-format", "both", "tree")
        if code == 0:
            for title in titles:
                workspace = _workspace_from_tree(out, title)
                if workspace is not None:
                    found[title] = workspace
            if len(found) == len(titles):
                return found
        time.sleep(0.1)
    return found


def _pane_handles(node: dict) -> list[tuple[str | None, str | None]]:
    """In-order ``(id, ref)`` pane handles of a layout subtree."""
    if "pane" in node:
        pane = node["pane"]
        return [(pane.get("id"), pane.get("ref"))]
    handles: list[tuple[str | None, str | None]] = []
    for child in node.get("children", []):
        handles.extend(_pane_handles(child))
    return handles


def _flat_pane_handles(workspace: dict) -> list[tuple[str | None, str | None]]:
    """Pane ``(id, ref)`` pairs from a workspace's flat payload."""
    return [(pane.get("id"), pane.get("ref")) for pane in workspace.get("panes", [])]


def _has_nonempty_handles(handles: list[tuple[str | None, str | None]]) -> bool:
    """Whether every handle has both an ID and a ref under ``--id-format both``."""
    return bool(handles) and all(
        isinstance(pane_id, str)
        and bool(pane_id)
        and isinstance(pane_ref, str)
        and bool(pane_ref)
        for pane_id, pane_ref in handles
    )


def _has_dock_panes(workspace: dict) -> bool:
    """Whether the flat pane list includes a pane from a separate Dock tree."""
    return any(pane.get("dock_scope") is not None for pane in workspace.get("panes", []))


def _dock_surface_ids(workspace: dict) -> set[str]:
    """IDs of surfaces in the workspace's authoritative Dock pane rows."""
    return {
        surface_id
        for pane in workspace.get("panes", [])
        if pane.get("dock_scope") is not None
        for surface in pane.get("surfaces", [])
        if isinstance(surface_id := surface.get("id"), str) and surface_id
    }


def _wait_for_dock_panes(
    cli_path: str,
    workspace_ref: str,
    title: str,
    *,
    expected_surface_id: str | None = None,
    baseline_surface_ids: set[str] | None = None,
    timeout: float = 10.0,
) -> dict | None:
    """Poll until a workspace exposes at least one Dock pane in its tree."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        code, out, _ = run(
            cli_path,
            "--json",
            "--id-format",
            "both",
            "tree",
            "--workspace",
            workspace_ref,
        )
        if code == 0:
            workspace = _workspace_from_tree(out, title)
            if workspace is not None and _has_dock_panes(workspace):
                surface_ids = _dock_surface_ids(workspace)
                if expected_surface_id is not None and expected_surface_id not in surface_ids:
                    time.sleep(0.1)
                    continue
                if (
                    expected_surface_id is None
                    and baseline_surface_ids is not None
                    and not surface_ids.difference(baseline_surface_ids)
                ):
                    time.sleep(0.1)
                    continue
                return workspace
        time.sleep(0.1)
    return None


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
    dock_title = f"__cl_tree_layout_dock_{os.getpid()}__"
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
    created_titles: list[str] = []
    dock_surfaces: list[tuple[str, str]] = []
    dock_baseline_surface_ids: set[str] = set()
    failures: list[str] = []

    def create(title: str, *extra: str) -> str | None:
        code, out, err = run(cli, "workspace", "create", "--name", title, "--focus", "false", *extra)
        if code != 0:
            failures.append(f"create {title!r} failed (exit {code}): {err or out}")
            return None
        created_titles.append(title)
        ref = next((tok for tok in out.replace("\n", " ").split() if tok.startswith("workspace:")), None)
        if ref is None:
            failures.append(f"create {title!r} returned no workspace reference: {out or '<no output>'}")
            return None
        created.append(ref)
        return ref

    try:
        single_ref = create(single_title)
        nested_ref = create(nested_title, "--layout", nested_layout)
        dock_ref = create(dock_title)
        snapshots = _wait_for_workspaces(cli, created_titles)
        # If a successful create did not print a ref, retain a cleanup handle
        # from the authoritative tree snapshot once the workspace materializes.
        for workspace in snapshots.values():
            ref = workspace.get("ref")
            if isinstance(ref, str) and ref not in created:
                created.append(ref)
        if dock_title in snapshots:
            dock_baseline_surface_ids = _dock_surface_ids(snapshots[dock_title])

        # --- single pane: layout is a bare pane leaf ---
        if single_ref:
            code, out, err = run(
                cli,
                "--json",
                "--id-format",
                "both",
                "tree",
                "--workspace",
                single_ref,
            )
            ws = _workspace_from_tree(out, single_title) if code == 0 else None
            if ws is None:
                failures.append(f"single-pane workspace not found in tree (exit {code}): {err}")
            elif "layout" not in ws:
                failures.append("single-pane workspace has no `layout` field")
            elif ws["layout"] is None:
                if not _has_dock_panes(ws):
                    failures.append("single-pane workspace has unavailable `layout` without Dock panes")
            else:
                layout = ws["layout"]
                if "pane" not in layout:
                    failures.append(f"single-pane layout is not a bare pane leaf: {json.dumps(layout)}")
                else:
                    flat_handles = _flat_pane_handles(ws)
                    layout_handles = _pane_handles(layout)
                    if layout_handles != flat_handles:
                        failures.append(
                            f"single-pane layout handles {layout_handles} != flat panes {flat_handles}"
                        )
                    if not _has_nonempty_handles(flat_handles) or not _has_nonempty_handles(layout_handles):
                        failures.append("single-pane layout omitted a nonempty pane id/ref under --id-format both")

        # --- nested H-over-V: both directions + nesting + ratios round-trip ---
        if nested_ref:
            code, out, err = run(
                cli,
                "--json",
                "--id-format",
                "both",
                "tree",
                "--workspace",
                nested_ref,
            )
            ws = _workspace_from_tree(out, nested_title) if code == 0 else None
            if ws is None:
                failures.append(f"nested workspace not found in tree (exit {code}): {err}")
            elif "layout" not in ws:
                failures.append("nested workspace has no `layout` field")
            elif ws["layout"] is None:
                if not _has_dock_panes(ws):
                    failures.append("nested workspace has unavailable `layout` without Dock panes")
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
                    if not isinstance(children[0], dict) or "pane" not in children[0]:
                        failures.append("outer child[0] is not a pane leaf")
                    inner = children[1]
                    if not isinstance(inner, dict):
                        failures.append("outer child[1] is not a split node")
                    else:
                        if inner.get("direction") != "vertical":
                            failures.append(f"inner direction != vertical: {inner.get('direction')}")
                        try:
                            inner_split = float(inner.get("split", 0))
                        except (TypeError, ValueError):
                            inner_split = None
                        if inner_split is None or abs(inner_split - 0.5) > 0.01:
                            failures.append(f"inner split != 0.5: {inner.get('split')}")
                        inner_children = inner.get("children", [])
                        if len(inner_children) != 2:
                            failures.append("inner vertical split does not have 2 children")
                        elif not all(isinstance(child, dict) and "pane" in child for child in inner_children):
                            failures.append("inner vertical split children are not pane leaves")

                # Every layout pane (ID + ref) must appear in the flat panes array.
                flat_handles = _flat_pane_handles(ws)
                leaves = _pane_handles(layout)
                if Counter(leaves) != Counter(flat_handles):
                    failures.append(f"layout pane handles {leaves} != flat panes {flat_handles}")
                if not _has_nonempty_handles(flat_handles) or not _has_nonempty_handles(leaves):
                    failures.append("nested layout omitted a nonempty pane id/ref under --id-format both")
                if len(leaves) != 3:
                    failures.append(f"expected 3 pane leaves, got {len(leaves)}")

        # Exercise the fail-closed path for a workspace whose flat pane list
        # includes a separate Dock tree. Keep the created Dock surface handle
        # so cleanup does not leave a global Dock panel behind. This runs after
        # the ordinary layout assertions so the global Dock cannot contaminate
        # their workspace snapshots.
        if dock_ref:
            code, out, err = run(
                cli,
                "--json",
                "new-pane",
                "--placement",
                "dock",
                "--workspace",
                dock_ref,
                "--focus",
                "false",
            )
            if code != 0:
                failures.append(f"create Dock pane failed (exit {code}): {err or out}")
            else:
                try:
                    dock_payload = json.loads(out)
                except json.JSONDecodeError:
                    dock_payload = {}
                dock_pane_id = dock_payload.get("dock_pane_id")
                if not isinstance(dock_pane_id, str) or not dock_pane_id:
                    dock_pane_id = None
                dock_surface_id = dock_payload.get("dock_surface_id")
                if not isinstance(dock_surface_id, str) or not dock_surface_id:
                    dock_surface_id = None
                if dock_surface_id is not None:
                    # Retain the response handle immediately so a later tree
                    # timeout cannot strand the newly created Dock surface.
                    dock_surfaces.append((dock_ref, dock_surface_id))
                dock_workspace = _wait_for_dock_panes(
                    cli,
                    dock_ref,
                    dock_title,
                    expected_surface_id=dock_surface_id,
                    baseline_surface_ids=dock_baseline_surface_ids,
                )
                if dock_workspace is None:
                    failures.append("Dock workspace did not expose a Dock pane in tree")
                elif dock_workspace.get("layout") is not None:
                    failures.append("Dock workspace emitted a partial `layout` instead of null")
                elif not _has_dock_panes(dock_workspace):
                    failures.append("Dock workspace tree did not mark its Dock pane")
                else:
                    flat_panes = dock_workspace.get("panes", [])
                    flat_pane_ids = {pane.get("id") for pane in flat_panes}
                    if dock_pane_id is not None and dock_pane_id not in flat_pane_ids:
                        failures.append(
                            f"Dock pane id {dock_pane_id!r} is absent from flat pane ids {sorted(flat_pane_ids)}"
                        )
                    if not all(isinstance(pane.get("ref"), str) and pane["ref"] for pane in flat_panes):
                        failures.append("Dock workspace has a pane without a nonempty flat `ref`")
                    dock_surface_ids = _dock_surface_ids(dock_workspace)
                    if dock_surface_id is None:
                        # The create response normally includes dock_surface_id,
                        # but the authoritative tree is the cleanup fallback if
                        # a transport/formatter drops that field. Prefer a new
                        # surface over any Dock surface that predated this test.
                        candidates = dock_surface_ids.difference(dock_baseline_surface_ids)
                        if dock_pane_id is not None:
                            dock_pane = next(
                                (pane for pane in flat_panes if pane.get("id") == dock_pane_id),
                                None,
                            )
                            pane_surface_ids = {
                                surface_id
                                for surface in (dock_pane or {}).get("surfaces", [])
                                if isinstance(surface_id := surface.get("id"), str) and surface_id
                            }
                            candidates = pane_surface_ids.difference(dock_baseline_surface_ids) or pane_surface_ids
                        if len(candidates) == 1:
                            dock_surface_id = next(iter(candidates))
                        elif not candidates:
                            failures.append(
                                "Dock pane create returned no surface id and tree had no unambiguous new Dock surface"
                            )
                        else:
                            failures.append(
                                "Dock pane create returned no surface id and tree had ambiguous "
                                f"Dock surfaces: {sorted(candidates)}"
                            )
                    elif dock_surface_id not in dock_surface_ids:
                        failures.append(
                            f"Dock surface id {dock_surface_id!r} is absent from authoritative "
                            f"Dock surfaces {sorted(dock_surface_ids)}"
                        )
                    if dock_surface_id is not None and (dock_ref, dock_surface_id) not in dock_surfaces:
                        dock_surfaces.append((dock_ref, dock_surface_id))
    finally:
        for workspace_ref, surface_ref in dock_surfaces:
            close_code, close_out, close_err = run(
                cli,
                "close-surface",
                "--workspace",
                workspace_ref,
                "--surface",
                surface_ref,
            )
            if close_code != 0:
                failures.append(
                    f"close Dock surface {surface_ref!r} failed (exit {close_code}): {close_err or close_out}"
                )
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
