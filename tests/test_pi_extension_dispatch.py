#!/usr/bin/env python3
"""Regression coverage for Pi extension dispatch responsiveness and stale surfaces."""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
from pathlib import Path

from claude_teams_test_utils import resolve_cmux_cli


def make_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


def install_extension(root: Path) -> Path:
    config_dir = root / "pi-agent"
    env = os.environ.copy()
    env["PI_CODING_AGENT_DIR"] = str(config_dir)
    install = subprocess.run(
        [resolve_cmux_cli(), "hooks", "pi", "install", "--yes"],
        capture_output=True,
        text=True,
        check=False,
        env=env,
        timeout=20,
    )
    if install.returncode != 0:
        raise RuntimeError(
            f"Pi extension install failed: exit={install.returncode} "
            f"stdout={install.stdout!r} stderr={install.stderr!r}"
        )

    extension_path = config_dir / "extensions" / "cmux-session.ts"
    override = os.environ.get("CMUX_TEST_PI_EXTENSION_OVERRIDE")
    if override:
        shutil.copyfile(override, extension_path)
    return extension_path


def run_extension(
    *,
    bun: str,
    root: Path,
    extension_path: Path,
    fake_cmux: Path,
    source: str,
    extra_env: dict[str, str],
) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env.update(extra_env)
    env["CMUX_TEST_PI_EXTENSION_PATH"] = str(extension_path)
    env["CMUX_PI_CMUX_BIN"] = str(fake_cmux)
    env["CMUX_SURFACE_ID"] = "00000000-0000-0000-0000-000000008672"
    env["CMUX_WORKSPACE_ID"] = "00000000-0000-0000-0000-000000008673"
    return subprocess.run(
        [bun, "--eval", source],
        cwd=root,
        capture_output=True,
        text=True,
        check=False,
        env=env,
        timeout=20,
    )


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

    del cli_path
    with tempfile.TemporaryDirectory(prefix="cmux-pi-dispatch-") as td:
        root = Path(td)
        try:
            extension_path = install_extension(root)
        except Exception as exc:
            print(f"FAIL: {exc}")
            return 1

        slow_log = root / "slow-cmux.log"
        slow_cmux = root / "slow-cmux"
        make_executable(
            slow_cmux,
            """#!/usr/bin/env bash
set -euo pipefail
printf 'start %s\n' "$*" >> "$CMUX_TEST_PI_DISPATCH_LOG"
cat >/dev/null
sleep 0.4
printf 'end %s\n' "$*" >> "$CMUX_TEST_PI_DISPATCH_LOG"
printf '{}\n'
""",
        )
        responsiveness_source = """
const extensionPath = process.env.CMUX_TEST_PI_EXTENSION_PATH;
const mod = await import(extensionPath);
const handlers = new Map();
mod.default({
  on(name, handler) {
    handlers.set(name, handler);
  }
});
const beforeAgentStart = handlers.get("before_agent_start");
if (typeof beforeAgentStart !== "function") throw new Error("missing before_agent_start");
const ctx = {
  cwd: "/tmp/pi-dispatch-project",
  sessionManager: {
    getSessionId() { return "pi-dispatch-session"; }
  }
};
const startedAt = Date.now();
let heartbeatAt = 0;
const heartbeat = new Promise((resolve) => {
  setTimeout(() => {
    heartbeatAt = Date.now();
    resolve();
  }, 75);
});
const first = beforeAgentStart({ prompt: "first" }, ctx);
const second = beforeAgentStart({ prompt: "second" }, ctx);
await heartbeat;
const heartbeatDelay = heartbeatAt - startedAt;
if (heartbeatDelay >= 300) {
  throw new Error(`Pi event loop blocked for ${heartbeatDelay}ms during cmux dispatch`);
}
await Promise.all([first, second]);
"""
        responsive = run_extension(
            bun=bun,
            root=root,
            extension_path=extension_path,
            fake_cmux=slow_cmux,
            source=responsiveness_source,
            extra_env={"CMUX_TEST_PI_DISPATCH_LOG": str(slow_log)},
        )
        if responsive.returncode != 0:
            print("FAIL: Pi hook dispatch blocked the extension event loop")
            print(f"exit={responsive.returncode}")
            print(f"stdout={responsive.stdout.strip()}")
            print(f"stderr={responsive.stderr.strip()}")
            return 1

        slow_lines = [line for line in slow_log.read_text(encoding="utf-8").splitlines() if line]
        phases = [line.split(" ", 1)[0] for line in slow_lines]
        if phases != ["start", "end", "start", "end"]:
            print(f"FAIL: concurrent Pi hooks were not serialized: {slow_lines!r}")
            return 1
        if not all("hooks pi prompt-submit" in line for line in slow_lines):
            print(f"FAIL: responsiveness harness captured unexpected commands: {slow_lines!r}")
            return 1

        stale_log = root / "stale-cmux.log"
        stale_cmux = root / "stale-cmux"
        make_executable(
            stale_cmux,
            """#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$CMUX_TEST_PI_STALE_LOG"
cat >/dev/null
sleep 0.15
printf 'Error: not_found: Surface not found\n' >&2
exit 1
""",
        )
        stale_source = """
const extensionPath = process.env.CMUX_TEST_PI_EXTENSION_PATH;
const mod = await import(extensionPath);
const handlers = new Map();
mod.default({
  on(name, handler) {
    handlers.set(name, handler);
  }
});
const ctx = {
  cwd: "/tmp/pi-stale-surface-project",
  sessionManager: {
    getSessionId() { return "pi-stale-surface-session"; }
  }
};
await handlers.get("session_start")({}, ctx);
await handlers.get("before_agent_start")({ prompt: "hello" }, ctx);
await handlers.get("agent_end")({
  messages: [{ role: "assistant", content: "done" }],
  stopReason: "completed"
}, ctx);
await handlers.get("session_shutdown")({ reason: "quit" }, ctx);
"""
        stale = run_extension(
            bun=bun,
            root=root,
            extension_path=extension_path,
            fake_cmux=stale_cmux,
            source=stale_source,
            extra_env={"CMUX_TEST_PI_STALE_LOG": str(stale_log)},
        )
        if stale.returncode != 0:
            print("FAIL: stale-surface Pi harness failed to execute")
            print(f"exit={stale.returncode}")
            print(f"stdout={stale.stdout.strip()}")
            print(f"stderr={stale.stderr.strip()}")
            return 1

        stale_calls = [line for line in stale_log.read_text(encoding="utf-8").splitlines() if line]
        if len(stale_calls) != 1:
            print(
                "FAIL: stale CMUX_SURFACE_ID was retried after its first permanent failure: "
                f"{stale_calls!r}"
            )
            return 1
        warning_count = stale.stderr.count('"source":"cmux-pi-extension"')
        if warning_count != 1:
            print(f"FAIL: stale surface emitted {warning_count} warnings instead of one: {stale.stderr!r}")
            return 1

    print("PASS: Pi dispatch stays responsive, serialized, and fails stale surfaces once")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
