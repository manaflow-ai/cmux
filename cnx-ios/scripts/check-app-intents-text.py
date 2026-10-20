#!/usr/bin/env python3
"""Refuse App Intents text that App Store Connect rejects (error 90626).

Usage: check-app-intents-text.py <CnxApp.app>

Apple refuses a build whose App Intents metadata names an Apple device
("iPhone", "iPad", "iPod", "Apple Watch") in an intent title, description or
App Shortcut phrase: the text must read for every device. The build only
fails in Apple processing, after the upload, so testflight-build.sh runs this
on the built app first. It reads every string in
<app>/Metadata.appintents/*.actionsdata (the JSON Xcode extracts from the
intents) and exits 1 naming each offending string. An app without intents
passes.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

BANNED = re.compile(r"\b(iPhone|iPad|iPod|Apple Watch)\b")


def strings(value: object):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for item in value.values():
            yield from strings(item)
    elif isinstance(value, list):
        for item in value:
            yield from strings(item)


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__.strip().splitlines()[2], file=sys.stderr)
        return 2
    metadata = Path(argv[1]) / "Metadata.appintents"
    bad: list[str] = []
    for path in sorted(metadata.glob("*.actionsdata")):
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as error:
            print(f"error: {path} is not readable JSON: {error}", file=sys.stderr)
            return 1
        bad += sorted({text for text in strings(data) if BANNED.search(text)})
    if bad:
        print("error: App Intents text names an Apple device; App Store Connect rejects it (90626):", file=sys.stderr)
        for text in bad:
            print(f"  - {text}", file=sys.stderr)
        return 1
    print("ok: App Intents text names no Apple device")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
