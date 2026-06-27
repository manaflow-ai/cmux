#!/usr/bin/env python3
"""
Regression test: the generated Amp plugin is importable and emits cmux hook calls.
"""

from __future__ import annotations

import base64
import os
import shutil
import subprocess
import tempfile
import time
from pathlib import Path

from claude_teams_test_utils import resolve_cmux_cli


def make_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8") if path.exists() else ""


def main() -> int:
    # Amp loads `.ts` plugins itself via Node, so use Node for the import
    # check too. Requires Node 22.6+ for `--experimental-strip-types`
    # (default in Node 24).
    node = shutil.which("node")
    if node is None:
        print("SKIP: node not found")
        return 0
    try:
        raw_version = subprocess.check_output([node, "--version"], text=True).strip()
        version_parts = tuple(int(part) for part in raw_version.lstrip("v").split(".")[:3])
    except Exception:
        version_parts = (0, 0, 0)
    if version_parts < (22, 6, 0):
        print("SKIP: node >= 22.6.0 required")
        return 0

    try:
        cli_path = resolve_cmux_cli()
    except Exception as exc:
        print(f"FAIL: {exc}")
        return 1

    with tempfile.TemporaryDirectory(prefix="cmux-amp-extension-") as td:
        root = Path(td)
        # `amp` has no documented config-dir override, so install resolves
        # the plugin path against $HOME. Point HOME at the temp dir for the
        # install step so we don't touch the user's real ~/.config/amp.
        env = os.environ.copy()
        env["HOME"] = str(root)

        install = subprocess.run(
            [cli_path, "hooks", "amp", "install", "--yes"],
            capture_output=True,
            text=True,
            check=False,
            env=env,
            timeout=20,
        )
        if install.returncode != 0:
            print("FAIL: amp plugin install failed")
            print(f"exit={install.returncode}")
            print(f"stdout={install.stdout.strip()}")
            print(f"stderr={install.stderr.strip()}")
            return 1

        extension_path = root / ".config" / "amp" / "plugins" / "cmux-session.ts"
        if not extension_path.exists():
            print(f"FAIL: expected plugin at {extension_path}")
            return 1
        extension_text = extension_path.read_text(encoding="utf-8")
        if "cmux-amp-session-extension-marker" not in extension_text:
            print(f"FAIL: expected cmux marker in {extension_path}")
            return 1

        fake_cmux = root / "fake-cmux"
        fake_args_log = root / "fake-cmux-args.log"
        fake_stdin_log = root / "fake-cmux-stdin.log"
        fake_env_log = root / "fake-cmux-env.log"
        fake_bin = root / "bin"
        fake_bin.mkdir()
        fake_amp = fake_bin / "amp"
        make_executable(fake_amp, "#!/usr/bin/env bash\nexit 0\n")
        make_executable(
            fake_cmux,
            """#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$FAKE_CMUX_ARGS_LOG"
cat >> "$FAKE_CMUX_STDIN_LOG"
printf '\n---\n' >> "$FAKE_CMUX_STDIN_LOG"
{
  printf 'kind=%s\n' "${CMUX_AGENT_LAUNCH_KIND-}"
  printf 'cwd=%s\n' "${CMUX_AGENT_LAUNCH_CWD-}"
  printf 'argv=%s\n' "${CMUX_AGENT_LAUNCH_ARGV_B64-}"
  printf 'amp_api_key=%s\n' "${AMP_API_KEY-}"
} >> "$FAKE_CMUX_ENV_LOG"
""",
        )

        check_env = env.copy()
        check_env["CMUX_TEST_AMP_EXTENSION_PATH"] = str(extension_path)
        check_env.pop("CMUX_SURFACE_ID", None)
        check_env.pop("CMUX_PANEL_ID", None)
        check_env["CMUX_WORKSPACE_ID"] = "workspace-amp-test"
        check_env["CMUX_AMP_CMUX_BIN"] = str(fake_cmux)
        check_env["AMP_API_KEY"] = "secret-should-not-propagate"
        check_env["FAKE_CMUX_ARGS_LOG"] = str(fake_args_log)
        check_env["FAKE_CMUX_STDIN_LOG"] = str(fake_stdin_log)
        check_env["FAKE_CMUX_ENV_LOG"] = str(fake_env_log)
        check_env["PWD"] = "/tmp/amp-project"
        check_env["PATH"] = f"{fake_bin}{os.pathsep}{env.get('PATH', '')}"
        check_source = """
const extensionPath = process.env.CMUX_TEST_AMP_EXTENSION_PATH;
const mod = await import(extensionPath);
if (typeof mod.default !== "function") throw new Error("missing default export");
const handlers = new Map();
mod.default({
  on(name, handler) {
    handlers.set(name, handler);
  }
});
for (const name of ["session.start", "agent.start", "agent.end"]) {
  if (typeof handlers.get(name) !== "function") throw new Error(`missing ${name}`);
}
process.argv.splice(
  0,
  process.argv.length,
  "/usr/local/bin/node",
  "/Users/example/node_modules/@ampcode/amp/dist/cli.js",
  "--mode",
  "geppetto"
);
const thread = { id: "T-amp-session-test" };
const ctx = { thread };
await handlers.get("session.start")({ thread }, ctx);
await handlers.get("agent.start")({ thread, message: "hello amp", id: "msg-user-1" }, ctx);
await handlers.get("agent.end")({ thread, message: "hello amp", id: "msg-user-1", status: "done", messages: [] }, ctx);
"""
        check_script = root / "check.mjs"
        check_script.write_text(check_source, encoding="utf-8")
        no_socket_check = subprocess.run(
            [node, "--experimental-strip-types", "--no-warnings", str(check_script)],
            cwd=root,
            capture_output=True,
            text=True,
            check=False,
            env=check_env,
            timeout=20,
        )
        if no_socket_check.returncode != 0:
            print("FAIL: generated Amp plugin failed without socket context")
            print(f"exit={no_socket_check.returncode}")
            print(f"stdout={no_socket_check.stdout.strip()}")
            print(f"stderr={no_socket_check.stderr.strip()}")
            return 1
        deadline = time.monotonic() + 1
        while time.monotonic() < deadline and not read_text(fake_args_log):
            time.sleep(0.05)
        if read_text(fake_args_log):
            print("FAIL: plugin invoked cmux without CMUX_SOCKET_PATH")
            print(read_text(fake_args_log))
            return 1

        check_env["CMUX_SOCKET_PATH"] = str(root / "cmux-test.sock")
        check = subprocess.run(
            [node, "--experimental-strip-types", "--no-warnings", str(check_script)],
            cwd=root,
            capture_output=True,
            text=True,
            check=False,
            env=check_env,
            timeout=20,
        )
        if check.returncode != 0:
            print("FAIL: generated Amp plugin is not importable")
            print(f"exit={check.returncode}")
            print(f"stdout={check.stdout.strip()}")
            print(f"stderr={check.stderr.strip()}")
            return 1

        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            args_log = read_text(fake_args_log)
            stdin_log = read_text(fake_stdin_log)
            env_log = read_text(fake_env_log)
            if (
                "hooks amp session-start" in args_log
                and "hooks amp prompt-submit" in args_log
                and "hooks amp stop" in args_log
                and '"session_id":"T-amp-session-test"' in stdin_log
                and "argv=" in env_log
            ):
                break
            time.sleep(0.05)
        args_log = read_text(fake_args_log)
        stdin_log = read_text(fake_stdin_log)
        env_log = read_text(fake_env_log)
        for expected in [
            "hooks amp session-start",
            "hooks amp prompt-submit",
            "hooks amp stop",
        ]:
            if expected not in args_log:
                print(f"FAIL: plugin did not invoke {expected}, got {args_log!r}")
                return 1
        if '"session_id":"T-amp-session-test"' not in stdin_log:
            print(f"FAIL: plugin did not pass session id, got {stdin_log!r}")
            return 1
        if "kind=amp" not in env_log or "cwd=/tmp/amp-project" not in env_log or "argv=" not in env_log:
            print(f"FAIL: plugin did not pass launch metadata environment, got {env_log!r}")
            return 1
        if "amp_api_key=secret-should-not-propagate" in env_log:
            print(f"FAIL: plugin propagated AMP_API_KEY into hook subprocess, got {env_log!r}")
            return 1
        argv_line = next((line for line in env_log.splitlines() if line.startswith("argv=")), "")
        try:
            argv_value = argv_line[len("argv="):] if argv_line.startswith("argv=") else argv_line
            decoded_argv = [
                value
                for value in base64.b64decode(argv_value).decode("utf-8").split("\0")
                if value
            ]
        except Exception as exc:
            print(f"FAIL: plugin launch argv was not valid base64 NUL data: {exc}; env={env_log!r}")
            return 1
        expected_argv = [
            str(fake_amp),
            "--mode",
            "geppetto",
        ]
        if decoded_argv != expected_argv:
            print(f"FAIL: plugin captured wrong Amp launch argv; expected {expected_argv!r}, got {decoded_argv!r}")
            return 1

    print("PASS: generated Amp plugin installs and emits cmux hooks")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
