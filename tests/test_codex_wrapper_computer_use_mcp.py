#!/usr/bin/env python3
"""
Regression test for cmux-codex-wrapper attaching the cmux-owned computer-use MCP
server to Codex sessions without using Codex app-server/computer-use.
"""

from __future__ import annotations

import json
import os
import shutil
import socket
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE_WRAPPER = ROOT / "Resources" / "bin" / "cmux-codex-wrapper"


def make_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


def read_lines(path: Path) -> list[str]:
    if not path.exists():
        return []
    return path.read_text(encoding="utf-8").splitlines()


def expect(condition: bool, message: str, failures: list[str]) -> None:
    if not condition:
        failures.append(message)


def run_wrapper(argv: list[str]) -> tuple[int, list[str], str]:
    with tempfile.TemporaryDirectory(prefix="cmux-codex-wrapper-test-") as td:
        tmp = Path(td)
        wrapper_dir = tmp / "wrapper-bin"
        real_dir = tmp / "real-bin"
        computer_use_dir = tmp / "computer-use-mcp"
        wrapper_dir.mkdir(parents=True)
        real_dir.mkdir(parents=True)
        computer_use_dir.mkdir(parents=True)

        wrapper = wrapper_dir / "cmux-codex-wrapper"
        shutil.copy2(SOURCE_WRAPPER, wrapper)
        wrapper.chmod(0o755)

        args_log = tmp / "codex-args.log"
        socket_path = tmp / "cmux.sock"

        make_executable(
            real_dir / "codex",
            """#!/usr/bin/env bash
set -euo pipefail
: > "$FAKE_CODEX_ARGS_LOG"
for arg in "$@"; do
  printf '%s\\n' "$arg" >> "$FAKE_CODEX_ARGS_LOG"
done
""",
        )
        make_executable(
            wrapper_dir / "cmux",
            """#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--socket" ]]; then
  shift 2
fi
if [[ "${1:-}" == "ping" ]]; then
  exit 0
fi
if [[ "${1:-}" == "hooks" && "${2:-}" == "codex" && "${3:-}" == "inject-args" ]]; then
  printf '%s\\0' --enable hooks -c hooks.cmux-test=true
  exit 0
fi
exit 1
""",
        )
        make_executable(
            wrapper_dir / "cmux-computer-use-provider",
            "#!/usr/bin/env bash\nexit 0\n",
        )
        (computer_use_dir / "cmux-computer-use-mcp.mjs").write_text(
            "// test MCP server\n", encoding="utf-8"
        )

        test_socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        test_socket.bind(str(socket_path))
        try:
            env = os.environ.copy()
            env["PATH"] = f"{wrapper_dir}:{real_dir}:{env.get('PATH', '/usr/bin:/bin')}"
            env["CMUX_SURFACE_ID"] = "surface:test"
            env["CMUX_SOCKET_PATH"] = str(socket_path)
            env["CMUX_BUNDLED_CLI_PATH"] = str(wrapper_dir / "cmux")
            env["FAKE_CODEX_ARGS_LOG"] = str(args_log)
            env.pop("CMUX_CODEX_HOOKS_DISABLED", None)
            env.pop("CMUX_COMPUTER_USE_MCP_DISABLED", None)

            proc = subprocess.run(
                [str(wrapper), *argv],
                cwd=tmp,
                env=env,
                capture_output=True,
                text=True,
                check=False,
            )
        finally:
            test_socket.close()

        return proc.returncode, read_lines(args_log), proc.stderr


def test_codex_gets_cmux_computer_use_mcp(failures: list[str]) -> None:
    code, args, stderr = run_wrapper(["hello"])
    expect(code == 0, f"wrapper exited {code}: {stderr}", failures)
    expect("app-server" not in args, f"must not use codex app-server, got {args}", failures)
    expect(
        "--enable" in args and "hooks" in args and "hooks.cmux-test=true" in args,
        f"expected existing hook injection args to survive, got {args}",
        failures,
    )
    expect("hello" in args, f"expected user prompt to survive, got {args}", failures)

    command_config = next(
        (arg for arg in args if arg.startswith("mcp_servers.cmux-computer-use.command=")),
        None,
    )
    args_config = next(
        (arg for arg in args if arg.startswith("mcp_servers.cmux-computer-use.args=")),
        None,
    )
    expect(command_config is not None, f"missing computer-use command config in {args}", failures)
    expect(args_config is not None, f"missing computer-use args config in {args}", failures)
    if command_config is not None:
        command = json.loads(command_config.split("=", 1)[1])
        expect(Path(command).name == "node", f"expected node command, got {command_config}", failures)
    if args_config is not None:
        mcp_args = json.loads(args_config.split("=", 1)[1])
        expect(
            len(mcp_args) == 1 and mcp_args[0].endswith("/computer-use-mcp/cmux-computer-use-mcp.mjs"),
            f"expected bundled MCP server path, got {args_config}",
            failures,
        )

    computer_use_command_index = args.index("-c") if "-c" in args else -1
    prompt_index = args.index("hello") if "hello" in args else -1
    expect(
        0 <= computer_use_command_index < prompt_index,
        f"expected computer-use config before user argv, got {args}",
        failures,
    )


def main() -> int:
    failures: list[str] = []
    test_codex_gets_cmux_computer_use_mcp(failures)
    if failures:
        for failure in failures:
            print(f"FAIL: {failure}")
        return 1
    print("PASS: codex wrapper injects cmux computer-use MCP")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
