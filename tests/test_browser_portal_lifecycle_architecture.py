#!/usr/bin/env python3
"""Static regression checks for deterministic browser lifecycle architecture.

Guards the long-term browser mounting design:
1) BrowserPanelView updateNSView must use a single portal-based mount path.
2) Legacy attach-retry and direct attach/detach churn helpers stay removed.
3) BrowserPanel handles WebContent termination via deterministic webview replacement,
   not blind `webView.reload()`.
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

    view_path = root / "Sources" / "Panels" / "BrowserPanelView.swift"
    view_source = view_path.read_text(encoding="utf-8")

    if "updateUsingWindowPortal(nsView, context: context, webView: webView)" not in view_source:
        failures.append("updateNSView no longer routes through updateUsingWindowPortal")
    if "scheduleAttachRetry(" in view_source:
        failures.append("Legacy attach retry helper still present in BrowserPanelView")
    if "attachRetryWorkItem" in view_source:
        failures.append("Legacy attachRetryWorkItem state still present in BrowserPanelView")
    if "usesWindowPortal" in view_source:
        failures.append("Dual portal/non-portal lifecycle state still present in BrowserPanelView")

    panel_path = root / "Sources" / "Panels" / "BrowserPanel.swift"
    panel_source = panel_path.read_text(encoding="utf-8")

    if "@Published private(set) var webViewInstanceID" not in panel_source:
        failures.append("BrowserPanel is missing webViewInstanceID for deterministic instance remounting")
    if "replaceWebViewAfterContentProcessTermination" not in panel_source:
        failures.append("BrowserPanel is missing deterministic WebContent termination replacement path")

    terminate_delegate = extract_block(
        panel_source,
        "func webView(_ webView: WKWebView, webContentProcessDidTerminate: WKWebView)",
    )
    if "didTerminateWebContentProcess?(webView)" not in terminate_delegate:
        failures.append("webContentProcessDidTerminate no longer delegates to deterministic replacement handler")
    if "webView.reload()" in terminate_delegate:
        failures.append("webContentProcessDidTerminate still does blind webView.reload()")

    if failures:
        print("FAIL: browser lifecycle architecture regression guards failed")
        for item in failures:
            print(f" - {item}")
        return 1

    print("PASS: browser lifecycle architecture regression guards are in place")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
