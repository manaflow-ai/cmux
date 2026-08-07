#!/usr/bin/env python3
"""
Regression test: the generated Amp plugin is importable and emits cmux hook calls.
"""

from __future__ import annotations

import base64
import json
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
        check_env["CMUX_SURFACE_ID"] = "surface-amp-test"
        check_env["CMUX_AMP_CMUX_BIN"] = str(fake_cmux)
        check_env["AMP_API_KEY"] = "secret-should-not-propagate"
        check_env["FAKE_CMUX_ARGS_LOG"] = str(fake_args_log)
        check_env["FAKE_CMUX_STDIN_LOG"] = str(fake_stdin_log)
        check_env["FAKE_CMUX_ENV_LOG"] = str(fake_env_log)
        check_env["PWD"] = "/tmp/amp-project"
        check_env["PATH"] = f"{fake_bin}{os.pathsep}{env.get('PATH', '')}"
        check_source = """
import * as fs from "node:fs";
const extensionPath = process.env.CMUX_TEST_AMP_EXTENSION_PATH;
const mod = await import(extensionPath);
if (typeof mod.default !== "function") throw new Error("missing default export");
const handlers = new Map();
let stateSubscriber = null;
let titleSubscriber = null;
let currentState = "idle";
const thread = {
  id: "T-amp-session-test",
  state: {
    get: async () => currentState,
    subscribe(cb) {
      stateSubscriber = cb;
      return { unsubscribe() {} };
    }
  },
  title: {
    get: async () => "Initial Amp title",
    subscribe(cb) {
      titleSubscriber = cb;
      return { unsubscribe() {} };
    }
  }
};
mod.default({
  on(name, handler) {
    handlers.set(name, handler);
  },
  thread
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
const ctx = { thread };
await handlers.get("session.start")({ thread }, ctx);
if (typeof stateSubscriber !== "function") throw new Error("missing thread.state subscription");
await handlers.get("agent.start")({ thread, message: "hello amp", id: "msg-user-1" }, ctx);
currentState = "running";
await stateSubscriber(currentState);
if (typeof titleSubscriber === "function") titleSubscriber("Updated Amp title");
await handlers.get("agent.end")({ thread, message: "hello amp", id: "msg-user-1", status: "done", messages: [] }, ctx);
await new Promise((resolve) => setTimeout(resolve, 350));
const beforeSettled = fs.existsSync(process.env.FAKE_CMUX_ARGS_LOG)
  ? fs.readFileSync(process.env.FAKE_CMUX_ARGS_LOG, "utf8")
  : "";
if (beforeSettled.includes("hooks amp stop")) {
  throw new Error("agent.end emitted completion before authoritative thread idle");
}
currentState = "awaiting-approval";
await stateSubscriber(currentState);
currentState = "idle";
await stateSubscriber(currentState);

await handlers.get("agent.start")({ thread, message: "fail now", id: "msg-user-2" }, ctx);
currentState = "running";
await stateSubscriber(currentState);
await handlers.get("agent.end")({ thread, message: "fail now", id: "msg-user-2", status: "error", messages: [] }, ctx);
currentState = "error";
await stateSubscriber(currentState);
await new Promise((resolve) => setTimeout(resolve, 350));
"""
        check_script = root / "check.mjs"
        check_script.write_text(check_source, encoding="utf-8")
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
                and "hooks amp title-update" in args_log
                and "hooks amp lifecycle" in args_log
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
            "hooks amp title-update",
            "hooks amp lifecycle",
        ]:
            if expected not in args_log:
                print(f"FAIL: plugin did not invoke {expected}, got {args_log!r}")
                return 1
        if '"session_id":"T-amp-session-test"' not in stdin_log:
            print(f"FAIL: plugin did not pass session id, got {stdin_log!r}")
            return 1
        payloads = []
        for chunk in stdin_log.split("\n---\n"):
            chunk = chunk.strip()
            if not chunk:
                continue
            try:
                payloads.append(json.loads(chunk))
            except json.JSONDecodeError:
                continue
        lifecycle = [
            payload for payload in payloads
            if payload.get("hook_event_name") == "Lifecycle"
        ]
        states = [payload.get("agent_state") for payload in lifecycle]
        for expected_state in ["running", "awaiting-approval", "idle", "error"]:
            if expected_state not in states:
                print(f"FAIL: plugin did not publish authoritative state {expected_state!r}, got {lifecycle!r}")
                return 1
        idle_outcomes = [
            payload.get("turn_outcome") for payload in lifecycle
            if payload.get("agent_state") == "idle"
        ]
        if idle_outcomes != ["done"]:
            print(f"FAIL: idle reconciliation lost the completed turn outcome, got {idle_outcomes!r}")
            return 1
        error_outcomes = [
            payload.get("turn_outcome") for payload in lifecycle
            if payload.get("agent_state") == "error"
        ]
        if error_outcomes != ["error"]:
            print(f"FAIL: error reconciliation lost the failed turn outcome, got {error_outcomes!r}")
            return 1
        title_updates = [
            payload.get("title") for payload in payloads
            if payload.get("hook_event_name") == "TitleUpdate"
        ]
        if title_updates[-1:] != ["Updated Amp title"]:
            print(f"FAIL: plugin did not persist the latest Amp title, got {title_updates!r}")
            return 1
        if "hooks amp stop" in args_log:
            print(f"FAIL: extension bypassed lifecycle reconciliation with a direct stop, got {args_log!r}")
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
