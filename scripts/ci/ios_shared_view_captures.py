#!/usr/bin/env python3
"""Export B8b's real XCTest PNGs from the bounded agent-sim console stream.

Attachments are acknowledged but not persisted by the current Linux UI runner.
This transport preserves screenshots taken after content assertions, before the
app terminates. It never substitutes a post-test screenshot of the Home screen.
"""
from __future__ import annotations

import base64
import hashlib
import json
import re
import struct
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

NAMES = ("b8b-ios-feed", "b8b-ios-agent-chat")
MAX_ENCODED = 4 * ((8 * 1024 * 1024 + 2) // 3)


def screenshots(lines):
    headers, chunks, ended = {}, {}, set()
    for line in lines:
        match = re.search(r"\bB8B_PNG_(BEGIN|CHUNK|END) (\S+)(.*?)\s*$", line)
        if not match:
            continue
        kind, name, rest = match.groups()
        if name not in NAMES:
            raise ValueError("unexpected capture name")
        fields = rest.split()
        if kind == "BEGIN":
            digest, size = fields
            header = (digest, int(size))
            if not re.fullmatch(r"[0-9a-f]{64}", digest) or not 0 < header[1] <= MAX_ENCODED:
                raise ValueError("invalid capture header")
            if name in headers and headers[name] != header:
                raise ValueError("conflicting capture header")
            headers[name] = header
            chunks.setdefault(name, {})
        elif kind == "CHUNK":
            offset, data = fields
            offset = int(offset)
            if name not in headers or offset < 0 or offset % 240 or not 0 < len(data) <= 240:
                raise ValueError("invalid capture chunk")
            if offset + len(data) > headers[name][1]:
                raise ValueError("capture exceeds declared size")
            previous = chunks[name].setdefault(offset, data)
            if previous != data:
                raise ValueError("conflicting capture chunk")
        elif fields:
            raise ValueError("invalid capture end")
        else:
            ended.add(name)

    result = {}
    for name in NAMES:
        if name not in headers or name not in ended:
            raise ValueError(f"missing capture: {name}")
        digest, size = headers[name]
        pieces = chunks[name]
        if set(pieces) != set(range(0, size, 240)):
            raise ValueError(f"incomplete capture: {name}")
        encoded = "".join(pieces[offset] for offset in range(0, size, 240))
        if len(encoded) != size:
            raise ValueError("capture length mismatch")
        png = base64.b64decode(encoded, validate=True)
        if hashlib.sha256(png).hexdigest() != digest:
            raise ValueError("capture hash mismatch")
        if len(png) < 33 or png[:16] != b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR":
            raise ValueError("capture is not a PNG")
        width, height = struct.unpack(">II", png[16:24])
        if width < 100 or height < 100:
            raise ValueError("capture is smaller than an app viewport")
        result[name] = (png, {"sha256": digest, "width": width, "height": height})
    return result


def require_render_test(path):
    cases = list(ET.parse(path).getroot().iter("testcase"))
    if not cases or any(case.find("failure") is not None or case.find("error") is not None for case in cases):
        raise ValueError("render tests missing or failed")
    if not any(
        case.get("classname", "").endswith("B8bIOSHarnessUITests")
        and case.get("name") == "testSharedViewsRenderInIOSHarness"
        and case.find("skipped") is None
        for case in cases
    ):
        raise ValueError("B8b render test did not pass")


def main(argv):
    log, out, junit, source = argv
    require_render_test(junit)
    if not re.fullmatch(r"[0-9a-f]{40}", source):
        raise ValueError("source SHA is required")
    with open(log, encoding="utf-8", errors="replace") as stream:
        captures = screenshots(stream)
    root = Path(__file__).resolve().parents[2]
    fixture_paths = (
        "cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileShell/B8bIOSHarnessRoot.swift",
        "cmux-next-ios/UITests/B8bIOSHarnessUITests.swift",
    )
    manifest = {
        "source_sha": source,
        "platform": "iOS hosted on Linux; not native macOS capture",
        "coverage": ["shared Feed question content", "shared agent chat mock transcript"],
        "gaps": ["AppKit", "macOS styling", "native macOS window chrome"],
        "fixtures": {p: hashlib.sha256((root / p).read_bytes()).hexdigest() for p in fixture_paths},
        "captures": {},
    }
    out = Path(out)
    out.mkdir(parents=True, exist_ok=True)
    for name, (png, metadata) in captures.items():
        (out / (name + ".png")).write_bytes(png)
        manifest["captures"][name + ".png"] = metadata
    (out / "captures.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print("shared-views: exported two hash-verified XCTest PNGs")


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except (ValueError, OSError, ET.ParseError) as error:
        print(f"shared-views: {error}", file=sys.stderr)
        sys.exit(1)
