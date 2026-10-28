#!/usr/bin/env python3
"""Refresh the Chrome part of the browser's emulated device list.

The daemon owns the device list (browser-devices-v1: browser.devices.list,
browser.tab.emulate); it compiles in one data file that every engine, page and
the CLI read through it:
cmux-tui/crates/cmux-tui-core/data/emulated-devices.json

Its Chrome entries are Chrome DevTools' own list, copied verbatim (JSONV1
keys) from devtools-frontend front_end/models/emulation/EmulatedDevices.ts,
the array between DEVICE-LIST-BEGIN and DEVICE-LIST-END, in Chrome's order.
Entries with "origin": "cmux" are devices Chrome does not list yet; each names
its spec sources. This script replaces the Chrome entries, keeps the cmux
ones, and drops a cmux entry whose title Chrome now lists (Chrome's values win).

Usage (no network access here; fetch the file first):
  curl -fsSL -o /tmp/EmulatedDevices.ts \
    https://raw.githubusercontent.com/ChromeDevTools/devtools-frontend/<ref>/front_end/models/emulation/EmulatedDevices.ts
  python3 -I scripts/cmux-next/import-chrome-devices.py /tmp/EmulatedDevices.ts --ref <ref> --commit <sha>
"""
import argparse
import json
import pathlib
import re
import sys

DATA = pathlib.Path(__file__).resolve().parents[2] / "cmux-tui/crates/cmux-tui-core/data/emulated-devices.json"


def chrome_devices(source: str) -> list:
    begin = source.index("const emulatedDevices = [")
    end = source.index("// DEVICE-LIST-END", begin)
    body = source[source.index("[", begin):end].rstrip().rstrip(",") + "]"
    # Chrome's own build swaps the JS branch for the plain one (embed_mobile_devices_in_cpp.py).
    body = re.sub(r"/\* DEVICE-LIST-IF-JS \*/.*?/\* DEVICE-LIST-ELSE\n(.*?)DEVICE-LIST-END-IF \*/", r"\1", body, flags=re.S)
    body = "\n".join(line for line in body.split("\n") if not line.strip().startswith("//"))
    body = re.sub(r"'((?:[^'\\]|\\.)*)'", lambda m: json.dumps(m.group(1).replace("\\'", "'")), body)
    body = re.sub(r",(\s*[\]}])", r"\1", body)
    devices = json.loads(body)
    for device in devices:
        device["origin"] = "chrome"
    return devices


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", help="a local copy of EmulatedDevices.ts")
    parser.add_argument("--ref", required=True, help="the devtools-frontend ref it came from, e.g. chromium/8037")
    parser.add_argument("--commit", required=True, help="the devtools-frontend commit of that ref")
    parser.add_argument("--chromium", required=True, help="the Chromium milestone of the ref, e.g. 154 (the daemon puts <milestone>.0.0.0 in place of a device's %s)")
    parser.add_argument("--check", action="store_true", help="fail if the data file's Chrome part differs")
    args = parser.parse_args()

    chrome = chrome_devices(pathlib.Path(args.source).read_text())
    current = json.loads(DATA.read_text()) if DATA.exists() else {"devices": []}
    titles = {device["title"] for device in chrome}
    cmux = [d for d in current["devices"] if d.get("origin") == "cmux" and d["title"] not in titles]
    data = {
        "format": 1,
        "chrome": {
            "repository": "https://chromium.googlesource.com/devtools/devtools-frontend",
            "path": "front_end/models/emulation/EmulatedDevices.ts",
            "ref": args.ref,
            "commit": args.commit,
            "chromium": args.chromium,
            "devices": len(chrome),
        },
        # cmux's menu fields for Chrome's rows (released, brand, group) by title,
        # kept apart so the Chrome rows stay verbatim.
        "chrome-annotations": current.get("chrome-annotations", {}),
        "devices": chrome + cmux,
    }
    text = json.dumps(data, indent=1, ensure_ascii=False) + "\n"
    if args.check:
        if DATA.read_text() != text:
            print(f"{DATA} is stale: run without --check", file=sys.stderr)
            return 1
        return 0
    DATA.write_text(text)
    print(f"{len(chrome)} Chrome devices, {len(cmux)} cmux devices -> {DATA}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
