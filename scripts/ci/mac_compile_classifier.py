#!/usr/bin/env python3
"""Shared path classifier for macOS app compile/test admission.

The classifier is deliberately conservative: ``True`` means a path is known to
be compiled or bundled into the Mac app, ``False`` means it is known to be
outside the app, and ``None`` means the caller must fail open.  CI routing and
cmux-next routing both consume this module so their Mac admission decisions
cannot drift.
"""
from __future__ import annotations

from enum import Enum


class MacCompilePath(Enum):
    APP = "app"
    NON_APP = "non-app"
    UNKNOWN = "unknown"


_APP_PREFIXES = (
    "App/", "CLI/", "cmuxTests/", "cmuxUITests/", "cmux.xcodeproj/",
    "Packages/", "Resources/", "Native/", "TunnelExtension/", "Assets.xcassets/",
)
_APP_EXACT = frozenset(("cmux.xcodeproj", "ghostty-next"))
_NON_APP_PREFIXES = (
    ".github/", "docs/", "design/", "scripts/", "web/", "webviews/",
    "workers/", "config/vite-plus/",
)
_NON_APP_EXACT = frozenset((
    "README", "README.md", "README.rst", "CHANGELOG.md", "package.json",
    "bun.lock", "biome.json", "bunfig.toml", ".npmrc", ".vercelignore", "vercel.json",
))


def classify(path: str) -> MacCompilePath:
    """Classify a repository-relative path for Mac app admission."""
    path = path.strip().replace("\\", "/")
    while path.startswith("./"):
        path = path[2:]
    if path in _APP_EXACT or path.startswith(_APP_PREFIXES):
        return MacCompilePath.APP
    if path in _NON_APP_EXACT or path.startswith(_NON_APP_PREFIXES):
        return MacCompilePath.NON_APP
    return MacCompilePath.UNKNOWN


def requires_mac_compile(path: str) -> bool | None:
    """Return True/False for known app/non-app paths, None when unknown."""
    result = classify(path)
    return {MacCompilePath.APP: True, MacCompilePath.NON_APP: False}.get(result)
