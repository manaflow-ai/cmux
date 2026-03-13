#!/usr/bin/env python3
"""
Check whether the current focused terminal surface duplicates a Pure-style
preprompt line when Enter is pressed on an empty prompt.

Usage:
  python3 scripts/probe-pure-prompt-duplication.py

Run this from a spare cmux pane. The script creates a temporary workspace,
probes the prompt there, and restores your original workspace afterwards.
"""

from __future__ import annotations

import argparse
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str((Path(__file__).resolve().parents[1] / "tests_v2")))
from cmux import cmux, cmuxError


def _is_prompt_line(line: str) -> bool:
    stripped = line.strip()
    return stripped.startswith("❯") or stripped.startswith(">") or stripped.startswith("$")


def _prompt_block(text: str) -> tuple[list[str], str]:
    lines = text.splitlines()
    while lines and not lines[-1].strip():
        lines.pop()

    prompt_idx = -1
    for i in range(len(lines) - 1, -1, -1):
        if _is_prompt_line(lines[i]):
            prompt_idx = i
            break
    if prompt_idx == -1:
        raise cmuxError(f"Could not find prompt line in surface text:\n{text}")

    preprompt: list[str] = []
    i = prompt_idx - 1
    while i >= 0 and lines[i].strip():
        preprompt.append(lines[i])
        i -= 1
    preprompt.reverse()
    return preprompt, lines[prompt_idx]


def _duplicate_run_length(preprompt: list[str]) -> int:
    if not preprompt:
        return 0
    last = preprompt[-1]
    count = 1
    for line in reversed(preprompt[:-1]):
        if line != last:
            break
        count += 1
    return count


def _read_text(client: cmux, workspace_id: str, surface_id: str) -> str:
    payload = client._call(
        "surface.read_text",
        {
            "workspace_id": workspace_id,
            "surface_id": surface_id,
            "scrollback": True,
            "lines": 80,
        },
    ) or {}
    return str(payload.get("text") or "")


def _wait_for_prompt_text(
    client: cmux,
    workspace_id: str,
    surface_id: str,
    *,
    timeout: float,
) -> tuple[str, list[str], str]:
    start = time.time()
    last_text = ""
    last_error = ""

    while time.time() - start < timeout:
        last_text = _read_text(client, workspace_id, surface_id)
        try:
            preprompt, prompt = _prompt_block(last_text)
            return last_text, preprompt, prompt
        except Exception as exc:
            last_error = str(exc)
            time.sleep(0.2)

    raise cmuxError(
        "Timed out waiting for a prompt block "
        f"(last_error={last_error!r}, surface_text={last_text!r})"
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--enters", type=int, default=3)
    parser.add_argument("--delay", type=float, default=0.8)
    parser.add_argument("--prompt-timeout", type=float, default=15.0)
    parser.add_argument("--keep-workspace", action="store_true")
    parser.add_argument(
        "--socket",
        default=os.environ.get("CMUX_SOCKET") or os.environ.get("CMUX_SOCKET_PATH") or "/tmp/cmux-debug.sock",
    )
    args = parser.parse_args()

    with cmux(args.socket) as client:
        current = client._call("workspace.current", {}) or {}
        original_workspace_id = str(current.get("workspace_id") or "")
        if not original_workspace_id:
            raise cmuxError(f"workspace.current returned no workspace_id: {current}")

        created = client._call("workspace.create", {}) or {}
        workspace_id = str(created.get("workspace_id") or "")
        if not workspace_id:
            raise cmuxError(f"workspace.create returned no workspace_id: {created}")
        client._call("workspace.select", {"workspace_id": workspace_id})

        surface_id = ""
        probe_text = ""

        start = time.time()
        while True:
            try:
                listed = client._call("surface.list", {"workspace_id": workspace_id}) or {}
                surfaces = listed.get("surfaces") or []
                if surfaces:
                    surface_id = str(surfaces[0].get("id") or "")
                if surface_id:
                    baseline = _read_text(client, workspace_id, surface_id)
                    probe_text = baseline
                    break
                raise cmuxError("surface not ready yet")
            except Exception as exc:
                probe_text = str(exc)
                if time.time() - start > 10:
                    raise cmuxError(f"Timed out waiting for readable terminal surface: {probe_text}")
                time.sleep(0.2)

        try:
            print(f"workspace={workspace_id}")
            print(f"surface={surface_id}")

            baseline, preprompt, prompt = _wait_for_prompt_text(
                client,
                workspace_id,
                surface_id,
                timeout=args.prompt_timeout,
            )
            baseline_run = _duplicate_run_length(preprompt)
            print(f"baseline_prompt={prompt!r}")
            print(f"baseline_preprompt={preprompt!r}")
            print(f"baseline_duplicate_run={baseline_run}")

            if baseline_run > 1:
                print("FAIL: surface is already duplicated before probing")
                print(baseline)
                return 1

            for step in range(1, args.enters + 1):
                client._call(
                    "surface.send_text",
                    {
                        "workspace_id": workspace_id,
                        "surface_id": surface_id,
                        "text": "\n",
                    },
                )
                time.sleep(args.delay)

                text, preprompt, prompt = _wait_for_prompt_text(
                    client,
                    workspace_id,
                    surface_id,
                    timeout=args.prompt_timeout,
                )
                duplicate_run = _duplicate_run_length(preprompt)
                print(f"after_enter_{step}_prompt={prompt!r}")
                print(f"after_enter_{step}_preprompt={preprompt!r}")
                print(f"after_enter_{step}_duplicate_run={duplicate_run}")

                if duplicate_run > 1:
                    print("FAIL: prompt duplication reproduced")
                    print(text)
                    return 1

            print("PASS: empty Enter did not duplicate the current prompt block")
            return 0
        finally:
            if not args.keep_workspace:
                try:
                    client._call("workspace.close", {"workspace_id": workspace_id})
                except Exception:
                    pass
                client._call("workspace.select", {"workspace_id": original_workspace_id})


if __name__ == "__main__":
    raise SystemExit(main())
