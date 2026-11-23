#!/usr/bin/env python3
"""No fleet script makes macOS ask a person something on a screen nobody answers (cmuxterm-hq handbook,
prompt-on-an-unattended-screen).

On 2026-11-19 launch-fresh-install.sh (row q) left two asks on cmux-austin-mini-0, both in the worker's name, since
the worker starts every step: "wants access to control Finder" (osascript `tell application "Finder" to duplicate`)
and "would like to access files on a removable volume" (`open DMG`: DiskImageMounter mounts it under /Volumes, and
the run never detached it). So in every tracked .sh and .py under scripts/ and .github/:

  - no Apple event to Finder, unless the file gates it behind an opt-in variable that a fleet job never sets
    (FINDER_EVENT_GATES);
  - no DMG opened through LaunchServices (`open X.dmg`, `open "$dmg..."`);
  - every `hdiutil attach` passes -nobrowse and its own -mountpoint, never /Volumes;
  - in a file that writes com.apple.quarantine, every `hdiutil attach` also passes -noautofsck: hdiutil runs fsck_apfs
    on a quarantined image first, and fsck_apfs reading its device is the removable-volume ask (tccd on
    cmux-austin-mini-0, 10:53Z: accessing fsck_apfs, responsible the worker).

Static: it reads the files, runs nothing. Run: python3 scripts/measure/tests/no-unattended-prompts.test.py [--root DIR]
"""

import argparse
import re
import subprocess
import sys
from pathlib import Path

# A file that may send Finder an Apple event, and the variable that must gate it (a person's own session only).
FINDER_EVENT_GATES = {"scripts/measure/files-finder-bench.sh": "CMUX_FILES_BENCH_FINDER_EVENTS"}
FINDER_EVENT = re.compile(r'application\s+(?:id\s+)?\\?"(?:Finder|com\.apple\.finder)\\?"')
# `open` as a command (line start, after console/exec/sudo, or a subshell) whose arguments name a DMG.
OPEN_DMG = re.compile(r'(?:^|[;&(]|\b(?:console|exec|sudo -n|then|do))\s*(?:/usr/bin/)?open\s+[^|;&\n]*(?:\.dmg\b|\$\{?[A-Za-z_]*dmg)')
QUARANTINE_WRITE = re.compile(r'xattr"?,?\s+"?-w"?,?\s+(?:"?-r"?,?\s+)?"?com\.apple\.quarantine')
# A call, not a message about one ("hdiutil attach: ..."): options or a path follow.
ATTACH = re.compile(r'\bhdiutil\s+attach\s+["$-]|"hdiutil",\s*"attach"')
THIS = "scripts/measure/tests/no-unattended-prompts.test.py"


def tracked(root):
    out = subprocess.run(["git", "-C", root, "ls-files", "--", "scripts", ".github"], capture_output=True, text=True,
                         check=True).stdout.split()
    return [p for p in out if p.endswith((".sh", ".py", ".yml", ".yaml")) and p != THIS]


def logical_lines(text):
    """Shell continuation lines joined, numbered by their first line."""
    lines, start, buf = [], None, ""
    for n, line in enumerate(text.splitlines(), 1):
        start = start or n
        if line.endswith("\\"):
            buf += line[:-1] + " "
            continue
        lines.append((start, buf + line))
        start, buf = None, ""
    if buf:
        lines.append((start, buf))
    return lines


def findings(root):
    bad = []
    for rel in tracked(root):
        path = Path(root, rel)
        try:
            text = path.read_text(errors="replace")
        except OSError:
            continue
        raw = text.splitlines()
        quarantines = QUARANTINE_WRITE.search(text) is not None
        for n, line in logical_lines(text):
            if quarantines and ATTACH.search(line):
                window = " ".join(raw[n - 1:n + 2]) if rel.endswith(".py") else line
                if "-noautofsck" not in window:
                    bad.append(f"{rel}:{n}: hdiutil attach in a file that quarantines, without -noautofsck (fsck_apfs "
                               "asks for the removable volume)")
            code = line.split("#", 1)[0] if rel.endswith(".sh") else line
            if FINDER_EVENT.search(code):
                gate = FINDER_EVENT_GATES.get(rel)
                before = "\n".join(raw[max(0, n - 4):n])
                if not gate or gate not in before:
                    bad.append(f"{rel}:{n}: an Apple event to Finder (asks 'wants access to control Finder')")
            if OPEN_DMG.search(code):
                bad.append(f"{rel}:{n}: a DMG opened through LaunchServices (mounted under /Volumes, a removable "
                           "volume)")
            if re.search(r'\bhdiutil\s+attach\b', code) and not rel.endswith(".py"):
                if "-mountpoint" not in code or "-nobrowse" not in code:
                    bad.append(f"{rel}:{n}: hdiutil attach without -nobrowse and its own -mountpoint")
            if rel.endswith(".py") and re.search(r'"hdiutil",\s*"attach"', code):
                window = " ".join(raw[n - 1:n + 2])
                if '"-mountpoint"' not in window or '"-nobrowse"' not in window:
                    bad.append(f"{rel}:{n}: hdiutil attach without -nobrowse and its own -mountpoint")
    return bad


def self_test():
    """The patterns catch the two lines that asked on cmux-austin-mini-0, and pass their replacements."""
    asked = [
        """console /usr/bin/osascript -e 'tell application "Finder" to duplicate ((POSIX file src) as alias)'""",
        'console /usr/bin/open "$dmgfile" >>"$OUT/mount.log" 2>&1',
    ]
    fine = [
        'console /usr/bin/ditto "$found" "$dir/$(basename "$found")"',
        'gate dmg open "$out/app.dmg"',
        'hdiutil attach "$dmgfile" -nobrowse -readonly -mountpoint "$mount"',
    ]
    assert FINDER_EVENT.search(asked[0]), asked[0]
    assert OPEN_DMG.search(asked[1]), asked[1]
    for line in fine:
        assert not FINDER_EVENT.search(line) and not OPEN_DMG.search(line), line


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=str(Path(__file__).resolve().parents[3]))
    root = ap.parse_args().root
    self_test()
    bad = findings(root)
    for b in bad:
        print(f"FAIL {b}")
    print(f"{'FAIL' if bad else 'ok'}: {len(bad)} finding(s) in {root}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
