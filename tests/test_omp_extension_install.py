#!/usr/bin/env python3
"""
Regression test: the generated OMP extension is importable and emits cmux hook calls.
"""

from __future__ import annotations

import base64
import os
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

    with tempfile.TemporaryDirectory(prefix="cmux-omp-extension-") as td:
        root = Path(td)
        config_dir = root / "omp-agent"
        env = os.environ.copy()
        env["PI_CODING_AGENT_DIR"] = str(config_dir)

        install = subprocess.run(
            [cli_path, "hooks", "omp", "install", "--yes"],
            capture_output=True,
            text=True,
            check=False,
            env=env,
            timeout=20,
        )
        if install.returncode != 0:
            print("FAIL: omp extension install failed")
            print(f"exit={install.returncode}")
            print(f"stdout={install.stdout.strip()}")
            print(f"stderr={install.stderr.strip()}")
            return 1

        extension_path = config_dir / "extensions" / "cmux-session.ts"
        if not extension_path.exists():
            print(f"FAIL: expected extension at {extension_path}")
            return 1
        extension_text = extension_path.read_text(encoding="utf-8")
        if "cmux-omp-session-extension-marker" not in extension_text:
            print(f"FAIL: expected cmux marker in {extension_path}")
            return 1

        fake_cmux = root / "fake-cmux"
        fake_args_log = root / "fake-cmux-args.log"
        fake_stdin_log = root / "fake-cmux-stdin.log"
        fake_env_log = root / "fake-cmux-env.log"
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
} >> "$FAKE_CMUX_ENV_LOG"
""",
        )

        check_env = env.copy()
        check_env["CMUX_TEST_OMP_EXTENSION_PATH"] = str(extension_path)
        check_env["CMUX_SURFACE_ID"] = "surface-omp-test"
        check_env["CMUX_OMP_CMUX_BIN"] = str(fake_cmux)
        check_env["FAKE_CMUX_ARGS_LOG"] = str(fake_args_log)
        check_env["FAKE_CMUX_STDIN_LOG"] = str(fake_stdin_log)
        check_env["FAKE_CMUX_ENV_LOG"] = str(fake_env_log)
        check_source = """
const extensionPath = process.env.CMUX_TEST_OMP_EXTENSION_PATH;
const mod = await import(extensionPath);
if (typeof mod.default !== "function") throw new Error("missing default export");
const handlers = new Map();
mod.default({
  on(name, handler) {
    handlers.set(name, handler);
  }
});
for (const name of ["session_start", "before_agent_start", "agent_end"]) {
  if (typeof handlers.get(name) !== "function") throw new Error(`missing ${name}`);
}
process.argv.splice(
  0,
  process.argv.length,
  "/Users/example/.bun/bin/omp",
  "--model",
  "anthropic/claude-sonnet-4-5"
);
const ctx = {
  cwd: "/tmp/omp-project",
  sessionManager: {
    getSessionId() { return "omp-session-test"; }
  }
};
await handlers.get("session_start")({}, ctx);
await handlers.get("before_agent_start")({ prompt: "hello omp" }, ctx);
await handlers.get("agent_end")({
  messages: [
    { role: "user", content: "hello omp" },
    { role: "assistant", content: [{ type: "text", text: "done" }] }
  ],
  stopReason: "completed"
}, ctx);
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
            print("FAIL: generated OMP extension is not importable")
            print(f"exit={check.returncode}")
            print(f"stdout={check.stdout.strip()}")
            print(f"stderr={check.stderr.strip()}")
            return 1

        args_log = fake_args_log.read_text(encoding="utf-8") if fake_args_log.exists() else ""
        stdin_log = fake_stdin_log.read_text(encoding="utf-8") if fake_stdin_log.exists() else ""
        env_log = fake_env_log.read_text(encoding="utf-8") if fake_env_log.exists() else ""
        for expected in [
            "hooks omp session-start",
            "hooks omp prompt-submit",
            "hooks omp stop",
        ]:
            if expected not in args_log:
                print(f"FAIL: extension did not invoke {expected}, got {args_log!r}")
                return 1
        if '"session_id":"omp-session-test"' not in stdin_log:
            print(f"FAIL: extension did not pass session id, got {stdin_log!r}")
            return 1
        if '"prompt":"hello omp"' not in stdin_log or '"last_assistant_message":"done"' not in stdin_log:
            print(f"FAIL: extension did not pass prompt/assistant payload, got {stdin_log!r}")
            return 1
        if "kind=omp" not in env_log or "cwd=/tmp/omp-project" not in env_log or "argv=" not in env_log:
            print(f"FAIL: extension did not pass launch metadata environment, got {env_log!r}")
            return 1
        argv_line = next((line for line in env_log.splitlines() if line.startswith("argv=")), "")
        try:
            decoded_argv = [
                value
                for value in base64.b64decode(argv_line.removeprefix("argv=")).decode("utf-8").split("\0")
                if value
            ]
        except Exception as exc:
            print(f"FAIL: extension launch argv was not valid base64 NUL data: {exc}; env={env_log!r}")
            return 1
        expected_argv = [
            "/Users/example/.bun/bin/omp",
            "--model",
            "anthropic/claude-sonnet-4-5",
        ]
        if decoded_argv != expected_argv:
            print(f"FAIL: extension captured wrong OMP launch argv; expected {expected_argv!r}, got {decoded_argv!r}")
            return 1

    print("PASS: generated OMP extension installs and emits cmux hooks")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
