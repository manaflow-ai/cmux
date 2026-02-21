#!/usr/bin/env python3
"""Static regression checks for browser DevTools/portal review fixes.

Guards two follow-up fixes:
1) DevTools toggle path must retry restore when inspector show is transiently ignored.
2) Browser portal visibility must propagate even if host is temporarily off-window.
"""

from __future__ import annotations

import re
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

    panel_path = root / "Sources" / "Panels" / "BrowserPanel.swift"
    panel_source = panel_path.read_text(encoding="utf-8")
    toggle_block = extract_block(panel_source, "func toggleDeveloperTools() -> Bool")
    if "visibleAfterToggle" not in toggle_block:
        failures.append("toggleDeveloperTools() no longer re-checks inspector visibility")
    if "scheduleDeveloperToolsRestoreRetry()" not in toggle_block:
        failures.append("toggleDeveloperTools() no longer schedules a DevTools restore retry")

    view_path = root / "Sources" / "Panels" / "BrowserPanelView.swift"
    view_source = view_path.read_text(encoding="utf-8")
    portal_update_block = extract_block(view_source, "private func updateUsingWindowPortal(")
    if "BrowserWindowPortalRegistry.updateEntryVisibility(" not in portal_update_block:
        failures.append("BrowserPanelView.updateUsingWindowPortal() is missing deferred portal visibility propagation")
    if "zPriority: coordinator.desiredPortalZPriority" not in portal_update_block:
        failures.append("BrowserPanelView deferred portal update no longer propagates zPriority")

    portal_path = root / "Sources" / "BrowserWindowPortal.swift"
    portal_source = portal_path.read_text(encoding="utf-8")
    if not re.search(
        r"func\s+updateEntryVisibility\s*\(\s*forWebViewId\s+webViewId:\s*ObjectIdentifier,\s*visibleInUI:\s*Bool,\s*zPriority:\s*Int\s*\)",
        portal_source,
        flags=re.MULTILINE,
    ):
        failures.append("WindowBrowserPortal is missing updateEntryVisibility(forWebViewId:visibleInUI:zPriority:)")
    if not re.search(
        r"static\s+func\s+updateEntryVisibility\s*\(\s*for\s+webView:\s*WKWebView,\s*visibleInUI:\s*Bool,\s*zPriority:\s*Int\s*\)",
        portal_source,
        flags=re.MULTILINE,
    ):
        failures.append("BrowserWindowPortalRegistry is missing updateEntryVisibility(for:visibleInUI:zPriority:)")

    if failures:
        print("FAIL: browser devtools/portal regression guards failed")
        for item in failures:
            print(f" - {item}")
        return 1

    print("PASS: browser devtools/portal regression guards are in place")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
