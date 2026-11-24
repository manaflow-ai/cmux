#!/usr/bin/env python3
"""Build one capture tour per setup in examples/customize-showcase.

`customize-showcase-<name>.json` shows cmux as it ships, then types the setup's customize/
files into the Tour terminal (base64, so no shell expansion touches them), sets each of its
settings, and shoots the window, plus a New Tab for the setups that draw one. Each tour
launches its own app, so nothing carries over between setups. Run it after changing a setup:

    python3 scripts/cmux-next/media/tours/sync_customize_showcase.py          # write
    python3 scripts/cmux-next/media/tours/sync_customize_showcase.py --check  # exit 1 if stale
"""
from __future__ import annotations

import argparse
import base64
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]
TOURS = ROOT / "scripts/cmux-next/media/tours"
SHOWCASE = ROOT / "examples/customize-showcase"
PREFIX = "customize-showcase-"
TARGET = ["workspace", "name:Tour", "screen", "current", "pane", "current",
          "tab", "current", "terminal", "current", "write", "--text"]


def b64(path: Path) -> str:
    return base64.b64encode(path.read_bytes()).decode("ascii")


def value(v: object) -> str:
    return v if isinstance(v, str) else json.dumps(v)


def tour(folder: Path) -> dict:
    meta = json.loads((folder / "profile.json").read_text())
    name, settings = meta["name"], meta["settings"]
    custom = folder / "customize"
    text = ('clear; D="${CMUX_CUSTOMIZE_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/cmux/customize}"; '
            f'mkdir -p "$D" && echo {b64(custom / "main.js")} | base64 -d > "$D/main.js" '
            f'&& echo {b64(custom / "cmux-app.json")} | base64 -d > "$D/cmux-app.json" '
            + "".join(f'&& mkdir -p "$D/../themes" && echo {b64(t)} | base64 -d > "$D/../themes/{t.name}" '
                      for t in sorted((folder / "themes").glob("*.json")))
            + f"&& echo saved {name}\r")
    steps = [
        {"title": "Launch", "wait": 2, "shot": False},
        {"title": "New workspace", "cmux": ["workspace", "new", "--name", "Tour"], "shot": False},
        {"title": "Show the Tour workspace", "cmux": ["workspace", "name:Tour", "focus"], "shot": False},
        {"title": "Before: cmux as it ships", "wait": 2},
        {"title": f"{name}: its views", "daemon": True, "cmux": TARGET + [text], "wait": 4, "shot": False},
    ]
    for key, v in settings.items():
        steps.append({"title": f"{name}: {key}", "cmux": ["settings", "set", key, value(v)], "wait": 0.3, "shot": False})
    steps.append({"title": f"{name}: {meta['description']}", "wait": 3})
    if "tabs.newTabApp" in settings:
        steps.append({"title": f"{name}: a New Tab is the setup's own page", "cmux": ["action", "run", "newTab.default"],
                      "wait": 3, "optional": "a New Tab opens a terminal when tabs.newTabTemplate picks one"})
    out = {"title": f"Customization showcase: {name}", "customize": True, "steps": steps}
    if (folder / "themes").is_dir():
        # A tour settings file puts the app's config folder at the workdir, the customize folder's
        # parent, so the theme written beside it is the one appearance.themeFile finds.
        out["settings"] = {}
    return out


def expected() -> dict[Path, str]:
    folders = sorted(p for p in SHOWCASE.iterdir() if (p / "profile.json").is_file())
    return {TOURS / f"{PREFIX}{f.name}.json": json.dumps(tour(f), indent=2, ensure_ascii=False) + "\n" for f in folders}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    want = expected()
    have = set(TOURS.glob(f"{PREFIX}*.json"))
    if args.check:
        stale = [p.name for p, text in want.items() if not p.is_file() or p.read_text() != text]
        stale += [p.name for p in have - set(want)]
        if stale:
            print(f"stale: {', '.join(sorted(stale))}; run {Path(__file__).relative_to(ROOT)}", file=sys.stderr)
            return 1
        return 0
    for path in have - set(want):
        path.unlink()
    for path, text in want.items():
        path.write_text(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
