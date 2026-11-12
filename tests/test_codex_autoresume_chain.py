#!/usr/bin/env python3
"""Executable regression for recursive Codex wrapper autoresume."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WRAPPER = ROOT / "Resources" / "bin" / "cmux-codex-wrapper"
SESSION_ID = "0198f073-0a5b-7000-8000-000000000059"


def executable(path: Path, contents: str) -> None:
    path.write_text(contents, encoding="utf-8")
    path.chmod(0o755)


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="cmux-codex-autoresume-chain-") as td:
        root = Path(td)
        wrapper_dir = root / "wrapper"
        real_dir = root / "real"
        wrapper_dir.mkdir()
        real_dir.mkdir()
        wrapper = wrapper_dir / "cmux-codex-wrapper"
        shutil.copy2(WRAPPER, wrapper)
        wrapper.chmod(0o755)
        state_path = root / "state.json"
        state_path.write_text(json.dumps({"bindings": [], "calls": []}), encoding="utf-8")

        cli = root / "cmux"
        executable(
            cli,
            """#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
state_path = Path(os.environ["FAKE_STATE_PATH"])
state = json.loads(state_path.read_text())
args = sys.argv[1:]
state["calls"].append(args)
if args[:3] == ["hooks", "codex", "inject-args"]:
    sys.stdout.buffer.write(b"--enable\\0hooks\\0--dangerously-bypass-hook-trust\\0")
    sys.stdout.buffer.write(b"-c\\0hooks.SessionStart=[{hooks=[{type=\\\"command\\\",command=\\\"fake\\\"}]}]\\0")
    sys.stdout.buffer.write(b"-c\\0hooks.Stop=[{hooks=[{type=\\\"command\\\",command=\\\"fake\\\"}]}]\\0")
elif args[:4] == ["hooks", "enqueue", "codex", "session-start"] or args[:3] == ["hooks", "codex", "session-start"]:
    payload = json.loads(sys.stdin.read() or "{}")
    state["bindings"].append({
        "session_id": payload.get("session_id"),
        "pid": os.environ.get("CMUX_CODEX_PID"),
        "surface": os.environ.get("CMUX_SURFACE_ID"),
        "queued": args[1] == "enqueue",
    })
state_path.write_text(json.dumps(state), encoding="utf-8")
""",
        )

        real = real_dir / "codex"
        executable(
            real,
            """#!/usr/bin/env python3
import json, os, subprocess, sys
args = sys.argv[1:]
session_id = os.environ["FAKE_SESSION_ID"]
if "resume" in args:
    index = args.index("resume") + 1
    session_id = args[index]
else:
    subprocess.run(
        [os.environ["CMUX_BUNDLED_CLI_PATH"], "hooks", "codex", "session-start"],
        input=json.dumps({"session_id": session_id, "cwd": os.getcwd()}),
        text=True,
        check=True,
        env=os.environ,
    )
with open(os.environ["FAKE_CODEX_LOG"], "a", encoding="utf-8") as log:
    log.write(json.dumps({"session_id": session_id, "argv": args, "pid": os.environ.get("CMUX_CODEX_PID")}) + "\\n")
""",
        )

        env = os.environ.copy()
        env["PATH"] = f"{wrapper_dir}:{real_dir}:/usr/bin:/bin"
        env["HOME"] = str(root / "home")
        env["CMUX_SURFACE_ID"] = "11111111-1111-1111-1111-111111111111"
        env["CMUX_WORKSPACE_ID"] = "22222222-2222-2222-2222-222222222222"
        env["CMUX_BUNDLED_CLI_PATH"] = str(cli)
        env["FAKE_STATE_PATH"] = str(state_path)
        env["FAKE_CODEX_LOG"] = str(root / "codex.log")
        env["FAKE_SESSION_ID"] = SESSION_ID
        env["CMUX_COMPUTER_USE_APP_ENABLED"] = "0"
        env["CMUX_COMPUTER_USE_MCP_DISABLED"] = "1"
        env.pop("CMUX_SOCKET_PATH", None)

        invocations = [
            ["--yolo"],
            ["resume", SESSION_ID, "-c", "check_for_update_on_startup=false", "--yolo"],
            ["resume", SESSION_ID, "-c", "check_for_update_on_startup=false", "--yolo"],
            ["resume", SESSION_ID, "-c", "check_for_update_on_startup=false", "--yolo"],
        ]
        failures: list[str] = []
        for generation, argv in enumerate(invocations):
            result = subprocess.run(
                [str(wrapper), *argv],
                cwd=root,
                env=env,
                capture_output=True,
                text=True,
                check=False,
            )
            if result.returncode != 0:
                failures.append(f"generation {generation}: wrapper exited {result.returncode}")
            if result.stderr:
                failures.append(f"generation {generation}: unexpected stderr: {result.stderr!r}")

        state = json.loads(state_path.read_text(encoding="utf-8"))
        codex_launches = [json.loads(line) for line in (root / "codex.log").read_text().splitlines()]
        bindings = state["bindings"]
        if [launch["session_id"] for launch in codex_launches] != [SESSION_ID] * 4:
            failures.append(f"session identity changed: {codex_launches}")
        if len(bindings) != 4 or any(binding["session_id"] != SESSION_ID for binding in bindings):
            failures.append(f"resume binding did not survive every generation: {bindings}")
        if sum(1 for binding in bindings if binding["queued"]) != 3:
            failures.append(f"expected one queued resume SessionStart per resume: {bindings}")
        if len({binding["pid"] for binding in bindings}) != 4:
            failures.append(f"binding PID was not refreshed per generation: {bindings}")
        if any("restore codex" in " ".join(map(str, call)) for call in state["calls"]):
            failures.append(f"wrapper injected a duplicate restore selector: {state['calls']}")

        if failures:
            print("FAIL: recursive Codex autoresume chain")
            for failure in failures:
                print(f"- {failure}")
            return 1
        print("PASS: codex --yolo preserved one binding across three recursive resumes")
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
