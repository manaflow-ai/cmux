#!/usr/bin/env python3
"""
Regression coverage for https://github.com/manaflow-ai/cmux/issues/11257.

cmux injects ``cmux-bash-bootstrap.bash`` as an environment-backed
``PROMPT_COMMAND``.  Ghostty's bash-preexec integration and cmux's own
integration then replace that value with names of shell functions.  Bash keeps
the export attribute across those assignments, so a child bash that does not
load cmux's integration tries to run functions that do not exist.

This test runs the real bootstrap and both real integrations in an interactive
shell, verifies the first shell still has cmux's prompt hook without the export
attribute, and starts a nested interactive bash from that shell.  The nested
shell is started with no profile/rc files so any ``command not found`` output
can only come from an inherited ``PROMPT_COMMAND``.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import tempfile
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
BOOTSTRAP = REPO_ROOT / "Resources" / "shell-integration" / "cmux-bash-bootstrap.bash"
INTEGRATION_DIR = REPO_ROOT / "Resources" / "shell-integration"
GHOSTTY_RESOURCES_DIR = REPO_ROOT / "ghostty" / "src"


def _lean_bootstrap(text: str) -> str:
    """Mirror the app's removal of comments before environment injection."""

    return "\n".join(
        line
        for line in text.splitlines()
        if line.strip() and not line.strip().startswith("#")
    )


# The loop models Bash's prompt evaluation closely enough to cover the delayed
# bash-preexec install used by Bash 3.2 as well as the PROMPT_COMMAND array used
# by newer Bash versions.  Long options precede ``-li`` because Bash 3.2 treats
# ``bash -li --norc`` as an invalid option sequence; this is the same nested
# login/interactive/no-startup-files shell requested by the issue repro.
DRIVER = r"""
set +e

_cmux_test_run_prompt_commands() {
    if [[ "$(declare -p PROMPT_COMMAND 2>/dev/null)" == "declare -a"* ]]; then
        local command
        for command in "${PROMPT_COMMAND[@]}"; do
            eval "$command"
        done
    else
        eval "${PROMPT_COMMAND:-:}"
    fi
}

# Depending on whether Bash evaluates PROMPT_COMMAND before a -c command, one
# or more of these cycles executes the injected bootstrap. Three covers both
# that startup behavior and bash-preexec's delayed first-prompt installation.
for _cmux_test_cycle in 1 2 3; do
    _cmux_test_run_prompt_commands
done

_cmux_test_decl="$(declare -p PROMPT_COMMAND 2>/dev/null || true)"
_cmux_test_decl="${_cmux_test_decl//$'\n'/<NL>}"
printf '__CMUX_DECL_BEGIN__%s__CMUX_DECL_END__\n' "$_cmux_test_decl"

_cmux_test_child="$(printf 'exit\n' | "$CMUX_BASH_BIN" --noprofile --norc -li 2>&1)"
printf '__CMUX_CHILD_BEGIN__\n%s\n__CMUX_CHILD_END__\n' "$_cmux_test_child"
"""


_BASH_VERSION_RE = re.compile(r"\bversion\s+(\d+)\.(\d+)(?:\.(\d+))?")


def _bash_version(bash_bin: Path) -> tuple[int, int, int]:
    """Return the executable's Bash major, minor, and patch version."""

    result = subprocess.run(
        [str(bash_bin), "--version"],
        capture_output=True,
        text=True,
        timeout=8,
        check=False,
    )
    match = _BASH_VERSION_RE.search((result.stdout or "") + (result.stderr or ""))
    if result.returncode != 0 or match is None:
        raise AssertionError(
            f"could not determine Bash version for {bash_bin}: "
            f"exit={result.returncode}\n{result.stdout}\n{result.stderr}"
        )
    return tuple(int(part or 0) for part in match.groups())


def _bash_candidates() -> list[tuple[str, Path, tuple[int, int, int]]]:
    """Resolve and validate one system Bash 3.2 and one newer Bash binary.

    CI supplies explicit paths so a Linux runner cannot accidentally exercise
    only its one modern Bash. Local macOS runs discover the same pair from the
    system path and common Homebrew locations.
    """

    configured_legacy = os.environ.get("CMUX_BASH_32_BIN")
    configured_modern = os.environ.get("CMUX_BASH_NEW_BIN")
    if (configured_legacy is None) != (configured_modern is None):
        raise AssertionError(
            "CMUX_BASH_32_BIN and CMUX_BASH_NEW_BIN must be provided together"
        )

    if configured_legacy is not None and configured_modern is not None:
        raw_candidates = [
            ("Bash 3.2", Path(configured_legacy)),
            ("newer Bash", Path(configured_modern)),
        ]
    else:
        raw_candidates = [("discovered", Path("/bin/bash"))]
        for candidate in (
            shutil.which("bash"),
            "/opt/homebrew/bin/bash",
            "/usr/local/bin/bash",
        ):
            if candidate:
                raw_candidates.append(("discovered", Path(candidate)))

    candidates: list[tuple[str, Path, tuple[int, int, int]]] = []
    seen: set[Path] = set()
    for label, candidate in raw_candidates:
        if not candidate.is_file() or not os.access(candidate, os.X_OK):
            continue
        resolved = candidate.resolve()
        if resolved in seen:
            if configured_legacy is not None:
                raise AssertionError(
                    "Bash 3.2 and newer Bash paths resolve to the same executable: "
                    f"{resolved}"
                )
            continue
        seen.add(resolved)
        candidates.append((label, resolved, _bash_version(resolved)))

    legacy = [entry for entry in candidates if entry[2][:2] == (3, 2)]
    modern = [entry for entry in candidates if entry[2][:2] > (3, 2)]
    if not legacy or not modern:
        versions = ", ".join(
            f"{path} ({version[0]}.{version[1]}.{version[2]})"
            for _, path, version in candidates
        ) or "none"
        if configured_legacy is None and os.environ.get("GITHUB_ACTIONS") != "true":
            return []
        raise AssertionError(
            "the regression requires distinct Bash 3.2 and newer Bash executables; "
            f"found {versions}. Set CMUX_BASH_32_BIN and CMUX_BASH_NEW_BIN explicitly."
        )

    return [
        ("Bash 3.2", legacy[0][1], legacy[0][2]),
        ("newer Bash", modern[-1][1], modern[-1][2]),
    ]


def _run_driver(bash_bin: Path) -> subprocess.CompletedProcess[str]:
    """Run the bootstrap and nested-shell scenario with an isolated home."""

    env = {
        key: value
        for key, value in os.environ.items()
        if not key.startswith("CMUX")
        and key
        not in {
            "PROMPT_COMMAND",
            "GHOSTTY_RESOURCES_DIR",
            "GHOSTTY_SHELL_FEATURES",
            "GHOSTTY_BASH_INJECT",
        }
    }
    with tempfile.TemporaryDirectory(prefix="cmux-11257-") as home:
        env.update(
            {
                "HOME": home,
                "PATH": os.environ.get("PATH", ""),
                # Bash localizes diagnostics; pin English so the child-shell
                # command-not-found assertion is meaningful on every runner.
                "LANG": "C",
                "LC_ALL": "C",
                "TERM": "xterm-256color",
                "TERM_PROGRAM": "ghostty",
                # This is exactly the value TerminalSurface+StartupEnvironment
                # puts in the child environment after stripping comments.
                "PROMPT_COMMAND": _lean_bootstrap(
                    BOOTSTRAP.read_text(encoding="utf-8")
                ),
                "CMUX_SHELL_INTEGRATION": "1",
                "CMUX_SHELL_INTEGRATION_DIR": str(INTEGRATION_DIR),
                "CMUX_LOAD_GHOSTTY_BASH_INTEGRATION": "1",
                "GHOSTTY_RESOURCES_DIR": str(GHOSTTY_RESOURCES_DIR),
                "CMUX_TAB_ID": "tab-test",
                "CMUX_PANEL_ID": "panel-test",
                # Avoid socket, git, and port side effects; prompt function
                # installation itself remains active.
                "CMUX_SOCKET_PATH": "",
                "CMUX_NO_GIT_WATCH": "1",
                "CMUX_NO_PORTS": "1",
                "CMUX_BASH_BIN": str(bash_bin),
            }
        )
        return subprocess.run(
            [str(bash_bin), "--noprofile", "--norc", "-i", "-c", DRIVER],
            env=env,
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )


def _between(text: str, start: str, end: str) -> str:
    """Extract the text between two deterministic output markers."""

    try:
        return text.split(start, 1)[1].split(end, 1)[0]
    except IndexError as exc:
        raise AssertionError(
            f"missing output markers {start!r}/{end!r}\noutput:\n{text}"
        ) from exc


def test_prompt_command_is_not_exported_to_nested_bash() -> None:
    """Verify the bootstrap stays functional without exporting prompt hooks."""

    assert BOOTSTRAP.exists(), f"missing bootstrap file: {BOOTSTRAP}"
    assert (INTEGRATION_DIR / "cmux-bash-integration.bash").exists()
    assert (GHOSTTY_RESOURCES_DIR / "shell-integration" / "bash" / "ghostty.bash").exists()

    bash_bins = _bash_candidates()
    if not bash_bins:
        print("SKIP: Bash 3.2 and newer Bash are unavailable outside CI")
        return

    for label, bash_bin, version in bash_bins:
        proc = _run_driver(bash_bin)
        debug = (
            f"\n\n--- bash ---\n{label}: {bash_bin} ({version[0]}.{version[1]}.{version[2]})"
            f"\n--- exit ---\n{proc.returncode}"
            f"\n--- stdout ---\n{proc.stdout}"
            f"\n--- stderr ---\n{proc.stderr}"
        )
        assert proc.returncode == 0, "bootstrap driver exited non-zero" + debug

        declaration = _between(
            proc.stdout,
            "__CMUX_DECL_BEGIN__",
            "__CMUX_DECL_END__",
        )
        exported_declaration = re.match(
            r"^declare -[A-Za-z]*x[A-Za-z]*\s+PROMPT_COMMAND(?:=|\s|$)",
            declaration,
        )
        assert exported_declaration is None, (
            "PROMPT_COMMAND remained exported after the bootstrap; the first "
            f"shell would leak its function names to children: {declaration!r}"
            + debug
        )
        assert "_cmux_prompt_command" in declaration, (
            "cmux prompt integration was not installed in the first shell: "
            f"{declaration!r}" + debug
        )

        child_output = _between(
            proc.stdout,
            "__CMUX_CHILD_BEGIN__\n",
            "\n__CMUX_CHILD_END__",
        )
        assert "command not found" not in child_output.lower(), (
            "nested bash inherited function names through PROMPT_COMMAND and "
            "printed command-not-found noise" + debug
        )


if __name__ == "__main__":
    test_prompt_command_is_not_exported_to_nested_bash()
    print("PASS: PROMPT_COMMAND is private to the cmux bash shell")
