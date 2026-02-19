#!/usr/bin/env python3
"""Regression: CLI defaults to refs output; UUIDs only when requested."""

import glob
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Tuple

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")


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


def _run_cli_json(cli: str, args: List[str], extra_flags: Optional[List[str]] = None) -> Dict[str, Any]:
    cmd = [cli, "--socket", SOCKET_PATH, "--json"]
    if extra_flags:
        cmd += extra_flags
    cmd += args

    proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if proc.returncode != 0:
        merged = f"{proc.stdout}\n{proc.stderr}".strip()
        raise cmuxError(f"CLI failed ({' '.join(cmd)}): {merged}")

    try:
        return json.loads(proc.stdout or "{}")
    except Exception as exc:  # noqa: BLE001
        raise cmuxError(f"Invalid JSON output for {' '.join(cmd)}: {proc.stdout!r} ({exc})")


def _walk_dicts(value: Any):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from _walk_dicts(child)
    elif isinstance(value, list):
        for child in value:
            yield from _walk_dicts(child)


def _id_ref_pairs(payload: Dict[str, Any]) -> List[Tuple[str, str]]:
    pairs: List[Tuple[str, str]] = []
    for d in _walk_dicts(payload):
        if "id" in d and "ref" in d:
            pairs.append(("id", "ref"))
        for key in d.keys():
            if key.endswith("_id"):
                twin = f"{key[:-3]}_ref"
                if twin in d:
                    pairs.append((key, twin))
    return pairs


def _has_any_key(payload: Dict[str, Any], predicate: Callable[[str], bool]) -> bool:
    for d in _walk_dicts(payload):
        for key in d.keys():
            if predicate(key):
                return True
    return False


def main() -> int:
    cli = _find_cli_binary()

    default_payload = _run_cli_json(cli, ["identify"])
    both_payload = _run_cli_json(cli, ["identify"], extra_flags=["--id-format", "both"])
    uuid_payload = _run_cli_json(cli, ["identify"], extra_flags=["--id-format", "uuids"])

    _must(_has_any_key(default_payload, lambda k: k.endswith("_ref") or k == "ref"), f"Expected refs in default --json output: {default_payload}")
    _must(
        len(_id_ref_pairs(default_payload)) == 0,
        f"Default --json output should suppress id when matching ref exists; got pairs={_id_ref_pairs(default_payload)} payload={default_payload}",
    )

    both_pairs = _id_ref_pairs(both_payload)
    _must(len(both_pairs) > 0, f"--id-format both should include id/ref pairs; payload={both_payload}")

    _must(_has_any_key(uuid_payload, lambda k: k.endswith("_id") or k == "id"), f"--id-format uuids missing id keys: {uuid_payload}")
    _must(
        len(_id_ref_pairs(uuid_payload)) == 0,
        f"--id-format uuids should suppress *_ref when matching *_id exists; pairs={_id_ref_pairs(uuid_payload)} payload={uuid_payload}",
    )

    print("PASS: CLI id-format defaults are refs-first (with both/uuids opt-in working)")

    # ------------------------------------------------------------------
    # Verify migrated list commands also respect id-format
    # ------------------------------------------------------------------

    # list-panels
    panels_default = _run_cli_json(cli, ["list-panels"])
    surfaces = panels_default.get("surfaces", [])
    if surfaces:
        _must(
            _has_any_key(panels_default, lambda k: k.endswith("_ref") or k == "ref"),
            f"list-panels default should include refs: {panels_default}",
        )
        _must(
            len(_id_ref_pairs(panels_default)) == 0,
            f"list-panels default should suppress id when ref exists; pairs={_id_ref_pairs(panels_default)}",
        )

    panels_both = _run_cli_json(cli, ["list-panels"], extra_flags=["--id-format", "both"])
    if panels_both.get("surfaces"):
        _must(len(_id_ref_pairs(panels_both)) > 0, f"list-panels --id-format both should include pairs: {panels_both}")

    # list-panes
    panes_default = _run_cli_json(cli, ["list-panes"])
    panes = panes_default.get("panes", [])
    if panes:
        _must(
            _has_any_key(panes_default, lambda k: k.endswith("_ref") or k == "ref"),
            f"list-panes default should include refs: {panes_default}",
        )

    # list-workspaces
    ws_default = _run_cli_json(cli, ["list-workspaces"])
    workspaces = ws_default.get("workspaces", [])
    if workspaces:
        _must(
            _has_any_key(ws_default, lambda k: k.endswith("_ref") or k == "ref"),
            f"list-workspaces default should include refs: {ws_default}",
        )
        _must(
            len(_id_ref_pairs(ws_default)) == 0,
            f"list-workspaces default should suppress id when ref exists; pairs={_id_ref_pairs(ws_default)}",
        )

    # surface-health
    health_default = _run_cli_json(cli, ["surface-health"])
    health_surfaces = health_default.get("surfaces", [])
    if health_surfaces:
        _must(
            _has_any_key(health_default, lambda k: k.endswith("_ref") or k == "ref"),
            f"surface-health default should include refs: {health_default}",
        )

    print("PASS: Migrated list commands also respect id-format defaults")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
