#!/usr/bin/env python3
"""Symbolicate a macOS .ips crash report with atos against on-disk binaries.

System frames already carry symbol names inside the report. Frames from
locally built images (the app-host test build in DerivedData) only carry
image offsets, and the binaries are discarded when a CI runner is recycled,
so symbolication must happen on the runner before artifact upload.

Usage: symbolicate-ips.py <report.ips>

Prints a plain-text report to stdout. Exits 0 even when some images cannot
be symbolicated; frames fall back to image name + offset.
"""

import json
import subprocess
import sys


def load_report(path):
    with open(path, "r", errors="replace") as fh:
        text = fh.read()
    decoder = json.JSONDecoder()
    summary, index = decoder.raw_decode(text)
    payload, _ = decoder.raw_decode(text, json.decoder.WHITESPACE.match(text, index).end())
    return summary, payload


def atos_batch(binary_path, load_address, addresses):
    if not addresses:
        return {}
    cmd = ["/usr/bin/atos", "-o", binary_path, "-l", hex(load_address)]
    cmd.extend(hex(a) for a in addresses)
    try:
        out = subprocess.run(
            cmd, capture_output=True, text=True, timeout=120, check=False
        )
    except (OSError, subprocess.TimeoutExpired):
        return {}
    lines = out.stdout.splitlines()
    if len(lines) != len(addresses):
        return {}
    return dict(zip(addresses, lines))


def main():
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    summary, payload = load_report(sys.argv[1])

    images = payload.get("usedImages", [])
    exception = payload.get("exception", {})
    termination = payload.get("termination", {})
    print(f"process: {payload.get('procName')} pid={payload.get('pid')}")
    print(f"captureTime: {payload.get('captureTime')}")
    print(f"exception: {exception}")
    print(f"termination: {termination}")
    if payload.get("asi"):
        print(f"asi: {payload['asi']}")
    if payload.get("lastExceptionBacktrace") is not None:
        print("note: report has lastExceptionBacktrace (uncaught NSException)")
    faulting = payload.get("faultingThread")
    print(f"faultingThread: {faulting}")
    print()

    # Group unsymbolicated frame addresses per image so each binary needs one
    # atos invocation.
    wanted = {}
    threads = payload.get("threads", [])
    backtraces = list(threads)
    if payload.get("lastExceptionBacktrace") is not None:
        backtraces.append({"frames": payload["lastExceptionBacktrace"],
                           "name": "lastExceptionBacktrace"})
    for thread in backtraces:
        for frame in thread.get("frames", []):
            if "symbol" in frame:
                continue
            index = frame.get("imageIndex")
            offset = frame.get("imageOffset")
            if index is None or offset is None or index >= len(images):
                continue
            image = images[index]
            base = image.get("base")
            path = image.get("path")
            if base is None or not path:
                continue
            wanted.setdefault(index, set()).add(base + offset)

    resolved = {}
    for index, addresses in wanted.items():
        image = images[index]
        resolved[index] = atos_batch(image["path"], image["base"], sorted(addresses))

    for position, thread in enumerate(backtraces):
        label = thread.get("name") or thread.get("queue") or ""
        marker = " (faulting)" if position == faulting else ""
        print(f"thread {position} {label}{marker}".rstrip())
        for frame_index, frame in enumerate(thread.get("frames", [])):
            index = frame.get("imageIndex")
            offset = frame.get("imageOffset", 0)
            image = images[index] if index is not None and index < len(images) else {}
            image_name = image.get("name") or image.get("path", "?")
            symbol = frame.get("symbol")
            if symbol is not None:
                location = frame.get("symbolLocation", 0)
                text = f"{symbol} + {location}"
            else:
                address = image.get("base", 0) + offset
                text = resolved.get(index, {}).get(address) or f"0x{address:x}"
            print(f"  {frame_index:3d} {image_name:<40} {text}")
        print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
