#!/usr/bin/env python3
"""Static regression guards for portal/model drift protection.

This checks the invariant that portal binding/sync is model-authoritative:
if a terminal surface is no longer present in TabManager, stale SwiftUI/AppKit
callbacks must not be able to re-show it as an overlay.
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

    tab_manager_source = (root / "Sources" / "TabManager.swift").read_text(encoding="utf-8")
    portal_source = (root / "Sources" / "TerminalWindowPortal.swift").read_text(encoding="utf-8")
    terminal_view_source = (root / "Sources" / "GhosttyTerminalView.swift").read_text(encoding="utf-8")

    if "func hasSurfaceModel(surfaceId: UUID) -> Bool" not in tab_manager_source:
        failures.append("TabManager is missing hasSurfaceModel(surfaceId:) model lookup helper")

    if "var portalSurfaceId: UUID?" not in terminal_view_source:
        failures.append("GhosttySurfaceScrollView is missing portalSurfaceId for model checks")

    sync_block = extract_block(portal_source, "private func synchronizeHostedView(withId hostedId: ObjectIdentifier)")
    for required in [
        "if !isHostedViewBackedByModel(hostedView)",
        "reason=modelMissing",
        "detachHostedView(withId: hostedId)",
    ]:
        if required not in sync_block:
            failures.append(f"synchronizeHostedView() missing model-drift guard: {required}")

    registry_bind_block = extract_block(
        portal_source,
        "static func bind(hostedView: GhosttySurfaceScrollView, to anchorView: NSView, visibleInUI: Bool, zPriority: Int = 0)",
    )
    if "guard isHostedViewBackedByModel(hostedView) else" not in registry_bind_block:
        failures.append("TerminalWindowPortalRegistry.bind() missing model-authoritative guard")
    if 'dropModelMissingBinding(hostedView: hostedView, reason: "bind")' not in registry_bind_block:
        failures.append("TerminalWindowPortalRegistry.bind() missing model-missing cleanup path")

    registry_visibility_block = extract_block(
        portal_source,
        "static func updateEntryVisibility(for hostedView: GhosttySurfaceScrollView, visibleInUI: Bool)",
    )
    if "guard isHostedViewBackedByModel(hostedView) else" not in registry_visibility_block:
        failures.append("updateEntryVisibility() missing model-authoritative guard")

    if failures:
        print("FAIL: portal/model drift regression guards failed")
        for item in failures:
            print(f" - {item}")
        return 1

    print("PASS: portal/model drift guards are in place")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
