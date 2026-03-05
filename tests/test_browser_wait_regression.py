#!/usr/bin/env python3
"""Static regression guards for browser wait/snapshot reliability."""

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

    terminal_source = (root / "Sources" / "TerminalController.swift").read_text(encoding="utf-8")
    cli_source = (root / "CLI" / "cmux.swift").read_text(encoding="utf-8")

    wait_block = extract_block(terminal_source, "private func v2BrowserWait(params: [String: Any]) -> V2CallResult")
    if 'normalizedLoadState == "interactive"' not in wait_block:
        failures.append("browser wait no longer normalizes load_state interactive handling")
    if "__state === 'interactive' || __state === 'complete'" not in wait_block:
        failures.append("browser wait interactive load state no longer treats complete as satisfied")
    if 'code: "js_error"' not in wait_block:
        failures.append("browser wait no longer fails fast with js_error on script failures")

    run_js_block = extract_block(terminal_source, "private func v2RunJavaScript(")
    if "contentWorld: WKContentWorld" not in terminal_source:
        failures.append("v2RunJavaScript no longer accepts a configurable WKContentWorld")
    if "DispatchQueue.main.async(execute: evaluator)" not in run_js_block:
        failures.append("v2RunJavaScript no longer dispatches evaluation to main thread from background callers")
    if "completionSignal.wait(timeout:" not in run_js_block:
        failures.append("v2RunJavaScript no longer waits on completion semaphore for background calls")

    run_browser_js_block = extract_block(terminal_source, "private func v2RunBrowserJavaScript(")
    if "contentWorld: .defaultClient" not in run_browser_js_block:
        failures.append("v2RunBrowserJavaScript no longer retries non-eval scripts in isolated content world")

    if "browser screenshot [--out <path>]" not in cli_source:
        failures.append("top-level CLI help no longer documents browser screenshot")

    if failures:
        print("FAIL: browser wait regression guard failed")
        for item in failures:
            print(f" - {item}")
        return 1

    print("PASS: browser wait regression guard is in place")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
