#!/usr/bin/env python3
"""
Regression coverage for https://github.com/manaflow-ai/cmux/issues/9356.

Same bug as #6714, but in the bash integration: with ``set -o noclobber`` in the
user's interactive bash, every prompt prints

    bash: /var/folders/.../T/cmux-cli-shims/<surface-id>/claude: cannot overwrite existing file

``Resources/shell-integration/cmux-bash-integration.bash`` writes its per-surface
CLI shim with a plain ``>`` redirection::

    } >"$shim_path" 2>/dev/null || return 0

``_cmux_install_cli_command_shim`` runs more than once per shell (source time,
then again from the prompt hook), so the second and later writes target an
existing file. Under ``noclobber`` bash refuses the redirect and reports it; the
``2>/dev/null`` does not suppress the message because the shell's redirection
machinery reports the failure on the compound-command redirect itself. The
``|| return 0`` then skips the write, so the shim is also left stale.

Fix: bash's explicit clobber redirection ``>|`` for this cmux-owned generated
file, matching the zsh integration.

This test drives the real integration file through real bash with ``noclobber``
enabled and asserts that a second shim write is silent **and** actually
refreshes the shim contents. Deterministic (no PTY, no sleeps, no network) and
locale-pinned so assertions do not depend on bash's message wording.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
INTEGRATION = REPO_ROOT / "Resources/shell-integration/cmux-bash-integration.bash"

# Two explicit shim writes under noclobber, with two different wrapper paths so
# we can prove the second write refreshed the file rather than silently
# no-op'ing. Sourcing without CMUX_SHELL_INTEGRATION_DIR keeps the top-level
# wrapper install an early-return, and the prompt hooks never fire under
# `bash -c`, so these are the only writes.
DRIVER = r"""
set -o noclobber
source "$CMUX_BASH_INTEGRATION" 2>/dev/null
export TMPDIR="$CMUX_TEST_TMPDIR"
export CMUX_SURFACE_ID="$CMUX_TEST_SURFACE_ID"
_cmux_install_cli_command_shim claude "$CMUX_TEST_WRAPPER_A"
_cmux_install_cli_command_shim claude "$CMUX_TEST_WRAPPER_B"
"""


def _run_driver(tmp: Path) -> subprocess.CompletedProcess[str]:
    wrapper_a = tmp / "wrapper-a"
    wrapper_b = tmp / "wrapper-b"
    wrapper_a.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
    wrapper_b.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
    wrapper_a.chmod(0o755)
    wrapper_b.chmod(0o755)

    env = {key: value for key, value in os.environ.items() if not key.startswith("CMUX")}
    env.update(
        {
            "LC_ALL": "C",
            "LANG": "C",
            "CMUX_BASH_INTEGRATION": str(INTEGRATION),
            "CMUX_TEST_TMPDIR": str(tmp),
            "CMUX_TEST_SURFACE_ID": "issue-9356-shim",
            "CMUX_TEST_WRAPPER_A": str(wrapper_a),
            "CMUX_TEST_WRAPPER_B": str(wrapper_b),
            "CMUX_SOCKET_PATH": "",
            "CMUX_LOAD_GHOSTTY_BASH_INTEGRATION": "0",
            "GHOSTTY_RESOURCES_DIR": "",
        }
    )

    return subprocess.run(
        ["bash", "--norc", "--noprofile", "-c", DRIVER],
        env=env,
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )


def _run_prompt_command_export_regression() -> None:
    """Run the Bash 3.2/newer prompt-export regression on macOS CI."""

    if sys.platform != "darwin":
        return

    system_bash = Path("/bin/bash").resolve()
    newer_candidates = [
        os.environ.get("CMUX_BASH_NEW_BIN"),
        "/opt/homebrew/bin/bash",
        "/usr/local/bin/bash",
        shutil.which("bash"),
    ]

    def find_newer_bash() -> Path | None:
        for raw_candidate in newer_candidates:
            if not raw_candidate:
                continue
            candidate = Path(raw_candidate)
            if candidate.is_file() and os.access(candidate, os.X_OK):
                resolved = candidate.resolve()
                if resolved != system_bash:
                    return resolved
        return None

    newer_bash = find_newer_bash()
    if newer_bash is None and os.environ.get("GITHUB_ACTIONS") == "true":
        brew_environment = dict(os.environ)
        brew_environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        formula = subprocess.run(
            ["brew", "list", "--formula", "bash"],
            env=brew_environment,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
            timeout=30,
        )
        if formula.returncode != 0:
            subprocess.run(
                ["brew", "install", "bash"],
                env=brew_environment,
                check=True,
                timeout=120,
            )
        brew_prefix = subprocess.run(
            ["brew", "--prefix", "bash"],
            env=brew_environment,
            capture_output=True,
            text=True,
            check=True,
            timeout=30,
        ).stdout.strip()
        if brew_prefix:
            newer_candidates.append(str(Path(brew_prefix) / "bin" / "bash"))
        newer_bash = find_newer_bash()

    if newer_bash is None:
        raise RuntimeError(
            "Bash prompt export regression requires /bin/bash 3.2 and a distinct "
            "newer Bash executable"
        )

    regression = REPO_ROOT / "tests" / "test_issue_11257_prompt_command_export.py"
    environment = dict(os.environ)
    environment["CMUX_BASH_32_BIN"] = str(system_bash)
    environment["CMUX_BASH_NEW_BIN"] = str(newer_bash)
    result = subprocess.run(
        [sys.executable, str(regression)],
        env=environment,
        capture_output=True,
        text=True,
        timeout=90,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(
            "Bash PROMPT_COMMAND export regression failed\n"
            f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        )
    if result.stdout:
        print(result.stdout.strip())


def test_bash_shim_refresh_is_silent_and_refreshes_under_noclobber() -> None:
    assert INTEGRATION.exists(), f"missing integration file: {INTEGRATION}"

    with tempfile.TemporaryDirectory(prefix="cmux-9356-") as td:
        tmp = Path(td)
        proc = _run_driver(tmp)
        debug = (
            f"\nexit={proc.returncode}"
            f"\n--- driver stdout ---\n{proc.stdout}"
            f"\n--- driver stderr ---\n{proc.stderr}"
        )

        assert "cannot overwrite existing file" not in proc.stderr.lower(), (
            "cmux printed a noclobber 'cannot overwrite existing file' error while "
            "refreshing its own generated shim" + debug
        )
        # Locale-independent guard: the failing redirect names the shim path.
        assert "cmux-cli-shims" not in proc.stderr, (
            "the shim writer reported an error to stderr while refreshing the shim"
            + debug
        )

        shim_path = tmp / "cmux-cli-shims" / "issue-9356-shim" / "claude"
        assert shim_path.exists(), f"shim was not created at {shim_path}" + debug
        assert os.access(shim_path, os.X_OK), (
            f"shim is not executable: {shim_path}" + debug
        )

        contents = shim_path.read_text(encoding="utf-8")
        wrapper_b = str(tmp / "wrapper-b")
        wrapper_a = str(tmp / "wrapper-a")
        assert f'cmux_wrapper="{wrapper_b}"' in contents, (
            "cmux did not refresh its generated shim on the second write under "
            f"noclobber (expected wrapper {wrapper_b!r}).\n--- shim ---\n{contents}"
            + debug
        )
        assert f'cmux_wrapper="{wrapper_a}"' not in contents, (
            "stale wrapper path from the first write survived the refresh.\n"
            f"--- shim ---\n{contents}" + debug
        )


if __name__ == "__main__":
    test_bash_shim_refresh_is_silent_and_refreshes_under_noclobber()
    _run_prompt_command_export_regression()
    print("PASS: cmux refreshes its bash CLI shim silently under noclobber")
