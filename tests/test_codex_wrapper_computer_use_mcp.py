#!/usr/bin/env python3
"""
Regression tests for cmux-codex-wrapper attaching cmux's bundled Computer Use
MCP client to Codex sessions.
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
SOURCE_CLAUDE_WRAPPER = ROOT / "Resources" / "bin" / "cmux-claude-wrapper"
SOURCE_LINK_POLICY = ROOT / "skills" / "cmux-cua" / "link-policy.sh"

# This is the public Codex compatibility roster. Keep the contract here in
# the same order as Resources/cmux-cua/SKILL.md: a fresh Codex process must
# complete MCP discovery before it accepts its first user turn.
CMUX_CUA_TOOL_ROSTER = [
    "list_apps",
    "get_app_state",
    "click",
    "perform_secondary_action",
    "set_value",
    "select_text",
    "scroll",
    "drag",
    "press_key",
    "type_text",
]


FAKE_MCP_HELPER = r'''#!/usr/bin/env python3
import json
import os
import sys

TOOLS = %r
TRACE = os.environ.get("FAKE_MCP_TRACE_LOG")


def record(event, payload=None):
    if not TRACE:
        return
    value = {"event": event}
    if payload is not None:
        value["payload"] = payload
    with open(TRACE, "a", encoding="utf-8") as stream:
        stream.write(json.dumps(value, sort_keys=True) + "\n")


def receive():
    headers = {}
    while True:
        line = sys.stdin.buffer.readline()
        if not line:
            return None
        if line in (b"\r\n", b"\n"):
            break
        key, value = line.decode("ascii").split(":", 1)
        headers[key.lower().strip()] = value.strip()
    length = int(headers["content-length"])
    body = sys.stdin.buffer.read(length)
    if len(body) != length:
        return None
    return json.loads(body.decode("utf-8"))


def send(message):
    body = json.dumps(message, separators=(",", ":")).encode("utf-8")
    sys.stdout.buffer.write(
        ("Content-Length: %%d\r\n\r\n" %% len(body)).encode("ascii") + body
    )
    sys.stdout.buffer.flush()


record(
    "helper:started",
    {
        "force_proxy": os.environ.get("CMUX_CUA_MCP_FORCE_PROXY"),
        "external_permission_flow": os.environ.get("CMUX_CUA_EXTERNAL_PERMISSION_FLOW"),
        "auth_present": bool(os.environ.get("CMUX_CUA_SOCKET_AUTH_TOKEN")),
        "daemon_app": os.environ.get("CMUX_CUA_DAEMON_APP"),
        "permissions_gate": os.environ.get("CMUX_CUA_PERMISSIONS_GATE"),
    },
)

while True:
    message = receive()
    if message is None:
        break
    method = message.get("method")
    if method == "initialize":
        record("helper:initialize")
        send(
            {
                "jsonrpc": "2.0",
                "id": message.get("id"),
                "result": {
                    "protocolVersion": "2025-06-18",
                    "capabilities": {"tools": {}},
                    "serverInfo": {"name": "cmux-cua-test", "version": "1"},
                },
            }
        )
    elif method == "notifications/initialized":
        record("helper:initialized")
    elif method == "tools/list":
        record("helper:tools/list")
        send(
            {
                "jsonrpc": "2.0",
                "id": message.get("id"),
                "result": {
                    "tools": [
                        {
                            "name": name,
                            "description": "test tool",
                            "inputSchema": {"type": "object"},
                        }
                        for name in TOOLS
                    ]
                },
            }
        )
    else:
        record("helper:unexpected", {"method": method})
'''


FAKE_CODEX = r'''#!/usr/bin/env python3
import json
import os
import subprocess
import sys

TRACE = os.environ.get("FAKE_MCP_TRACE_LOG")
ARGS_LOG = os.environ["FAKE_CODEX_ARGS_LOG"]


def record(event, payload=None):
    if not TRACE:
        return
    value = {"event": event}
    if payload is not None:
        value["payload"] = payload
    with open(TRACE, "a", encoding="utf-8") as stream:
        stream.write(json.dumps(value, sort_keys=True) + "\n")


def config(prefix, args):
    for arg in args:
        if arg.startswith(prefix):
            return arg.split("=", 1)[1]
    return None


def send(stream, message):
    body = json.dumps(message, separators=(",", ":")).encode("utf-8")
    stream.write(
        ("Content-Length: %%d\r\n\r\n" %% len(body)).encode("ascii") + body
    )
    stream.flush()


def receive(stream):
    headers = {}
    while True:
        line = stream.readline()
        if not line:
            raise RuntimeError("MCP helper closed before a response")
        if line in (b"\r\n", b"\n"):
            break
        key, value = line.decode("ascii").split(":", 1)
        headers[key.lower().strip()] = value.strip()
    length = int(headers["content-length"])
    body = stream.read(length)
    if len(body) != length:
        raise RuntimeError("short MCP response")
    return json.loads(body.decode("utf-8"))


args = sys.argv[1:]
with open(ARGS_LOG, "w", encoding="utf-8") as stream:
    for arg in args:
        stream.write(arg + "\n")

if os.environ.get("FAKE_MCP_HANDSHAKE") == "1":
    command_raw = config("mcp_servers.cmux-cua.command=", args)
    mcp_args_raw = config("mcp_servers.cmux-cua.args=", args)
    if not command_raw or not mcp_args_raw:
        record("codex:missing-mcp-config")
        raise SystemExit(42)
    command = json.loads(command_raw)
    mcp_args = json.loads(mcp_args_raw)
    child_env = os.environ.copy()
    env_prefix = "mcp_servers.cmux-cua.env."
    for arg in args:
        if not arg.startswith(env_prefix):
            continue
        key, value = arg[len(env_prefix) :].split("=", 1)
        child_env[key] = json.loads(value)
    child_env["FAKE_MCP_TRACE_LOG"] = TRACE or ""
    record("codex:mcp_spawn", {"command": command, "args": mcp_args})
    helper = subprocess.Popen(
        [command, *mcp_args],
        env=child_env,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    try:
        assert helper.stdin is not None and helper.stdout is not None
        record("codex:mcp_initialize")
        send(
            helper.stdin,
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {
                    "protocolVersion": "2025-06-18",
                    "capabilities": {},
                    "clientInfo": {"name": "codex-test", "version": "1"},
                },
            },
        )
        initialize_result = receive(helper.stdout)
        record("codex:mcp_initialize_result", initialize_result)
        send(
            helper.stdin,
            {"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}},
        )
        record("codex:mcp_initialized")
        record("codex:mcp_tools_list")
        send(
            helper.stdin,
            {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}},
        )
        tools_result = receive(helper.stdout)
        names = [tool.get("name") for tool in tools_result.get("result", {}).get("tools", [])]
        record("codex:mcp_tools_list_result", {"names": names})
        if names != %r:
            record("codex:mcp_roster_mismatch", {"names": names})
            raise SystemExit(43)
    except Exception as error:
        record("codex:mcp_error", {"error": str(error)})
        raise SystemExit(44)
    finally:
        helper.terminate()
        helper.wait(timeout=5)

record("codex:user_turn")
'''


def make_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


def write_helper_info(path: Path, bundle_identifier: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("wb") as file:
        plistlib.dump(
            {
                "CFBundleExecutable": "cmux-cua",
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


def _frontmatter_name(skill_file: Path) -> str | None:
    """Read the name from an isolated fixture skill document."""
    in_frontmatter = False
    for line in skill_file.read_text(encoding="utf-8").splitlines():
        if line.strip() == "---":
            if in_frontmatter:
                break
            in_frontmatter = True
            continue
        if in_frontmatter and line.startswith("name:"):
            return line.split(":", 1)[1].strip().strip("\"'")
    return None


def discover_picker_entries(
    project_root: Path,
    global_root: Path,
) -> list[dict[str, str]]:
    """Model the filesystem contract that Codex supplies to its picker.

    The final picker is Codex-owned. These entries intentionally inspect only
    generated fixture files and the two roots whose precedence is relevant to
    this regression; they do not treat skills.config as a discovery root.
    """
    entries: list[dict[str, str]] = []
    candidates = [
        ("project", project_root / ".agents" / "skills" / "cmux-cua"),
        ("global", global_root / "cmux-cua"),
    ]
    for scope, skill_dir in candidates:
        skill_file = skill_dir / "SKILL.md"
        if not skill_file.is_file():
            continue
        name = _frontmatter_name(skill_file)
        if name:
            entries.append(
                {
                    "scope": scope,
                    "name": name,
                    "path": str(skill_file.resolve()),
                }
            )
    return entries


def arg_value(args: list[str], prefix: str) -> str | None:
    return next((arg.split("=", 1)[1] for arg in args if arg.startswith(prefix)), None)


def expect_scrubbed_mcp_env(
    args: list[str],
    failures: list[str],
    context: str,
    *,
    helper_owned: bool,
) -> None:
    embedded = arg_value(args, "mcp_servers.cmux-cua.env.CMUX_CUA_EMBEDDED=")
    daemon_app = arg_value(args, "mcp_servers.cmux-cua.env.CMUX_CUA_DAEMON_APP=")
    force_proxy = arg_value(args, "mcp_servers.cmux-cua.env.CMUX_CUA_MCP_FORCE_PROXY=")
    external_flow = arg_value(args, "mcp_servers.cmux-cua.env.CMUX_CUA_EXTERNAL_PERMISSION_FLOW=")
    auth_token = arg_value(args, "mcp_servers.cmux-cua.env.CMUX_CUA_SOCKET_AUTH_TOKEN=")
    default_session = arg_value(args, "mcp_servers.cmux-cua.env.CMUX_CUA_DEFAULT_SESSION=")
    state_owner_pid = arg_value(args, "mcp_servers.cmux-cua.env.CMUX_CUA_STATE_OWNER_PID=")
    permissions_gate = arg_value(args, "mcp_servers.cmux-cua.env.CMUX_CUA_PERMISSIONS_GATE=")
    telemetry = arg_value(args, "mcp_servers.cmux-cua.env.CMUX_CUA_TELEMETRY_ENABLED=")
    update_check = arg_value(args, "mcp_servers.cmux-cua.env.CMUX_CUA_UPDATE_CHECK=")
    cursor_gradient = arg_value(args, "mcp_servers.cmux-cua.env.CMUX_CUA_CURSOR_GRADIENT=")
    cursor_bloom = arg_value(args, "mcp_servers.cmux-cua.env.CMUX_CUA_CURSOR_BLOOM=")
    cursor_label = arg_value(args, "mcp_servers.cmux-cua.env.CMUX_CUA_CURSOR_LABEL=")
    state_dir = arg_value(args, "mcp_servers.cmux-cua.env.CMUX_CUA_STATE_DIR=")
    node_options = arg_value(args, "mcp_servers.cmux-cua.env.NODE_OPTIONS=")
    bun_options = arg_value(args, "mcp_servers.cmux-cua.env.BUN_OPTIONS=")
    expect(embedded is None, f"{context}: computer use must never be embedded: {args}", failures)
    expect(daemon_app is None, f"{context}: wrapper must not launch the helper daemon: {args}", failures)
    expect(permissions_gate is None, f"{context}: proxy must not own the daemon permission gate: {args}", failures)
    expect(force_proxy is not None, f"{context}: missing forced proxy config in {args}", failures)
    expect(external_flow is not None, f"{context}: missing proxy permission-wait config in {args}", failures)
    expect(auth_token is not None, f"{context}: missing daemon authentication config in {args}", failures)
    expect(default_session is not None, f"{context}: missing CMUX_CUA_DEFAULT_SESSION config in {args}", failures)
    expect(state_owner_pid is not None, f"{context}: missing stable state owner PID in {args}", failures)
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
    if state_owner_pid is not None:
        owner_pid = json.loads(state_owner_pid)
        expect(
            isinstance(owner_pid, str) and owner_pid.isdigit() and int(owner_pid) > 1,
            f"{context}: invalid stable state owner PID {state_owner_pid}",
            failures,
        )
    if permissions_gate is not None:
        expect(json.loads(permissions_gate) == "0", f"{context}: expected permission gate disabled, got {permissions_gate}", failures)
    if force_proxy is not None:
        expect(json.loads(force_proxy) == "1", f"{context}: expected forced proxy, got {force_proxy}", failures)
    if external_flow is not None:
        expect(
            json.loads(external_flow) == "1",
            f"{context}: proxy must honor the helper's external permission flow, got {external_flow}",
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
            json.loads(state_dir).endswith("/Library/Application Support/cmux/cmux-cua/runtime/default/state"),
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
    auth_token: bool = True,
    auth_token_file: bool = False,
    installed_broker: bool = True,
    live_app_enabled: bool | None = None,
    install_global_skill: bool = False,
    global_skill_opt_out: bool = False,
    preexisting_legacy_link: bool = False,
    preexisting_legacy_codex_link: bool = False,
    preexisting_cmux_link: bool = False,
    preexisting_valid_cmux_link: bool = False,
    preexisting_codex_home_cmux_link: bool = False,
    preexisting_unrelated_link: bool = False,
    preexisting_skill_directory: bool = False,
    project_skill_collision: bool = False,
    cwd_under_home_no_git: bool = False,
    mcp_handshake: bool = False,
    diagnostics: bool = False,
    non_cmux: bool = False,
) -> tuple[int, list[str], str, dict[str, object]]:
    with tempfile.TemporaryDirectory(prefix="cmux-codex-wrapper-test-") as td:
        tmp = Path(td)
        wrapper_dir = tmp / "cmux.app" / "Contents" / "Resources" / "bin"
        real_dir = tmp / "real-bin"
        wrapper_dir.mkdir(parents=True)
        real_dir.mkdir(parents=True)

        wrapper = wrapper_dir / "cmux-codex-wrapper"
        shutil.copy2(SOURCE_WRAPPER, wrapper)
        wrapper.chmod(0o755)
        bundled_skill = wrapper_dir.parent / "cmux-cua"
        bundled_skill.mkdir()
        shutil.copy2(SOURCE_LINK_POLICY, bundled_skill / "link-policy.sh")
        (bundled_skill / "SKILL.md").write_text(
            "---\n"
            "name: cmux-cua\n"
            "description: Test bundled cmux Computer Use skill.\n"
            "---\n"
            "\n"
            "Use the bundled Computer Use tools.\n",
            encoding="utf-8",
        )

        project_skill = tmp / ".agents" / "skills" / "cmux-cua"
        if project_skill_collision:
            project_skill.mkdir(parents=True)
            (project_skill / "SKILL.md").write_text(
                "---\n"
                "name: cmux-cua\n"
                "description: Project-owned build skill.\n"
                "---\n\n"
                "Build and test the project Computer Use implementation.\n",
                encoding="utf-8",
            )

        args_log = tmp / "codex-args.log"
        mcp_trace_log = tmp / "mcp-trace.log"
        socket_path = tmp / "cmux.sock"

        make_executable(
            real_dir / "codex",
            FAKE_CODEX % CMUX_CUA_TOOL_ROSTER,
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
            make_executable(wrapper_dir / "cmux-cua", "#!/usr/bin/env bash\nexit 0\n")
            helper_driver = (
                tmp
                / "cmux.app"
                / "Contents"
                / "Library"
                / "cmux Computer Use.app"
                / "Contents"
                / "MacOS"
                / "cmux-cua"
            )
            helper_driver.parent.mkdir(parents=True)
            make_executable(
                helper_driver,
                FAKE_MCP_HELPER % CMUX_CUA_TOOL_ROSTER
                if mcp_handshake
                else "#!/usr/bin/env bash\nexit 0\n",
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
            codex_home = sandbox_home / ".codex"
            env["HOME"] = str(sandbox_home)
            env["CODEX_HOME"] = str(codex_home)
            env["PATH"] = f"{wrapper_dir}:{real_dir}:{env.get('PATH', '/usr/bin:/bin')}"
            if not non_cmux:
                env["CMUX_SURFACE_ID"] = "surface:test"
                env["CMUX_SOCKET_PATH"] = str(socket_path)
            else:
                env.pop("CMUX_SURFACE_ID", None)
                env.pop("CMUX_SOCKET_PATH", None)
            env["CMUX_CUA_SOCKET_PATH"] = str(tmp / "cmux-cua.sock")
            env["CMUX_CUA_CODEX_SOCKET_PATH"] = str(tmp / "cmux-cua-codex.sock")
            env["CMUX_BUNDLED_CLI_PATH"] = str(wrapper_dir / "cmux")
            env["FAKE_CODEX_ARGS_LOG"] = str(args_log)
            env["FAKE_MCP_TRACE_LOG"] = str(mcp_trace_log)
            env["FAKE_MCP_HANDSHAKE"] = "1" if mcp_handshake else "0"
            env["NODE_OPTIONS"] = "--require=/tmp/cmux-mcp-preload-should-not-load.js"
            env["BUN_OPTIONS"] = "--preload=/tmp/cmux-mcp-preload-should-not-load.js"
            env.pop("CMUX_CODEX_HOOKS_DISABLED", None)
            env.pop("CMUX_COMPUTER_USE_MCP_DISABLED", None)
            env.pop("CMUX_CUA_EXTERNAL_CLIENT", None)
            env.pop("CMUX_CUA_AUTH_TOKEN_FILE", None)
            env.pop("CMUX_CUA_CLIENT_PATH", None)
            env.pop("CMUX_COMPUTER_USE_INSTALL_GLOBAL_SKILL", None)
            env.pop("CMUX_CUA_SOCKET_AUTH_TOKEN", None)
            env["CMUX_COMPUTER_USE_APP_ENABLED"] = "1"
            if diagnostics:
                env["CMUX_CUA_DIAGNOSTICS"] = "1"
            else:
                env.pop("CMUX_CUA_DIAGNOSTICS", None)
            skills_root = sandbox_home / ".agents" / "skills"
            if preexisting_cmux_link or preexisting_valid_cmux_link or preexisting_unrelated_link:
                skills_root.mkdir(parents=True, exist_ok=True)
                destination = skills_root / "cmux-cua"
                if preexisting_cmux_link:
                    destination.symlink_to(
                        "/Applications/cmux NIGHTLY old.app/Contents/Resources/cmux-cua"
                    )
                elif preexisting_valid_cmux_link:
                    old_skill = (
                        sandbox_home
                        / "Library"
                        / "Developer"
                        / "Xcode"
                        / "DerivedData"
                        / "cmux-fixture"
                        / "Build"
                        / "Products"
                        / "Debug"
                        / "cmux DEV old.app"
                        / "Contents"
                        / "Resources"
                        / "cmux-cua"
                    )
                    old_skill.mkdir(parents=True)
                    (old_skill / "SKILL.md").write_text(
                        "---\nname: cmux-cua\ndescription: Old cmux skill.\n---\n\nOld bundle.\n",
                        encoding="utf-8",
                    )
                    write_helper_info(
                        old_skill.parents[1] / "Info.plist",
                        "com.cmuxterm.app.debug.fixture",
                    )
                    destination.symlink_to(old_skill)
                else:
                    destination.symlink_to(
                        "/nonexistent/cmux NIGHTLY user-owned.app/Contents/Resources/cmux-cua"
                    )
            if preexisting_codex_home_cmux_link:
                old_root = codex_home / "skills"
                old_root.mkdir(parents=True, exist_ok=True)
                old_destination = old_root / "cmux-cua"
                old_destination.symlink_to(
                    "/Applications/cmux DEV old.app/Contents/Resources/cmux-cua"
                )
            if preexisting_legacy_link:
                skills_root.mkdir(parents=True, exist_ok=True)
                (skills_root / "cmux-computer-use").symlink_to(
                    "/Applications/cmux DEV old.app/Contents/Resources/cmux-computer-use"
                )
            if preexisting_legacy_codex_link:
                skills_root.mkdir(parents=True, exist_ok=True)
                (skills_root / "codex-cua").symlink_to(
                    "/Applications/cmux DEV old.app/Contents/Resources/codex-cua"
                )
            if preexisting_skill_directory:
                owned = skills_root / "cmux-cua"
                owned.mkdir(parents=True, exist_ok=True)
                (owned / "SKILL.md").write_text("user-owned\n", encoding="utf-8")
            if live_app_enabled is not None:
                live_setting = (
                    sandbox_home
                    / "Library"
                    / "Application Support"
                    / "cmux"
                    / "computer-use"
                    / "enabled"
                )
                live_setting.parent.mkdir(parents=True)
                live_setting.write_text(
                    "1\n" if live_app_enabled else "0\n",
                    encoding="utf-8",
                )
            if bundled_driver and installed_broker:
                installed_helper = (
                    sandbox_home
                    / "Library"
                    / "Application Support"
                    / "cmux"
                    / "computer-use"
                    / "helper"
                    / "default"
                    / "cmux Computer Use.app"
                    / "Contents"
                    / "MacOS"
                    / "cmux-cua"
                )
                installed_helper.parent.mkdir(parents=True)
                make_executable(
                    installed_helper,
                    FAKE_MCP_HELPER % CMUX_CUA_TOOL_ROSTER
                    if mcp_handshake
                    else "#!/usr/bin/env bash\nexit 0\n",
                )
                env["CMUX_CUA_CLIENT_PATH"] = str(installed_helper)
            if auth_token_file:
                token_file = tmp / "auth-token"
                token_file.write_text("cmux-test-auth-token\n", encoding="utf-8")
                token_file.chmod(0o600)
                env["CMUX_CUA_AUTH_TOKEN_FILE"] = str(token_file)
            elif auth_token:
                env["CMUX_CUA_SOCKET_AUTH_TOKEN"] = "cmux-test-auth-token"
            if override_driver:
                env["CMUX_CUA_EXTERNAL_CLIENT"] = "/bin/echo"
            if untrusted_override:
                untrusted_dir = tmp / "world-writable"
                untrusted_dir.mkdir()
                untrusted_dir.chmod(0o777)
                untrusted_driver = untrusted_dir / "cmux-cua"
                make_executable(untrusted_driver, "#!/usr/bin/env bash\nexit 0\n")
                env["CMUX_CUA_EXTERNAL_CLIENT"] = str(untrusted_driver)
            if group_writable_override:
                override_dir = tmp / "override-bin"
                override_dir.mkdir()
                group_writable_driver = override_dir / "cmux-cua"
                make_executable(group_writable_driver, "#!/usr/bin/env bash\nexit 0\n")
                group_writable_driver.chmod(0o775)
                env["CMUX_CUA_EXTERNAL_CLIENT"] = str(group_writable_driver)
            if group_writable_ancestor:
                # Group-writable (but not world-writable) parent dir with a
                # correctly-permissioned driver file: rejection can only come
                # from the ancestor group-write check.
                ancestor_dir = tmp / "group-writable-dir"
                ancestor_dir.mkdir()
                ancestor_dir.chmod(0o775)
                ancestor_driver = ancestor_dir / "cmux-cua"
                make_executable(ancestor_driver, "#!/usr/bin/env bash\nexit 0\n")
                env["CMUX_CUA_EXTERNAL_CLIENT"] = str(ancestor_driver)
            if disabled:
                env["CMUX_COMPUTER_USE_MCP_DISABLED"] = "1"
            if hooks_disabled:
                env["CMUX_CODEX_HOOKS_DISABLED"] = "1"
            if install_global_skill:
                env["CMUX_COMPUTER_USE_INSTALL_GLOBAL_SKILL"] = "1"
            elif global_skill_opt_out:
                env["CMUX_COMPUTER_USE_INSTALL_GLOBAL_SKILL"] = "0"

            launch_cwd = (
                sandbox_home / "projects" / "plain"
                if cwd_under_home_no_git
                else tmp
            )
            launch_cwd.mkdir(parents=True, exist_ok=True)
            proc = subprocess.run(
                [str(wrapper), *argv],
                cwd=launch_cwd,
                env=env,
                capture_output=True,
                text=True,
                check=False,
            )
            installed_skill = (
                sandbox_home
                / ".agents"
                / "skills"
                / "cmux-cua"
            )
            legacy_skill = installed_skill.parent / "cmux-computer-use"
            legacy_codex_skill = installed_skill.parent / "codex-cua"
            codex_home_skill = codex_home / "skills" / "cmux-cua"
            skill_probe: dict[str, object] = {
                "bundled_skill": str(bundled_skill.resolve()),
                "exists": installed_skill.exists(),
                "is_symlink": installed_skill.is_symlink(),
                "target": (
                    os.readlink(installed_skill)
                    if installed_skill.is_symlink()
                    else None
                ),
                "content": (
                    (installed_skill / "SKILL.md").read_text(encoding="utf-8")
                    if (installed_skill / "SKILL.md").is_file()
                    else None
                ),
                "legacy_present": legacy_skill.exists() or legacy_skill.is_symlink(),
                "legacy_codex_present": legacy_codex_skill.exists() or legacy_codex_skill.is_symlink(),
                "codex_home_exists": codex_home_skill.exists() or codex_home_skill.is_symlink(),
                "codex_home_is_symlink": codex_home_skill.is_symlink(),
                "project_content": (
                    (project_skill / "SKILL.md").read_text(encoding="utf-8")
                    if (project_skill / "SKILL.md").is_file()
                    else None
                ),
                "picker_entries": [],
                "mcp_trace": [],
            }
            if mcp_trace_log.exists():
                trace: list[dict[str, object]] = []
                for line in mcp_trace_log.read_text(encoding="utf-8").splitlines():
                    try:
                        value = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    if isinstance(value, dict):
                        trace.append(value)
                skill_probe["mcp_trace"] = trace
            skill_probe["picker_entries"] = discover_picker_entries(
                tmp,
                sandbox_home / ".agents" / "skills",
            )
        finally:
            if test_socket is not None:
                test_socket.close()

        return proc.returncode, read_lines(args_log), proc.stderr, skill_probe


def command_config(args: list[str]) -> str | None:
    return arg_value(args, "mcp_servers.cmux-cua.command=")


def args_config(args: list[str]) -> str | None:
    return arg_value(args, "mcp_servers.cmux-cua.args=")


def configured_skill_path(args: list[str]) -> Path | None:
    raw = arg_value(args, "skills.config=")
    prefix = '[{path="'
    suffix = '",enabled=true}]'
    if raw is None or not raw.startswith(prefix) or not raw.endswith(suffix):
        return None
    escaped_path = raw[len(prefix) : -len(suffix)]
    return Path(json.loads(f'"{escaped_path}"'))


def attachment_diagnostic(stderr: str, reason: str) -> bool:
    expected = f"cmux-cua: codex attachment={reason}"
    return expected in {line.strip() for line in stderr.splitlines()}


def trace_events(skill: dict[str, object]) -> list[dict[str, object]]:
    value = skill.get("mcp_trace")
    return value if isinstance(value, list) else []


def helper_was_started(skill: dict[str, object]) -> bool:
    return any(
        event.get("event") in {"codex:mcp_spawn", "helper:started"}
        for event in trace_events(skill)
    )


def test_codex_fresh_session_handshakes_before_first_user_turn(failures: list[str]) -> None:
    code, args, stderr, skill = run_wrapper(
        ["hello"],
        mcp_handshake=True,
        diagnostics=True,
    )
    expect(code == 0, f"fresh MCP handshake exited {code}: {stderr}", failures)
    expect(
        attachment_diagnostic(stderr, "attached"),
        f"fresh session must report an attached cmux-cua proxy, got {stderr!r}",
        failures,
    )
    expect(
        "cmux-test-auth-token" not in stderr,
        "attachment diagnostics must not disclose the daemon credential",
        failures,
    )
    events = trace_events(skill)
    names = [event.get("event") for event in events]
    required = [
        "codex:mcp_initialize",
        "helper:initialize",
        "codex:mcp_initialize_result",
        "codex:mcp_initialized",
        "codex:mcp_tools_list",
        "helper:tools/list",
        "codex:mcp_tools_list_result",
        "codex:user_turn",
    ]
    positions = [names.index(name) if name in names else -1 for name in required]
    expect(
        all(position >= 0 for position in positions) and positions == sorted(positions),
        f"fresh Codex must complete MCP discovery before user turn, got {names}",
        failures,
    )
    tools_result = next(
        (
            event.get("payload", {}).get("names")
            for event in events
            if event.get("event") == "codex:mcp_tools_list_result"
            and isinstance(event.get("payload"), dict)
        ),
        None,
    )
    expect(
        tools_result == CMUX_CUA_TOOL_ROSTER,
        f"fresh Codex must receive the exact cmux-cua tool roster, got {tools_result!r}",
        failures,
    )
    helper_env = next(
        (
            event.get("payload")
            for event in events
            if event.get("event") == "helper:started"
        ),
        None,
    )
    expect(
        isinstance(helper_env, dict)
        and helper_env.get("force_proxy") == "1"
        and helper_env.get("external_permission_flow") == "1"
        and helper_env.get("auth_present") is True
        and helper_env.get("daemon_app") is None
        and helper_env.get("permissions_gate") is None,
        f"fresh helper must retain forced proxy/TCC boundary environment, got {helper_env!r}",
        failures,
    )
    expect(command_config(args) is not None, f"fresh session lost MCP config: {args}", failures)


def test_codex_stale_socket_reports_fail_closed_attachment(failures: list[str]) -> None:
    code, args, stderr, skill = run_wrapper(
        ["hello"],
        dead_socket=True,
        diagnostics=True,
    )
    expect(code == 0, f"stale-socket wrapper exited {code}: {stderr}", failures)
    expect(
        attachment_diagnostic(stderr, "stale-cmux-socket"),
        f"stale cmux socket must be observable, got {stderr!r}",
        failures,
    )
    expect(command_config(args) is None, f"stale socket must fail closed, got {args}", failures)
    expect("hooks.cmux-test=true" in args, f"stale socket must preserve hooks, got {args}", failures)
    expect("hello" in args, f"stale socket must preserve the prompt, got {args}", failures)
    expect(not helper_was_started(skill), f"stale socket must not start an MCP helper, got {skill}", failures)


def test_codex_disabled_hooks_reports_inert_attachment(failures: list[str]) -> None:
    code, args, stderr, skill = run_wrapper(
        ["hello"],
        hooks_disabled=True,
        diagnostics=True,
    )
    expect(code == 0, f"disabled-hooks wrapper exited {code}: {stderr}", failures)
    expect(args == ["hello"], f"disabled hooks must remain fully inert, got {args}", failures)
    expect(
        attachment_diagnostic(stderr, "hooks-disabled"),
        f"disabled hooks must report why attachment was skipped, got {stderr!r}",
        failures,
    )
    expect(not helper_was_started(skill), f"disabled hooks must not start an MCP helper, got {skill}", failures)


def test_codex_outside_cmux_reports_fail_closed_attachment(failures: list[str]) -> None:
    code, args, stderr, skill = run_wrapper(
        ["hello"],
        non_cmux=True,
        diagnostics=True,
    )
    expect(code == 0, f"non-cmux wrapper exited {code}: {stderr}", failures)
    expect(args == ["hello"], f"outside cmux Codex must be untouched, got {args}", failures)
    expect(
        attachment_diagnostic(stderr, "outside-cmux"),
        f"outside-cmux fail-closed behavior must be observable, got {stderr!r}",
        failures,
    )
    expect(not helper_was_started(skill), f"outside cmux must not start an MCP helper, got {skill}", failures)


def test_codex_gets_cmux_cua(failures: list[str]) -> None:
    code, args, stderr, skill = run_wrapper(["hello"])
    expect(code == 0, f"wrapper exited {code}: {stderr}", failures)
    expect("app-server" not in args, f"must not use codex app-server, got {args}", failures)
    expect(
        "--enable" in args and "hooks" in args and "hooks.cmux-test=true" in args,
        f"expected existing hook injection args to survive, got {args}",
        failures,
    )
    expect("hello" in args, f"expected user prompt to survive, got {args}", failures)
    expect("skill-install=" not in stderr and "managed-link-retired" not in stderr,
           f"ordinary Codex launch must keep diagnostics quiet, got {stderr!r}", failures)
    # Codex CLI does not discover skills from skills.config session flags; the
    # default path is deliberately picker-inert and leaves global state absent.
    expect(configured_skill_path(args) is None, f"Codex must not fake session picker discovery, got {args}", failures)
    expect(
        skill["exists"] is False and skill["is_symlink"] is False,
        f"default launch must not mutate Codex's global picker root, got {skill}",
        failures,
    )

    cmd = command_config(args)
    mcp_args_raw = args_config(args)
    expect(cmd is not None, f"missing computer-use command config in {args}", failures)
    expect(mcp_args_raw is not None, f"missing computer-use args config in {args}", failures)
    if cmd is not None:
        command = json.loads(cmd)
        command_path = Path(command)
        expect(
            command_path.name == "cmux-cua",
            f"expected installed Computer Use broker command, got {cmd}",
            failures,
        )
        expect(
            command_path.parts[-4:] == (
                "cmux Computer Use.app",
                "Contents",
                "MacOS",
                "cmux-cua",
            ),
            f"expected installed cmux Computer Use broker command, got {command}",
            failures,
        )
    if mcp_args_raw is not None:
        mcp_args = json.loads(mcp_args_raw)
        expect(
            len(mcp_args) == 4
            and mcp_args[:2] == ["mcp", "--socket"]
            and mcp_args[3] == "--codex-computer-use-compat",
            f"expected Codex-compatible shared daemon proxy args, got {mcp_args_raw}",
            failures,
        )
        if len(mcp_args) >= 3:
            expect(
                mcp_args[2].endswith("/cmux-cua-codex.sock")
                and not mcp_args[2].endswith("/cmux-cua.sock"),
                f"expected the isolated Codex daemon socket, got {mcp_args[2]!r}",
                failures,
            )
    expect_scrubbed_mcp_env(args, failures, "bundled cmux-cua", helper_owned=True)

    computer_use_command_index = args.index("-c") if "-c" in args else -1
    prompt_index = args.index("hello") if "hello" in args else -1
    expect(
        0 <= computer_use_command_index < prompt_index,
        f"expected computer-use config before user argv, got {args}",
        failures,
    )


def test_codex_default_does_not_mutate_global_or_fake_session_discovery(
    failures: list[str],
) -> None:
    code, args, stderr, skill = run_wrapper(["hello"])
    expect(code == 0, f"session-skill wrapper exited {code}: {stderr}", failures)
    expect(
        skill["exists"] is False and skill["is_symlink"] is False,
        f"expected no global picker link by default, got {skill}",
        failures,
    )
    expect(
        configured_skill_path(args) is None,
        f"Codex skills.config must not claim unsupported session discovery, got {args}",
        failures,
    )
    expect(
        len(skill.get("picker_entries", [])) == 0,
        f"default Codex picker contract must have no global/session row, got {skill.get('picker_entries')}",
        failures,
    )


def test_codex_default_skill_path_is_picker_safe(failures: list[str]) -> None:
    """Without explicit installation Codex has no picker discovery root."""
    code, args, stderr, skill = run_wrapper(["hello"])
    expect(code == 0, f"default-scope wrapper exited {code}: {stderr}", failures)
    expect(
        skill["exists"] is False and skill["is_symlink"] is False,
        f"default launch must not install a global picker link, got {skill}",
        failures,
    )
    expect(configured_skill_path(args) is None, f"Codex must not emit an unsupported session skill path, got {args}", failures)
    expect(
        len(skill.get("picker_entries", [])) == 0,
        f"default picker contract should contain no row, got {skill.get('picker_entries')}",
        failures,
    )


def test_codex_preserves_unverified_dangling_link_by_default(failures: list[str]) -> None:
    """A dangling link has no verifiable ownership and remains untouched."""
    code, args, stderr, skill = run_wrapper(
        ["hello"],
        preexisting_cmux_link=True,
    )
    expect(code == 0, f"stale-link wrapper exited {code}: {stderr}", failures)
    expect(
        skill["is_symlink"] is True
        and skill["target"] == "/Applications/cmux NIGHTLY old.app/Contents/Resources/cmux-cua",
        f"unverified dangling link must be preserved safely, got {skill}",
        failures,
    )
    expect(
        configured_skill_path(args) is None,
        f"stale-link cleanup must not emit unsupported session discovery, got {args}",
        failures,
    )
    expect(
        len(skill.get("picker_entries", [])) == 0,
        f"stale-link cleanup should leave no Codex picker row without opt-in, got {skill.get('picker_entries')}",
        failures,
    )


def test_codex_explicit_opt_in_preserves_unverified_dangling_link(failures: list[str]) -> None:
    code, args, stderr, skill = run_wrapper(
        ["hello"],
        preexisting_cmux_link=True,
        install_global_skill=True,
        diagnostics=True,
    )
    expect(code == 0, f"explicit stale-link wrapper exited {code}: {stderr}", failures)
    expect("cmux-cua: skill-install=blocked-user-path" in stderr and "/.agents/skills/cmux-cua" in stderr,
           f"explicit blocked install must identify the preserved path, got {stderr!r}", failures)
    expect(
        skill["is_symlink"] is True
        and skill["target"] == "/Applications/cmux NIGHTLY old.app/Contents/Resources/cmux-cua",
        f"explicit opt-in must preserve an unverified dangling link, got {skill}",
        failures,
    )
    expect(
        configured_skill_path(args) is None,
        f"retargeted global link must not add a fallback duplicate, got {args}",
        failures,
    )


def test_codex_home_ancestor_is_not_project_collision(failures: list[str]) -> None:
    """A managed global link under HOME must not become a project collision."""
    for opt_in in (False, True):
        code, args, stderr, skill = run_wrapper(
            ["hello"], preexisting_valid_cmux_link=True,
            cwd_under_home_no_git=True, install_global_skill=opt_in,
            diagnostics=not opt_in,
        )
        expect(code == 0, f"home-ancestor wrapper exited {code}: {stderr}", failures)
        expect(skill["exists"] is opt_in and skill["is_symlink"] is opt_in,
               f"per-launch opt-in={opt_in} must control the managed link: {skill}", failures)
        if opt_in:
            expect(skill["target"] == skill["bundled_skill"],
                   f"HOME ancestor must permit retargeting to this exact bundle: {skill}", failures)
        else:
            expect("managed-link-retired" in stderr and "/.agents/skills/cmux-cua" in stderr,
                   f"retired managed Codex link must be diagnosed, got {stderr!r}", failures)
        expect(configured_skill_path(args) is None,
               f"HOME ancestor must not produce an unsupported session path: {args}", failures)
        expect(len(skill["picker_entries"]) == int(opt_in),
               f"per-launch opt-in must control global discovery: {skill['picker_entries']}", failures)


def test_codex_preserves_unverified_codex_home_link(failures: list[str]) -> None:
    """A dangling CODEX_HOME link has no ownership proof and remains intact."""
    code, args, stderr, skill = run_wrapper(
        ["hello"],
        preexisting_codex_home_cmux_link=True,
    )
    expect(code == 0, f"CODEX_HOME migration wrapper exited {code}: {stderr}", failures)
    expect(
        skill["codex_home_exists"] is True and skill["codex_home_is_symlink"] is True,
        f"unverified CODEX_HOME link must be preserved, got {skill}",
        failures,
    )
    expect(
        configured_skill_path(args) is None,
        f"deprecated-root cleanup must not emit unsupported session discovery, got {args}",
        failures,
    )


def test_codex_collision_keeps_project_skill_and_one_picker_row(failures: list[str]) -> None:
    """A project skill wins without hiding or rewriting its contents."""
    code, args, stderr, skill = run_wrapper(
        ["hello"],
        project_skill_collision=True,
    )
    expect(code == 0, f"collision wrapper exited {code}: {stderr}", failures)
    entries = skill.get("picker_entries")
    expect(
        isinstance(entries, list) and len(entries) == 1,
        f"project/global collision must not leave duplicate picker rows, got {entries}",
        failures,
    )
    if isinstance(entries, list) and entries:
        expect(
            entries[0]["scope"] == "project" and entries[0]["name"] == "cmux-cua",
            f"project-first resolution must remain deterministic, got {entries}",
            failures,
        )
    expect(
        isinstance(skill.get("project_content"), str)
        and "Build and test the project" in skill["project_content"],
        f"project-owned skill must remain untouched, got {skill}",
        failures,
    )
    expect(
        configured_skill_path(args) is None,
        f"bundled fallback must not add a same-name row during a collision, got {args}",
        failures,
    )


def test_codex_explicit_global_opt_in_still_installs_without_collision(
    failures: list[str],
) -> None:
    code, args, stderr, skill = run_wrapper(
        ["hello"],
        install_global_skill=True,
    )
    expect(code == 0, f"explicit-global wrapper exited {code}: {stderr}", failures)
    expect(
        skill["exists"] is True and skill["is_symlink"] is True,
        f"explicit opt-in should install the bundled link, got {skill}",
        failures,
    )
    expect(
        configured_skill_path(args) is None,
        f"installed global skill must not also be injected by path, got {args}",
        failures,
    )
    expect(
        len(skill.get("picker_entries", [])) == 1
        and skill["picker_entries"][0]["scope"] == "global",
        f"explicit global install should leave one global picker row, got {skill.get('picker_entries')}",
        failures,
    )


def test_codex_explicit_global_opt_in_does_not_override_project_skill(
    failures: list[str],
) -> None:
    code, args, stderr, skill = run_wrapper(
        ["hello"],
        install_global_skill=True,
        project_skill_collision=True,
        diagnostics=True,
    )
    expect(code == 0, f"collision opt-in wrapper exited {code}: {stderr}", failures)
    expect(
        skill["exists"] is False and skill["is_symlink"] is False,
        f"global opt-in must not create a duplicate beside a project skill, got {skill}",
        failures,
    )
    expect(
        configured_skill_path(args) is None,
        f"collision opt-in must not add a same-name fallback, got {args}",
        failures,
    )
    expect("skill-install=blocked-project-collision" in stderr,
           f"explicit project collision must be diagnosed, got {stderr!r}", failures)


def test_codex_managed_global_link_does_not_shadow_project(failures: list[str]) -> None:
    code, _args, stderr, skill = run_wrapper(
        ["hello"],
        preexisting_valid_cmux_link=True,
        project_skill_collision=True,
    )
    expect(code == 0, f"durable collision wrapper exited {code}: {stderr}", failures)
    expect(
        skill["exists"] is False and skill["is_symlink"] is False,
        f"ordinary launch must retire the verified app-managed global link, got {skill}",
        failures,
    )
    expect(
        isinstance(skill.get("picker_entries"), list)
        and [entry["scope"] for entry in skill["picker_entries"]] == ["project"],
        f"the preserved project skill should be the only picker row, got {skill.get('picker_entries')}",
        failures,
    )


def test_codex_preserves_unrelated_global_symlink_by_default(failures: list[str]) -> None:
    code, args, stderr, skill = run_wrapper(
        ["hello"],
        preexisting_unrelated_link=True,
    )
    expect(code == 0, f"unrelated-link wrapper exited {code}: {stderr}", failures)
    expect(
        skill["is_symlink"] is True
        and skill["target"]
        == "/nonexistent/cmux NIGHTLY user-owned.app/Contents/Resources/cmux-cua",
        f"unrelated symlink must remain untouched, got {skill}",
        failures,
    )
    expect(
        configured_skill_path(args) is None,
        f"preserved user link must not receive a duplicate fallback, got {args}",
        failures,
    )


def test_codex_preserves_unverified_legacy_computer_use_link(failures: list[str]) -> None:
    code, _args, stderr, skill = run_wrapper(["hello"], preexisting_legacy_link=True)
    expect(code == 0, f"legacy-migration wrapper exited {code}: {stderr}", failures)
    expect(
        skill["legacy_present"] is True,
        f"unverified legacy cmux-computer-use link must be preserved, got {skill}",
        failures,
    )


def test_codex_preserves_unverified_legacy_codex_cua_link(failures: list[str]) -> None:
    code, args, stderr, skill = run_wrapper(
        ["hello"],
        preexisting_legacy_codex_link=True,
    )
    expect(code == 0, f"legacy codex-cua wrapper exited {code}: {stderr}", failures)
    expect(
        skill["legacy_codex_present"] is True,
        f"unverified codex-cua alias must be preserved, got {skill}",
        failures,
    )
    expect(
        configured_skill_path(args) is None,
        f"legacy codex-cua migration must not emit unsupported session discovery, got {args}",
        failures,
    )
    expect(
        skill["exists"] is False and skill["is_symlink"] is False,
        f"canonical global link should remain absent, got {skill}",
        failures,
    )
def test_codex_does_not_duplicate_user_owned_skill_path(failures: list[str]) -> None:
    code, args, stderr, skill = run_wrapper(["hello"], preexisting_skill_directory=True)
    expect(code == 0, f"user-owned-path wrapper exited {code}: {stderr}", failures)
    expect(
        skill["is_symlink"] is False and skill["content"] == "user-owned\n",
        f"expected the user-owned skill directory untouched, got {skill}",
        failures,
    )
    expect(
        configured_skill_path(args) is None,
        f"expected no same-name fallback beside a user-owned path, got {args}",
        failures,
    )


def test_codex_global_skill_can_be_disabled_explicitly(failures: list[str]) -> None:
    code, args, stderr, skill = run_wrapper(
        ["hello"],
        global_skill_opt_out=True,
    )
    expect(code == 0, f"opt-out skill wrapper exited {code}: {stderr}", failures)
    expect(
        configured_skill_path(args) is None,
        f"Codex opt-out must not emit unsupported session discovery, got {args}",
        failures,
    )
    expect(
        skill["exists"] is False and skill["is_symlink"] is False,
        f"expected explicit opt-out to leave global skill state untouched, got {skill}",
        failures,
    )


def test_codex_computer_use_wrapper_is_a_pure_proxy(failures: list[str]) -> None:
    source = SOURCE_WRAPPER.read_text(encoding="utf-8")
    claude_source = SOURCE_CLAUDE_WRAPPER.read_text(encoding="utf-8")
    expect(
        "cmux_computer_use_standalone_helper" not in source,
        "codex wrapper must not install or replace the standalone helper",
        failures,
    )
    expect(
        "CMUX_CUA_DAEMON_APP" not in source,
        "codex wrapper must not own helper daemon launch",
        failures,
    )
    expect(
        "CMUX_CUA_MCP_FORCE_PROXY" in source,
        "codex wrapper must force the shared daemon proxy path",
        failures,
    )
    expect(
        "--codex-computer-use-compat" not in claude_source,
        "Claude wrapper must retain the native cmux Computer Use surface",
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


def test_codex_rejects_proxy_only_cmux_cua_override(failures: list[str]) -> None:
    code, args, stderr, _ = run_wrapper(["hello"], bundled_driver=False, override_driver=True)
    expect(code == 0, f"override wrapper exited {code}: {stderr}", failures)
    cmd = command_config(args)
    expect(
        cmd is None,
        f"Codex must not attach a proxy-only override that cannot authenticate as the installed daemon: {args}",
        failures,
    )


def test_codex_fork_gets_hooks_and_cmux_cua(failures: list[str]) -> None:
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
            Path(json.loads(cmd)).name == "cmux-cua",
            f"expected installed Computer Use broker command for fork, got {cmd}",
            failures,
        )
    first_config_index = args.index("-c") if "-c" in args else -1
    fork_index = args.index("fork") if "fork" in args else -1
    expect(
        0 <= first_config_index < fork_index,
        f"expected injected config before the fork subcommand, got {args}",
        failures,
    )


def test_codex_rejects_cmux_cua_override_under_world_writable_ancestor(failures: list[str]) -> None:
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


def test_codex_skips_when_installed_broker_is_unavailable(failures: list[str]) -> None:
    # Codex app approval authenticates the MCP proxy as the exact executable
    # already serving the cmux-owned daemon. Falling back to the separately
    # signed Resources/bin client can list schemas but fails before the first
    # real MCP session, so the wrapper must fail closed instead.
    code, args, stderr, skill = run_wrapper(
        ["hello"],
        installed_broker=False,
    )
    expect(code == 0, f"missing-broker wrapper exited {code}: {stderr}", failures)
    expect(
        command_config(args) is None,
        f"expected no injection without the installed daemon broker, got {args}",
        failures,
    )
    expect(
        skill["exists"] is False and skill["is_symlink"] is False,
        "the default launch must not create a global skill before the helper broker is available",
        failures,
    )
    expect(
        configured_skill_path(args) is None,
        f"missing broker must not emit unsupported session discovery, got {args}",
        failures,
    )


def test_codex_skips_when_disabled(failures: list[str]) -> None:
    code, args, stderr, skill = run_wrapper(["hello"], disabled=True)
    expect(code == 0, f"disabled wrapper exited {code}: {stderr}", failures)
    expect(command_config(args) is None, f"expected no injection with kill switch, got {args}", failures)
    expect(configured_skill_path(args) is None, f"expected no skill config with kill switch, got {args}", failures)
    expect(skill["exists"] is False, f"expected no global skill with kill switch, got {skill}", failures)


def test_codex_skips_when_live_app_setting_is_disabled(failures: list[str]) -> None:
    code, args, stderr, _ = run_wrapper(["hello"], live_app_enabled=False)
    expect(code == 0, f"live-disabled wrapper exited {code}: {stderr}", failures)
    expect(
        command_config(args) is None,
        f"expected no injection when the live app setting is disabled, got {args}",
        failures,
    )


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
    # live cmux socket there is no authoritative evidence cmux owns this process
    # chain, so the TCC-sensitive driver must NOT be attached. Hook
    # injection remains independent of this gate so a transient socket outage
    # does not discard the surface context needed for later rebinding.
    code, args, stderr, _ = run_wrapper(["hello"], dead_socket=True)
    expect(code == 0, f"dead-socket wrapper exited {code}: {stderr}", failures)
    expect(
        "hooks.cmux-test=true" in args,
        f"expected hook args to survive a dead socket, got {args}",
        failures,
    )
    expect("hello" in args, f"expected user prompt to survive, got {args}", failures)
    expect(
        command_config(args) is None,
        f"expected NO computer-use attach with dead socket (fail closed), got {args}",
        failures,
    )


def test_codex_rejects_cmux_cua_override_under_group_writable_ancestor(failures: list[str]) -> None:
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


def test_codex_rejects_group_writable_cmux_cua_override(failures: list[str]) -> None:
    # A group-writable override binary could be swapped by another local user
    # and then run under cmux's TCC identity; the wrapper must reject it.
    code, args, stderr, _ = run_wrapper(
        ["hello"],
        bundled_driver=False,
        group_writable_override=True,
    )
    expect(code == 0, f"group-writable override wrapper exited {code}: {stderr}", failures)
    expect(command_config(args) is None, f"expected group-writable override rejection, got {args}", failures)


def test_codex_gets_cmux_cua_when_hook_injection_fails(failures: list[str]) -> None:
    # The bundled cmux-cua client is local and independent of the cmux hook socket, so
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
            Path(command).name == "cmux-cua",
            f"expected installed Computer Use broker command after hook failure, got {cmd}",
            failures,
        )
    expect_scrubbed_mcp_env(args, failures, "hook-injection failure", helper_owned=True)


def test_codex_skips_for_strict_mcp_config(failures: list[str]) -> None:
    code, args, stderr, _ = run_wrapper(["--strict-mcp-config", "-c", "mcp_servers.user.command=\"x\"", "hello"])
    expect(code == 0, f"strict wrapper exited {code}: {stderr}", failures)
    expect(command_config(args) is None, f"expected no cmux injection with strict config, got {args}", failures)
    expect(configured_skill_path(args) is None, f"expected no cmux skill with strict config, got {args}", failures)
    expect("mcp_servers.user.command=\"x\"" in args, f"expected user's config to survive, got {args}", failures)


def main() -> int:
    failures: list[str] = []
    test_codex_fresh_session_handshakes_before_first_user_turn(failures)
    test_codex_stale_socket_reports_fail_closed_attachment(failures)
    test_codex_disabled_hooks_reports_inert_attachment(failures)
    test_codex_outside_cmux_reports_fail_closed_attachment(failures)
    test_codex_gets_cmux_cua(failures)
    test_codex_default_does_not_mutate_global_or_fake_session_discovery(failures)
    test_codex_default_skill_path_is_picker_safe(failures)
    test_codex_preserves_unverified_dangling_link_by_default(failures)
    test_codex_explicit_opt_in_preserves_unverified_dangling_link(failures)
    test_codex_home_ancestor_is_not_project_collision(failures)
    test_codex_preserves_unverified_codex_home_link(failures)
    test_codex_collision_keeps_project_skill_and_one_picker_row(failures)
    test_codex_explicit_global_opt_in_still_installs_without_collision(failures)
    test_codex_explicit_global_opt_in_does_not_override_project_skill(failures)
    test_codex_managed_global_link_does_not_shadow_project(failures)
    test_codex_preserves_unrelated_global_symlink_by_default(failures)
    test_codex_preserves_unverified_legacy_computer_use_link(failures)
    test_codex_preserves_unverified_legacy_codex_cua_link(failures)
    test_codex_does_not_duplicate_user_owned_skill_path(failures)
    test_codex_global_skill_can_be_disabled_explicitly(failures)
    test_codex_computer_use_wrapper_is_a_pure_proxy(failures)
    test_codex_reads_private_daemon_credential_file(failures)
    test_codex_rejects_proxy_only_cmux_cua_override(failures)
    test_codex_rejects_cmux_cua_override_under_world_writable_ancestor(failures)
    test_codex_skips_when_driver_unavailable(failures)
    test_codex_skips_when_installed_broker_is_unavailable(failures)
    test_codex_skips_when_disabled(failures)
    test_codex_skips_when_live_app_setting_is_disabled(failures)
    test_codex_skips_when_daemon_credential_is_missing(failures)
    test_codex_fork_gets_hooks_and_cmux_cua(failures)
    test_codex_hooks_disabled_is_fully_inert(failures)
    test_codex_fails_closed_for_computer_use_when_socket_dead(failures)
    test_codex_rejects_cmux_cua_override_under_group_writable_ancestor(failures)
    test_codex_rejects_group_writable_cmux_cua_override(failures)
    test_codex_gets_cmux_cua_when_hook_injection_fails(failures)
    test_codex_skips_for_strict_mcp_config(failures)
    if failures:
        for failure in failures:
            print(f"FAIL: {failure}")
        return 1
    print("PASS: codex wrapper injects cmux-cua MCP")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
