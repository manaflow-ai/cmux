#!/usr/bin/env python3
from __future__ import annotations

import os
import socket
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WRAPPER = ROOT / "Resources" / "bin" / "cmux-claude-wrapper"
SHELL_INTEGRATION_DIR = ROOT / "Resources" / "shell-integration"


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


def test_wrapper_skips_cmux_shims_and_bundled_claude(failures: list[str]) -> None:
    with tempfile.TemporaryDirectory(prefix="cmux-claude-wrapper-resolution-") as td:
        root = Path(td)
        bundle_bin = root / "cmux.app" / "Contents" / "Resources" / "bin"
        shim_bin = root / "shim-bin"
        real_bin = root / "real-bin"
        for directory in (bundle_bin, shim_bin, real_bin):
            directory.mkdir(parents=True, exist_ok=True)

        wrapper = bundle_bin / "cmux-claude-wrapper"
        wrapper.write_bytes(WRAPPER.read_bytes())
        wrapper.chmod(0o755)

        write_executable(
            bundle_bin / "claude",
            """#!/bin/sh
echo bundled-claude "$@"
""",
        )
        write_executable(
            real_bin / "claude",
            """#!/bin/sh
echo real-claude "$@"
""",
        )
        shim = shim_bin / "claude"
        write_executable(
            shim,
            f"""#!/bin/sh
export CMUX_CLAUDE_WRAPPER_SHIM="{shim}"
export CMUX_CLAUDE_WRAPPER_SHIM_ROOT="{shim_bin}"
exec "{wrapper}" "$@"
""",
        )

        env = minimal_env(f"{shim_bin}:{bundle_bin}:{real_bin}:/usr/bin:/bin")
        env["CMUX_CLAUDE_WRAPPER_SHIM"] = str(shim)
        env["CMUX_CLAUDE_WRAPPER_SHIM_ROOT"] = str(shim_bin)
        env["CMUX_CUSTOM_CLAUDE_PATH"] = str(bundle_bin / "claude")

        result = run_wrapper([str(shim), "--version"], env)
        output = (result.stdout + result.stderr).strip()
        if result.returncode != 0:
            failures.append(f"wrapper exited {result.returncode}: {output}")
        if output != "real-claude --version":
            failures.append(f"expected user claude, got {output!r}")


def test_wrapper_skips_inherited_cmux_cli_shim_roots(failures: list[str]) -> None:
    with tempfile.TemporaryDirectory(prefix="cmux-claude-wrapper-inherited-shim-") as td:
        root = Path(td)
        wrapper_bin = root / "wrapper-bin"
        current_shim_root = root / "tmp" / "cmux-cli-shims" / "current-surface"
        inherited_shim_root = root / "tmp" / "cmux-cli-shims" / "old-surface"
        real_bin = root / "real-bin"
        for directory in (wrapper_bin, current_shim_root, inherited_shim_root, real_bin):
            directory.mkdir(parents=True, exist_ok=True)

        wrapper = wrapper_bin / "cmux-claude-wrapper"
        wrapper.write_bytes(WRAPPER.read_bytes())
        wrapper.chmod(0o755)

        current_shim = current_shim_root / "claude"
        write_executable(
            current_shim,
            """#!/bin/sh
echo current-shim "$@"
exit 42
""",
        )
        write_executable(
            inherited_shim_root / "claude",
            """#!/bin/sh
echo inherited-shim "$@"
exit 43
""",
        )
        write_executable(
            real_bin / "claude",
            """#!/bin/sh
echo real-claude "$@"
""",
        )

        env = minimal_env(f"{current_shim_root}:{wrapper_bin}:{inherited_shim_root}:{real_bin}:/usr/bin:/bin")
        env["CMUX_CLAUDE_WRAPPER_SHIM"] = str(current_shim)
        env["CMUX_CLAUDE_WRAPPER_SHIM_ROOT"] = str(current_shim_root)

        result = run_wrapper([str(wrapper), "--version"], env)
        output = (result.stdout + result.stderr).strip()
        if result.returncode != 0:
            failures.append(f"inherited-shim wrapper exited {result.returncode}: {output}")
        if output != "real-claude --version":
            failures.append(f"expected inherited cmux shim roots to be skipped, got {output!r}")


def test_replay_path_beats_path_claude(failures: list[str]) -> None:
    with tempfile.TemporaryDirectory(prefix="cmux-claude-wrapper-replay-") as td:
        root = Path(td)
        replay_bin = root / "captured-bin"
        path_bin = root / "older-path-bin"
        replay_bin.mkdir()
        path_bin.mkdir()

        replay_claude = replay_bin / "claude"
        write_executable(
            replay_claude,
            """#!/bin/sh
echo captured-claude "$@"
""",
        )
        write_executable(
            path_bin / "claude",
            """#!/bin/sh
echo older-path-claude "$@"
""",
        )

        env = minimal_env(f"{path_bin}:/usr/bin:/bin")
        env["CMUX_RESOLVED_CLAUDE_PATH"] = str(replay_claude)
        result = run_wrapper([str(WRAPPER), "--version"], env)
        output = (result.stdout + result.stderr).strip()
        if result.returncode != 0:
            failures.append(f"replay-path wrapper exited {result.returncode}: {output}")
        if output != "captured-claude --version":
            failures.append(f"expected captured Claude to beat PATH, got {output!r}")


def test_stale_replay_path_falls_back_to_path(failures: list[str]) -> None:
    with tempfile.TemporaryDirectory(prefix="cmux-claude-wrapper-stale-replay-") as td:
        root = Path(td)
        path_bin = root / "current-path-bin"
        path_bin.mkdir()
        write_executable(
            path_bin / "claude",
            """#!/bin/sh
echo current-path-claude "$@"
""",
        )

        env = minimal_env(f"{path_bin}:/usr/bin:/bin")
        env["CMUX_RESOLVED_CLAUDE_PATH"] = str(root / "removed-bin" / "claude")
        result = run_wrapper([str(WRAPPER), "--version"], env)
        output = (result.stdout + result.stderr).strip()
        if result.returncode != 0:
            failures.append(f"stale-replay wrapper exited {result.returncode}: {output}")
        if output != "current-path-claude --version":
            failures.append(f"expected stale replay path to fall back to PATH, got {output!r}")


def test_interactive_launch_exposes_resolved_path_without_passthrough_leak(
    failures: list[str],
) -> None:
    with tempfile.TemporaryDirectory(prefix="cmux-claude-wrapper-capture-") as td:
        root = Path(td)
        bin_dir = root / "bin"
        home_dir = root / "home"
        tmp_dir = root / "tmp"
        for directory in (bin_dir, home_dir, tmp_dir):
            directory.mkdir()

        selected_claude = bin_dir / "claude"
        write_executable(
            selected_claude,
            """#!/bin/sh
printf 'resolved=%s\\n' "${CMUX_RESOLVED_CLAUDE_PATH-__UNSET__}"
printf 'executable=%s\\n' "${CMUX_AGENT_LAUNCH_EXECUTABLE-__UNSET__}"
printf 'argv='
printf '<%s>' "$@"
printf '\\n'
""",
        )
        fake_cmux = bin_dir / "cmux"
        write_executable(
            fake_cmux,
            """#!/bin/sh
if [ "${1:-}" = "--socket" ] && [ "${3:-}" = "ping" ]; then
  exit 0
fi
exit 1
""",
        )

        socket_path = root / "cmux.sock"
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
            listener.bind(str(socket_path))
            listener.listen(1)
            env = minimal_env(f"{bin_dir}:/usr/bin:/bin", tmp_dir)
            env.update(
                {
                    "HOME": str(home_dir),
                    "CMUX_SURFACE_ID": "surface-replay-capture",
                    "CMUX_SOCKET_PATH": str(socket_path),
                    "CMUX_BUNDLED_CLI_PATH": str(fake_cmux),
                }
            )

            interactive = run_wrapper([str(WRAPPER), "--model", "sonnet"], env)
            interactive_output = (interactive.stdout + interactive.stderr).strip()
            if interactive.returncode != 0:
                failures.append(
                    f"interactive capture wrapper exited {interactive.returncode}: {interactive_output}"
                )
            if f"resolved={selected_claude}" not in interactive_output:
                failures.append(
                    f"expected hook launch to expose selected resolved path, got {interactive_output!r}"
                )
            if f"executable={selected_claude}" not in interactive_output:
                failures.append(
                    f"expected hook launch executable capture to use selected path, got {interactive_output!r}"
                )

            replay_env = dict(env)
            replay_env["CMUX_RESOLVED_CLAUDE_PATH"] = str(selected_claude)
            passthrough = run_wrapper(
                [str(WRAPPER), "doctor", "--flag", "space arg"],
                replay_env,
            )
            passthrough_output = (passthrough.stdout + passthrough.stderr).strip()
            if passthrough.returncode != 0:
                failures.append(
                    f"doctor passthrough wrapper exited {passthrough.returncode}: {passthrough_output}"
                )
            if "resolved=__UNSET__" not in passthrough_output:
                failures.append(
                    f"expected doctor passthrough to scrub replay key, got {passthrough_output!r}"
                )
            if "argv=<doctor><--flag><space arg>" not in passthrough_output:
                failures.append(
                    f"expected doctor passthrough argv to remain exact, got {passthrough_output!r}"
                )


def test_shell_integration_does_not_shim_grok(failures: list[str]) -> None:
    with tempfile.TemporaryDirectory(prefix="cmux-grok-wrapper-resolution-") as td:
        root = Path(td)
        real_bin = root / "real-bin"
        real_bin.mkdir(parents=True, exist_ok=True)
        write_executable(
            real_bin / "grok",
            """#!/bin/sh
echo real-grok "$@"
""",
        )

        base_env = minimal_env(f"{real_bin}:/usr/bin:/bin")
        base_env["CMUX_SHELL_INTEGRATION_DIR"] = str(SHELL_INTEGRATION_DIR)

        shell_commands = [
            [
                "/bin/bash",
                "--noprofile",
                "--norc",
                "-c",
                'source "$CMUX_SHELL_INTEGRATION_DIR/cmux-bash-integration.bash"; grok --version',
            ],
            [
                "/bin/zsh",
                "-f",
                "-c",
                'source "$CMUX_SHELL_INTEGRATION_DIR/cmux-zsh-integration.zsh"; grok --version',
            ],
        ]
        for argv in shell_commands:
            result = run_wrapper(argv, base_env)
            output = (result.stdout + result.stderr).strip()
            shell_name = Path(argv[0]).name
            if result.returncode != 0:
                failures.append(f"{shell_name} grok wrapper exited {result.returncode}: {output}")
            if output != "real-grok --version":
                failures.append(f"{shell_name} expected user grok, got {output!r}")


def test_shell_integration_preserves_empty_path_components(failures: list[str]) -> None:
    with tempfile.TemporaryDirectory(prefix="cmux-shell-path-components-") as td:
        root = Path(td)
        tmpdir = root / "tmp"
        first = root / "first-bin"
        last = root / "last-bin"
        for directory in (tmpdir, first, last):
            directory.mkdir(parents=True, exist_ok=True)

        surface_id = "surface-path-test"
        shim_root = tmpdir / "cmux-cli-shims" / surface_id
        expected_path = f"{shim_root}::{first}::{last}:"

        input_path = f":{first}::{shim_root}:{last}:"
        base_env = minimal_env("/usr/bin:/bin", tmpdir)
        base_env["CMUX_SHELL_INTEGRATION_DIR"] = str(SHELL_INTEGRATION_DIR)
        base_env["CMUX_SURFACE_ID"] = surface_id
        base_env["CMUX_TEST_INPUT_PATH"] = input_path

        shell_commands = [
            [
                "/bin/bash",
                "--noprofile",
                "--norc",
                "-c",
                'PATH="$CMUX_TEST_INPUT_PATH"; '
                'source "$CMUX_SHELL_INTEGRATION_DIR/cmux-bash-integration.bash"; '
                'printf "%s\\n" "$PATH"',
            ],
            [
                "/bin/zsh",
                "-f",
                "-c",
                'PATH="$CMUX_TEST_INPUT_PATH"; '
                'source "$CMUX_SHELL_INTEGRATION_DIR/cmux-zsh-integration.zsh"; '
                'printf "%s\\n" "$PATH"',
            ],
        ]
        for argv in shell_commands:
            result = run_wrapper(argv, base_env)
            shell_name = Path(argv[0]).name
            output = result.stdout.rstrip("\n")
            if result.returncode != 0:
                failures.append(
                    f"{shell_name} path preservation exited {result.returncode}: "
                    f"{(result.stdout + result.stderr).strip()}"
                )
            if output != expected_path:
                failures.append(f"{shell_name} expected PATH {expected_path!r}, got {output!r}")


def main() -> int:
    failures: list[str] = []
    test_wrapper_skips_cmux_shims_and_bundled_claude(failures)
    test_wrapper_skips_inherited_cmux_cli_shim_roots(failures)
    test_replay_path_beats_path_claude(failures)
    test_stale_replay_path_falls_back_to_path(failures)
    test_interactive_launch_exposes_resolved_path_without_passthrough_leak(failures)
    test_shell_integration_does_not_shim_grok(failures)
    test_shell_integration_preserves_empty_path_components(failures)
    if failures:
        print("FAIL: claude wrapper binary resolution checks failed")
        for failure in failures:
            print(f"- {failure}")
        return 1
    print("PASS: provider wrappers resolve user-owned binaries without shim recursion")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
