#!/usr/bin/env python3
"""Regression: tmux-compat ``show-options`` returns safe defaults instead of erroring.

Background: GitHub issue #3239 reports that ``cmux omx`` startup fails because
Codex v0.125.0 probes::

    tmux show-options -sv extended-keys

and any variation that lands at ``cmux __tmux-compat show-options ...`` for an
option other than ``extended-keys`` would throw
``Error: Unsupported tmux compatibility command: show-options``. Real tmux is
tolerant of unset options when ``-q`` is set and returns a default for known
options, so the cmux compat shim should match that to keep external tools
working.

These tests exercise the handler directly via the CLI. They follow the
``tests_v2`` runner contract (a tagged ``cmux DEV`` instance is launched and
``CMUX_SOCKET_PATH`` is set by ``scripts/run-tests-v2.sh``). The show-options
handler does not touch the v2 socket API, but the dispatcher resolves the
socket before reaching the handler, so the test still requires a running
instance.
"""

import glob
import os
import subprocess
import sys
from pathlib import Path
from typing import List, Optional

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET_PATH", "/tmp/cmux-debug.sock")


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _find_cli_binary() -> str:
    env_cli = os.environ.get("CMUXTERM_CLI")
    if env_cli and os.path.isfile(env_cli) and os.access(env_cli, os.X_OK):
        return env_cli

    candidates = glob.glob(os.path.expanduser(
        "~/Library/Developer/Xcode/DerivedData/**/Build/Products/Debug/cmux"
    ), recursive=True)
    candidates += glob.glob("/tmp/cmux-*/Build/Products/Debug/cmux")
    candidates = [p for p in candidates if os.path.isfile(p) and os.access(p, os.X_OK)]
    if not candidates:
        raise cmuxError("Could not locate cmux CLI binary; set CMUXTERM_CLI")
    candidates.sort(key=lambda p: os.path.getmtime(p), reverse=True)
    return candidates[0]


def _run_tmux_compat(cli: str, args: List[str]) -> subprocess.CompletedProcess:
    env = dict(os.environ)
    env.pop("CMUX_WORKSPACE_ID", None)
    env.pop("CMUX_SURFACE_ID", None)
    env["CMUX_SOCKET_PATH"] = SOCKET_PATH
    cmd = [cli, "--socket", SOCKET_PATH, "__tmux-compat"] + args
    return subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        check=False,
        env=env,
        timeout=10,
    )


def _expect_value(
    cli: str,
    args: List[str],
    expected_stdout: Optional[str],
    *,
    label: str,
) -> None:
    proc = _run_tmux_compat(cli, args)
    _must(
        proc.returncode == 0,
        f"{label}: expected exit 0, got {proc.returncode}\n"
        f"  args: {args}\n  stdout: {proc.stdout!r}\n  stderr: {proc.stderr!r}",
    )
    if expected_stdout is not None:
        actual = proc.stdout.rstrip("\n")
        _must(
            actual == expected_stdout,
            f"{label}: expected stdout {expected_stdout!r}, got {actual!r}\n"
            f"  args: {args}\n  full stdout: {proc.stdout!r}\n  stderr: {proc.stderr!r}",
        )


def test_extended_keys_value_only(cli: str) -> None:
    """Regression for the original bug repro: ``show-options -sv extended-keys``.

    This already worked before the fix (it was the only supported option), but
    locks in the behavior so the safe-default refactor doesn't regress it.
    """
    print("  test_extended_keys_value_only ... ", end="", flush=True)
    _expect_value(cli, ["show-options", "-sv", "extended-keys"], "on", label="extended-keys -sv")
    print("PASS")


def test_extended_keys_full_form(cli: str) -> None:
    print("  test_extended_keys_full_form ... ", end="", flush=True)
    _expect_value(cli, ["show-options", "extended-keys"], "extended-keys on", label="extended-keys (no -v)")
    print("PASS")


def test_default_terminal_value_only(cli: str) -> None:
    """``show-options -sv default-terminal`` returns a tmux-compatible value.

    Pre-fix this throws ``Unsupported tmux compatibility command: show-options
    default-terminal`` and exits non-zero.
    """
    print("  test_default_terminal_value_only ... ", end="", flush=True)
    _expect_value(
        cli, ["show-options", "-sv", "default-terminal"], "tmux-256color",
        label="default-terminal -sv",
    )
    print("PASS")


def test_extended_keys_format_value_only(cli: str) -> None:
    """``extended-keys-format`` is the second probe Codex/the issue mentions.

    Real tmux's default is ``csi-u``. Pre-fix this throws.
    """
    print("  test_extended_keys_format_value_only ... ", end="", flush=True)
    _expect_value(
        cli, ["show-options", "-sv", "extended-keys-format"], "csi-u",
        label="extended-keys-format -sv",
    )
    print("PASS")


def test_status_off_value_only(cli: str) -> None:
    """``status`` defaults to ``off`` in our shim (cmux has no tmux status line)."""
    print("  test_status_off_value_only ... ", end="", flush=True)
    _expect_value(cli, ["show-options", "-sv", "status"], "off", label="status -sv")
    print("PASS")


def test_unknown_option_returns_empty(cli: str) -> None:
    """Unknown options must return empty + exit 0, never throw.

    Real tmux returns empty for unset options under ``-q``; tools that probe
    expect non-failure. Pre-fix this throws ``Unsupported tmux compatibility
    command: show-options some-future-option``.

    The assertion is exact (``proc.stdout == ""``, not ``.strip()``) so a
    regression that prints a stray blank line is caught.
    """
    print("  test_unknown_option_returns_empty ... ", end="", flush=True)
    proc = _run_tmux_compat(cli, ["show-options", "-sv", "some-future-option"])
    _must(
        proc.returncode == 0,
        f"unknown-option -sv: expected exit 0, got {proc.returncode}\n"
        f"  stdout: {proc.stdout!r}\n  stderr: {proc.stderr!r}",
    )
    _must(
        proc.stdout == "",
        f"unknown-option -sv: expected empty stdout, got {proc.stdout!r}",
    )
    _must(
        "Unsupported tmux compatibility command" not in proc.stderr,
        f"unknown-option -sv: stderr should not say Unsupported, got {proc.stderr!r}",
    )
    print("PASS")


def test_unknown_option_no_v_prints_nothing(cli: str) -> None:
    """Unknown option without ``-v`` must also print nothing (no trailing space).

    Locks in the contract caught in code review: a previous draft printed
    ``"<name> "`` (key + space + newline) for unknown options because the
    fallback emitted ``defaults[name] ?? ""`` unconditionally. Real tmux ``-q``
    prints nothing for unknown options regardless of ``-v``.
    """
    print("  test_unknown_option_no_v_prints_nothing ... ", end="", flush=True)
    proc = _run_tmux_compat(cli, ["show-options", "some-future-option"])
    _must(
        proc.returncode == 0,
        f"unknown-option no -v: expected exit 0, got {proc.returncode}\n"
        f"  stdout: {proc.stdout!r}\n  stderr: {proc.stderr!r}",
    )
    _must(
        proc.stdout == "",
        f"unknown-option no -v: expected empty stdout, got {proc.stdout!r}",
    )
    print("PASS")


def test_show_alias_works(cli: str) -> None:
    print("  test_show_alias_works ... ", end="", flush=True)
    _expect_value(cli, ["show", "-sv", "extended-keys"], "on", label="show alias")
    _expect_value(cli, ["show-option", "-sv", "extended-keys"], "on", label="show-option alias")
    print("PASS")


def test_global_flag_does_not_break(cli: str) -> None:
    print("  test_global_flag_does_not_break ... ", end="", flush=True)
    _expect_value(
        cli, ["show-options", "-gv", "default-terminal"], "tmux-256color",
        label="default-terminal -gv",
    )
    print("PASS")


def test_issue_3239_exact_repro(cli: str) -> None:
    """Locks in the exact command from issue #3239.

    Issue body, "Steps to reproduce" section 4 and "Direct command output":
        $ cmux __tmux-compat show-options -sv extended-keys
        Error: Unsupported tmux compatibility command: show-options

    After the fix, the same invocation must exit 0 and print ``on``.
    """
    print("  test_issue_3239_exact_repro ... ", end="", flush=True)
    proc = _run_tmux_compat(cli, ["show-options", "-sv", "extended-keys"])
    _must(
        proc.returncode == 0,
        f"issue #3239 repro: expected exit 0, got {proc.returncode}\n"
        f"  stdout: {proc.stdout!r}\n  stderr: {proc.stderr!r}",
    )
    _must(
        "Unsupported tmux compatibility command" not in proc.stdout
        and "Unsupported tmux compatibility command" not in proc.stderr,
        f"issue #3239 repro: must not print Unsupported error\n"
        f"  stdout: {proc.stdout!r}\n  stderr: {proc.stderr!r}",
    )
    _must(
        proc.stdout.rstrip("\n") == "on",
        f"issue #3239 repro: stdout should be 'on', got {proc.stdout!r}",
    )
    print("PASS")


def main() -> int:
    cli = _find_cli_binary()
    print(f"Using CLI: {cli}")
    print(f"Socket: {SOCKET_PATH}")

    passed = 0
    failed = 0
    errors: List = []

    # Connect to assert the cmux instance is up before issuing CLI probes.
    # The handler under test does not touch the v2 socket API, but the
    # ``__tmux-compat`` dispatcher resolves the socket first.
    with cmux(SOCKET_PATH):
        tests = [
            ("test_extended_keys_value_only", lambda: test_extended_keys_value_only(cli)),
            ("test_extended_keys_full_form", lambda: test_extended_keys_full_form(cli)),
            ("test_default_terminal_value_only", lambda: test_default_terminal_value_only(cli)),
            ("test_extended_keys_format_value_only", lambda: test_extended_keys_format_value_only(cli)),
            ("test_status_off_value_only", lambda: test_status_off_value_only(cli)),
            ("test_unknown_option_returns_empty", lambda: test_unknown_option_returns_empty(cli)),
            ("test_unknown_option_no_v_prints_nothing", lambda: test_unknown_option_no_v_prints_nothing(cli)),
            ("test_show_alias_works", lambda: test_show_alias_works(cli)),
            ("test_global_flag_does_not_break", lambda: test_global_flag_does_not_break(cli)),
            ("test_issue_3239_exact_repro", lambda: test_issue_3239_exact_repro(cli)),
        ]

        for name, test_fn in tests:
            try:
                test_fn()
                passed += 1
            except Exception as e:
                failed += 1
                errors.append((name, str(e)))
                print(f"FAIL: {e}")

    print(f"\n{'=' * 60}")
    print(f"Results: {passed} passed, {failed} failed, {passed + failed} total")
    if errors:
        print("\nFailures:")
        for name, err in errors:
            print(f"  {name}: {err}")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
