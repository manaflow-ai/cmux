#!/usr/bin/env python3
"""
Regression test: the generated OpenCode session plugin is valid ESM.
"""

from __future__ import annotations

import base64
import os
import json
import shutil
import subprocess
import tempfile
from pathlib import Path

from claude_teams_test_utils import resolve_cmux_cli


def make_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


def main() -> int:
    bun = shutil.which("bun")
    if bun is None:
        print("SKIP: bun not found")
        return 0

    try:
        cli_path = resolve_cmux_cli()
    except Exception as exc:
        print(f"FAIL: {exc}")
        return 1

    with tempfile.TemporaryDirectory(prefix="cmux-opencode-plugin-") as td:
        root = Path(td)
        config_dir = root / "opencode"
        config_dir.mkdir(parents=True, exist_ok=True)
        config_json = config_dir / "opencode.json"
        config_json.write_text(
            json.dumps(
                {
                    "plugin": [
                        "oh-my-opencode",
                        ["existing-plugin", {"enabled": True}],
                        "cmux-session",
                        "./plugins/cmux-session.js",
                    ]
                }
            ),
            encoding="utf-8",
        )
        env = os.environ.copy()
        env["OPENCODE_CONFIG_DIR"] = str(config_dir)

        install = subprocess.run(
            [cli_path, "opencode", "install-hooks", "--yes"],
            capture_output=True,
            text=True,
            check=False,
            env=env,
            timeout=20,
        )
        if install.returncode != 0:
            print("FAIL: opencode plugin install failed")
            print(f"exit={install.returncode}")
            print(f"stdout={install.stdout.strip()}")
            print(f"stderr={install.stderr.strip()}")
            return 1

        plugin_path = config_dir / "plugins" / "cmux-session.js"
        if not plugin_path.exists():
            print(f"FAIL: expected plugin at {plugin_path}")
            return 1

        try:
            config = json.loads(config_json.read_text(encoding="utf-8"))
        except Exception as exc:
            print(f"FAIL: invalid opencode.json after install: {exc}")
            return 1
        plugins = config.get("plugin")
        if not isinstance(plugins, list):
            print(f"FAIL: expected plugin list in opencode.json, got {plugins!r}")
            return 1
        stale = [
            entry
            for entry in plugins
            if (entry if isinstance(entry, str) else entry[0] if isinstance(entry, list) and entry else "")
            in {"cmux-session", "./plugins/cmux-session.js"}
        ]
        if stale:
            print(f"FAIL: expected stale cmux plugin registrations removed, got {plugins!r}")
            return 1
        if "oh-my-opencode" not in plugins or ["existing-plugin", {"enabled": True}] not in plugins:
            print(f"FAIL: installer did not preserve existing plugin entries: {plugins!r}")
            return 1

        opencode = shutil.which("opencode")
        if opencode is not None:
            debug = subprocess.run(
                [opencode, "--print-logs", "--log-level", "DEBUG", "debug", "config"],
                capture_output=True,
                text=True,
                check=False,
                env=env,
                timeout=30,
            )
            debug_output = debug.stdout + "\n" + debug.stderr
            if debug.returncode != 0:
                print("FAIL: opencode debug config failed")
                print(f"exit={debug.returncode}")
                print(debug_output[-4000:])
                return 1
            if "path=cmux-session loading plugin" in debug_output:
                print("FAIL: opencode tried to resolve cmux-session as a package")
                print(debug_output[-4000:])
                return 1
            if f"file://{plugin_path}" not in debug_output:
                print("FAIL: opencode did not auto-load cmux session plugin file")
                print(debug_output[-4000:])
                return 1

        fake_cmux = root / "fake-cmux"
        fake_args_log = root / "fake-cmux-args.log"
        fake_stdin_log = root / "fake-cmux-stdin.log"
        fake_env_log = root / "fake-cmux-env.log"
        plugin_copy_path = config_dir / "plugins" / "cmux-session-copy.js"
        shutil.copyfile(plugin_path, plugin_copy_path)
        make_executable(
            fake_cmux,
            """#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >> "$FAKE_CMUX_ARGS_LOG"
cat >> "$FAKE_CMUX_STDIN_LOG"
printf '\\n---\\n' >> "$FAKE_CMUX_STDIN_LOG"
{
  printf 'kind=%s\\n' "${CMUX_AGENT_LAUNCH_KIND-}"
  printf 'cwd=%s\\n' "${CMUX_AGENT_LAUNCH_CWD-}"
  printf 'argv=%s\\n' "${CMUX_AGENT_LAUNCH_ARGV_B64-}"
} >> "$FAKE_CMUX_ENV_LOG"
""",
        )

        check_env = env.copy()
        check_env["CMUX_TEST_OPENCODE_PLUGIN_PATH"] = str(plugin_path)
        check_env["CMUX_TEST_OPENCODE_PLUGIN_COPY_PATH"] = str(plugin_copy_path)
        check_env["CMUX_SURFACE_ID"] = "surface-opencode-test"
        check_env["CMUX_OPENCODE_CMUX_BIN"] = str(fake_cmux)
        check_env["FAKE_CMUX_ARGS_LOG"] = str(fake_args_log)
        check_env["FAKE_CMUX_STDIN_LOG"] = str(fake_stdin_log)
        check_env["FAKE_CMUX_ENV_LOG"] = str(fake_env_log)
        check_source = """
const pluginPath = process.env.CMUX_TEST_OPENCODE_PLUGIN_PATH;
const pluginCopyPath = process.env.CMUX_TEST_OPENCODE_PLUGIN_COPY_PATH;
const mod = await import(pluginPath);
const duplicateMod = await import(pluginCopyPath);
if (typeof mod.CMUXSessionRestore !== "function") {
  throw new Error("missing CMUXSessionRestore export");
}
if (typeof mod.default !== "function") {
  throw new Error("missing default export");
}
const hooks = await mod.default({ directory: "/tmp/opencode-project" });
const duplicateHooks = await duplicateMod.default({ directory: "/tmp/opencode-project" });
if (!hooks || typeof hooks.event !== "function") {
  throw new Error("missing event hook");
}
if (duplicateHooks && typeof duplicateHooks.event === "function") {
  throw new Error("duplicate plugin returned event hook");
}
process.argv.splice(
  0,
  process.argv.length,
  "/Users/example/.bun/bin/opencode",
  "/$bunfs/root/src/cli/cmd/tui/worker.js",
  "--model",
  "anthropic/claude-sonnet-4-6"
);
await hooks.event({
  event: {
    type: "session.created",
    properties: {
      info: {
        id: "opencode-session-test",
        directory: "/tmp/opencode-project"
      }
    }
  }
});
"""
        check = subprocess.run(
            [bun, "--eval", check_source],
            cwd=root,
            capture_output=True,
            text=True,
            check=False,
            env=check_env,
            timeout=20,
        )
        if check.returncode != 0:
            print("FAIL: generated OpenCode plugin is not importable ESM")
            print(f"exit={check.returncode}")
            print(f"stdout={check.stdout.strip()}")
            print(f"stderr={check.stderr.strip()}")
            return 1

        args_log = fake_args_log.read_text(encoding="utf-8") if fake_args_log.exists() else ""
        stdin_log = fake_stdin_log.read_text(encoding="utf-8") if fake_stdin_log.exists() else ""
        env_log = fake_env_log.read_text(encoding="utf-8") if fake_env_log.exists() else ""
        if "opencode-hook session-start" not in args_log:
            print(f"FAIL: plugin did not invoke opencode-hook session-start, got {args_log!r}")
            return 1
        if args_log.count("opencode-hook session-start") != 1:
            print(f"FAIL: plugin invoked duplicate session-start hooks, got {args_log!r}")
            return 1
        if '"session_id":"opencode-session-test"' not in stdin_log or '"/tmp/opencode-project"' not in stdin_log:
            print(f"FAIL: plugin did not pass expected session payload, got {stdin_log!r}")
            return 1
        if "kind=opencode" not in env_log or "cwd=/tmp/opencode-project" not in env_log or "argv=" not in env_log:
            print(f"FAIL: plugin did not pass launch metadata environment, got {env_log!r}")
            return 1
        argv_line = next((line for line in env_log.splitlines() if line.startswith("argv=")), "")
        encoded_argv = argv_line.removeprefix("argv=")
        try:
            decoded_argv = [
                value
                for value in base64.b64decode(encoded_argv).decode("utf-8").split("\0")
                if value
            ]
        except Exception as exc:
            print(f"FAIL: plugin launch argv was not valid base64 NUL data: {exc}; env={env_log!r}")
            return 1
        expected_argv = [
            "/Users/example/.bun/bin/opencode",
            "--model",
            "anthropic/claude-sonnet-4-6",
        ]
        if decoded_argv != expected_argv:
            print(
                "FAIL: plugin captured wrong OpenCode launch argv; "
                f"expected {expected_argv!r}, got {decoded_argv!r}"
            )
            return 1

    print("PASS: generated OpenCode plugin installs and imports as ESM")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
