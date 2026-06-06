#!/usr/bin/env python3
"""Regression: page CLI and socket v2 stay in sync."""

import glob
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Dict, List, Optional, Tuple

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET_PATH", "/tmp/cmux-debug.sock")


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


def _run_cli(cli: str, args: List[str], json_output: bool, cwd: Optional[str] = None) -> str:
    env = dict(os.environ)
    env.pop("CMUX_WORKSPACE_ID", None)
    env.pop("CMUX_SURFACE_ID", None)
    env.pop("CMUX_TAB_ID", None)

    cmd = [cli, "--socket", SOCKET_PATH]
    if json_output:
        cmd.append("--json")
    cmd.extend(args)

    proc = subprocess.run(cmd, capture_output=True, text=True, check=False, env=env, cwd=cwd)
    if proc.returncode != 0:
        merged = f"{proc.stdout}\n{proc.stderr}".strip()
        raise cmuxError(f"CLI failed ({' '.join(cmd)}): {merged}")
    return proc.stdout


def _run_cli_json(cli: str, args: List[str], cwd: Optional[str] = None) -> Dict:
    output = _run_cli(cli, args, json_output=True, cwd=cwd)
    try:
        return json.loads(output or "{}")
    except Exception as exc:  # noqa: BLE001
        raise cmuxError(f"Invalid JSON output for {' '.join(args)}: {output!r} ({exc})")


def _page_titles_and_selected(payload: Dict) -> Tuple[List[str], List[str]]:
    pages = payload.get("pages") or []
    titles = [str(page.get("title") or "") for page in pages]
    selected = [str(page.get("title") or "") for page in pages if bool(page.get("selected"))]
    return titles, selected


def _page_refs_by_title(payload: Dict) -> Dict[str, str]:
    refs: Dict[str, str] = {}
    for page in payload.get("pages") or []:
        title = str(page.get("title") or "")
        ref = str(page.get("page_ref") or "")
        if title and ref:
            refs[title] = ref
    return refs


def _workspace_node(tree: Dict, workspace_id: str) -> Dict:
    windows = tree.get("windows") or []
    for window in windows:
        for workspace in window.get("workspaces") or []:
            if str(workspace.get("id") or "") == workspace_id:
                return workspace
    raise cmuxError(f"Workspace {workspace_id} not present in system.tree: {tree}")


def _workspace_id_at_index(rows: List[Tuple[int, str, str, bool]], index: int, window_id: str) -> str:
    for row_index, workspace_id, _title, _selected in rows:
        if row_index == index:
            return workspace_id
    raise cmuxError(f"Window {window_id} has no workspace at index {index}: {rows}")


def main() -> int:
    cli = _find_cli_binary()

    help_text = _run_cli(cli, ["list-pages", "--help"], json_output=False)
    _must("page:<n>" in help_text, "list-pages --help should mention page:<n> refs")
    _must("current-page" in help_text, "list-pages --help should mention related page commands")

    with cmux(SOCKET_PATH) as c:
        routed_window_id = None
        try:
            focused = c.identify().get("focused") or {}
            current_window_id = str(focused.get("window_id") or c.current_window())
            routed_window_id = c.new_window()
            time.sleep(0.2)

            current_window_ws1 = _workspace_id_at_index(
                c.list_workspaces(window_id=current_window_id),
                1,
                current_window_id,
            )
            routed_window_ws1 = _workspace_id_at_index(
                c.list_workspaces(window_id=routed_window_id),
                1,
                routed_window_id,
            )
            _must(
                current_window_ws1 != routed_window_ws1,
                f"Test setup expected each window to have its own workspace:1 (w1={current_window_ws1}, w2={routed_window_ws1})",
            )

            c.focus_window(current_window_id)
            time.sleep(0.2)

            first_routed_page = _run_cli_json(
                cli,
                [
                    "new-page",
                    "--window",
                    routed_window_id,
                    "--workspace",
                    "workspace:1",
                    "--title",
                    "window-routed-a",
                ],
            )
            _must(
                str(first_routed_page.get("workspace_id") or "") == routed_window_ws1,
                f"new-page --window should resolve workspace:1 inside the requested window: {first_routed_page}",
            )
            second_routed_page = _run_cli_json(
                cli,
                [
                    "new-page",
                    "--window",
                    routed_window_id,
                    "--workspace",
                    "workspace:1",
                    "--title",
                    "window-routed-b",
                ],
            )
            _must(
                str(second_routed_page.get("workspace_id") or "") == routed_window_ws1,
                f"second new-page --window should stay in the requested window: {second_routed_page}",
            )

            current_window_list = c._call("page.list", {"workspace_id": current_window_ws1}) or {}
            current_window_titles, _ = _page_titles_and_selected(current_window_list)
            _must(
                "window-routed-a" not in current_window_titles and "window-routed-b" not in current_window_titles,
                f"command-local --window must not create pages in the focused window: {current_window_list}",
            )

            routed_list = _run_cli_json(
                cli,
                ["list-pages", "--window", routed_window_id, "--workspace", "workspace:1"],
            )
            routed_titles, _ = _page_titles_and_selected(routed_list)
            _must(
                "window-routed-a" in routed_titles and "window-routed-b" in routed_titles,
                f"list-pages --window should list pages from the requested window: {routed_list}",
            )
            routed_refs = _page_refs_by_title(routed_list)
            second_routed_ref = routed_refs.get("window-routed-b")
            _must(bool(second_routed_ref), f"list-pages --window returned no ref for window-routed-b: {routed_list}")

            reordered_routed = _run_cli_json(
                cli,
                [
                    "reorder-page",
                    "--window",
                    routed_window_id,
                    "--workspace",
                    "workspace:1",
                    "--page",
                    second_routed_ref,
                    "--index",
                    "0",
                ],
            )
            _must(
                str(reordered_routed.get("workspace_id") or "") == routed_window_ws1,
                f"reorder-page --window should resolve workspace:1 inside the requested window: {reordered_routed}",
            )
            reordered_routed_list = c._call("page.list", {"workspace_id": routed_window_ws1}) or {}
            reordered_titles, _ = _page_titles_and_selected(reordered_routed_list)
            _must(
                reordered_titles and reordered_titles[0] == "window-routed-b",
                f"reorder-page --window should reorder the requested window workspace: {reordered_routed_list}",
            )
        finally:
            if routed_window_id:
                try:
                    c.close_window(routed_window_id)
                except Exception:
                    pass

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

            positional_renamed = _run_cli_json(
                cli,
                ["rename-page", "--workspace", workspace_id, first_page_ref, "agents-positional"],
            )
            _must(
                str(positional_renamed.get("page_id") or "") == first_page_id,
                f"rename-page positional handle targeted wrong page: {positional_renamed}",
            )
            _must(
                str(positional_renamed.get("page_title") or "") == "agents-positional",
                f"rename-page positional handle did not set title: {positional_renamed}",
            )
            _run_cli_json(
                cli,
                ["rename-page", "--workspace", workspace_id, "--page", first_page_ref, "agents"],
            )

            numeric_title = _run_cli_json(
                cli,
                ["rename-page", "--workspace", workspace_id, "2024"],
            )
            _must(
                str(numeric_title.get("page_id") or "") == second_page_id,
                f"rename-page numeric title should target the current page: {numeric_title}",
            )
            _must(
                str(numeric_title.get("page_title") or "") == "2024",
                f"rename-page numeric title was misparsed as a page handle: {numeric_title}",
            )
            numeric_title_terminator = _run_cli_json(
                cli,
                ["rename-page", "--workspace", workspace_id, "--", "5"],
            )
            _must(
                str(numeric_title_terminator.get("page_id") or "") == second_page_id,
                f"rename-page -- numeric title should target the current page: {numeric_title_terminator}",
            )
            _must(
                str(numeric_title_terminator.get("page_title") or "") == "5",
                f"rename-page -- numeric title was misparsed as a page handle: {numeric_title_terminator}",
            )
            _run_cli_json(
                cli,
                ["rename-page", "--workspace", workspace_id, "editor"],
            )

            numeric_duplicate = _run_cli_json(
                cli,
                ["duplicate-page", "--workspace", workspace_id, "--", "5"],
            )
            numeric_duplicate_id = str(numeric_duplicate.get("page_id") or "")
            numeric_duplicate_ref = str(numeric_duplicate.get("page_ref") or "")
            _must(
                bool(numeric_duplicate_id) and numeric_duplicate_id not in {first_page_id, second_page_id},
                f"duplicate-page -- numeric title should create a distinct page: {numeric_duplicate}",
            )
            _must(
                str(numeric_duplicate.get("page_title") or "") == "5",
                f"duplicate-page -- numeric title was misparsed as a page handle: {numeric_duplicate}",
            )
            _run_cli_json(
                cli,
                ["close-page", "--workspace", workspace_id, "--page", numeric_duplicate_ref],
            )

            option_like_title_page = _run_cli_json(
                cli,
                ["new-page", "--workspace", workspace_id, "--", "--window", "draft"],
            )
            option_like_title_page_ref = str(option_like_title_page.get("page_ref") or "")
            _must(
                str(option_like_title_page.get("page_title") or "") == "--window draft",
                f"new-page should preserve option-looking title text after --: {option_like_title_page}",
            )
            _run_cli_json(
                cli,
                ["close-page", "--workspace", workspace_id, "--page", option_like_title_page_ref],
            )

            option_like_duplicate = _run_cli_json(
                cli,
                ["duplicate-page", "--workspace", workspace_id, "--", "--page", "literal"],
            )
            option_like_duplicate_ref = str(option_like_duplicate.get("page_ref") or "")
            _must(
                str(option_like_duplicate.get("page_title") or "") == "--page literal",
                f"duplicate-page should preserve option-looking title text after --: {option_like_duplicate}",
            )
            _run_cli_json(
                cli,
                ["close-page", "--workspace", workspace_id, "--page", option_like_duplicate_ref],
            )

            with tempfile.TemporaryDirectory() as temp_dir:
                Path(temp_dir, "list-pages").mkdir()
                listed_from_path_collision = _run_cli_json(
                    cli,
                    ["list-pages", "--workspace", workspace_id],
                    cwd=temp_dir,
                )
            _must(
                str(listed_from_path_collision.get("workspace_id") or "") == workspace_id,
                f"list-pages should dispatch even when cwd contains a same-named path: {listed_from_path_collision}",
            )
            collision_titles, _ = _page_titles_and_selected(listed_from_path_collision)
            _must(
                collision_titles == ["agents", "editor"],
                f"list-pages path collision should return page data, not open a workspace path: {listed_from_path_collision}",
            )

            socket_renamed_current = c._call(
                "page.rename",
                {"workspace_id": workspace_id, "title": "editor-current"},
            ) or {}
            _must(
                str(socket_renamed_current.get("page_id") or "") == second_page_id,
                f"page.rename without page_id should rename the active page: {socket_renamed_current}",
            )
            _must(
                str(socket_renamed_current.get("page_title") or "") == "editor-current",
                f"page.rename without page_id did not apply title: {socket_renamed_current}",
            )
            socket_restored_current = c._call(
                "page.rename",
                {"workspace_id": workspace_id, "title": "editor"},
            ) or {}
            _must(
                str(socket_restored_current.get("page_id") or "") == second_page_id,
                f"page.rename without page_id should keep targeting the active page: {socket_restored_current}",
            )
            try:
                c._call(
                    "page.duplicate",
                    {
                        "workspace_id": workspace_id,
                        "page_id": "00000000-0000-4000-8000-000000000001",
                        "title": "wrong-page",
                    },
                )
                _must(False, "page.duplicate with a stale explicit page_id should fail")
            except cmuxError as exc:
                _must(
                    "not_found" in str(exc),
                    f"page.duplicate with a stale explicit page_id should return not_found: {exc}",
                )

            listed = c._call("page.list", {"workspace_id": workspace_id}) or {}
            titles, selected_titles = _page_titles_and_selected(listed)
            _must(titles == ["agents", "editor"], f"page.list returned unexpected titles after create: {listed}")
            _must(selected_titles == ["editor"], f"page.list should report editor selected after create: {listed}")
            _must(str(listed.get("page_id") or "") == second_page_id, f"page.list should mirror active page: {listed}")

            page_targeted_surface = c._call(
                "surface.create",
                {"workspace_id": workspace_id, "page_id": first_page_id, "focus": False},
            ) or {}
            _must(
                str(page_targeted_surface.get("workspace_id") or "") == workspace_id,
                f"surface.create with page_id should resolve the requested workspace: {page_targeted_surface}",
            )

            page_targeted_list = c._call("page.list", {"workspace_id": workspace_id}) or {}
            page_targeted_pages = {
                str(page.get("title") or ""): page
                for page in (page_targeted_list.get("pages") or [])
            }
            _must(
                int(page_targeted_pages.get("agents", {}).get("surface_count", -1)) == 2,
                f"surface.create with page_id should add the surface to agents: {page_targeted_list}",
            )
            _must(
                int(page_targeted_pages.get("editor", {}).get("surface_count", -1)) == 1,
                f"surface.create with page_id must not mutate the active editor page: {page_targeted_list}",
            )

            positional_duplicate = _run_cli_json(
                cli,
                ["duplicate-page", "--workspace", workspace_id, first_page_ref, "--title", "agents-positional"],
            )
            positional_duplicate_id = str(positional_duplicate.get("page_id") or "")
            positional_duplicate_ref = str(positional_duplicate.get("page_ref") or "")
            _must(
                bool(positional_duplicate_id) and bool(positional_duplicate_ref),
                f"duplicate-page positional page handle returned no page handle: {positional_duplicate}",
            )
            positional_duplicate_list = c._call("page.list", {"workspace_id": workspace_id}) or {}
            positional_duplicate_pages = {
                str(page.get("title") or ""): page
                for page in (positional_duplicate_list.get("pages") or [])
            }
            _must(
                int(positional_duplicate_pages.get("agents-positional", {}).get("surface_count", -1)) == 2,
                f"duplicate-page positional handle should duplicate the requested page, not the active page: {positional_duplicate_list}",
            )
            _run_cli_json(
                cli,
                ["close-page", "--workspace", workspace_id, "--page", positional_duplicate_ref],
            )

            selected = _run_cli_json(
                cli,
                ["select-page", "--workspace", workspace_id, "--page", first_page_ref],
            )
            _must(str(selected.get("page_id") or "") == first_page_id, f"select-page targeted wrong page: {selected}")

            selected_via_terminator = _run_cli_json(
                cli,
                ["select-page", "--workspace", workspace_id, "--", first_page_ref],
            )
            _must(
                str(selected_via_terminator.get("page_id") or "") == first_page_id,
                f"select-page should accept a positional page after --: {selected_via_terminator}",
            )

            selected_by_number = _run_cli_json(
                cli,
                ["select-page", "--workspace", workspace_id, "1"],
            )
            _must(
                str(selected_by_number.get("page_id") or "") == first_page_id,
                f"select-page 1 should select the first page: {selected_by_number}",
            )

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
                str(workspace.get("selected_page_id") or "") == duplicate_page_id,
                f"system.tree selected page did not mirror active duplicated page: {workspace}",
            )

            after_socket_reorder_list = _run_cli_json(cli, ["list-pages", "--workspace", workspace_id])
            after_socket_reorder_refs = _page_refs_by_title(after_socket_reorder_list)
            duplicate_page_ref = after_socket_reorder_refs.get("database", duplicate_page_ref)
            first_page_ref = after_socket_reorder_refs.get("agents", first_page_ref)
            second_page_ref = after_socket_reorder_refs.get("editor", second_page_ref)

            after_reordered = _run_cli_json(
                cli,
                [
                    "reorder-page",
                    "--workspace",
                    workspace_id,
                    "--page",
                    second_page_ref,
                    "--after",
                    duplicate_page_ref,
                ],
            )
            _must(
                int(after_reordered.get("page_index", -1)) == 1,
                f"reorder-page --after should move editor immediately after database: {after_reordered}",
            )
            after_list = _run_cli_json(cli, ["list-pages", "--workspace", workspace_id])
            after_titles, _ = _page_titles_and_selected(after_list)
            _must(
                after_titles == ["database", "editor", "agents"],
                f"reorder-page --after should preserve the anchor-before-page order: {after_list}",
            )
            after_refs = _page_refs_by_title(after_list)
            duplicate_page_ref = after_refs.get("database", duplicate_page_ref)
            first_page_ref = after_refs.get("agents", first_page_ref)
            second_page_ref = after_refs.get("editor", second_page_ref)

            terminator_reordered = _run_cli_json(
                cli,
                [
                    "reorder-page",
                    "--workspace",
                    workspace_id,
                    "--index",
                    "1",
                    "--",
                    first_page_ref,
                ],
            )
            _must(
                int(terminator_reordered.get("page_index", -1)) == 1,
                f"reorder-page should accept a positional page after --: {terminator_reordered}",
            )
            terminator_list = _run_cli_json(cli, ["list-pages", "--workspace", workspace_id])
            terminator_titles, _ = _page_titles_and_selected(terminator_list)
            _must(
                terminator_titles == ["database", "agents", "editor"],
                f"reorder-page with -- should move agents back after database: {terminator_list}",
            )
            terminator_refs = _page_refs_by_title(terminator_list)
            duplicate_page_ref = terminator_refs.get("database", duplicate_page_ref)
            first_page_ref = terminator_refs.get("agents", first_page_ref)
            second_page_ref = terminator_refs.get("editor", second_page_ref)

            restored_reorder = _run_cli_json(
                cli,
                [
                    "reorder-page",
                    "--workspace",
                    workspace_id,
                    "--page",
                    second_page_ref,
                    "--after",
                    first_page_ref,
                ],
            )
            _must(
                int(restored_reorder.get("page_index", -1)) == 2,
                f"reorder-page --after should restore editor after agents: {restored_reorder}",
            )
            restored_list = _run_cli_json(cli, ["list-pages", "--workspace", workspace_id])
            restored_titles, _ = _page_titles_and_selected(restored_list)
            _must(
                restored_titles == ["database", "agents", "editor"],
                f"reorder-page --after should restore the expected final order: {restored_list}",
            )
            restored_refs = _page_refs_by_title(restored_list)
            duplicate_page_ref = restored_refs.get("database", duplicate_page_ref)

            last_page = c._call("page.last", {"workspace_id": workspace_id}) or {}
            _must(str(last_page.get("page_id") or "") == second_page_id, f"page.last should select editor: {last_page}")

            current_cli = _run_cli_json(cli, ["current-page", "--workspace", workspace_id])
            _must(
                str(current_cli.get("page_id") or "") == second_page_id,
                f"current-page CLI should agree with page.last: {current_cli}",
            )

            socket_closed_current = c._call("page.close", {"workspace_id": workspace_id}) or {}
            _must(
                str(socket_closed_current.get("page_id") or "") == second_page_id,
                f"page.close without page_id should close the active page: {socket_closed_current}",
            )
            _must(
                str(socket_closed_current.get("selected_page_id") or "") == first_page_id,
                f"page.close without page_id should select the nearest surviving neighbor: {socket_closed_current}",
            )
            after_socket_close_list = _run_cli_json(cli, ["list-pages", "--workspace", workspace_id])
            after_socket_close_titles, after_socket_close_selected = _page_titles_and_selected(after_socket_close_list)
            _must(
                after_socket_close_titles == ["database", "agents"],
                f"list-pages should reflect socket current-page close: {after_socket_close_list}",
            )
            _must(
                after_socket_close_selected == ["agents"],
                f"list-pages should keep agents selected after socket current-page close: {after_socket_close_list}",
            )

            closed = _run_cli_json(
                cli,
                ["close-page", "--workspace", workspace_id, "--page", duplicate_page_ref],
            )
            _must(str(closed.get("page_id") or "") == duplicate_page_id, f"close-page closed wrong page: {closed}")
            _must(
                str(closed.get("selected_page_id") or "") == first_page_id,
                f"close-page should select the nearest surviving neighbor after closing the leftmost active page: {closed}",
            )

            final_list = _run_cli_json(cli, ["list-pages", "--workspace", workspace_id])
            final_titles, final_selected = _page_titles_and_selected(final_list)
            _must(final_titles == ["agents"], f"list-pages should reflect closed duplicate page: {final_list}")
            _must(final_selected == ["agents"], f"list-pages should report agents selected after close: {final_list}")
            _must(str(final_list.get("page_id") or "") == first_page_id, f"list-pages active page mismatch after close: {final_list}")

            scratch_page = _run_cli_json(
                cli,
                ["new-page", "--workspace", workspace_id, "--title", "scratch"],
            )
            scratch_page_id = str(scratch_page.get("page_id") or "")
            _must(bool(scratch_page_id), f"new-page scratch returned no page_id: {scratch_page}")
            closed_current_cli = _run_cli_json(cli, ["close-page", "--workspace", workspace_id])
            _must(
                str(closed_current_cli.get("page_id") or "") == scratch_page_id,
                f"close-page --workspace without --page should close the active page: {closed_current_cli}",
            )
            _must(
                str(closed_current_cli.get("selected_page_id") or "") == first_page_id,
                f"close-page --workspace should return to the surviving page: {closed_current_cli}",
            )

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
