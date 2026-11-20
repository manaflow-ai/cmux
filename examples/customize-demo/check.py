#!/usr/bin/env python3
"""Check that every customization profile is runnable by the demo.

The demo is intentionally made from profile files in four folders.  Keep the
inventory check next to the demo so adding a look without adding it to the
recording order fails immediately instead of producing an incomplete gallery.
"""

import json
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent
FOLDERS = ("looks", "last-demo", "glass", "widgets")


def profiles() -> list[str]:
    return sorted(
        f"{folder}/{path.name}"
        for folder in FOLDERS
        for path in (ROOT / folder).glob("*.json")
    )


def main() -> int:
    expected = profiles()
    listed = subprocess.run(
        [str(ROOT / "demo.sh"), "--list"], capture_output=True, text=True, check=True
    ).stdout.split()
    if set(listed) != set(expected) or len(listed) != len(expected):
        missing = sorted(set(expected) - set(listed))
        extra = sorted(set(listed) - set(expected))
        print(f"demo inventory mismatch: missing={missing} extra={extra}", file=sys.stderr)
        return 1

    for relative in expected:
        path = ROOT / relative
        profile = json.loads(path.read_text())
        files = profile.get("files", {})
        manifest_text = files.get("customize/cmux-app.json")
        main_text = files.get("customize/main.js", "")
        if manifest_text:
            manifest = json.loads(manifest_text)
            if not manifest.get("implements"):
                print(f"{relative}: manifest has no feature surfaces", file=sys.stderr)
                return 1
            if "__cmuxAppExports" not in main_text:
                print(f"{relative}: customize/main.js exports no feature surface", file=sys.stderr)
                return 1
        elif not profile.get("settings"):
            print(f"{relative}: has neither app surfaces nor settings", file=sys.stderr)
            return 1

    if len(expected) != 13:
        print(f"expected 13 demo profiles, found {len(expected)}", file=sys.stderr)
        return 1
    print(f"ok: {len(expected)} profiles are in demo.sh and expose feature surfaces")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
