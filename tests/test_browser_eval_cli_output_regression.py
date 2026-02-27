#!/usr/bin/env python3
"""Static regression guard for browser eval CLI output formatting.

Ensures `cmux browser <surface> eval <script>` prints the evaluated value
instead of always printing `OK`.
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

    if "func displayBrowserValue(_ value: Any) -> String" not in browser_block:
        failures.append("runBrowserCommand() is missing displayBrowserValue() helper")
    else:
        value_block = extract_block(browser_block, "func displayBrowserValue(_ value: Any) -> String")
        if 'dict["__cmux_t"] as? String' not in value_block or 'type == "undefined"' not in value_block:
            failures.append("displayBrowserValue() no longer maps __cmux_t=undefined to literal 'undefined'")
        required_guards = [
            "if value is NSNull",
            "if let string = value as? String",
            "if let bool = value as? Bool",
            "if let number = value as? NSNumber",
        ]
        for guard in required_guards:
            if guard not in value_block:
                failures.append(f"displayBrowserValue() no longer handles: {guard}")

    eval_block = extract_block(browser_block, 'if subcommand == "eval"')
    if 'let payload = try client.sendV2(method: "browser.eval"' not in eval_block:
        failures.append("browser eval path no longer calls browser.eval v2 method")
    if 'if let value = payload["value"]' not in eval_block:
        failures.append("browser eval path no longer reads payload value")
    if "fallback = displayBrowserValue(value)" not in eval_block:
        failures.append("browser eval path no longer formats payload value for CLI output")
    if 'output(payload, fallback: "OK")' in eval_block:
        failures.append("browser eval path regressed to unconditional OK output")

    if failures:
        print("FAIL: browser eval CLI output regression guard failed")
        for item in failures:
            print(f" - {item}")
        return 1

    print("PASS: browser eval CLI output regression guard is in place")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
