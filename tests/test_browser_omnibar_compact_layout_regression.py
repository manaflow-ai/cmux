#!/usr/bin/env python3
"""Static regression guards for compact browser omnibar sizing."""

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


def parse_cgfloat_constant(source: str, name: str) -> float | None:
    match = re.search(
        rf"private let {re.escape(name)}: CGFloat = ([0-9]+(?:\.[0-9]+)?)",
        source,
    )
    if not match:
        return None
    return float(match.group(1))


def main() -> int:
    root = repo_root()
    failures: list[str] = []

    view_path = root / "Sources" / "Panels" / "BrowserPanelView.swift"
    view_source = view_path.read_text(encoding="utf-8")

    hit_size = parse_cgfloat_constant(view_source, "addressBarButtonHitSize")
    if hit_size is None:
        failures.append("addressBarButtonHitSize constant is missing")
    elif hit_size > 26:
        failures.append(
            f"addressBarButtonHitSize regressed to {hit_size:g}; expected <= 26 for compact omnibar height"
        )

    vertical_padding = parse_cgfloat_constant(view_source, "addressBarVerticalPadding")
    if vertical_padding is None:
        failures.append("addressBarVerticalPadding constant is missing")
    elif vertical_padding > 4:
        failures.append(
            f"addressBarVerticalPadding regressed to {vertical_padding:g}; expected <= 4 for compact omnibar height"
        )

    address_bar_block = extract_block(view_source, "private var addressBar: some View")
    if ".padding(.vertical, addressBarVerticalPadding)" not in address_bar_block:
        failures.append("addressBar no longer applies compact vertical padding via addressBarVerticalPadding")

    button_bar_block = extract_block(view_source, "private var addressBarButtonBar: some View")
    hit_frame_uses = button_bar_block.count("addressBarButtonHitSize")
    if hit_frame_uses < 3:
        failures.append(
            "navigation buttons no longer consistently use addressBarButtonHitSize frames (padding may be lost)"
        )

    extract_block(view_source, "private struct OmnibarAddressButtonStyle: ButtonStyle")
    style_body_block = extract_block(view_source, "private struct OmnibarAddressButtonStyleBody: View")
    if "configuration.isPressed" not in style_body_block:
        failures.append("OmnibarAddressButtonStyleBody is missing pressed-state styling")
    if "isHovered" not in style_body_block or ".onHover" not in style_body_block:
        failures.append("OmnibarAddressButtonStyleBody is missing hover-state styling")

    style_uses = view_source.count(".buttonStyle(OmnibarAddressButtonStyle())")
    if style_uses < 4:
        failures.append(
            "address bar buttons no longer consistently use OmnibarAddressButtonStyle"
        )

    if failures:
        print("FAIL: browser omnibar compact layout regression guards failed")
        for failure in failures:
            print(f" - {failure}")
        return 1

    print("PASS: browser omnibar compact layout regression guards are in place")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
