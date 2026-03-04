#!/usr/bin/env python3
"""Static regression guard for browser console/errors CLI output formatting.

Ensures non-JSON `browser console list` and `browser errors list` do not fall
back to unconditional `OK` when logs exist.
"""

from __future__ import annotations

import subprocess
from pathlib import Path


def repo_root() -> Path:
    result = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        capture_output=True,
        text=True,
    )
    if result.returncode == 0:
        return Path(result.stdout.strip())
    return Path(__file__).resolve().parents[1]


def extract_block(source: str, signature: str) -> str:
    start = source.find(signature)
    if start < 0:
        raise ValueError(f"Missing signature: {signature}")
    brace_start = source.find("{", start)
    if brace_start < 0:
        raise ValueError(f"Missing opening brace for: {signature}")
    depth = 0
    for idx in range(brace_start, len(source)):
        char = source[idx]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return source[brace_start : idx + 1]
    raise ValueError(f"Unbalanced braces for: {signature}")


def main() -> int:
    root = repo_root()
    failures: list[str] = []

    cli_path = root / "CLI" / "cmux.swift"
    cli_source = cli_path.read_text(encoding="utf-8")
    browser_block = extract_block(cli_source, "private func runBrowserCommand(")

    if "func displayBrowserLogItems(_ value: Any?) -> String?" not in browser_block:
        failures.append("runBrowserCommand() is missing displayBrowserLogItems() helper")
    else:
        helper_block = extract_block(browser_block, "func displayBrowserLogItems(_ value: Any?) -> String?")
        if "return \"[\\(level)] \\(text)\"" not in helper_block:
            failures.append("displayBrowserLogItems() no longer renders level-prefixed log lines")
        if "return \"[error] \\(message)\"" not in helper_block:
            failures.append("displayBrowserLogItems() no longer renders concise JS error messages")
        if "return displayBrowserValue(dict)" not in helper_block:
            failures.append("displayBrowserLogItems() no longer falls back to structured formatting")

    console_block = extract_block(browser_block, 'if subcommand == "console"')
    if 'displayBrowserLogItems(payload["entries"])' not in console_block:
        failures.append("browser console path no longer formats entries for non-JSON output")
    if 'output(payload, fallback: "OK")' in console_block:
        failures.append("browser console path regressed to unconditional OK output")

    errors_block = extract_block(browser_block, 'if subcommand == "errors"')
    if 'displayBrowserLogItems(payload["errors"])' not in errors_block:
        failures.append("browser errors path no longer formats errors for non-JSON output")
    if 'output(payload, fallback: "OK")' in errors_block:
        failures.append("browser errors path regressed to unconditional OK output")

    if failures:
        print("FAIL: browser console/errors CLI output regression guard failed")
        for item in failures:
            print(f" - {item}")
        return 1

    print("PASS: browser console/errors CLI output regression guard is in place")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
