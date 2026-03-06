#!/usr/bin/env python3
"""Regression guard: browser transient dismantle must not tear down portal state.

This bug class produced intermittent blank browser panes after split/workspace churn.
The long-term lifecycle contract is:
1) BrowserPanelView.dismantleNSView treats teardown as transient (no detach/visibility mutation/sync).
2) BrowserPanel.close() performs permanent detach from BrowserWindowPortalRegistry.
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
    dismantle_block = extract_block(view_source, "static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator)")

    if "BrowserWindowPortalRegistry.detach(" in dismantle_block:
        failures.append("BrowserPanelView.dismantleNSView still detaches browser portal entry")
    if "BrowserWindowPortalRegistry.updateEntryVisibility(" in dismantle_block:
        failures.append("BrowserPanelView.dismantleNSView still mutates browser portal visibility")
    if "BrowserWindowPortalRegistry.synchronizeForAnchor(" in dismantle_block:
        failures.append("BrowserPanelView.dismantleNSView still forces portal synchronize during transient teardown")
    if "coordinator.desiredPortalVisibleInUI = false" in dismantle_block:
        failures.append("BrowserPanelView.dismantleNSView still forces desiredPortalVisibleInUI false")
    if "coordinator.desiredPortalZPriority = 0" in dismantle_block:
        failures.append("BrowserPanelView.dismantleNSView still forces desiredPortalZPriority to 0")

    panel_path = root / "Sources" / "Panels" / "BrowserPanel.swift"
    panel_source = panel_path.read_text(encoding="utf-8")
    close_block = extract_block(panel_source, "func close()")
    if "BrowserWindowPortalRegistry.detach(webView: webView)" not in close_block:
        failures.append("BrowserPanel.close() is missing permanent BrowserWindowPortalRegistry.detach call")

    if failures:
        print("FAIL: browser transient dismantle lifecycle regression guards failed")
        for item in failures:
            print(f" - {item}")
        return 1

    print("PASS: browser transient dismantle lifecycle regression guards are in place")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
