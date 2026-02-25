#!/usr/bin/env python3
"""Static regression checks for terminal tiny-pane resize/overflow fixes.

Guards the key invariants for issue #348:
1) Terminal portal sync must stabilize layout and clamp hosted frames to host bounds.
2) Surface sizing must prefer live bounds over stale pending values when available.
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

    portal_path = root / "Sources" / "TerminalWindowPortal.swift"
    portal_source = portal_path.read_text(encoding="utf-8")

    if "hostView.layer?.masksToBounds = true" not in portal_source:
        failures.append("WindowTerminalPortal init no longer enables hostView layer clipping")
    if "hostView.postsFrameChangedNotifications = true" not in portal_source:
        failures.append("WindowTerminalPortal init no longer enables hostView frame-change notifications")
    if "hostView.postsBoundsChangedNotifications = true" not in portal_source:
        failures.append("WindowTerminalPortal init no longer enables hostView bounds-change notifications")

    if "private func synchronizeLayoutHierarchy()" not in portal_source:
        failures.append("WindowTerminalPortal missing synchronizeLayoutHierarchy()")
    if "private func synchronizeHostFrameToReference() -> Bool" not in portal_source:
        failures.append("WindowTerminalPortal missing synchronizeHostFrameToReference()")
    if "hostedView.reconcileGeometryNow()" not in extract_block(
        portal_source,
        "func bind(hostedView: GhosttySurfaceScrollView, to anchorView: NSView, visibleInUI: Bool, zPriority: Int = 0)",
    ):
        failures.append("bind() no longer pre-reconciles hosted geometry before attach")

    sync_block = extract_block(portal_source, "private func synchronizeHostedView(withId hostedId: ObjectIdentifier)")
    for required in [
        "let hostBounds = hostView.bounds",
        "let clampedFrame = frameInHost.intersection(hostBounds)",
        "let targetFrame = (hasFiniteFrame && hasVisibleIntersection) ? clampedFrame : frameInHost",
        "scheduleDeferredFullSynchronizeAll()",
        "hostedView.reconcileGeometryNow()",
        "hostedView.refreshSurfaceNow()",
    ]:
        if required not in sync_block:
            failures.append(f"terminal portal sync missing: {required}")

    terminal_view_path = root / "Sources" / "GhosttyTerminalView.swift"
    terminal_view_source = terminal_view_path.read_text(encoding="utf-8")

    resolved_block = extract_block(terminal_view_source, "private func resolvedSurfaceSize(preferred size: CGSize?) -> CGSize")
    bounds_index = resolved_block.find("let currentBounds = bounds.size")
    pending_index = resolved_block.find("if let pending = pendingSurfaceSize")
    if bounds_index < 0 or pending_index < 0 or bounds_index > pending_index:
        failures.append("resolvedSurfaceSize() no longer prefers bounds before pendingSurfaceSize")

    update_block = extract_block(terminal_view_source, "private func updateSurfaceSize(size: CGSize? = nil)")
    if "let size = resolvedSurfaceSize(preferred: size)" not in update_block:
        failures.append("updateSurfaceSize() no longer resolves size via resolvedSurfaceSize()")

    if failures:
        print("FAIL: terminal resize/portal regression guards failed")
        for item in failures:
            print(f" - {item}")
        return 1

    print("PASS: terminal resize/portal regression guards are in place")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
