#!/usr/bin/env python3
"""Regression tests for https://github.com/manaflow-ai/cmux/issues/10230.

A custom `Claude Binary Path` script that resolves `claude` through PATH finds
cmux's own per-surface shim, so control re-enters `cmux-claude-wrapper` after it
has already injected its hook `--settings`. The wrapper must treat that re-entry
as a no-op: the injected settings must converge instead of growing one hook copy
per pass, and a user's own `--settings` must survive unchanged.
"""

from __future__ import annotations

import json
import shutil
import socket
import subprocess
import tempfile
from pathlib import Path

from node_runtime import ensure_node_on_path


ROOT = Path(__file__).resolve().parents[1]
SOURCE_WRAPPER = ROOT / "Resources" / "bin" / "cmux-claude-wrapper"
CMUX_HOOK_FEED_COMMAND = "hooks feed --source claude"


def make_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


def settings_from_argv(argv: list[str]) -> dict | None:
    index = 0
    while index < len(argv):
        arg = argv[index]
        if arg == "--":
            return None
        if arg == "--settings" and index + 1 < len(argv):
            return json.loads(argv[index + 1])
        if arg.startswith("--settings="):
            return json.loads(arg[len("--settings=") :])
        index += 1
    return None


def count_cmux_hook_commands(settings: dict) -> int:
    total = 0
    for entries in (settings.get("hooks") or {}).values():
        for entry in entries:
            for hook in entry.get("hooks", []):
                if CMUX_HOOK_FEED_COMMAND in hook.get("command", ""):
                    total += 1
    return total


def collect_hook_commands(settings: dict) -> list[str]:
    commands: list[str] = []
    for entries in (settings.get("hooks") or {}).values():
        for entry in entries:
            for hook in entry.get("hooks", []):
                commands.append(hook.get("command", ""))
    return commands


class ReentryRun:
    def __init__(self, returncode: int, stderr: str, passes: list[list[str]], real_argv: list[str]) -> None:
        self.returncode = returncode
        self.stderr = stderr
        self.passes = passes
        self.real_argv = real_argv


def run_reentry(
    *,
    argv: list[str],
    break_after: int | None,
    scrub_env_marker: bool = False,
    timeout: float = 30.0,
) -> ReentryRun:
    """Launch cmux's shim `claude` with a re-entrant custom Claude Binary Path.

    The custom binary path is a script that hands off to a launcher which
    resolves `claude` through PATH, exactly like the reporter's setup. PATH puts
    cmux's shim directory first, so every hand-off lands back in the wrapper.
    `break_after` passes lets the launcher escape the loop and reach the real
    binary; `None` keeps the loop running so the wrapper's guard has to stop it.
    `scrub_env_marker` drops every cmux env marker the way a launcher that
    rebuilds the environment would, leaving argv as the only re-entry signal.
    """

    with tempfile.TemporaryDirectory(prefix="cmux-claude-reentry-") as td:
        tmp = Path(td)
        shim_dir = tmp / "tmp" / "cmux-cli-shims" / "surface-reentry"
        launcher_dir = tmp / "launcher-bin"
        custom_dir = tmp / "custom-bin"
        real_dir = tmp / "real-bin"
        pass_dir = tmp / "passes"
        for directory in (shim_dir, launcher_dir, custom_dir, real_dir, pass_dir):
            directory.mkdir(parents=True, exist_ok=True)

        shim_claude = shim_dir / "claude"
        shutil.copy2(SOURCE_WRAPPER, shim_claude)
        shim_claude.chmod(0o755)

        fake_cmux = """#!/usr/bin/env bash
if [[ "${1:-}" == "--socket" ]]; then
  shift 2
fi
if [[ "${1:-}" == "ping" ]]; then
  exit 0
fi
exit 0
"""
        make_executable(shim_dir / "cmux", fake_cmux)

        real_argv_log = tmp / "real-argv.json"
        make_executable(
            real_dir / "claude",
            f"""#!/usr/bin/env python3
import json, sys
open({str(real_argv_log)!r}, "w").write(json.dumps(sys.argv[1:]))
""",
        )

        # Resolves `claude` through PATH the way `shutil.which` / `command -v` /
        # `execvp` do in a user launcher, which is what finds cmux's shim.
        break_after_literal = "None" if break_after is None else str(break_after)
        scrub_literal = "True" if scrub_env_marker else "False"
        make_executable(
            launcher_dir / "claude-launcher",
            f"""#!/usr/bin/env python3
import json, os, shutil, sys

pass_dir = {str(pass_dir)!r}
break_after = {break_after_literal}
scrub_env_marker = {scrub_literal}
argv = sys.argv[2:]
if scrub_env_marker:
    os.environ.pop("CMUX_CLAUDE_WRAPPER_HOOKS_INJECTED", None)
index = len(os.listdir(pass_dir)) + 1
with open(os.path.join(pass_dir, "pass-%03d.json" % index), "w") as handle:
    json.dump(argv, handle)
if break_after is not None and index >= break_after:
    entries = [e for e in os.environ["PATH"].split(os.pathsep) if "cmux-cli-shims" not in e]
    os.environ["PATH"] = os.pathsep.join(entries)
target = shutil.which("claude")
if target is None:
    sys.stderr.write("launcher: claude not found\\n")
    raise SystemExit(127)
os.execv(target, ["claude"] + argv)
""",
        )

        custom_claude = custom_dir / "claude-custom"
        make_executable(
            custom_claude,
            f"""#!/bin/sh
exec {launcher_dir / "claude-launcher"} claude "$@"
""",
        )

        socket_path = str(tmp / "cmux.sock")
        test_socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        test_socket.bind(socket_path)

        # The wrapper folds a user's --settings into its own with node; without
        # node on PATH it falls back to emitting two --settings flags and the
        # merge under test never runs.
        node_dir = str(Path(ensure_node_on_path() or "/usr/bin/node").parent)
        env = {
            "HOME": str(tmp / "home"),
            "PATH": f"{shim_dir}:{launcher_dir}:{real_dir}:{node_dir}:/usr/bin:/bin",
            "TMPDIR": str(tmp / "tmp") + "/",
            "CMUX_SURFACE_ID": "surface:reentry",
            "CMUX_SOCKET_PATH": socket_path,
            "CMUX_CLAUDE_WRAPPER_SHIM": str(shim_claude),
            "CMUX_CLAUDE_WRAPPER_SHIM_ROOT": str(shim_dir),
            "CMUX_CUSTOM_CLAUDE_PATH": str(custom_claude),
        }
        (tmp / "home").mkdir(parents=True, exist_ok=True)

        try:
            proc = subprocess.run(
                [str(shim_claude), *argv],
                cwd=tmp,
                env=env,
                capture_output=True,
                text=True,
                timeout=timeout,
                check=False,
            )
            returncode = proc.returncode
            stderr = proc.stderr
        except subprocess.TimeoutExpired as expired:
            returncode = -1
            stderr = (expired.stderr or b"").decode("utf-8", "replace") if isinstance(expired.stderr, bytes) else (expired.stderr or "")
            stderr = f"TIMEOUT after {timeout}s\n{stderr}"
        finally:
            test_socket.close()

        passes = [json.loads(path.read_text(encoding="utf-8")) for path in sorted(pass_dir.iterdir())]
        real_argv = json.loads(real_argv_log.read_text(encoding="utf-8")) if real_argv_log.exists() else []
        return ReentryRun(returncode, stderr, passes, real_argv)


def test_reentry_does_not_duplicate_injected_hooks(failures: list[str]) -> None:
    run = run_reentry(argv=[], break_after=3)

    if len(run.passes) < 3:
        failures.append(f"expected at least 3 wrapper passes, got {len(run.passes)}: stderr={run.stderr!r}")
        return
    if not run.real_argv:
        failures.append(f"real claude never started: stderr={run.stderr!r}")
        return

    baseline = settings_from_argv(run.passes[0])
    if baseline is None:
        failures.append(f"first pass carried no --settings: {run.passes[0]!r}")
        return

    baseline_hook_count = count_cmux_hook_commands(baseline)
    if baseline_hook_count != 3:
        failures.append(f"expected 3 cmux hook-feed commands on first pass, got {baseline_hook_count}")

    for index, pass_argv in enumerate(run.passes[1:], start=2):
        settings = settings_from_argv(pass_argv)
        if settings is None:
            failures.append(f"pass {index} carried no --settings: {pass_argv!r}")
            continue
        hook_count = count_cmux_hook_commands(settings)
        if hook_count != baseline_hook_count:
            failures.append(
                f"pass {index} duplicated cmux hooks: {hook_count} hook-feed commands, expected {baseline_hook_count}"
            )
        if settings != baseline:
            failures.append(f"pass {index} settings diverged from the first pass")
        if pass_argv.count("--settings") != 1:
            failures.append(f"pass {index} carried {pass_argv.count('--settings')} --settings arguments, expected 1")
        if pass_argv.count("--session-id") > 1:
            failures.append(f"pass {index} carried {pass_argv.count('--session-id')} --session-id arguments")

    final_settings = settings_from_argv(run.real_argv)
    if final_settings is None:
        failures.append(f"real claude received no --settings: {run.real_argv!r}")
    elif count_cmux_hook_commands(final_settings) != baseline_hook_count:
        failures.append(
            "real claude received "
            f"{count_cmux_hook_commands(final_settings)} cmux hook-feed commands, expected {baseline_hook_count}"
        )


def test_reentry_preserves_user_settings(failures: list[str]) -> None:
    user_settings = {
        "model": "user-selected-model",
        "hooks": {
            "Stop": [
                {
                    "matcher": "",
                    "hooks": [{"type": "command", "command": "user-stop-hook", "timeout": 7}],
                }
            ]
        },
    }
    run = run_reentry(argv=["--settings", json.dumps(user_settings)], break_after=3)

    if len(run.passes) < 3:
        failures.append(f"expected at least 3 wrapper passes with user settings, got {len(run.passes)}: stderr={run.stderr!r}")
        return

    baseline = settings_from_argv(run.passes[0])
    if baseline is None:
        failures.append(f"first pass carried no --settings: {run.passes[0]!r}")
        return

    for index, pass_argv in enumerate(run.passes, start=1):
        settings = settings_from_argv(pass_argv)
        if settings is None:
            failures.append(f"pass {index} carried no --settings")
            continue
        if settings.get("model") != "user-selected-model":
            failures.append(f"pass {index} lost the user's model setting: {settings.get('model')!r}")
        user_hook_count = collect_hook_commands(settings).count("user-stop-hook")
        if user_hook_count != 1:
            failures.append(f"pass {index} carried {user_hook_count} copies of the user's hook, expected 1")
        cmux_hook_count = count_cmux_hook_commands(settings)
        if cmux_hook_count != 3:
            failures.append(f"pass {index} carried {cmux_hook_count} cmux hook-feed commands, expected 3")
        if settings != baseline:
            failures.append(f"pass {index} settings diverged from the first pass")


def test_merge_converges_without_the_env_marker(failures: list[str]) -> None:
    """The merge alone must converge, so a launcher that rebuilds the
    environment still cannot grow the injected block one copy per pass."""

    user_settings = {"model": "user-selected-model"}
    run = run_reentry(
        argv=["--settings", json.dumps(user_settings)],
        break_after=3,
        scrub_env_marker=True,
    )

    if len(run.passes) < 3:
        failures.append(f"expected at least 3 wrapper passes without the env marker, got {len(run.passes)}: stderr={run.stderr!r}")
        return

    baseline = settings_from_argv(run.passes[0])
    if baseline is None:
        failures.append(f"first pass carried no --settings: {run.passes[0]!r}")
        return

    for index, pass_argv in enumerate(run.passes[1:], start=2):
        settings = settings_from_argv(pass_argv)
        if settings is None:
            failures.append(f"pass {index} carried no --settings without the env marker")
            continue
        hook_count = count_cmux_hook_commands(settings)
        if hook_count != 3:
            failures.append(f"pass {index} carried {hook_count} cmux hook-feed commands without the env marker, expected 3")
        if settings.get("model") != "user-selected-model":
            failures.append(f"pass {index} lost the user's model setting without the env marker")
        if settings != baseline:
            failures.append(f"pass {index} settings diverged from the first pass without the env marker")


def test_unbounded_reentry_loop_is_stopped(failures: list[str]) -> None:
    run = run_reentry(argv=[], break_after=None, timeout=30.0)

    if run.returncode == -1:
        failures.append(f"wrapper never stopped the re-entry loop: {run.stderr!r} after {len(run.passes)} passes")
        return
    if run.returncode == 0:
        failures.append(f"expected a non-zero exit from the re-entry guard, got 0: {run.stderr!r}")
    if "cmux:" not in run.stderr:
        failures.append(f"expected an actionable cmux error on stderr, got: {run.stderr!r}")
    if "Claude Binary Path" not in run.stderr:
        failures.append(f"expected the error to name Claude Binary Path, got: {run.stderr!r}")
    if len(run.passes) > 32:
        failures.append(f"re-entry guard allowed {len(run.passes)} passes before stopping")


def main() -> int:
    if ensure_node_on_path() is None:
        print("SKIP: node runtime not found; the wrapper's --settings merge needs node")
        return 0
    failures: list[str] = []
    test_reentry_does_not_duplicate_injected_hooks(failures)
    test_reentry_preserves_user_settings(failures)
    test_merge_converges_without_the_env_marker(failures)
    test_unbounded_reentry_loop_is_stopped(failures)
    if failures:
        print("FAIL: claude wrapper --settings re-entry checks failed")
        for failure in failures:
            print(f"- {failure}")
        return 1
    print("PASS: claude wrapper --settings injection converges across re-entry")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
