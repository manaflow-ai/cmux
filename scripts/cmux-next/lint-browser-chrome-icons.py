#!/usr/bin/env python3
"""Fails when the cmux-next browser chrome draws an icon that is not Chrome's.

The browser toolbar, address bar, find bar, extension buttons and side panel header draw
Chromium's own icons, vendored in design/icons/chromium and generated into the cmux pack
(catalog entries with "source": "chromium"). This lint scans the browser chrome sources
(Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/{UI,PageInfo,Omnibox}) and reports:

- an SF Symbol or asset image (`NSImage(systemSymbolName:`, `Image(systemName:`, `NSImage(named:`);
- a pack icon that is not a Chromium one where a button or image is given its icon
  (`ChromeIconButton(icon: .x`, `ButtonState(icon: .x`, `NSImage.icon(.x`, `setIcon(.x`).

A line that must keep a cmux or system icon (Chrome has no such control, or nothing is vendored
yet) carries `// chrome-icons: allow <reason>` on it or on the line above.
Run: python3 scripts/cmux-next/lint-browser-chrome-icons.py
"""
import json
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
ICONS = REPO / "Packages" / "macOS" / "CmuxNext" / "Sources" / "CmuxNextIcons"
BROWSER = REPO / "Packages" / "macOS" / "CmuxNext" / "Sources" / "CmuxNextBrowser"
SCOPES = ("UI", "PageInfo", "Omnibox")
ALLOW = "chrome-icons: allow"
SYSTEM = re.compile(r"NSImage\(systemSymbolName:|Image\(systemName:|NSImage\(named:")
ASSIGN = re.compile(r"ChromeIconButton\(icon:|ButtonState\(icon:|NSImage\.icon\(|setIcon\(")
MEMBER = re.compile(r"(?<![\w)\]])\.([a-z][A-Za-z0-9]*)\b")
DECL = re.compile(r'static let (`?)(\w+)\1 = IconName\("([^"]+)"\)')


def swift_members():
    """IconName member -> pack name, from the generated IconName+Members.swift."""
    text = (ICONS / "IconName+Members.swift").read_text()
    return {member: name for _, member, name in DECL.findall(text)}


def chromium_names():
    catalog = json.loads((ICONS / "Resources" / "icon-catalog.json").read_text())["icons"]
    return {e["name"] for e in catalog if e.get("source") == "chromium"}


def allowed(lines, i):
    return ALLOW in lines[i] or (i > 0 and ALLOW in lines[i - 1])


def lint():
    members, chromium = swift_members(), chromium_names()
    problems = []
    for scope in SCOPES:
        for path in sorted((BROWSER / scope).rglob("*.swift")):
            lines = path.read_text().splitlines()
            rel = path.relative_to(REPO)
            for i, line in enumerate(lines):
                code = line.split("//", 1)[0]
                if allowed(lines, i):
                    continue
                if SYSTEM.search(code):
                    problems.append(f"{rel}:{i + 1}: SF Symbol or asset image in browser chrome; use a Chromium pack icon")
                match = ASSIGN.search(code)
                if not match:
                    continue
                for member in MEMBER.findall(code[match.start():]):
                    name = members.get(member)
                    if name and name != "placeholder" and name not in chromium:
                        problems.append(f"{rel}:{i + 1}: .{member} ({name}) is not a Chromium icon")
    return problems


def main():
    problems = lint()
    for problem in problems:
        print(problem, file=sys.stderr)
    if problems:
        print(f"\n{len(problems)} non-Chrome icon(s) in the browser chrome. Use a browser.* icon from "
              "design/icons/chromium (add one to manifest.json and run scripts/icons/chromium_icons.py, "
              f"then scripts/icons/build_pack.py), or mark the line `// {ALLOW} <reason>`.", file=sys.stderr)
        return 1
    print("browser chrome icons: all Chromium")
    return 0


if __name__ == "__main__":
    sys.exit(main())
