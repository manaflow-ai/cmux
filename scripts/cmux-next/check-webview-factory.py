#!/usr/bin/env python3
"""Every cmux-next web view goes through one engine decision: a cmux page is a
PageWebView (CmuxNextPages), whose engine PageEnginePolicy picks from
`browser.defaultEngine` (Chromium by default) and `browser.siteEngines`; a
browser tab is a BrowserTab whose engine BrowserEngineResolver picks. A raw
WKWebView made anywhere else would show in WebKit whatever the person chose.

Scans Swift sources under PACKAGE/Sources (default Packages/macOS/CmuxNext)
for a WKWebView made or subclassed: `WKWebView(`, `<Name>WKWebView(frame`,
`class X: WKWebView`. A hit is allowed only when the same line, or the line
directly above it, carries `// webview-allow: <reason>` with a non-empty
reason (the engine itself, or why the view cannot run in Chromium yet).

Usage: python3 -I scripts/cmux-next/check-webview-factory.py [PACKAGE_DIR]
"""
import pathlib, re, sys

root = pathlib.Path(__file__).resolve().parents[2]
package = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else root / "Packages/macOS/CmuxNext"
sources = package / "Sources"
if not sources.is_dir():
    print(f"check-webview-factory: no {sources}", file=sys.stderr)
    sys.exit(2)
made = re.compile(r"(?<![A-Za-z0-9_.])(?:[A-Z][A-Za-z0-9_]*)?WKWebView\s*\(\s*(?:frame\s*:|\))")
subclass = re.compile(r"\b(?:class|actor)\s+\w+\s*(?:<[^>]*>)?\s*:\s*(?:[\w.]+\s*,\s*)*WKWebView\b")
allow = re.compile(r"//\s*webview-allow:\s*\S")
failures = []
for path in sorted(sources.rglob("*.swift")):
    lines = path.read_text(encoding="utf-8").splitlines()
    for index, line in enumerate(lines):
        code = line.split("//", 1)[0]
        if not (made.search(code) or subclass.search(code)):
            continue
        if allow.search(line) or (index > 0 and allow.search(lines[index - 1])):
            continue
        failures.append(f"{path.relative_to(sources.parent)}:{index + 1}: {line.strip()}")
if failures:
    print("A WKWebView outside the engine decision (make a PageWebView or a BrowserTab, or add"
          " `// webview-allow: <reason>`):")
    print("\n".join(failures))
    sys.exit(1)
print("check-webview-factory: every web view goes through the engine decision")
