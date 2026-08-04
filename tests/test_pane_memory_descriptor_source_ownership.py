#!/usr/bin/env python3
"""Keep periodic pane-memory descriptor collection out of libghostty."""

from __future__ import annotations

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DESCRIPTOR_SOURCE = ROOT / "Sources" / "AppDelegate+PaneMemoryGuardrail.swift"
SAMPLER_SOURCE = ROOT / "Sources" / "PaneMemoryGuardrail.swift"


def main() -> None:
    descriptor_source = DESCRIPTOR_SOURCE.read_text(encoding="utf-8")
    for forbidden in (".controllingTTYName()", ".foregroundProcessID()"):
        if forbidden in descriptor_source:
            raise AssertionError(
                f"periodic pane-memory descriptor collection still calls libghostty: {forbidden}"
            )

    sampler_source = SAMPLER_SOURCE.read_text(encoding="utf-8")
    if "pids(forCMUXSurfaceID: descriptor.panelId)" not in sampler_source:
        raise AssertionError("pane-memory sampling lost its nonblocking surface-ID attribution")

    print("PASS: pane-memory descriptors use cached identity without periodic libghostty calls")


if __name__ == "__main__":
    main()
