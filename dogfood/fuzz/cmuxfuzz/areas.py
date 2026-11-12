"""Map changed files to fuzzer areas, so runs lean toward what recent PRs touched."""

from __future__ import annotations

import re
import subprocess
from collections import Counter
from pathlib import Path

# Area names match `Action.area` in actions.py.
AREAS = (
    "splits",
    "drag",
    "tabs",
    "workspaces",
    "sidebar",
    "palette",
    "terminal",
    "window",
    "browser",
    "settings",
)

_RULES: list[tuple[re.Pattern[str], tuple[str, ...]]] = [
    (re.compile(r"(^|/)bonsplit(/|$)", re.I), ("splits", "drag", "tabs")),
    (re.compile(r"split|divider|pane(?!l)", re.I), ("splits", "drag")),
    (re.compile(r"drag|drop", re.I), ("drag", "tabs")),
    (re.compile(r"tabbar|tab_?bar|surfacetab|TabItem|tabs?/", re.I), ("tabs",)),
    (re.compile(r"workspace|TabManager", re.I), ("workspaces",)),
    (re.compile(r"sidebar", re.I), ("sidebar", "workspaces")),
    (re.compile(r"palette|command", re.I), ("palette",)),
    (re.compile(r"ghostty|terminal|surface|paste|clipboard|keyboard", re.I), ("terminal",)),
    (re.compile(r"window|fullscreen|titlebar|ContentView|AppDelegate", re.I), ("window",)),
    (re.compile(r"browser|webview|cmux-browser", re.I), ("browser",)),
    (re.compile(r"settings|config", re.I), ("settings",)),
]

_APP_PREFIXES = ("Sources/", "Packages/macOS/", "vendor/bonsplit", "CLI/")


def areas_for_paths(paths: list[str]) -> Counter[str]:
    counts: Counter[str] = Counter()
    for path in paths:
        if not path.startswith(_APP_PREFIXES):
            continue
        for pattern, areas in _RULES:
            if pattern.search(path):
                counts.update(areas)
    return counts


def weights_from_counts(counts: Counter[str], *, boost: float = 3.0) -> dict[str, float]:
    """Every area keeps weight 1; touched areas gain up to `boost` more."""
    top = max(counts.values(), default=0)
    return {
        area: 1.0 + (boost * counts[area] / top if top else 0.0)
        for area in AREAS
    }


def changed_paths_for_ref(repo: Path, base: str, head: str) -> list[str]:
    out = subprocess.run(
        ["git", "-C", str(repo), "diff", "--name-only", f"{base}...{head}"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    return [line for line in out.splitlines() if line]


def recent_main_paths(repo: Path, ref: str, commits: int = 60) -> list[str]:
    out = subprocess.run(
        ["git", "-C", str(repo), "log", f"-{commits}", "--name-only", "--format=", ref],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    return [line for line in out.splitlines() if line]


def parse_focus(focus: str | None) -> dict[str, float] | None:
    """`--focus splits,drag` pins the run to those areas (others get a trickle)."""
    if not focus:
        return None
    wanted = {part.strip() for part in focus.split(",") if part.strip()}
    unknown = wanted - set(AREAS)
    if unknown:
        raise SystemExit(f"unknown area(s): {', '.join(sorted(unknown))}; known: {', '.join(AREAS)}")
    return {area: (10.0 if area in wanted else 0.3) for area in AREAS}
