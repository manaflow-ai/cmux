#!/usr/bin/env python3
"""
Regression guard for issue #1565.

The shipped bash integration must keep cmux fire-and-forget async jobs in the
backgrounded subshell form rather than reintroducing brace-group + disown
launches for the known prompt-time call sites.
"""

from __future__ import annotations

import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
INTEGRATION_PATH = ROOT / "Resources" / "shell-integration" / "cmux-bash-integration.bash"

EXPECTED_ASYNC_SUBSHELL_COUNTS = {
    "_cmux_relay_rpc_bg": 1,
    "_cmux_report_tty_once": 1,
    "_cmux_report_shell_activity_state": 1,
    "_cmux_ports_kick": 1,
    "_cmux_emit_pr_command_hint": 1,
    "_cmux_start_pr_poll_loop": 1,
    "_cmux_prompt_command": 2,
}

ASYNC_BRACE_GROUP_RE = re.compile(r"^\s*}\s*>/dev/null 2>&1 &(?:\s*disown)?\s*$", re.MULTILINE)
ASYNC_SUBSHELL_RE = re.compile(r"^\s*\)\s*>/dev/null 2>&1 &\s*$", re.MULTILINE)
FUNCTION_BODY_RE_TEMPLATE = r"^{name}\(\) \{{\n(?P<body>.*?)^}}"


def extract_function_body(script_text: str, function_name: str) -> str:
    pattern = re.compile(
        FUNCTION_BODY_RE_TEMPLATE.format(name=re.escape(function_name)),
        re.MULTILINE | re.DOTALL,
    )
    match = pattern.search(script_text)
    if match is None:
        raise AssertionError(f"missing function definition for {function_name}")
    return match.group("body")


def main() -> int:
    script_text = INTEGRATION_PATH.read_text(encoding="utf-8")
    failures: list[str] = []

    if "& disown" in script_text:
        failures.append("cmux-bash-integration.bash still contains '& disown'")

    for function_name, expected_count in EXPECTED_ASYNC_SUBSHELL_COUNTS.items():
        body = extract_function_body(script_text, function_name)
        brace_group_hits = len(ASYNC_BRACE_GROUP_RE.findall(body))
        if brace_group_hits:
            failures.append(
                f"{function_name}: found {brace_group_hits} brace-group async launch(es)"
            )

        if "disown" in body:
            failures.append(f"{function_name}: unexpected disown remains in function body")

        subshell_hits = len(ASYNC_SUBSHELL_RE.findall(body))
        if subshell_hits != expected_count:
            failures.append(
                f"{function_name}: expected {expected_count} async subshell launch(es), found {subshell_hits}"
            )

    if failures:
        print("FAIL:")
        for failure in failures:
            print(failure)
        return 1

    print("PASS: bash integration async cmux jobs use backgrounded subshells without disown")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
