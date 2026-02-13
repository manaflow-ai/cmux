#!/usr/bin/env python3
"""Regression test: `identify` caller args must honor ref-style handles."""

import glob
import json
import os
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmuxterm-debug.sock")


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _find_cli_binary() -> str:
    env_cli = os.environ.get("CMUXTERM_CLI")
    if env_cli and os.path.isfile(env_cli) and os.access(env_cli, os.X_OK):
        return env_cli

    fixed = os.path.expanduser("~/Library/Developer/Xcode/DerivedData/cmuxterm-tests-v2/Build/Products/Debug/cmuxterm")
    if os.path.isfile(fixed) and os.access(fixed, os.X_OK):
        return fixed

    candidates = glob.glob(os.path.expanduser("~/Library/Developer/Xcode/DerivedData/**/Build/Products/Debug/cmuxterm"), recursive=True)
    candidates += glob.glob("/tmp/cmuxterm-*/Build/Products/Debug/cmuxterm")
    candidates = [p for p in candidates if os.path.isfile(p) and os.access(p, os.X_OK)]
    if not candidates:
        raise cmuxError("Could not locate cmuxterm CLI binary; set CMUXTERM_CLI")
    candidates.sort(key=lambda p: os.path.getmtime(p), reverse=True)
    return candidates[0]


def _run_cli_json(cli: str, args: list[str], retries: int = 4) -> dict:
    last_merged = ""
    for attempt in range(1, retries + 1):
        proc = subprocess.run(
            [cli, "--socket", SOCKET_PATH, "--json"] + args,
            capture_output=True,
            text=True,
            check=False,
        )
        if proc.returncode == 0:
            try:
                return json.loads(proc.stdout or "{}")
            except Exception as exc:  # noqa: BLE001
                raise cmuxError(f"Invalid CLI JSON output for {' '.join(args)}: {proc.stdout!r} ({exc})")

        merged = f"{proc.stdout}\n{proc.stderr}".strip()
        last_merged = merged
        if "Command timed out" in merged and attempt < retries:
            time.sleep(0.2)
            continue
        raise cmuxError(f"CLI failed ({' '.join(args)}): {merged}")

    raise cmuxError(f"CLI failed ({' '.join(args)}): {last_merged}")


def _workspace_and_surface_sets(payload: dict) -> tuple[set[str], set[str]]:
    focused = payload.get("focused") or {}
    workspaces = {
        str(payload.get("workspace_id") or ""),
        str(payload.get("workspace_ref") or ""),
        str(focused.get("workspace_id") or ""),
        str(focused.get("workspace_ref") or ""),
    }
    surfaces = {
        str(payload.get("surface_id") or ""),
        str(payload.get("surface_ref") or ""),
        str(focused.get("surface_id") or ""),
        str(focused.get("surface_ref") or ""),
    }
    return ({x for x in workspaces if x}, {x for x in surfaces if x})


def main() -> int:
    cli = _find_cli_binary()
    client = cmux(SOCKET_PATH)
    client.connect()

    created_workspace_id: str | None = None
    try:
        base_ident = _run_cli_json(cli, ["identify"])
        base_workspaces, _ = _workspace_and_surface_sets(base_ident)
        base_workspace_id = str((base_ident.get("focused") or {}).get("workspace_id") or "")
        base_workspace_ref = str((base_ident.get("focused") or {}).get("workspace_ref") or "")
        _must(bool(base_workspace_id) and bool(base_workspace_ref), f"identify missing base workspace handles: {base_ident}")

        created_workspace_id = client.new_workspace()
        _must(bool(created_workspace_id), "workspace.create returned empty workspace id")
        client.select_workspace(created_workspace_id)

        current_ident = _run_cli_json(cli, ["identify"])
        current_workspaces, _ = _workspace_and_surface_sets(current_ident)
        _must(
            len(base_workspaces.intersection(current_workspaces)) == 0,
            f"Expected switched current workspace to differ from base; base={base_workspaces} current={current_workspaces}",
        )

        identify_ws_ref = _run_cli_json(cli, ["identify", "--workspace", base_workspace_ref])
        caller_ws = identify_ws_ref.get("caller") or {}
        got_ws = str(caller_ws.get("workspace_id") or caller_ws.get("workspace_ref") or "")
        _must(bool(got_ws), f"identify --workspace <ref> returned empty caller workspace: {identify_ws_ref}")
        _must(
            got_ws in {base_workspace_id, base_workspace_ref},
            f"identify --workspace <ref> did not resolve target workspace; got={got_ws} expected one of {[base_workspace_id, base_workspace_ref]}",
        )

        list_payload = client._call("surface.list", {"workspace_id": base_workspace_id}) or {}
        surfaces = list_payload.get("surfaces") or []
        _must(len(surfaces) > 0, f"No surfaces found in target workspace: {list_payload}")

        target_surface = surfaces[0]
        target_surface_id = str(target_surface.get("id") or "")
        target_surface_ref = str(target_surface.get("ref") or "")
        _must(bool(target_surface_id) and bool(target_surface_ref), f"surface.list missing id/ref: {target_surface}")

        identify_both_refs = _run_cli_json(
            cli,
            ["identify", "--workspace", base_workspace_ref, "--surface", target_surface_ref],
        )
        caller_both = identify_both_refs.get("caller") or {}
        got_ws_both = str(caller_both.get("workspace_id") or caller_both.get("workspace_ref") or "")
        got_surface_both = str(caller_both.get("surface_id") or caller_both.get("surface_ref") or "")

        _must(
            got_ws_both in {base_workspace_id, base_workspace_ref},
            f"identify --workspace/--surface refs resolved wrong workspace; got={got_ws_both} payload={identify_both_refs}",
        )
        _must(
            got_surface_both in {target_surface_id, target_surface_ref},
            f"identify --workspace/--surface refs resolved wrong surface; got={got_surface_both} expected one of {[target_surface_id, target_surface_ref]}",
        )

    finally:
        if created_workspace_id:
            try:
                client.close_workspace(created_workspace_id)
            except Exception:
                pass
        try:
            client.close()
        except Exception:
            pass

    print("PASS: identify caller accepts workspace/surface ref handles and resolves target context")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
