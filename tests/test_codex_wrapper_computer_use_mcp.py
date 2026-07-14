#!/usr/bin/env python3
"""
Regression tests for cmux-codex-wrapper attaching cmux's bundled cua-driver
MCP server to Codex sessions.
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


def arg_value(args: list[str], prefix: str) -> str | None:
    return next((arg.split("=", 1)[1] for arg in args if arg.startswith(prefix)), None)


def expect_scrubbed_mcp_env(args: list[str], failures: list[str], context: str) -> None:
    embedded = arg_value(args, "mcp_servers.cmux-computer-use.env.CUA_DRIVER_EMBEDDED=")
    telemetry = arg_value(args, "mcp_servers.cmux-computer-use.env.CUA_DRIVER_RS_TELEMETRY_ENABLED=")
    update_check = arg_value(args, "mcp_servers.cmux-computer-use.env.CUA_DRIVER_RS_UPDATE_CHECK=")
    node_options = arg_value(args, "mcp_servers.cmux-computer-use.env.NODE_OPTIONS=")
    bun_options = arg_value(args, "mcp_servers.cmux-computer-use.env.BUN_OPTIONS=")
    expect(embedded is not None, f"{context}: missing CUA_DRIVER_EMBEDDED config in {args}", failures)
    expect(telemetry is not None, f"{context}: missing telemetry opt-out config in {args}", failures)
    expect(update_check is not None, f"{context}: missing update-check opt-out config in {args}", failures)
    expect(node_options is not None, f"{context}: missing NODE_OPTIONS scrub config in {args}", failures)
    expect(bun_options is not None, f"{context}: missing BUN_OPTIONS scrub config in {args}", failures)
    if embedded is not None:
        expect(json.loads(embedded) == "1", f"{context}: expected embedded env, got {embedded}", failures)
    if telemetry is not None:
        expect(json.loads(telemetry) == "false", f"{context}: expected telemetry disabled, got {telemetry}", failures)
    if update_check is not None:
        expect(json.loads(update_check) == "false", f"{context}: expected update check disabled, got {update_check}", failures)
    if node_options is not None:
        expect(json.loads(node_options) == "", f"{context}: expected empty NODE_OPTIONS, got {node_options}", failures)
    if bun_options is not None:
        expect(json.loads(bun_options) == "", f"{context}: expected empty BUN_OPTIONS, got {bun_options}", failures)


def run_wrapper(
    argv: list[str],
    *,
    bundled_driver: bool = True,
    override_driver: bool = False,
    untrusted_override: bool = False,
    group_writable_override: bool = False,
    disabled: bool = False,
    hooks_inject_fails: bool = False,
    hooks_disabled: bool = False,
    dead_socket: bool = False,
) -> tuple[int, list[str], str, Path]:
    with tempfile.TemporaryDirectory(prefix="cmux-codex-wrapper-test-") as td:
        tmp = Path(td)
        wrapper_dir = tmp / "wrapper-bin"
        real_dir = tmp / "real-bin"
        wrapper_dir.mkdir(parents=True)
        real_dir.mkdir(parents=True)

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
        inject_args_body = (
            "  exit 1\n"
            if hooks_inject_fails
            else "  printf '%s\\0' --enable hooks -c hooks.cmux-test=true\n  exit 0\n"
        )
        make_executable(
            wrapper_dir / "cmux",
            f"""#!/usr/bin/env bash
set -euo pipefail
if [[ "${{1:-}}" == "--socket" ]]; then
  shift 2
fi
if [[ "${{1:-}}" == "ping" ]]; then
  exit 0
fi
if [[ "${{1:-}}" == "hooks" && "${{2:-}}" == "codex" && "${{3:-}}" == "inject-args" ]]; then
{inject_args_body}fi
exit 1
""",
        )
        if bundled_driver:
            make_executable(wrapper_dir / "cmux-cua-driver", "#!/usr/bin/env bash\nexit 0\n")

        test_socket: socket.socket | None = None
        if not dead_socket:
            test_socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            test_socket.bind(str(socket_path))
        try:
            env = os.environ.copy()
            env["PATH"] = f"{wrapper_dir}:{real_dir}:{env.get('PATH', '/usr/bin:/bin')}"
            env["CMUX_SURFACE_ID"] = "surface:test"
            env["CMUX_SOCKET_PATH"] = str(socket_path)
            env["CMUX_BUNDLED_CLI_PATH"] = str(wrapper_dir / "cmux")
            env["FAKE_CODEX_ARGS_LOG"] = str(args_log)
            env["NODE_OPTIONS"] = "--require=/tmp/cmux-mcp-preload-should-not-load.js"
            env["BUN_OPTIONS"] = "--preload=/tmp/cmux-mcp-preload-should-not-load.js"
            env.pop("CMUX_CODEX_HOOKS_DISABLED", None)
            env.pop("CMUX_COMPUTER_USE_MCP_DISABLED", None)
            env.pop("CMUX_CUA_DRIVER", None)
            if override_driver:
                env["CMUX_CUA_DRIVER"] = "/bin/echo"
            if untrusted_override:
                untrusted_dir = tmp / "world-writable"
                untrusted_dir.mkdir()
                untrusted_dir.chmod(0o777)
                untrusted_driver = untrusted_dir / "cua-driver"
                make_executable(untrusted_driver, "#!/usr/bin/env bash\nexit 0\n")
                env["CMUX_CUA_DRIVER"] = str(untrusted_driver)
            if group_writable_override:
                override_dir = tmp / "override-bin"
                override_dir.mkdir()
                group_writable_driver = override_dir / "cua-driver"
                make_executable(group_writable_driver, "#!/usr/bin/env bash\nexit 0\n")
                group_writable_driver.chmod(0o775)
                env["CMUX_CUA_DRIVER"] = str(group_writable_driver)
            if disabled:
                env["CMUX_COMPUTER_USE_MCP_DISABLED"] = "1"
            if hooks_disabled:
                env["CMUX_CODEX_HOOKS_DISABLED"] = "1"

            proc = subprocess.run(
                [str(wrapper), *argv],
                cwd=tmp,
                env=env,
                capture_output=True,
                text=True,
                check=False,
            )
        finally:
            if test_socket is not None:
                test_socket.close()

        return proc.returncode, read_lines(args_log), proc.stderr, tmp


def command_config(args: list[str]) -> str | None:
    return arg_value(args, "mcp_servers.cmux-computer-use.command=")


def args_config(args: list[str]) -> str | None:
    return arg_value(args, "mcp_servers.cmux-computer-use.args=")


def test_codex_gets_cmux_cua_driver(failures: list[str]) -> None:
    code, args, stderr, _ = run_wrapper(["hello"])
    expect(code == 0, f"wrapper exited {code}: {stderr}", failures)
    expect("app-server" not in args, f"must not use codex app-server, got {args}", failures)
    expect(
        "--enable" in args and "hooks" in args and "hooks.cmux-test=true" in args,
        f"expected existing hook injection args to survive, got {args}",
        failures,
    )
    expect("hello" in args, f"expected user prompt to survive, got {args}", failures)

    cmd = command_config(args)
    mcp_args_raw = args_config(args)
    expect(cmd is not None, f"missing computer-use command config in {args}", failures)
    expect(mcp_args_raw is not None, f"missing computer-use args config in {args}", failures)
    if cmd is not None:
        command = json.loads(cmd)
        expect(Path(command).name == "cmux-cua-driver", f"expected bundled driver command, got {cmd}", failures)
    if mcp_args_raw is not None:
        mcp_args = json.loads(mcp_args_raw)
        expect(mcp_args == ["--embedded"], f"expected embedded driver args, got {mcp_args_raw}", failures)
    expect_scrubbed_mcp_env(args, failures, "bundled cua-driver")

    computer_use_command_index = args.index("-c") if "-c" in args else -1
    prompt_index = args.index("hello") if "hello" in args else -1
    expect(
        0 <= computer_use_command_index < prompt_index,
        f"expected computer-use config before user argv, got {args}",
        failures,
    )


def test_codex_uses_trusted_cua_driver_override(failures: list[str]) -> None:
    code, args, stderr, _ = run_wrapper(["hello"], bundled_driver=False, override_driver=True)
    expect(code == 0, f"override wrapper exited {code}: {stderr}", failures)
    cmd = command_config(args)
    expect(cmd is not None, f"override missing command config in {args}", failures)
    if cmd is not None:
        command = json.loads(cmd)
        expect(Path(command).name == "echo", f"expected override driver command, got {cmd}", failures)
    expect_scrubbed_mcp_env(args, failures, "override cua-driver")


def test_codex_rejects_cua_driver_override_under_world_writable_ancestor(failures: list[str]) -> None:
    code, args, stderr, _ = run_wrapper(
        ["hello"],
        bundled_driver=False,
        untrusted_override=True,
    )
    expect(code == 0, f"untrusted override wrapper exited {code}: {stderr}", failures)
    expect(command_config(args) is None, f"expected untrusted override rejection, got {args}", failures)


def test_codex_skips_when_driver_unavailable(failures: list[str]) -> None:
    code, args, stderr, _ = run_wrapper(["hello"], bundled_driver=False)
    expect(code == 0, f"no-driver wrapper exited {code}: {stderr}", failures)
    expect(command_config(args) is None, f"expected no injection without driver, got {args}", failures)


def test_codex_skips_when_disabled(failures: list[str]) -> None:
    code, args, stderr, _ = run_wrapper(["hello"], disabled=True)
    expect(code == 0, f"disabled wrapper exited {code}: {stderr}", failures)
    expect(command_config(args) is None, f"expected no injection with kill switch, got {args}", failures)


def test_codex_gets_cua_driver_when_hooks_disabled(failures: list[str]) -> None:
    # CMUX_CODEX_HOOKS_DISABLED opts out of HOOK injection only. The bundled
    # computer-use MCP is local, independent of the hook machinery, and has its
    # own kill switch, so cmux-launched sessions keep it.
    code, args, stderr, _ = run_wrapper(["hello"], hooks_disabled=True)
    expect(code == 0, f"hooks-disabled wrapper exited {code}: {stderr}", failures)
    expect(
        "hooks.cmux-test=true" not in args and "--enable" not in args,
        f"expected no hook args with hooks disabled, got {args}",
        failures,
    )
    expect("hello" in args, f"expected user prompt to survive, got {args}", failures)
    cmd = command_config(args)
    expect(cmd is not None, f"missing computer-use command config with hooks disabled in {args}", failures)
    if cmd is not None:
        expect(
            Path(json.loads(cmd)).name == "cmux-cua-driver",
            f"expected bundled driver command with hooks disabled, got {cmd}",
            failures,
        )
    expect_scrubbed_mcp_env(args, failures, "hooks disabled")


def test_codex_gets_cua_driver_when_socket_dead(failures: list[str]) -> None:
    # A stale/dead cmux socket breaks hook delivery only; the bundled
    # computer-use MCP does not need the socket and must survive passthrough.
    code, args, stderr, _ = run_wrapper(["hello"], dead_socket=True)
    expect(code == 0, f"dead-socket wrapper exited {code}: {stderr}", failures)
    expect(
        "hooks.cmux-test=true" not in args,
        f"expected no hook args with dead socket, got {args}",
        failures,
    )
    expect("hello" in args, f"expected user prompt to survive, got {args}", failures)
    cmd = command_config(args)
    expect(cmd is not None, f"missing computer-use command config with dead socket in {args}", failures)
    if cmd is not None:
        expect(
            Path(json.loads(cmd)).name == "cmux-cua-driver",
            f"expected bundled driver command with dead socket, got {cmd}",
            failures,
        )
    expect_scrubbed_mcp_env(args, failures, "dead socket")


def test_codex_rejects_group_writable_cua_driver_override(failures: list[str]) -> None:
    # A group-writable override binary could be swapped by another local user
    # and then run under cmux's TCC identity; the wrapper must reject it.
    code, args, stderr, _ = run_wrapper(
        ["hello"],
        bundled_driver=False,
        group_writable_override=True,
    )
    expect(code == 0, f"group-writable override wrapper exited {code}: {stderr}", failures)
    expect(command_config(args) is None, f"expected group-writable override rejection, got {args}", failures)


def test_codex_gets_cua_driver_when_hook_injection_fails(failures: list[str]) -> None:
    # The bundled driver is local and independent of the cmux hook socket, so
    # a failed `hooks codex inject-args` emit must not drop computer use.
    code, args, stderr, _ = run_wrapper(["hello"], hooks_inject_fails=True)
    expect(code == 0, f"hook-failure wrapper exited {code}: {stderr}", failures)
    expect(
        "hooks.cmux-test=true" not in args,
        f"expected no hook args when inject-args fails, got {args}",
        failures,
    )
    expect("hello" in args, f"expected user prompt to survive, got {args}", failures)
    cmd = command_config(args)
    expect(cmd is not None, f"missing computer-use command config after hook failure in {args}", failures)
    if cmd is not None:
        command = json.loads(cmd)
        expect(
            Path(command).name == "cmux-cua-driver",
            f"expected bundled driver command after hook failure, got {cmd}",
            failures,
        )
    expect_scrubbed_mcp_env(args, failures, "hook-injection failure")


def test_codex_skips_for_strict_mcp_config(failures: list[str]) -> None:
    code, args, stderr, _ = run_wrapper(["--strict-mcp-config", "-c", "mcp_servers.user.command=\"x\"", "hello"])
    expect(code == 0, f"strict wrapper exited {code}: {stderr}", failures)
    expect(command_config(args) is None, f"expected no cmux injection with strict config, got {args}", failures)
    expect("mcp_servers.user.command=\"x\"" in args, f"expected user's config to survive, got {args}", failures)


def main() -> int:
    failures: list[str] = []
    test_codex_gets_cmux_cua_driver(failures)
    test_codex_uses_trusted_cua_driver_override(failures)
    test_codex_rejects_cua_driver_override_under_world_writable_ancestor(failures)
    test_codex_skips_when_driver_unavailable(failures)
    test_codex_skips_when_disabled(failures)
    test_codex_gets_cua_driver_when_hooks_disabled(failures)
    test_codex_gets_cua_driver_when_socket_dead(failures)
    test_codex_rejects_group_writable_cua_driver_override(failures)
    test_codex_gets_cua_driver_when_hook_injection_fails(failures)
    test_codex_skips_for_strict_mcp_config(failures)
    if failures:
        for failure in failures:
            print(f"FAIL: {failure}")
        return 1
    print("PASS: codex wrapper injects cmux cua-driver MCP")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
