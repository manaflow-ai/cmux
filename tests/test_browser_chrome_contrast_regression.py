#!/usr/bin/env python3
"""Static regression guards for browser chrome contrast in mixed theme setups."""

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
    source = view_path.read_text(encoding="utf-8")
    failures: list[str] = []

    try:
        browser_panel_view_block = extract_block(source, "struct BrowserPanelView: View")
    except ValueError as error:
        failures.append(str(error))
        browser_panel_view_block = ""

    try:
        resolver_block = extract_block(source, "func resolvedBrowserChromeColorScheme(")
    except ValueError as error:
        failures.append(str(error))
        resolver_block = ""

    if resolver_block:
        if "backgroundColor.isLightColor ? .light : .dark" not in resolver_block:
            failures.append(
                "resolvedBrowserChromeColorScheme must map luminance to a light/dark ColorScheme"
            )

    try:
        chrome_scheme_block = extract_block(
            browser_panel_view_block,
            "private var browserChromeColorScheme: ColorScheme",
        )
    except ValueError as error:
        failures.append(str(error))
        chrome_scheme_block = ""

    if chrome_scheme_block and "resolvedBrowserChromeColorScheme(" not in chrome_scheme_block:
        failures.append("browserChromeColorScheme must use resolvedBrowserChromeColorScheme")

    try:
        omnibar_background_block = extract_block(
            browser_panel_view_block,
            "private var omnibarPillBackgroundColor: NSColor",
        )
    except ValueError as error:
        failures.append(str(error))
        omnibar_background_block = ""

    if omnibar_background_block and "for: browserChromeColorScheme" not in omnibar_background_block:
        failures.append("omnibar pill background must use browserChromeColorScheme")

    try:
        address_bar_block = extract_block(
            browser_panel_view_block,
            "private var addressBar: some View",
        )
    except ValueError as error:
        failures.append(str(error))
        address_bar_block = ""

    if address_bar_block and ".environment(\\.colorScheme, browserChromeColorScheme)" not in address_bar_block:
        failures.append("addressBar must apply browserChromeColorScheme via environment")

    try:
        body_block = extract_block(browser_panel_view_block, "var body: some View")
    except ValueError as error:
        failures.append(str(error))
        body_block = ""

    if body_block:
        if "OmnibarSuggestionsView(" not in body_block:
            failures.append("Expected OmnibarSuggestionsView block in BrowserPanelView body")
        elif ".environment(\\.colorScheme, browserChromeColorScheme)" not in body_block:
            failures.append("Omnibar suggestions must apply browserChromeColorScheme via environment")

    if failures:
        print("FAIL: browser chrome contrast regression guards failed")
        for failure in failures:
            print(f" - {failure}")
        return 1

    print("PASS: browser chrome contrast regression guards are in place")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
