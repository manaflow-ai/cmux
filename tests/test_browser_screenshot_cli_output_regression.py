#!/usr/bin/env python3
"""Static regression guard for browser screenshot CLI output.

Ensures `cmux browser <surface> screenshot` returns an accessible image URL/path
instead of bare `OK`, and keeps a local `--json` escape hatch for subcommand
positioned flags.
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

    cli_source = (root / "CLI" / "cmux.swift").read_text(encoding="utf-8")
    browser_block = extract_block(cli_source, "private func runBrowserCommand(")
    screenshot_block = extract_block(browser_block, 'if subcommand == "screenshot"')

    if 'let localJSONOutput = hasFlag(subArgs, name: "--json")' not in screenshot_block:
        failures.append("browser screenshot no longer supports local --json flag parsing")
    if "let outputAsJSON = jsonOutput || localJSONOutput" not in screenshot_block:
        failures.append("browser screenshot no longer merges global/local json output flags")
    if 'payload["url"] = screenshotURL' not in screenshot_block:
        failures.append("browser screenshot no longer attaches url to payload")
    if 'print("OK \\(screenshotURL)")' not in screenshot_block:
        failures.append("browser screenshot no longer prints image URL in non-JSON mode")

    controller_source = (root / "Sources" / "TerminalController.swift").read_text(encoding="utf-8")
    v2_screenshot_block = extract_block(controller_source, "private func v2BrowserScreenshot(params: [String: Any]) -> V2CallResult")

    if 'result["path"] = imageURL.path' not in v2_screenshot_block:
        failures.append("browser.screenshot v2 response no longer includes screenshot path")
    if 'result["url"] = imageURL.absoluteString' not in v2_screenshot_block:
        failures.append("browser.screenshot v2 response no longer includes screenshot URL")

    if failures:
        print("FAIL: browser screenshot CLI output regression guard failed")
        for item in failures:
            print(f" - {item}")
        return 1

    print("PASS: browser screenshot CLI output regression guard is in place")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
