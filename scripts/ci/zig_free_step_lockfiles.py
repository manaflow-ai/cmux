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

# Modes that build one package of a shared workspace with no ghostty-next checkout: the
# package's dependency closure in that lockfile must hold no Ghostty crate.
EXEMPT_MODE_PACKAGES = {
    "api-compat": ("cmux-tui/Cargo.lock", "cmux-api-compat"),
    "api-compat-write": ("cmux-tui/Cargo.lock", "cmux-api-compat"),
}


def ghostty_crates(lock_text: str) -> list[str]:
    """Return the sorted Ghostty crate names in a Cargo.lock."""
    packages = tomllib.loads(lock_text).get("package", [])
    return sorted({p.get("name", "") for p in packages} & GHOSTTY_CRATES)


def ghostty_crates_reached(lock_text: str, package: str) -> list[str]:
    """Return the sorted Ghostty crates in package's dependency closure ([] if package is absent)."""
    deps: dict[str, list[str]] = {}
    for p in tomllib.loads(lock_text).get("package", []):
        deps.setdefault(p.get("name", ""), []).extend(d.split()[0] for d in p.get("dependencies", []))
    seen: set[str] = set()
    todo = [package] if package in deps else []
    while todo:
        name = todo.pop()
        if name not in seen:
            seen.add(name)
            todo.extend(deps.get(name, []))
    return sorted(seen & GHOSTTY_CRATES)
