#!/usr/bin/env python3
"""
Regression tests for cmux-codex-wrapper attaching cmux's bundled cua-driver
MCP server to Codex sessions.
"""

from __future__ import annotations

import json
import os
import plistlib
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


def write_helper_info(path: Path, bundle_identifier: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("wb") as file:
        plistlib.dump(
            {
                "CFBundleExecutable": "cmux-cua-driver",
                "CFBundleIdentifier": bundle_identifier,
                "CFBundleName": "cmux Computer Use",
                "CFBundlePackageType": "APPL",
            },
            file,
        )


def read_lines(path: Path) -> list[str]:
    if not path.exists():
        return []
    return path.read_text(encoding="utf-8").splitlines()


def expect(condition: bool, message: str, failures: list[str]) -> None:
    if not condition:
        failures.append(message)


def arg_value(args: list[str], prefix: str) -> str | None:
    return next((arg.split("=", 1)[1] for arg in args if arg.startswith(prefix)), None)


def expect_scrubbed_mcp_env(
    args: list[str],
    failures: list[str],
    context: str,
    *,
    helper_owned: bool,
) -> None:
    embedded = arg_value(args, "mcp_servers.cmux-computer-use.env.CUA_DRIVER_EMBEDDED=")
    daemon_app = arg_value(args, "mcp_servers.cmux-computer-use.env.CUA_DRIVER_DAEMON_APP=")
    force_proxy = arg_value(args, "mcp_servers.cmux-computer-use.env.CUA_DRIVER_RS_MCP_FORCE_PROXY=")
    external_flow = arg_value(args, "mcp_servers.cmux-computer-use.env.CUA_DRIVER_RS_EXTERNAL_PERMISSION_FLOW=")
    auth_token = arg_value(args, "mcp_servers.cmux-computer-use.env.CUA_DRIVER_SOCKET_AUTH_TOKEN=")
    default_session = arg_value(args, "mcp_servers.cmux-computer-use.env.CUA_DRIVER_DEFAULT_SESSION=")
    permissions_gate = arg_value(args, "mcp_servers.cmux-computer-use.env.CUA_DRIVER_RS_PERMISSIONS_GATE=")
    telemetry = arg_value(args, "mcp_servers.cmux-computer-use.env.CUA_DRIVER_RS_TELEMETRY_ENABLED=")
    update_check = arg_value(args, "mcp_servers.cmux-computer-use.env.CUA_DRIVER_RS_UPDATE_CHECK=")
    cursor_gradient = arg_value(args, "mcp_servers.cmux-computer-use.env.CUA_DRIVER_CURSOR_GRADIENT=")
    cursor_bloom = arg_value(args, "mcp_servers.cmux-computer-use.env.CUA_DRIVER_CURSOR_BLOOM=")
    cursor_label = arg_value(args, "mcp_servers.cmux-computer-use.env.CUA_DRIVER_CURSOR_LABEL=")
    state_dir = arg_value(args, "mcp_servers.cmux-computer-use.env.CUA_DRIVER_STATE_DIR=")
    node_options = arg_value(args, "mcp_servers.cmux-computer-use.env.NODE_OPTIONS=")
    bun_options = arg_value(args, "mcp_servers.cmux-computer-use.env.BUN_OPTIONS=")
    expect(embedded is None, f"{context}: computer use must never be embedded: {args}", failures)
    expect(daemon_app is None, f"{context}: wrapper must not launch the helper daemon: {args}", failures)
    expect(permissions_gate is None, f"{context}: proxy must not own the daemon permission gate: {args}", failures)
    expect(force_proxy is not None, f"{context}: missing forced proxy config in {args}", failures)
    expect(external_flow is not None, f"{context}: missing proxy permission-wait config in {args}", failures)
    expect(auth_token is not None, f"{context}: missing daemon authentication config in {args}", failures)
    expect(default_session is not None, f"{context}: missing CUA_DRIVER_DEFAULT_SESSION config in {args}", failures)
    expect(telemetry is not None, f"{context}: missing telemetry opt-out config in {args}", failures)
    expect(update_check is not None, f"{context}: missing update-check opt-out config in {args}", failures)
    expect(cursor_gradient is not None, f"{context}: missing cursor gradient config in {args}", failures)
    expect(cursor_bloom is not None, f"{context}: missing cursor bloom config in {args}", failures)
    expect(cursor_label is not None, f"{context}: missing cursor label config in {args}", failures)
    expect(state_dir is not None, f"{context}: missing state directory config in {args}", failures)
    expect(node_options is not None, f"{context}: missing NODE_OPTIONS scrub config in {args}", failures)
    expect(bun_options is not None, f"{context}: missing BUN_OPTIONS scrub config in {args}", failures)
    if embedded is not None:
        expect(json.loads(embedded) == "1", f"{context}: expected embedded env, got {embedded}", failures)
    if default_session is not None:
        expect(json.loads(default_session).startswith("cmux-"), f"{context}: expected cmux- default session, got {default_session}", failures)
    if permissions_gate is not None:
        expect(json.loads(permissions_gate) == "0", f"{context}: expected permission gate disabled, got {permissions_gate}", failures)
    if force_proxy is not None:
        expect(json.loads(force_proxy) == "1", f"{context}: expected forced proxy, got {force_proxy}", failures)
    if external_flow is not None:
        expect(
            json.loads(external_flow) == "0",
            f"{context}: proxy must wait for the helper's grants, got {external_flow}",
            failures,
        )
    if auth_token is not None:
        expect(json.loads(auth_token) == "cmux-test-auth-token", f"{context}: unexpected daemon auth token", failures)
    if telemetry is not None:
        expect(json.loads(telemetry) == "false", f"{context}: expected telemetry disabled, got {telemetry}", failures)
    if update_check is not None:
        expect(json.loads(update_check) == "false", f"{context}: expected update check disabled, got {update_check}", failures)
    if cursor_gradient is not None:
        expect(json.loads(cursor_gradient) == "#12c7f5,#2d8cff,#6c5cff", f"{context}: unexpected cursor gradient {cursor_gradient}", failures)
    if cursor_bloom is not None:
        expect(json.loads(cursor_bloom) == "#2d8cff", f"{context}: unexpected cursor bloom {cursor_bloom}", failures)
    if cursor_label is not None:
        expect(json.loads(cursor_label) == "cmux", f"{context}: unexpected cursor label {cursor_label}", failures)
    if state_dir is not None:
        expect(
            json.loads(state_dir).endswith("/Library/Application Support/cmux/computer-use/runtime/default/state"),
            f"{context}: unexpected state dir {state_dir}",
            failures,
        )
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
    group_writable_ancestor: bool = False,
    disabled: bool = False,
    hooks_inject_fails: bool = False,
    hooks_disabled: bool = False,
    dead_socket: bool = False,
    stale_helper_bundle_id: str | None = None,
    auth_token: bool = True,
    auth_token_file: bool = False,
) -> tuple[int, list[str], str, Path]:
    with tempfile.TemporaryDirectory(prefix="cmux-codex-wrapper-test-") as td:
        tmp = Path(td)
        wrapper_dir = tmp / "cmux.app" / "Contents" / "Resources" / "bin"
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
if [[ -n "${FAKE_HELPER_INFO_PLIST:-}" && -f "$FAKE_HELPER_INFO_PLIST" ]]; then
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$FAKE_HELPER_INFO_PLIST" >&2
fi
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
            helper_driver = (
                tmp
                / "cmux.app"
                / "Contents"
                / "Library"
                / "cmux Computer Use.app"
                / "Contents"
                / "MacOS"
                / "cmux-cua-driver"
            )
            helper_driver.parent.mkdir(parents=True)
            make_executable(
                helper_driver,
                "#!/usr/bin/env bash\nexit 0\n",
            )
            write_helper_info(
                helper_driver.parents[1] / "Info.plist",
                "com.cmuxterm.test.current.computer-use",
            )

        test_socket: socket.socket | None = None
        if not dead_socket:
            test_socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            test_socket.bind(str(socket_path))
        try:
            env = os.environ.copy()
            sandbox_home = tmp / "home"
            sandbox_home.mkdir()
            if bundled_driver and stale_helper_bundle_id is not None:
                stale_driver = (
                    sandbox_home
                    / "Library"
                    / "Application Support"
                    / "cmux"
                    / "computer-use"
                    / "helper"
                    / "cmux Computer Use.app"
                    / "Contents"
                    / "MacOS"
                    / "cmux-cua-driver"
                )
                stale_driver.parent.mkdir(parents=True, exist_ok=True)
                make_executable(stale_driver, "#!/usr/bin/env bash\nexit 0\n")
                stale_info = stale_driver.parents[1] / "Info.plist"
                write_helper_info(stale_info, stale_helper_bundle_id)
                env["FAKE_HELPER_INFO_PLIST"] = str(stale_info)
            env["HOME"] = str(sandbox_home)
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
            env.pop("CMUX_CUA_AUTH_TOKEN_FILE", None)
            env.pop("CUA_DRIVER_SOCKET_AUTH_TOKEN", None)
            if auth_token_file:
                token_file = tmp / "auth-token"
                token_file.write_text("cmux-test-auth-token\n", encoding="utf-8")
                token_file.chmod(0o600)
                env["CMUX_CUA_AUTH_TOKEN_FILE"] = str(token_file)
            elif auth_token:
                env["CUA_DRIVER_SOCKET_AUTH_TOKEN"] = "cmux-test-auth-token"
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
            if group_writable_ancestor:
                # Group-writable (but not world-writable) parent dir with a
                # correctly-permissioned driver file: rejection can only come
                # from the ancestor group-write check.
                ancestor_dir = tmp / "group-writable-dir"
                ancestor_dir.mkdir()
                ancestor_dir.chmod(0o775)
                ancestor_driver = ancestor_dir / "cua-driver"
                make_executable(ancestor_driver, "#!/usr/bin/env bash\nexit 0\n")
                env["CMUX_CUA_DRIVER"] = str(ancestor_driver)
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
        command_path = Path(command)
        expect(command_path.name == "cmux-cua-driver", f"expected bundled driver command, got {cmd}", failures)
        expect(
            command_path.parts[-4:] == (
                "cmux Computer Use.app",
                "Contents",
                "MacOS",
                "cmux-cua-driver",
            ),
            f"expected signed cmux Computer Use proxy command, got {command}",
            failures,
        )
    if mcp_args_raw is not None:
        mcp_args = json.loads(mcp_args_raw)
        expect(
            len(mcp_args) == 3 and mcp_args[:2] == ["mcp", "--socket"],
            f"expected shared daemon proxy args, got {mcp_args_raw}",
            failures,
        )
        if len(mcp_args) == 3:
            expect(
                mcp_args[2].startswith("/tmp/cmux-cua-") and mcp_args[2].endswith("/default/cua.sock"),
                f"expected short per-user daemon socket, got {mcp_args[2]!r}",
                failures,
            )
    expect_scrubbed_mcp_env(args, failures, "bundled cua-driver", helper_owned=True)

    computer_use_command_index = args.index("-c") if "-c" in args else -1
    prompt_index = args.index("hello") if "hello" in args else -1
    expect(
        0 <= computer_use_command_index < prompt_index,
        f"expected computer-use config before user argv, got {args}",
        failures,
    )


def test_codex_computer_use_wrapper_is_a_pure_proxy(failures: list[str]) -> None:
    source = SOURCE_WRAPPER.read_text(encoding="utf-8")
    expect(
        "cmux_computer_use_standalone_helper" not in source,
        "codex wrapper must not install or replace the standalone helper",
        failures,
    )
    expect(
        "CUA_DRIVER_DAEMON_APP" not in source,
        "codex wrapper must not own helper daemon launch",
        failures,
    )
    expect(
        "CUA_DRIVER_RS_MCP_FORCE_PROXY" in source,
        "codex wrapper must force the shared daemon proxy path",
        failures,
    )


def test_codex_reads_private_daemon_credential_file(failures: list[str]) -> None:
    code, args, stderr, _ = run_wrapper(
        ["hello"],
        auth_token=False,
        auth_token_file=True,
    )
    expect(code == 0, f"auth file wrapper exited {code}: {stderr}", failures)
    expect_scrubbed_mcp_env(args, failures, "private daemon credential file", helper_owned=True)


def test_codex_replaces_stale_standalone_helper_identity(failures: list[str]) -> None:
    code, _, stderr, _ = run_wrapper(
        ["hello"],
        stale_helper_bundle_id="com.cmuxterm.test.stale.computer-use",
    )
    expect(code == 0, f"stale helper identity: wrapper exited {code}: {stderr}", failures)
    expect(
        "com.cmuxterm.test.current.computer-use" in stderr,
        f"stale helper identity: expected current helper bundle id, got {stderr!r}",
        failures,
    )
    expect(
        "com.cmuxterm.test.stale.computer-use" not in stderr,
        f"stale helper identity: reused stale helper bundle id: {stderr!r}",
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
    expect_scrubbed_mcp_env(args, failures, "override cua-driver", helper_owned=False)


def test_codex_fork_gets_hooks_and_cua_driver(failures: list[str]) -> None:
    # `codex fork` starts a new interactive session from a previous one, so it
    # must receive hook injection and the computer-use MCP like exec/resume.
    code, args, stderr, _ = run_wrapper(["fork", "0e2f4bd8-2c34-4e6e-9d2b-000000000000"])
    expect(code == 0, f"fork wrapper exited {code}: {stderr}", failures)
    expect(
        "--enable" in args and "hooks" in args and "hooks.cmux-test=true" in args,
        f"expected hook injection for fork sessions, got {args}",
        failures,
    )
    expect("fork" in args, f"expected fork subcommand to survive, got {args}", failures)
    cmd = command_config(args)
    expect(cmd is not None, f"missing computer-use command config for fork in {args}", failures)
    if cmd is not None:
        expect(
            Path(json.loads(cmd)).name == "cmux-cua-driver",
            f"expected bundled driver command for fork, got {cmd}",
            failures,
        )
    first_config_index = args.index("-c") if "-c" in args else -1
    fork_index = args.index("fork") if "fork" in args else -1
    expect(
        0 <= first_config_index < fork_index,
        f"expected injected config before the fork subcommand, got {args}",
        failures,
    )


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


def test_codex_skips_when_daemon_credential_is_missing(failures: list[str]) -> None:
    code, args, stderr, _ = run_wrapper(["hello"], auth_token=False)
    expect(code == 0, f"missing-auth wrapper exited {code}: {stderr}", failures)
    expect(command_config(args) is None, f"expected no injection without daemon credential, got {args}", failures)


def test_codex_hooks_disabled_is_fully_inert(failures: list[str]) -> None:
    # CMUX_CODEX_HOOKS_DISABLED is the documented master opt-out: the wrapper
    # does nothing but exec the real codex — no hook args, no computer-use
    # attach, no argv changes.
    code, args, stderr, _ = run_wrapper(["hello"], hooks_disabled=True)
    expect(code == 0, f"hooks-disabled wrapper exited {code}: {stderr}", failures)
    expect(
        args == ["hello"],
        f"expected fully inert passthrough argv with hooks disabled, got {args}",
        failures,
    )


def test_codex_fails_closed_for_computer_use_when_socket_dead(failures: list[str]) -> None:
    # CMUX_SURFACE_ID can be stale (a shell that outlived cmux). Without a
    # live socket ping there is no authoritative evidence cmux owns this
    # process chain, so the TCC-sensitive driver must NOT be attached.
    code, args, stderr, _ = run_wrapper(["hello"], dead_socket=True)
    expect(code == 0, f"dead-socket wrapper exited {code}: {stderr}", failures)
    expect(
        "hooks.cmux-test=true" not in args,
        f"expected no hook args with dead socket, got {args}",
        failures,
    )
    expect("hello" in args, f"expected user prompt to survive, got {args}", failures)
    expect(
        command_config(args) is None,
        f"expected NO computer-use attach with dead socket (fail closed), got {args}",
        failures,
    )


def test_codex_rejects_cua_driver_override_under_group_writable_ancestor(failures: list[str]) -> None:
    # Write permission on a parent directory allows renaming the driver away
    # and dropping a replacement regardless of the file's own permissions, so
    # group-writable ancestors are as disqualifying as world-writable ones.
    code, args, stderr, _ = run_wrapper(
        ["hello"],
        bundled_driver=False,
        group_writable_ancestor=True,
    )
    expect(code == 0, f"group-writable ancestor wrapper exited {code}: {stderr}", failures)
    expect(command_config(args) is None, f"expected group-writable ancestor rejection, got {args}", failures)


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
    expect_scrubbed_mcp_env(args, failures, "hook-injection failure", helper_owned=True)


def test_codex_skips_for_strict_mcp_config(failures: list[str]) -> None:
    code, args, stderr, _ = run_wrapper(["--strict-mcp-config", "-c", "mcp_servers.user.command=\"x\"", "hello"])
    expect(code == 0, f"strict wrapper exited {code}: {stderr}", failures)
    expect(command_config(args) is None, f"expected no cmux injection with strict config, got {args}", failures)
    expect("mcp_servers.user.command=\"x\"" in args, f"expected user's config to survive, got {args}", failures)


def main() -> int:
    failures: list[str] = []
    test_codex_gets_cmux_cua_driver(failures)
    test_codex_computer_use_wrapper_is_a_pure_proxy(failures)
    test_codex_reads_private_daemon_credential_file(failures)
    test_codex_uses_trusted_cua_driver_override(failures)
    test_codex_rejects_cua_driver_override_under_world_writable_ancestor(failures)
    test_codex_skips_when_driver_unavailable(failures)
    test_codex_skips_when_disabled(failures)
    test_codex_skips_when_daemon_credential_is_missing(failures)
    test_codex_fork_gets_hooks_and_cua_driver(failures)
    test_codex_hooks_disabled_is_fully_inert(failures)
    test_codex_fails_closed_for_computer_use_when_socket_dead(failures)
    test_codex_rejects_cua_driver_override_under_group_writable_ancestor(failures)
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
