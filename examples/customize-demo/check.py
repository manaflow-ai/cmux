#!/usr/bin/env python3
"""Check that every customization we built is in the demo, one step each, and that the demo's own
looks go deeper than color.

The detector for "the demo left a look out": every installable look (each cmux-setup.json under
examples/looks and examples/gallery, a look folder with only a profile.json, every
examples/customize-showcase setup and the Leo collection) must have a fresh bundle here and be a
step of `demo.sh --list`, and every step must declare a feature surface (settings, files, or a
setup's actions). Adding a look without its demo step fails here.

The demo's own thirteen looks (looks/, last-demo/, glass/, widgets/) are also held to a deep
sidebar: the row and group keys below, the top right buttons and Session Info, and, where the look
has a theme file, its own density (tab and sidebar row corners and the sidebar's width). Claude,
Codex, studio, hosts and the Material look must each have a shape of their own, not only colors.
Every density token in every step is checked against the Density Playground's catalog
(DensityTokenCatalog.swift): its name and its range. Settings and theme keys themselves are
checked by looks/check (the app's own Rust preview), not here.
"""

import importlib.util
import json
import re
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent
REPO = ROOT.parent.parent
DEMO_LOOKS = ("looks", "last-demo", "glass", "widgets")
FOLDERS = DEMO_LOOKS + ("gallery", "showcase")
SIDEBAR_DEPTH_KEYS = {
    "sidebar.style",
    "sidebar.groupHeader.background",
    "sidebar.groupPalette",
    "sidebar.workspaceRow.directory",
    "sidebar.workspaceRow.branch",
    "sidebar.workspaceRow.agentStatus",
    "sidebar.workspaceRow.tabCount",
    "sidebar.workspaceRow.secondLineOrder",
    "workspaceColors.indicatorStyle",
}
# The top right buttons and Session Info (cmux#46749): every demo look chooses them.
CHROME_KEYS = ("window.titlebarButtons", "tabs.plusButton", "agentPane.display.sessionInfo.placement")
# A theme's density must shape the tabs and the sidebar, not one token.
TAB_CORNER = "tabCornerRadius"
ROW_CORNERS = ("sidebarCornerRadius", "verticalTabCornerRadius")
# Looks Leo named, which must not share a shape.
DISTINCT = ("looks/claude.json", "looks/codex.json", "looks/studio.json", "looks/hosts.json",
            "gallery/material.json")
CATALOG = REPO / "Packages/macOS/CmuxNext/Sources/CmuxNextDesign/DensityTokenCatalog.swift"


def load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


gallery = load("gallery_bundle", ROOT / "gallery" / "bundle.py")
showcase = load("showcase_bundle", ROOT / "showcase" / "bundle.py")


def profiles() -> list[str]:
    return sorted(
        f"{folder}/{path.name}"
        for folder in FOLDERS
        for path in (ROOT / folder).glob("*.json")
    )


def sources() -> dict[str, Path]:
    """Demo step -> the folder it comes from, for every installable look outside the demo."""
    out = {f"gallery/{name}": folder for name, folder in gallery.sources().items()}
    out.update({f"showcase/{name}": folder for name, (folder, _) in showcase.sources().items()})
    return out


def density_catalog() -> dict[str, tuple[float, float]]:
    """Token name -> (low, high), read from the Swift catalog; empty when this checkout lacks it."""
    if not CATALOG.is_file():
        return {}
    text = CATALOG.read_text()
    entries = {}
    for match in re.finditer(r'Entry\("(\w+)",((?:(?!Entry\().)*?)range: ([\d.]+)\.\.\.([\d.]+)', text, re.S):
        entries[match.group(1)] = (float(match.group(3)), float(match.group(4)))
    return entries


def flatten(value: dict, prefix: str = "") -> dict:
    out = {}
    for key, item in value.items():
        if isinstance(item, dict) and key not in ("colors", "density") and not prefix + key in ("tabs.toolbarButtons",):
            out.update(flatten(item, f"{prefix}{key}."))
        else:
            out[prefix + key] = item
    return out


def themes(profile: dict) -> dict[str, dict]:
    out = {}
    for path, text in profile.get("files", {}).items():
        if path.startswith("themes/") and path.endswith(".json"):
            out[path] = flatten(json.loads(gallery.strip_jsonc(text)))
    return out


def active_theme(profile: dict) -> dict:
    """The theme file the profile's appearance.themeFile names, flattened; {} when none."""
    name = profile.get("settings", {}).get("appearance.themeFile")
    return themes(profile).get(f"themes/{name}.json", {}) if name else {}


def shape(profile: dict) -> tuple:
    theme = active_theme(profile)
    tokens = (theme.get("density") or {}).get("tokens", {})
    return (tokens.get("sidebarWidth"), tokens.get(TAB_CORNER),
            tokens.get("sidebarCornerRadius"), theme.get("appearance.cornerFlush"))


def problems() -> list[str]:
    found = []
    expected = profiles()
    listed = subprocess.run(
        [str(ROOT / "demo.sh"), "--list"], capture_output=True, text=True, check=True
    ).stdout.split()
    if len(listed) != len(set(listed)):
        found.append("demo.sh --list repeats a step")
    if set(listed) != set(expected):
        found.append(f"demo inventory mismatch: missing={sorted(set(expected) - set(listed))} "
                     f"extra={sorted(set(listed) - set(expected))}")

    # Every installable look is a demo step, and every bundle is fresh.
    for step, folder in sources().items():
        if step not in listed:
            found.append(f"{folder.relative_to(REPO)} is not in the demo: run its folder's bundle.py")
    for part in FOLDERS:
        result = subprocess.run([sys.executable, str(ROOT / part / "bundle.py"), "--check"],
                                capture_output=True, text=True)
        if result.returncode:
            found.append(f"{part}: {result.stderr.strip()}")

    catalog = density_catalog()
    if not catalog:
        print(f"note: {CATALOG.relative_to(REPO)} is not in this checkout; density tokens unchecked",
              file=sys.stderr)
    loaded = {}
    for relative in expected:
        profile = json.loads((ROOT / relative).read_text())
        loaded[relative] = profile
        settings = profile.get("settings", {})
        files = profile.get("files", {})
        setup = profile.get("x-setup", {})
        manifest_text = files.get("customize/cmux-app.json")
        if manifest_text and not json.loads(manifest_text).get("implements"):
            found.append(f"{relative}: its customize app implements no feature surface")
        if not settings and not files and not setup.get("actions"):
            found.append(f"{relative}: has no settings, files or actions: nothing to show")
        for path, theme in themes(profile).items():
            for token, value in ((theme.get("density") or {}).get("tokens") or {}).items():
                if catalog and token not in catalog:
                    found.append(f"{relative}: {path}: density token {token} is not in the Density Playground")
                elif catalog and not catalog[token][0] <= value <= catalog[token][1]:
                    low, high = catalog[token]
                    found.append(f"{relative}: {path}: {token} {value} is outside {low:g}...{high:g}")

        if relative.split("/")[0] not in DEMO_LOOKS:
            continue
        sidebar_keys = set(settings) & SIDEBAR_DEPTH_KEYS
        if len(sidebar_keys) < 6:
            found.append(f"{relative}: sidebar customization is shallow ({len(sidebar_keys)}/6 depth keys)")
        if "workspaceColors.indicatorStyle" not in settings:
            found.append(f"{relative}: sidebar customization does not choose an indicator style")
        theme = active_theme(profile)
        effective = {**settings, **theme}
        for key in CHROME_KEYS:
            if key not in effective:
                found.append(f"{relative}: does not choose {key} (the top right buttons and Session Info)")
        if settings.get("appearance.themeFile"):
            tokens = (theme.get("density") or {}).get("tokens") or {}
            if TAB_CORNER not in tokens or not any(t in tokens for t in ROW_CORNERS) or "sidebarWidth" not in tokens:
                found.append(f"{relative}: its theme's density must set {TAB_CORNER}, a row corner "
                             f"({' or '.join(ROW_CORNERS)}) and sidebarWidth")

    shapes = {}
    for relative in DISTINCT:
        if relative not in loaded:
            found.append(f"{relative}: missing")
            continue
        look = shape(loaded[relative])
        if None in look[:3]:
            found.append(f"{relative}: its theme sets no sidebar width, tab corner and sidebar corner")
        if look in shapes.values():
            other = next(name for name, value in shapes.items() if value == look)
            found.append(f"{relative}: same tabs and sidebar shape as {other}: {look}")
        shapes[relative] = look
    return found


def main() -> int:
    found = problems()
    for problem in found:
        print(problem, file=sys.stderr)
    if found:
        return 1
    steps = profiles()
    outside = len(sources())
    print(f"ok: {len(steps)} profiles are steps of demo.sh ({len(steps) - outside} demo looks, "
          f"{outside} from the gallery, showcase and Leo collection), each with a feature surface")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
