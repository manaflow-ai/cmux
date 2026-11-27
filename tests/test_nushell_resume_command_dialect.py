#!/usr/bin/env python3
"""
Pin the nushell typed-command envelope against real ``nu``.

cmux resume/relaunch commands are POSIX one-liners executed either by
``"$_cmux_resume_shell" -c '<cmd>'`` (auto-resume startup script,
``Sources/SessionPersistence.swift``) or typed into the user's interactive
shell (sessions panel, session drag-drop, hibernation resume, clipboard):

    cd -- '<dir>' 2>/dev/null || [ ! -d '<dir>' ] && 'claude' '--resume' '<id>'

Every construct in that line is a parse error in nushell: ``&&``, ``||``,
``[ … ]``, ``2>/dev/null``, POSIX quote concatenation, and even a POSIX-quoted
command head (``'claude' 'arg'`` is "expected operator"). Rather than teach
every builder a second dialect, cmux keeps the body POSIX and delegates it
through ``/bin/sh`` at the final typed boundary
(``NushellTypedShellCommand.wrapping(posixCommand:)`` in CMUXAgentLaunch —
the same portable-envelope precedent as issue #5639's ``/bin/sh -c`` wrap and
the ``/bin/zsh <launcher-script>`` startup inputs):

    ^/bin/sh -c "<posix command, \\ and \" escaped>"

This test replicates that envelope (``nu_wrap`` mirrors the Swift
implementation as a golden) and drives it through real ``nu`` with a fake
``claude`` recording argv/cwd/env, asserting:

1. The wrapped legacy resume command runs the agent with argv intact from the
   session's working directory.
2. A missing working directory still launches the agent (the POSIX
   ``|| [ ! -d … ]`` fallback survives the wrap).
3. Quoting edges survive both layers: dirs/args with spaces, single quotes,
   double quotes, and backslashes.
4. Non-ASCII arguments survive via the POSIX ``"$(printf …)"`` substitution
   that cmux emits for them (needs a real sh — exactly why the wrap exists).
5. An ``env K=V`` prefix reaches the agent's environment.
6. The UNwrapped POSIX string is (still) a nushell parse error — the reason
   this envelope exists.

Deterministic: no PTY, no sleeps, no network. Skips loudly without ``nu``
locally; fails when ``CI`` is set so CI can never silently skip.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
from pathlib import Path
from typing import Optional


def _find_nu() -> Optional[str]:
    """Locate a nu binary: CMUX_TEST_NU_BIN override, PATH, then Homebrew paths."""
    override = os.environ.get("CMUX_TEST_NU_BIN")
    candidates = [
        override,
        shutil.which("nu"),
        "/opt/homebrew/bin/nu",
        "/usr/local/bin/nu",
    ]
    for candidate in candidates:
        if candidate and Path(candidate).is_file() and os.access(candidate, os.X_OK):
            return candidate
    return None


def _require_nu() -> Optional[str]:
    """Return a nu path, skip loudly when absent locally, fail when CI is set."""
    nu = _find_nu()
    if nu is None:
        if os.environ.get("CI"):
            raise AssertionError(
                "nushell (nu) is required on CI for this test but was not found; "
                "the CI workflow must install a pinned nushell before running it"
            )
        print("SKIP: nushell (nu) not found; install nushell to run this test")
    return nu


def nu_double_quote(value: str) -> str:
    """Golden mirror of NushellTypedShellCommand.doubleQuoted."""
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def nu_wrap(posix_command: str) -> str:
    """Golden mirror of NushellTypedShellCommand.wrapping(posixCommand:)."""
    return "^/bin/sh -c " + nu_double_quote(posix_command)


def posix_quote(value: str) -> str:
    """POSIX single-quoting as TerminalStartupShellQuoting.singleQuoted."""
    return "'" + value.replace("'", "'\\''") + "'"


def posix_printf_substitution(value: str) -> str:
    """The ASCII printf substitution cmux emits for non-ASCII values."""
    octal = "".join(f"\\{byte:03o}" for byte in value.encode("utf-8"))
    return '"$(printf \'' + octal + "')\""


def legacy_resume_command(workdir: str, argv_tail: str) -> str:
    """The historical POSIX resume one-liner shape for `workdir` + agent argv."""
    quoted = posix_quote(workdir)
    return f"cd -- {quoted} 2>/dev/null || [ ! -d {quoted} ] && {argv_tail}"


def _sandbox(tmp: Path) -> dict:
    """Build an isolated env whose PATH resolves `claude` to an argv/cwd/env recorder."""
    record_dir = tmp / "record"
    record_dir.mkdir()
    bin_dir = tmp / "bin"
    bin_dir.mkdir()
    fake_claude = bin_dir / "claude"
    fake_claude.write_text(
        "#!/bin/sh\n"
        'pwd > "$CMUX_TEST_RECORD_DIR/cwd"\n'
        'printf \'%s\\n\' "$@" > "$CMUX_TEST_RECORD_DIR/args"\n'
        'printf \'%s\\n\' "${CMUX_TEST_MARKER:-}" > "$CMUX_TEST_RECORD_DIR/marker"\n',
        encoding="utf-8",
    )
    fake_claude.chmod(0o755)

    home = tmp / "home"
    home.mkdir()
    env = {key: value for key, value in os.environ.items() if not key.startswith("CMUX")}
    env.update(
        {
            "LC_ALL": "C",
            "LANG": "C",
            "TERM": "xterm-256color",
            "HOME": str(home),
            "XDG_CONFIG_HOME": str(home / ".config"),
            "PATH": os.pathsep.join([str(bin_dir), "/usr/bin", "/bin"]),
            "CMUX_TEST_RECORD_DIR": str(record_dir),
        }
    )
    return {"env": env, "record_dir": record_dir}


def _run_nu_c(nu: str, env: dict, command: str, cwd: Path) -> subprocess.CompletedProcess:
    """Run `command` through plain `nu -c`, matching the auto-resume dispatch and typed input."""
    # Matches the auto-resume dispatch and typed input: plain `nu -c '<cmd>'`.
    return subprocess.run(
        [nu, "-c", command],
        env=env,
        cwd=str(cwd),
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )


def _read(record_dir: Path, name: str) -> str:
    """Read a file the fake agent recorded, failing if the agent never ran."""
    path = record_dir / name
    assert path.exists(), f"agent never wrote {name} (was it launched?)"
    return path.read_text(encoding="utf-8").rstrip("\n")


def _debug(proc: subprocess.CompletedProcess) -> str:
    """Render process (and socket) state for assertion failure messages."""
    return (
        f"\nexit={proc.returncode}"
        f"\n--- nu stdout ---\n{proc.stdout}"
        f"\n--- nu stderr ---\n{proc.stderr}"
    )


SESSION_ID = "01234567-89ab-cdef-0123-456789abcdef"


def test_wrapped_legacy_resume_runs_agent_in_working_directory() -> None:
    nu = _require_nu()
    if nu is None:
        return
    with tempfile.TemporaryDirectory(prefix="cmux-nu-envelope-") as td:
        tmp = Path(td)
        sandbox = _sandbox(tmp)
        workdir = tmp / "project"
        workdir.mkdir()

        posix = legacy_resume_command(
            str(workdir), f"'claude' '--resume' '{SESSION_ID}'"
        )
        proc = _run_nu_c(nu, sandbox["env"], nu_wrap(posix), cwd=tmp)
        assert proc.returncode == 0, "wrapped resume command failed" + _debug(proc)
        assert _read(sandbox["record_dir"], "args") == f"--resume\n{SESSION_ID}", (
            "agent argv corrupted" + _debug(proc)
        )
        recorded_cwd = _read(sandbox["record_dir"], "cwd")
        assert Path(recorded_cwd).resolve() == workdir.resolve(), (
            f"agent ran in {recorded_cwd!r}, expected {workdir}" + _debug(proc)
        )


def test_wrapped_resume_survives_missing_working_directory() -> None:
    nu = _require_nu()
    if nu is None:
        return
    with tempfile.TemporaryDirectory(prefix="cmux-nu-envelope-") as td:
        tmp = Path(td)
        sandbox = _sandbox(tmp)
        missing = tmp / "deleted-project"

        posix = legacy_resume_command(
            str(missing), f"'claude' '--resume' '{SESSION_ID}'"
        )
        proc = _run_nu_c(nu, sandbox["env"], nu_wrap(posix), cwd=tmp)
        assert proc.returncode == 0, (
            "resume must still launch the agent when the saved directory is "
            "gone (POSIX fallback must survive the wrap)" + _debug(proc)
        )
        assert _read(sandbox["record_dir"], "args") == f"--resume\n{SESSION_ID}", (
            "agent argv corrupted for missing-dir resume" + _debug(proc)
        )
        recorded_cwd = _read(sandbox["record_dir"], "cwd")
        assert Path(recorded_cwd).resolve() == tmp.resolve(), (
            f"agent should run from the launch cwd, got {recorded_cwd!r}"
            + _debug(proc)
        )


def test_wrapped_resume_quoting_edges() -> None:
    nu = _require_nu()
    if nu is None:
        return
    with tempfile.TemporaryDirectory(prefix="cmux-nu-envelope-") as td:
        tmp = Path(td)
        sandbox = _sandbox(tmp)
        workdir = tmp / 'dir with "quotes", \'apostrophes\' and spaces'
        workdir.mkdir()

        tricky_arg = 'value with spaces, "double", \'single\' and back\\slash'
        argv_tail = " ".join(
            [
                posix_quote("claude"),
                posix_quote("--resume"),
                posix_quote(SESSION_ID),
                posix_quote("--append-system-prompt"),
                posix_quote(tricky_arg),
            ]
        )
        posix = legacy_resume_command(str(workdir), argv_tail)
        proc = _run_nu_c(nu, sandbox["env"], nu_wrap(posix), cwd=tmp)
        assert proc.returncode == 0, "quoted resume command failed" + _debug(proc)
        assert _read(sandbox["record_dir"], "args") == (
            f"--resume\n{SESSION_ID}\n--append-system-prompt\n{tricky_arg}"
        ), "quoting mangled agent argv" + _debug(proc)
        recorded_cwd = _read(sandbox["record_dir"], "cwd")
        assert Path(recorded_cwd).resolve() == workdir.resolve(), (
            f"agent ran in {recorded_cwd!r}, expected quoted dir {workdir}"
            + _debug(proc)
        )


def test_wrapped_resume_non_ascii_printf_substitution() -> None:
    nu = _require_nu()
    if nu is None:
        return
    with tempfile.TemporaryDirectory(prefix="cmux-nu-envelope-") as td:
        tmp = Path(td)
        sandbox = _sandbox(tmp)

        fancy = "résumé — προφίλ"
        argv_tail = (
            f"'claude' '--resume' '{SESSION_ID}' "
            f"'--append-system-prompt' {posix_printf_substitution(fancy)}"
        )
        proc = _run_nu_c(nu, sandbox["env"], nu_wrap(argv_tail), cwd=tmp)
        assert proc.returncode == 0, (
            "printf-substituted argument failed under the wrap" + _debug(proc)
        )
        assert _read(sandbox["record_dir"], "args") == (
            f"--resume\n{SESSION_ID}\n--append-system-prompt\n{fancy}"
        ), "non-ASCII argument corrupted" + _debug(proc)


def test_wrapped_env_prefix_reaches_agent() -> None:
    nu = _require_nu()
    if nu is None:
        return
    with tempfile.TemporaryDirectory(prefix="cmux-nu-envelope-") as td:
        tmp = Path(td)
        sandbox = _sandbox(tmp)

        posix = (
            f"env {posix_quote('CMUX_TEST_MARKER=hello nu')} "
            f"'claude' '--resume' '{SESSION_ID}'"
        )
        proc = _run_nu_c(nu, sandbox["env"], nu_wrap(posix), cwd=tmp)
        assert proc.returncode == 0, "env-prefixed relaunch failed" + _debug(proc)
        assert _read(sandbox["record_dir"], "marker") == "hello nu", (
            "env prefix did not reach the agent environment" + _debug(proc)
        )


def test_legacy_posix_resume_string_is_a_nushell_parse_error() -> None:
    nu = _require_nu()
    if nu is None:
        return
    with tempfile.TemporaryDirectory(prefix="cmux-nu-envelope-") as td:
        tmp = Path(td)
        sandbox = _sandbox(tmp)
        workdir = tmp / "project"
        workdir.mkdir()

        legacy = legacy_resume_command(
            str(workdir), f"'claude' '--resume' '{SESSION_ID}'"
        )
        proc = _run_nu_c(nu, sandbox["env"], legacy, cwd=tmp)
        assert proc.returncode != 0, (
            "expected the unwrapped POSIX resume string to fail under nushell; "
            "if nushell learned POSIX and-or lists, revisit the envelope"
            + _debug(proc)
        )
        assert not (sandbox["record_dir"] / "args").exists(), (
            "the agent must not launch off the unwrapped POSIX string under "
            "nushell" + _debug(proc)
        )


if __name__ == "__main__":
    test_wrapped_legacy_resume_runs_agent_in_working_directory()
    test_wrapped_resume_survives_missing_working_directory()
    test_wrapped_resume_quoting_edges()
    test_wrapped_resume_non_ascii_printf_substitution()
    test_wrapped_env_prefix_reaches_agent()
    test_legacy_posix_resume_string_is_a_nushell_parse_error()
    if _find_nu() is None:
        print("SKIP: nushell (nu) not found; nothing was verified")
    else:
        print("PASS: nushell typed-command envelope semantics hold on real nu")
