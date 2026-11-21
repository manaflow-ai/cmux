#!/usr/bin/env python3
"""Keep the customize-templates tour in step with skills/cmux-customization/templates.

Each template folder gets one tour step that types its main.js and cmux-app.json into the
Tour terminal (base64, so no shell expansion touches it) and presses Return. This script
re-encodes every existing template step from the files as they are now, appends a step for
a template folder the tour does not have yet (a pane template also gets an app.open step),
and drops steps whose folder is gone. Run it after adding or changing a template:

    python3 scripts/cmux-next/media/tours/sync_customize_templates.py          # write
    python3 scripts/cmux-next/media/tours/sync_customize_templates.py --check  # exit 1 if stale
"""
from __future__ import annotations

import argparse
import base64
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]
TOUR = ROOT / "scripts/cmux-next/media/tours/customize-templates.json"
TEMPLATES = ROOT / "skills/cmux-customization/templates"
TARGET = ["workspace", "name:Tour", "screen", "current", "pane", "current",
          "tab", "current", "terminal", "current", "write", "--text"]
SAVED = re.compile(r"&& echo saved (\S+?)\r?$")


def b64(path: Path) -> str:
    return base64.b64encode(path.read_bytes()).decode("ascii")


def write_text(folder: Path) -> str:
    return ('clear; D="${CMUX_CUSTOMIZE_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/cmux/customize}"; '
            f'mkdir -p "$D" && echo {b64(folder / "main.js")} | base64 -d > "$D/main.js" '
            f'&& echo {b64(folder / "cmux-app.json")} | base64 -d > "$D/cmux-app.json" '
            f"&& echo saved {folder.name}\r")


def saved_name(step: dict) -> str | None:
    cmux = step.get("cmux") or []
    if "--text" not in cmux:
        return None
    match = SAVED.search(cmux[cmux.index("--text") + 1])
    return match.group(1) if match else None


def new_steps(folder: Path) -> list[dict]:
    manifest = json.loads((folder / "cmux-app.json").read_text(encoding="utf-8"))
    description = manifest.get("description", "").rstrip(".")
    steps = [{"title": f"{folder.name}: {description[:1].lower()}{description[1:]}",
              "daemon": True, "cmux": [*TARGET, write_text(folder)], "wait": 6}]
    if any(key.startswith("cmux.pane/") for key in manifest.get("implements", {})):
        steps.append({"title": f"Open the pane: cmux action run app.open --app {manifest['id']}",
                      "cmux": ["action", "run", "app.open", "--app", manifest["id"]], "wait": 4})
    return steps


def sync(tour: dict) -> dict:
    folders = {f.name: f for f in sorted(TEMPLATES.iterdir())
               if f.is_dir() and (f / "main.js").is_file() and (f / "cmux-app.json").is_file()}
    steps, seen = [], set()
    for step in tour["steps"]:
        name = saved_name(step)
        if name is None:
            steps.append(step)
        elif name in folders:
            step["cmux"] = [*step["cmux"][:-1], write_text(folders[name])]
            steps.append(step)
            seen.add(name)
    for name, folder in folders.items():
        if name not in seen:
            steps.extend(new_steps(folder))
    tour["steps"] = steps
    return tour


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true", help="exit 1 when the tour is stale")
    args = parser.parse_args()
    before = TOUR.read_text(encoding="utf-8")
    after = json.dumps(sync(json.loads(before)), indent=2, ensure_ascii=False) + "\n"
    if args.check:
        if after != before:
            print(f"{TOUR.relative_to(ROOT)} is stale: run {Path(__file__).relative_to(ROOT)}", file=sys.stderr)
            return 1
        return 0
    TOUR.write_text(after, encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
