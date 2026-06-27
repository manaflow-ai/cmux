#!/usr/bin/env python3
from __future__ import annotations

import os
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


def expected_path_after_shim_install(initial_path: str, shim_root: Path) -> str:
    shim_root_text = str(shim_root)
    entries = initial_path.split(":")
    return ":".join([shim_root_text] + [entry for entry in entries if entry != shim_root_text])


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
                (
                    'PATH="$CMUX_TEST_INPUT_PATH"; '
                    'printf "CMUX_TEST_BEFORE=%s\\n" "$PATH"; '
                    'source "$CMUX_SHELL_INTEGRATION_DIR/cmux-bash-integration.bash"; '
                    'printf "CMUX_TEST_AFTER=%s\\n" "$PATH"'
                ),
            ],
            [
                "/bin/zsh",
                "-f",
                "-c",
                (
                    'PATH="$CMUX_TEST_INPUT_PATH"; '
                    'printf "CMUX_TEST_BEFORE=%s\\n" "$PATH"; '
                    'source "$CMUX_SHELL_INTEGRATION_DIR/cmux-zsh-integration.zsh"; '
                    'printf "CMUX_TEST_AFTER=%s\\n" "$PATH"'
                ),
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
            lines = output.splitlines()
            before_prefix = "CMUX_TEST_BEFORE="
            after_prefix = "CMUX_TEST_AFTER="
            before = next((line[len(before_prefix):] for line in lines if line.startswith(before_prefix)), None)
            after = next((line[len(after_prefix):] for line in lines if line.startswith(after_prefix)), None)
            if before is None or after is None:
                failures.append(f"{shell_name} path preservation missing sentinel output: {output!r}")
                continue
            expected_path = expected_path_after_shim_install(before, shim_root)
            if after != expected_path:
                failures.append(f"{shell_name} expected PATH {expected_path!r}, got {after!r}")


def main() -> int:
    failures: list[str] = []
    test_wrapper_skips_cmux_shims_and_bundled_claude(failures)
    test_wrapper_skips_inherited_cmux_cli_shim_roots(failures)
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
