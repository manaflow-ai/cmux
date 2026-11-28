#!/bin/bash
# Read the cmux crash reports a fleet Mac holds, in a form a Linux lane can symbolicate.
#
# A walk that loses its app names only the report's file and its top symbols. Those are often the nearest
# exported symbol of a stripped image (Chromium Embedded Framework frames read "ChromeWebAppShortcutCopierMain"),
# which says nothing. This prints, per cmux*.ips modified since `since=`, the exception, termination and asi
# lines, every image's name, UUID and load address, and each frame of the crashed thread and of
# lastExceptionBacktrace as image + offset, so the CEF `-debug` asset or the app's dSYM can name it. It also
# prints the FATAL / Check failed lines of every recent cef.log and cef.previous.log under
# ~/Library/Application Support (Chromium writes a CHECK's message there, not to stdout).
#
# Read only: it launches, kills and deletes nothing. Paths under the home folder print as ~.
#   cmux-ci run --class light --label measure --target-worker HOST \
#     --script scripts/measure/crash-report-read.sh --ref <sha> --arg=since=2026-11-28T20:00:00Z [--arg=name=cmux-2026-11-28-123712]
# Python 3.9 (a Mac's /usr/bin/python3) runs the body below.
exec "${CRR_PYTHON:-/usr/bin/python3}" -I - "$@" <<'PY'
import datetime as dt
import json
import os
import sys
from pathlib import Path

HOME = str(Path.home())


def tidy(text):
    return str(text).replace(HOME, "~")


def args():
    since, name = None, ""
    for arg in sys.argv[1:]:
        if arg.startswith("since="):
            since = dt.datetime.fromisoformat(arg[6:].replace("Z", "+00:00")).timestamp()
        elif arg.startswith("name="):
            name = arg[5:]
        else:
            sys.exit(f"unknown argument: {arg}")
    return since if since is not None else (dt.datetime.now().timestamp() - 86400), name


def frames(thread, images, limit=60):
    out = []
    for frame in (thread or {}).get("frames", [])[:limit]:
        image = images[frame.get("imageIndex", -1)] if 0 <= frame.get("imageIndex", -1) < len(images) else {}
        out.append(f"    {image.get('name', '?')} +0x{frame.get('imageOffset', 0):x}"
                   f" {frame.get('symbol', '')}{'+' + str(frame['symbolLocation']) if 'symbolLocation' in frame else ''}")
    return out


def report(path):
    text = path.read_text(errors="replace")
    head, _, body = text.partition("\n")
    try:
        header, data = json.loads(head), json.loads(body)
    except json.JSONDecodeError as error:
        print(f"CRR {tidy(path)}: not parsed ({error})")
        return
    images = data.get("usedImages", [])
    print(f"CRR report {path.name} app={header.get('app_name')} version={header.get('app_version')}"
          f" build={header.get('build_version')} time={header.get('timestamp')}")
    print(f"CRR exception {json.dumps(data.get('exception'))}")
    print(f"CRR termination {tidy(json.dumps(data.get('termination')))}")
    for key in ("asi", "crashInfo", "ktriageinfo"):
        if data.get(key):
            print(f"CRR {key} {tidy(json.dumps(data[key]))[:2000]}")
    threads = data.get("threads", [])
    crashed = next((t for t in threads if t.get("triggered")), None)
    if crashed is None and isinstance(data.get("faultingThread"), int) and data["faultingThread"] < len(threads):
        crashed = threads[data["faultingThread"]]
    print(f"CRR crashed thread name={crashed.get('name') if crashed else None}"
          f" queue={crashed.get('queue') if crashed else None} index={threads.index(crashed) if crashed else None}")
    for line in frames(crashed, images):
        print(line)
    if data.get("lastExceptionBacktrace"):
        print("CRR lastExceptionBacktrace")
        for line in frames({"frames": data["lastExceptionBacktrace"]}, images):
            print(line)
    main = threads[0] if threads else None
    if main is not None and main is not crashed:
        print("CRR main thread")
        for line in frames(main, images, 30):
            print(line)
    for image in images:
        if image.get("name"):
            print(f"CRR image {image.get('name')} uuid={image.get('uuid')} base=0x{image.get('base', 0):x}"
                  f" size={image.get('size')} arch={image.get('arch')}")


def cef_logs(since):
    support = Path(HOME, "Library/Application Support")
    if not support.is_dir():
        return
    for root, dirs, files in os.walk(support):
        depth = Path(root).relative_to(support).parts
        if len(depth) > 4:
            dirs[:] = []
            continue
        for name in files:
            if name not in ("cef.log", "cef.previous.log"):
                continue
            path = Path(root, name)
            try:
                if path.stat().st_mtime < since:
                    continue
                lines = path.read_text(errors="replace").splitlines()
            except OSError:
                continue
            hits = [line for line in lines if "FATAL" in line or "Check failed" in line or "NOTREACHED" in line]
            print(f"CRR cef log {tidy(path)} lines={len(lines)} fatal={len(hits)}")
            for line in hits[-20:]:
                print(f"    {tidy(line)[:600]}")


def main():
    since, name = args()
    found = 0
    for folder in (Path(HOME, "Library/Logs/DiagnosticReports"), Path("/Library/Logs/DiagnosticReports")):
        if not folder.is_dir():
            print(f"CRR folder {tidy(folder)} missing")
            continue
        for path in sorted(folder.glob("*.ips"), key=lambda p: p.stat().st_mtime):
            lowered = path.name.lower()
            if not lowered.startswith("cmux") or name not in path.name or path.stat().st_mtime < since:
                continue
            found += 1
            report(path)
    print(f"CRR reports {found}")
    cef_logs(since)


if __name__ == "__main__":
    main()
PY
