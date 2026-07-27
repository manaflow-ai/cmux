#!/usr/bin/env python3
"""Regression tests for https://github.com/manaflow-ai/cmux/issues/7035.

A `claude` defined as a shell function/wrapper in the user's rc file is
invisible to cmux's non-interactive launch paths. The Claude Binary Path
setting (CMUX_CUSTOM_CLAUDE_PATH) must accept a launch *command* (a /bin/sh
snippet receiving the agent arguments as "$@"), not just a binary path, so
users can route cmux's claude launches through their own shell function.
"""
from __future__ import annotations

import os
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WRAPPER = ROOT / "Resources" / "bin" / "cmux-claude-wrapper"


def minimal_env(path: str, tmpdir: Path | None = None) -> dict[str, str]:
    env = {
        "HOME": os.environ.get("HOME", str(ROOT)),
        "PATH": path,
    }
    if tmpdir is not None:
        env["TMPDIR"] = str(tmpdir)
    return env


def write_executable(path: Path, contents: str) -> None:
    path.write_text(contents, encoding="utf-8")
    path.chmod(0o755)


def run_wrapper(argv: list[str], env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        argv,
        env=env,
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )


def install_wrapper(bundle_bin: Path) -> Path:
    bundle_bin.mkdir(parents=True, exist_ok=True)
    wrapper = bundle_bin / "cmux-claude-wrapper"
    wrapper.write_bytes(WRAPPER.read_bytes())
    wrapper.chmod(0o755)
    return wrapper


def test_command_mode_runs_custom_command(failures: list[str]) -> None:
    """A command-string CMUX_CUSTOM_CLAUDE_PATH runs with the args as "$@"."""
    with tempfile.TemporaryDirectory(prefix="cmux-claude-custom-command-") as td:
        root = Path(td)
        wrapper = install_wrapper(root / "cmux.app" / "Contents" / "Resources" / "bin")
        log = root / "argv.log"
        logger = root / "log-args.sh"
        write_executable(
            logger,
            f"""#!/bin/sh
printf '%s\\n' "custom-claude $*" > "{log}"
""",
        )

        # No claude binary anywhere on PATH: the command is the only way to launch.
        env = minimal_env("/usr/bin:/bin")
        env["CMUX_CUSTOM_CLAUDE_PATH"] = f'"{logger}" "$@"'

        result = run_wrapper([str(wrapper), "--version", "hello world"], env)
        output = (result.stdout + result.stderr).strip()
        if result.returncode != 0:
            failures.append(f"command mode exited {result.returncode}: {output}")
        if not log.exists():
            failures.append(f"custom command never ran (wrapper output: {output!r})")
        elif log.read_text(encoding="utf-8").strip() != "custom-claude --version hello world":
            failures.append(f"custom command got wrong argv: {log.read_text(encoding='utf-8').strip()!r}")


def test_command_mode_reaches_zsh_shell_function(failures: list[str]) -> None:
    """The issue #7035 repro: claude defined only as a zsh function in ~/.zshrc."""
    with tempfile.TemporaryDirectory(prefix="cmux-claude-zsh-function-") as td:
        root = Path(td)
        wrapper = install_wrapper(root / "cmux.app" / "Contents" / "Resources" / "bin")
        zdot = root / "zdot"
        zdot.mkdir(parents=True, exist_ok=True)
        marker = root / "marker"
        (zdot / ".zshrc").write_text(
            f"""claude() {{ printf '%s\\n' "function-claude $*" > "{marker}"; }}
""",
            encoding="utf-8",
        )

        env = minimal_env("/usr/bin:/bin")
        env["ZDOTDIR"] = str(zdot)
        env["CMUX_CUSTOM_CLAUDE_PATH"] = '/bin/zsh -lic \'claude "$@"\' claude "$@"'

        result = run_wrapper([str(wrapper), "--resume", "session-123"], env)
        output = (result.stdout + result.stderr).strip()
        if result.returncode != 0:
            failures.append(f"zsh function launch exited {result.returncode}: {output}")
        if not marker.exists():
            failures.append(f"zsh claude function never ran (wrapper output: {output!r})")
        elif marker.read_text(encoding="utf-8").strip() != "function-claude --resume session-123":
            failures.append(
                f"zsh claude function got wrong argv: {marker.read_text(encoding='utf-8').strip()!r}"
            )


def test_command_mode_in_cmux_stale_socket_passthrough(failures: list[str]) -> None:
    """Inside a cmux terminal with a stale/missing socket the command still runs."""
    with tempfile.TemporaryDirectory(prefix="cmux-claude-custom-command-in-cmux-") as td:
        root = Path(td)
        wrapper = install_wrapper(root / "cmux.app" / "Contents" / "Resources" / "bin")
        log = root / "argv.log"
        logger = root / "log-args.sh"
        write_executable(
            logger,
            f"""#!/bin/sh
printf '%s\\n' "custom-claude $*" > "{log}"
""",
        )

        env = minimal_env("/usr/bin:/bin")
        env["CMUX_SURFACE_ID"] = "surface-custom-command"
        env["CMUX_CUSTOM_CLAUDE_PATH"] = f'"{logger}" "$@"'

        result = run_wrapper([str(wrapper), "--version"], env)
        output = (result.stdout + result.stderr).strip()
        if result.returncode != 0:
            failures.append(f"in-cmux command mode exited {result.returncode}: {output}")
        if not log.exists():
            failures.append(f"in-cmux custom command never ran (wrapper output: {output!r})")
        elif log.read_text(encoding="utf-8").strip() != "custom-claude --version":
            failures.append(
                f"in-cmux custom command got wrong argv: {log.read_text(encoding='utf-8').strip()!r}"
            )


def test_command_mode_reentry_falls_back_without_looping(failures: list[str]) -> None:
    """A custom command whose inner `claude` re-enters the cmux shim must not loop.

    The re-entry (guard env var already exported) has to fall back to normal
    PATH resolution, skipping both the shim and command mode.
    """
    with tempfile.TemporaryDirectory(prefix="cmux-claude-custom-command-loop-") as td:
        root = Path(td)
        bundle_bin = root / "cmux.app" / "Contents" / "Resources" / "bin"
        wrapper = install_wrapper(bundle_bin)
        shim_bin = root / "shim-bin"
        real_bin = root / "real-bin"
        for directory in (shim_bin, real_bin):
            directory.mkdir(parents=True, exist_ok=True)

        shim = shim_bin / "claude"
        write_executable(
            shim,
            f"""#!/bin/sh
export CMUX_CLAUDE_WRAPPER_SHIM="{shim}"
export CMUX_CLAUDE_WRAPPER_SHIM_ROOT="{shim_bin}"
exec "{wrapper}" "$@"
""",
        )
        write_executable(
            real_bin / "claude",
            """#!/bin/sh
echo real-claude "$@"
""",
        )

        log = root / "custom.log"
        env = minimal_env(f"{shim_bin}:{real_bin}:/usr/bin:/bin")
        env["CMUX_CLAUDE_WRAPPER_SHIM"] = str(shim)
        env["CMUX_CLAUDE_WRAPPER_SHIM_ROOT"] = str(shim_bin)
        # The custom command notes that it ran, then resolves `claude` through
        # PATH again — which hits the cmux shim and re-enters the wrapper.
        env["CMUX_CUSTOM_CLAUDE_PATH"] = f'echo custom-ran >> "{log}"; exec "{shim}" "$@"'

        result = run_wrapper([str(shim), "--version"], env)
        output = (result.stdout + result.stderr).strip()
        if result.returncode != 0:
            failures.append(f"re-entrant command mode exited {result.returncode}: {output}")
        if not log.exists():
            failures.append(f"re-entrant custom command never ran (wrapper output: {output!r})")
        elif log.read_text(encoding="utf-8").strip() != "custom-ran":
            failures.append(
                "custom command must run exactly once on re-entry, got "
                f"{log.read_text(encoding='utf-8').strip()!r}"
            )
        if log.exists() and output != "real-claude --version":
            failures.append(f"re-entry expected real claude fallback, got {output!r}")


def test_binary_mode_with_space_in_path_still_execs_directly(failures: list[str]) -> None:
    """An existing executable-file value keeps binary mode, even with spaces."""
    with tempfile.TemporaryDirectory(prefix="cmux-claude-custom-binary-space-") as td:
        root = Path(td)
        wrapper = install_wrapper(root / "cmux.app" / "Contents" / "Resources" / "bin")
        custom_bin = root / "dir with space"
        custom_bin.mkdir(parents=True, exist_ok=True)
        custom_claude = custom_bin / "claude"
        write_executable(
            custom_claude,
            """#!/bin/sh
echo custom-binary-claude "$@"
""",
        )

        env = minimal_env("/usr/bin:/bin")
        env["CMUX_CUSTOM_CLAUDE_PATH"] = str(custom_claude)

        result = run_wrapper([str(wrapper), "--version"], env)
        output = (result.stdout + result.stderr).strip()
        if result.returncode != 0:
            failures.append(f"binary mode exited {result.returncode}: {output}")
        if output != "custom-binary-claude --version":
            failures.append(f"expected direct exec of custom binary, got {output!r}")


def _expect_path_fallback(
    failures: list[str],
    label: str,
    custom_value_for: "callable",
) -> None:
    """The configured value must keep the silent PATH fallback: the PATH claude
    runs and receives the full argv."""
    with tempfile.TemporaryDirectory(prefix=f"cmux-claude-custom-fallback-{label}-") as td:
        root = Path(td)
        wrapper = install_wrapper(root / "cmux.app" / "Contents" / "Resources" / "bin")
        real_bin = root / "real-bin"
        real_bin.mkdir(parents=True, exist_ok=True)
        write_executable(
            real_bin / "claude",
            """#!/bin/sh
echo real-claude "$@"
""",
        )

        env = minimal_env(f"{real_bin}:/usr/bin:/bin")
        env["CMUX_CUSTOM_CLAUDE_PATH"] = custom_value_for(root)

        result = run_wrapper([str(wrapper), "--resume", "session-123"], env)
        output = (result.stdout + result.stderr).strip()
        if result.returncode != 0:
            failures.append(f"{label}: fallback exited {result.returncode}: {output}")
        elif output != "real-claude --resume session-123":
            failures.append(
                f"{label}: expected PATH fallback with args intact, got {output!r}"
            )


def test_values_without_args_reference_keep_path_fallback(failures: list[str]) -> None:
    """No-regression: values without a literal "$@" never enter command mode.

    A stale spaced path used to fall back silently and must keep doing so
    (not hard-fail through /bin/sh); an unexpanded $HOME-style value must not
    become a command that silently drops the arguments; a spaced command
    without "$@" could never forward the args, so it falls back too.
    """
    _expect_path_fallback(
        failures, "stale-spaced-path", lambda root: str(root / "dir with space" / "claude")
    )
    _expect_path_fallback(
        failures, "unexpanded-home-path", lambda root: "$HOME/bin/claude"
    )
    _expect_path_fallback(
        failures, "command-without-args-token", lambda root: "zsh -lic claude"
    )


def main() -> int:
    failures: list[str] = []
    test_command_mode_runs_custom_command(failures)
    test_command_mode_reaches_zsh_shell_function(failures)
    test_command_mode_in_cmux_stale_socket_passthrough(failures)
    test_command_mode_reentry_falls_back_without_looping(failures)
    test_binary_mode_with_space_in_path_still_execs_directly(failures)
    test_values_without_args_reference_keep_path_fallback(failures)
    if failures:
        print("FAIL: claude wrapper custom launch command checks failed")
        for failure in failures:
            print(f"- {failure}")
        return 1
    print("PASS: claude wrapper honors custom launch commands (issue #7035)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
