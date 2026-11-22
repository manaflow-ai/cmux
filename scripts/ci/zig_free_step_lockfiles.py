#!/usr/bin/env python3
"""Lockfiles of the fleet step modes that the build-fleet Zig gate exempts.

cmuxterm-hq build-fleet/cmd/controller/toolchain.go (ciStepRequirements,
ZigFreeModes) lets these scripts/ci/cmux-tui-rust-check.sh modes run on a host
whose Zig is older than the Ghostty pin. That is safe only while their
workspaces build no Ghostty crate (tests/test_zig_free_step_lockfiles.py).
"""

from __future__ import annotations

import tomllib

EXEMPT_MODE_LOCKFILES = {
    "rd-host": "cmux-tui/crates/cmux-rd-host/Cargo.lock",
    "optchat-chief": "Native/OptChat/optchat-chief/Cargo.lock",
}

# The crates that build libghostty-vt from ghostty-next with Zig.
GHOSTTY_CRATES = frozenset({"ghostty-vt-sys", "ghostty-vt"})


def ghostty_crates(lock_text: str) -> list[str]:
    """Return the sorted Ghostty crate names in a Cargo.lock."""
    packages = tomllib.loads(lock_text).get("package", [])
    return sorted({p.get("name", "") for p in packages} & GHOSTTY_CRATES)
