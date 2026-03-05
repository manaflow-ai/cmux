#!/usr/bin/env python3
"""Regression guards for browser Cmd+F overlay layering in portal mode."""

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
    view_path = root / "Sources" / "Panels" / "BrowserPanelView.swift"
    panel_path = root / "Sources" / "Panels" / "BrowserPanel.swift"
    source = view_path.read_text(encoding="utf-8")
    panel_source = panel_path.read_text(encoding="utf-8")
    failures: list[str] = []

    try:
        browser_panel_view_block = extract_block(source, "struct BrowserPanelView: View")
    except ValueError as error:
        failures.append(str(error))
        browser_panel_view_block = ""

    try:
        body_block = extract_block(browser_panel_view_block, "var body: some View")
    except ValueError as error:
        failures.append(str(error))
        body_block = ""

    if body_block and "BrowserSearchOverlay(" in body_block:
        failures.append(
            "BrowserSearchOverlay must not be mounted in BrowserPanelView body; "
            "portal-hosted WKWebView can cover SwiftUI overlays"
        )

    try:
        webview_repr_block = extract_block(source, "struct WebViewRepresentable: NSViewRepresentable")
    except ValueError as error:
        failures.append(str(error))
        webview_repr_block = ""

    if webview_repr_block:
        if "let browserSearchState: BrowserSearchState?" not in webview_repr_block:
            failures.append("WebViewRepresentable must include browserSearchState so Cmd+F state changes trigger updates")
        if "var searchOverlayHostingView: NSHostingView<BrowserSearchOverlay>?" not in webview_repr_block:
            failures.append("WebViewRepresentable.Coordinator must own a BrowserSearchOverlay hosting view")
        if "private static func updateSearchOverlay(" not in webview_repr_block:
            failures.append("WebViewRepresentable must define updateSearchOverlay helper")
        if "containerView: webView.superview" not in webview_repr_block:
            failures.append("Portal updates must sync BrowserSearchOverlay against the web view container")
        if "removeSearchOverlay(from: coordinator)" not in webview_repr_block:
            failures.append("WebViewRepresentable must remove browser search overlays during teardown/rebind")

    if "browserSearchState: panel.searchState" not in source:
        failures.append("BrowserPanelView must pass panel.searchState into WebViewRepresentable")

    try:
        update_ns_view_block = extract_block(webview_repr_block, "func updateNSView(_ nsView: NSView, context: Context)")
    except ValueError as error:
        failures.append(str(error))
        update_ns_view_block = ""

    if "Self.updateSearchOverlay(" in update_ns_view_block:
        failures.append("updateNSView must not re-run updateSearchOverlay outside portal lifecycle paths")

    try:
        suppress_focus_block = extract_block(panel_source, "func shouldSuppressWebViewFocus() -> Bool")
    except ValueError as error:
        failures.append(str(error))
        suppress_focus_block = ""

    if "if searchState != nil {" not in suppress_focus_block:
        failures.append("BrowserPanel.shouldSuppressWebViewFocus must suppress focus while find-in-page is active")

    if failures:
        print("FAIL: browser find overlay portal regression guards failed")
        for failure in failures:
            print(f" - {failure}")
        return 1

    print("PASS: browser find overlay remains mounted in portal-hosted AppKit layer")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
