#!/usr/bin/env python3
"""Static regression guard for browser eval async wrapping + telemetry injection."""

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


def extract_span(source: str, start_marker: str, end_marker: str) -> str:
    start = source.find(start_marker)
    if start < 0:
        raise ValueError(f"Missing start marker: {start_marker}")
    end = source.find(end_marker, start)
    if end < 0:
        raise ValueError(f"Missing end marker: {end_marker}")
    return source[start:end]


def main() -> int:
    root = repo_root()
    failures: list[str] = []

    terminal_path = root / "Sources" / "TerminalController.swift"
    panel_path = root / "Sources" / "Panels" / "BrowserPanel.swift"
    terminal_source = terminal_path.read_text(encoding="utf-8")
    panel_source = panel_path.read_text(encoding="utf-8")

    if "preferAsync: Bool = false" not in terminal_source:
        failures.append("v2RunJavaScript() no longer exposes preferAsync toggle")
    run_js_block = extract_block(terminal_source, "private func v2RunJavaScript(")
    if "callAsyncJavaScript" not in run_js_block:
        failures.append("v2RunJavaScript() no longer uses callAsyncJavaScript for async JS")

    run_browser_js_block = extract_block(terminal_source, "private func v2RunBrowserJavaScript(")
    required_wrapper_tokens = [
        "let asyncFunctionBody =",
        "__cmuxMaybeAwait",
        "__cmux_t",
        "__cmux_v",
        "return await __cmuxEvalInFrame();",
        "preferAsync: true",
    ]
    for token in required_wrapper_tokens:
        if token not in run_browser_js_block:
            failures.append(f"v2RunBrowserJavaScript() missing async eval wrapper token: {token}")

    if "v2BrowserUndefinedSentinel" not in terminal_source:
        failures.append("TerminalController is missing undefined sentinel handling")
    if "v2BrowserEvalEnvelopeTypeUndefined" not in terminal_source:
        failures.append("TerminalController is missing undefined envelope decode constant")

    hook_block = extract_block(terminal_source, "private func v2BrowserEnsureTelemetryHooks(")
    if "BrowserPanel.telemetryHookBootstrapScriptSource" not in hook_block:
        failures.append("v2BrowserEnsureTelemetryHooks() no longer uses shared BrowserPanel telemetry source")

    if "static let telemetryHookBootstrapScriptSource" not in panel_source:
        failures.append("BrowserPanel is missing telemetryHookBootstrapScriptSource")
    if "static let dialogTelemetryHookBootstrapScriptSource" not in panel_source:
        failures.append("BrowserPanel is missing dialogTelemetryHookBootstrapScriptSource")

    base_script_span = extract_span(
        panel_source,
        "static let telemetryHookBootstrapScriptSource =",
        "static let dialogTelemetryHookBootstrapScriptSource =",
    )
    if "window.alert = function(message)" in base_script_span:
        failures.append("Document-start telemetry script should not override alert dialogs")
    if "window.confirm = function(message)" in base_script_span:
        failures.append("Document-start telemetry script should not override confirm dialogs")
    if "window.prompt = function(message, defaultValue)" in base_script_span:
        failures.append("Document-start telemetry script should not override prompt dialogs")

    panel_init_block = extract_block(
        panel_source,
        "init(workspaceId: UUID, initialURL: URL? = nil, bypassInsecureHTTPHostOnce: String? = nil)",
    )
    required_init_tokens = [
        "config.userContentController.addUserScript(",
        "source: Self.telemetryHookBootstrapScriptSource",
        "injectionTime: .atDocumentStart",
    ]
    for token in required_init_tokens:
        if token not in panel_init_block:
            failures.append(f"BrowserPanel init() missing telemetry user-script token: {token}")

    if failures:
        print("FAIL: browser eval async wrapper / telemetry injection regression guard failed")
        for item in failures:
            print(f" - {item}")
        return 1

    print("PASS: browser eval async wrapper / telemetry injection regression guard is in place")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
