#!/usr/bin/env python3
"""Regression: page CLI and socket v2 stay in sync."""

import glob
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Dict, List, Tuple

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


def _resolve_socket_path() -> str:
    explicit = os.environ.get("CMUX_SOCKET")
    if explicit:
        return explicit

    tag = os.environ.get("CMUX_TAG")
    if tag:
        return f"/tmp/cmux-debug-{tag}.sock"

    raise cmuxError("Set CMUX_SOCKET or CMUX_TAG before running tests_v2 page parity against a tagged cmux build")


SOCKET_PATH = _resolve_socket_path()


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _find_cli_binary() -> str:
    env_cli = os.environ.get("CMUXTERM_CLI")
    if env_cli and os.path.isfile(env_cli) and os.access(env_cli, os.X_OK):
        return env_cli

    fixed = os.path.expanduser("~/Library/Developer/Xcode/DerivedData/cmux-tests-v2/Build/Products/Debug/cmux")
    if os.path.isfile(fixed) and os.access(fixed, os.X_OK):
        return fixed

    candidates = glob.glob(os.path.expanduser("~/Library/Developer/Xcode/DerivedData/**/Build/Products/Debug/cmux"), recursive=True)
    candidates += glob.glob("/tmp/cmux-*/Build/Products/Debug/cmux")
    candidates = [p for p in candidates if os.path.isfile(p) and os.access(p, os.X_OK)]
    if not candidates:
        raise cmuxError("Could not locate cmux CLI binary; set CMUXTERM_CLI")
    candidates.sort(key=lambda p: os.path.getmtime(p), reverse=True)
    return candidates[0]


def _run_cli(cli: str, args: List[str], json_output: bool) -> str:
    env = dict(os.environ)
    env.pop("CMUX_WORKSPACE_ID", None)
    env.pop("CMUX_SURFACE_ID", None)
    env.pop("CMUX_TAB_ID", None)

    cmd = [cli, "--socket", SOCKET_PATH]
    if json_output:
        cmd.append("--json")
    cmd.extend(args)

    proc = subprocess.run(cmd, capture_output=True, text=True, check=False, env=env)
    if proc.returncode != 0:
        merged = f"{proc.stdout}\n{proc.stderr}".strip()
        raise cmuxError(f"CLI failed ({' '.join(cmd)}): {merged}")
    return proc.stdout


def _run_cli_json(cli: str, args: List[str]) -> Dict:
    output = _run_cli(cli, args, json_output=True)
    try:
        return json.loads(output or "{}")
    except Exception as exc:  # noqa: BLE001
        raise cmuxError(f"Invalid JSON output for {' '.join(args)}: {output!r} ({exc})")


def _page_titles_and_selected(payload: Dict) -> Tuple[List[str], List[str]]:
    pages = payload.get("pages") or []
    titles = [str(page.get("title") or "") for page in pages]
    selected = [str(page.get("title") or "") for page in pages if bool(page.get("selected"))]
    return titles, selected


def _workspace_node(tree: Dict, workspace_id: str) -> Dict:
    windows = tree.get("windows") or []
    for window in windows:
        for workspace in window.get("workspaces") or []:
            if str(workspace.get("id") or "") == workspace_id:
                return workspace
    raise cmuxError(f"Workspace {workspace_id} not present in system.tree: {tree}")


def main() -> int:
    cli = _find_cli_binary()

    help_text = _run_cli(cli, ["list-pages", "--help"], json_output=False)
    _must("page:<n>" in help_text, "list-pages --help should mention page:<n> refs")
    _must("current-page" in help_text, "list-pages --help should mention related page commands")

    with cmux(SOCKET_PATH) as c:
        created = c._call("workspace.create", {}) or {}
        workspace_id = str(created.get("workspace_id") or "")
        _must(bool(workspace_id), f"workspace.create returned no workspace_id: {created}")

        try:
            c._call("workspace.select", {"workspace_id": workspace_id})

            initial = c._call("page.current", {"workspace_id": workspace_id}) or {}
            first_page_id = str(initial.get("page_id") or "")
            first_page_ref = str(initial.get("page_ref") or "")
            _must(bool(first_page_id) and bool(first_page_ref), f"page.current returned no initial page handle: {initial}")

            renamed = _run_cli_json(
                cli,
                ["rename-page", "--workspace", workspace_id, "--page", first_page_ref, "agents"],
            )
            _must(str(renamed.get("page_id") or "") == first_page_id, f"rename-page targeted wrong page: {renamed}")
            _must(str(renamed.get("page_title") or "") == "agents", f"rename-page did not set title: {renamed}")

            created_page = _run_cli_json(
                cli,
                ["new-page", "--workspace", workspace_id, "--title", "editor"],
            )
            second_page_id = str(created_page.get("page_id") or "")
            second_page_ref = str(created_page.get("page_ref") or "")
            _must(
                bool(second_page_id) and second_page_id != first_page_id,
                f"new-page did not create a distinct page: {created_page}",
            )
            _must(str(created_page.get("page_title") or "") == "editor", f"new-page did not set title: {created_page}")

            listed = c._call("page.list", {"workspace_id": workspace_id}) or {}
            titles, selected_titles = _page_titles_and_selected(listed)
            _must(titles == ["agents", "editor"], f"page.list returned unexpected titles after create: {listed}")
            _must(selected_titles == ["agents"], f"page.list should keep the current page selected after create: {listed}")
            _must(str(listed.get("page_id") or "") == first_page_id, f"page.list should mirror the unchanged active page: {listed}")

            selected = _run_cli_json(
                cli,
                ["select-page", "--workspace", workspace_id, "--page", first_page_ref],
            )
            _must(str(selected.get("page_id") or "") == first_page_id, f"select-page targeted wrong page: {selected}")

            current_after_select = c._call("page.current", {"workspace_id": workspace_id}) or {}
            _must(
                str(current_after_select.get("page_id") or "") == first_page_id,
                f"page.current disagrees with select-page: {current_after_select}",
            )

            duplicated = _run_cli_json(
                cli,
                ["duplicate-page", "--workspace", workspace_id, "--page", first_page_ref, "--title", "database"],
            )
            duplicate_page_id = str(duplicated.get("page_id") or "")
            duplicate_page_ref = str(duplicated.get("page_ref") or "")
            _must(
                bool(duplicate_page_id) and duplicate_page_id not in {first_page_id, second_page_id},
                f"duplicate-page did not create a distinct page: {duplicated}",
            )
            _must(str(duplicated.get("page_title") or "") == "database", f"duplicate-page did not set title: {duplicated}")

            reordered = c._call(
                "page.reorder",
                {"workspace_id": workspace_id, "page_id": duplicate_page_id, "index": 0},
            ) or {}
            _must(int(reordered.get("page_index", -1)) == 0, f"page.reorder did not move page to index 0: {reordered}")

            tree = c._call("system.tree", {"workspace_id": workspace_id}) or {}
            workspace = _workspace_node(tree, workspace_id)
            tree_titles = [str(page.get("title") or "") for page in (workspace.get("pages") or [])]
            _must(
                tree_titles == ["database", "agents", "editor"],
                f"system.tree page order did not match reorder result: {workspace}",
            )
            _must(
                str(workspace.get("selected_page_id") or "") == first_page_id,
                f"system.tree should keep the previously selected page active after duplicate/reorder: {workspace}",
            )

            last_page = c._call("page.last", {"workspace_id": workspace_id}) or {}
            _must(str(last_page.get("page_id") or "") == second_page_id, f"page.last should select editor: {last_page}")

            current_cli = _run_cli_json(cli, ["current-page", "--workspace", workspace_id])
            _must(
                str(current_cli.get("page_id") or "") == second_page_id,
                f"current-page CLI should agree with page.last: {current_cli}",
            )
            current_cli_text = _run_cli(cli, ["current-page", "--workspace", workspace_id], json_output=False).strip()
            _must(current_cli_text == second_page_ref, f"current-page text output should be the page ref: {current_cli_text!r}")

            closed = _run_cli_json(
                cli,
                ["close-page", "--workspace", workspace_id, "--page", duplicate_page_ref],
            )
            _must(str(closed.get("page_id") or "") == duplicate_page_id, f"close-page closed wrong page: {closed}")
            _must(
                str(closed.get("selected_page_id") or "") == second_page_id,
                f"close-page should preserve the selected page when closing an inactive page: {closed}",
            )

            final_list = _run_cli_json(cli, ["list-pages", "--workspace", workspace_id])
            final_titles, final_selected = _page_titles_and_selected(final_list)
            _must(final_titles == ["agents", "editor"], f"list-pages should reflect closed duplicate page: {final_list}")
            _must(final_selected == ["editor"], f"list-pages should keep editor selected after closing an inactive page: {final_list}")
            _must(str(final_list.get("page_id") or "") == second_page_id, f"list-pages active page mismatch after close: {final_list}")
            _must(
                second_page_ref.startswith("page:"),
                f"new-page should return a page ref handle: {created_page}",
            )
        finally:
            try:
                c.close_workspace(workspace_id)
            except Exception:
                pass

    print("PASS: page CLI and socket APIs stay consistent across create/select/reorder/close flows")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
