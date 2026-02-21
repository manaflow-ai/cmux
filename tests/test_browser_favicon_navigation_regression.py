#!/usr/bin/env python3
"""Static regression checks for favicon sync during browser navigation.

Guards the race fix where stale async favicon fetches must not overwrite the
icon after the user navigates (including back/forward and same-URL reloads).
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

    panel_path = root / "Sources" / "Panels" / "BrowserPanel.swift"
    panel_source = panel_path.read_text(encoding="utf-8")

    if "private var faviconRefreshGeneration: Int = 0" not in panel_source:
        failures.append("BrowserPanel is missing faviconRefreshGeneration state")

    refresh_block = extract_block(panel_source, "private func refreshFavicon(from webView: WKWebView)")
    if "let pageURLString = pageURL.absoluteString" not in refresh_block:
        failures.append("refreshFavicon() no longer captures pageURLString for staleness checks")
    if refresh_block.count("isCurrentFaviconRefresh(") < 3:
        failures.append("refreshFavicon() no longer checks staleness at each async stage")

    current_guard_block = extract_block(panel_source, "private func isCurrentFaviconRefresh(")
    if "generation == faviconRefreshGeneration" not in current_guard_block:
        failures.append("isCurrentFaviconRefresh() no longer validates refresh generation")
    if "webView.url?.absoluteString == pageURLString" not in current_guard_block:
        failures.append("isCurrentFaviconRefresh() no longer validates active page URL")

    loading_block = extract_block(panel_source, "private func handleWebViewLoadingChanged(_ newValue: Bool)")
    if "faviconRefreshGeneration &+= 1" not in loading_block:
        failures.append("handleWebViewLoadingChanged() no longer invalidates old favicon refreshes")
    if "faviconTask?.cancel()" not in loading_block:
        failures.append("handleWebViewLoadingChanged() no longer cancels stale favicon tasks")
    if "lastFaviconURLString = nil" not in loading_block:
        failures.append("handleWebViewLoadingChanged() no longer resets favicon URL cache on new loads")

    if failures:
        print("FAIL: browser favicon navigation regression guard failed")
        for item in failures:
            print(f" - {item}")
        return 1

    print("PASS: browser favicon navigation guard is in place")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
