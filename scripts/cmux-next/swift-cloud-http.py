#!/usr/bin/env python3
"""Swift Cloud networking left in the cmux NEXT Mac app: the files that still build a Cloud HTTP or WebSocket request.

goals/cloud-client-swift-to-rust.md (cmuxterm-hq): "Delete the Swift CloudAPIClient and move the Mac app's Cloud code
into the Rust app server, so the app's Cloud calls all go through the Rust Cloud clients and no Swift Cloud networking
code remains on the cmux-next branch." NOW reads this as code_shape.swift_cloud.http_files (the count must reach 0);
hq's fleet-reconciler-swift-logic-lines.yml runs it at feat-cmux-next's head in its token-free measure job.

    scripts/cmux-next/swift-cloud-http.py [--repo ROOT] [--json] [--check]

A file counts when its code (comments blanked, strings kept) builds a request (REQUEST: `URLRequest(`, a
`.webSocketTask(` or `URLSessionWebSocketTask`, `.data(for:` and the like) and it is Cloud code: its path names Cloud,
or its code names a Cloud base or client (CLOUD). Tests, fixtures, galleries, vendored and generated files are left
out (SKIP, NOW's now_code_shape TEST and VENDOR rules), and so are the few files NOT_CLOUD names with the reason
they are not Cloud.

--check is the guard (cmux-next guards, tooling-tests step tt-swift-cloud-http): it fails when a counted file is not
in ALLOW (scripts/cmux-next/swift-cloud-http-allow.txt, today's files that are still being moved), so no new Swift
file can build a Cloud request, and when an allowed file no longer counts, so the pull request that moves a file to
Rust also drops it from the list. The list only shrinks; the goal is an empty one. Leo, on cmux-next: "we should be
able to just do a whole lot more in cmux-next since we're on the branch".
Standard library only; run it with `python3 -I`.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

SOURCES = "Packages/macOS/CmuxNext/Sources"
METHOD_VERSION = 1
SKIP = re.compile(r"(^|/)(Tests?|tests?|UITests|fixtures|benches|bench|gallery|vendor|Vendor|third_party|generated|"
                  r"Generated)(/|$)|\+Generated\.swift$")
TOKENS = re.compile(r'"""[\s\S]*?"""|"(?:\\.|[^"\\\n])*"|//[^\n]*|/\*[\s\S]*?\*/')
REQUEST = re.compile(r"\bURLRequest\s*\(|\.webSocketTask\s*\(|\bURLSessionWebSocketTask\b"
                     r"|\.(?:data|upload|download|bytes)\s*\(\s*for\s*:")
CLOUD = re.compile(r"\b(?:CloudConfiguration|CloudAuth|CloudAccessToken|CloudAPIClient|CloudOwnerAPIClient|"
                   r"cloudAPIBase|apiBaseURL|cloudBaseURL)\b|cmux\.dev|cloud-api")
ALLOW = "scripts/cmux-next/swift-cloud-http-allow.txt"
# Files that name cmux.dev but talk to no Cloud API, each with why.
NOT_CLOUD = {
    "Packages/macOS/CmuxNext/Sources/CmuxNextUpdater/ReleasePushListener.swift":
        "the updater's release-feed socket on the cmux-presence Worker, not a Cloud API",
}


def code(text: str) -> str:
    """TEXT with comments blanked and strings kept."""
    return TOKENS.sub(lambda m: m.group(0) if m.group(0).startswith('"') else "", text)


def count(root: Path) -> dict:
    files = []
    base = root / SOURCES
    for path in sorted(base.rglob("*.swift")):
        rel = path.relative_to(root).as_posix()
        if SKIP.search(rel[len(SOURCES) + 1:]) or rel in NOT_CLOUD:
            continue
        text = code(path.read_text(encoding="utf-8", errors="replace"))
        sites = len(REQUEST.findall(text))
        if sites and ("Cloud" in rel[len(SOURCES):] or CLOUD.search(text)):
            files.append({"path": rel, "sites": sites, "bytes": path.stat().st_size})
    files.sort(key=lambda f: (-f["bytes"], f["path"]))
    return {"method": "swift-cloud-http", "method_version": METHOD_VERSION, "http_files": len(files),
            "http_sites": sum(f["sites"] for f in files), "http_bytes": sum(f["bytes"] for f in files),
            "files": files}


def allowed(root: Path) -> list[str]:
    """ALLOW's paths (under SOURCES), comments and blank lines dropped; a missing file allows nothing."""
    try:
        text = (root / ALLOW).read_text(encoding="utf-8")
    except FileNotFoundError:
        return []
    return [line.split("#", 1)[0].strip() for line in text.splitlines() if line.split("#", 1)[0].strip()]


def check(root: Path, got: dict) -> list[str]:
    """Problems with GOT against ALLOW: a counted file it does not list, a listed file that no longer counts."""
    allow = allowed(root)
    counted = {f["path"][len(SOURCES) + 1:]: f for f in got["files"]}
    problems = []
    for rel, f in sorted(counted.items()):
        if rel not in allow:
            problems.append(f"{SOURCES}/{rel}: builds {f['sites']} Cloud HTTP or WebSocket request(s) in Swift. "
                            f"Call the Rust app server's cloud.* method instead (add one in cmux-tui if none fits); "
                            f"a file that talks to no Cloud API goes in NOT_CLOUD in {Path(__file__).name} with why.")
    for rel in allow:
        if rel not in counted:
            problems.append(f"{ALLOW}: {rel} no longer builds a Cloud request (or is gone): delete its line.")
    seen = set()
    for rel in allow:
        if rel in seen:
            problems.append(f"{ALLOW}: {rel} is listed twice.")
        seen.add(rel)
    return problems


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--repo", default=str(Path(__file__).resolve().parents[2]))
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--check", action="store_true",
                        help=f"fail on a counted file {ALLOW} does not list, or a listed one that no longer counts")
    args = parser.parse_args(argv)
    root = Path(args.repo)
    if not (root / SOURCES).is_dir():
        print(f"swift-cloud-http: {root / SOURCES} is not a directory", file=sys.stderr)
        return 2
    got = count(root)
    if args.check:
        problems = check(root, got)
        for line in problems:
            print(f"swift-cloud-http: {line}", file=sys.stderr)
        if problems:
            return 1
        print(f"swift-cloud-http: ok, {got['http_files']} allowed files left ({ALLOW})")
        return 0
    if args.json:
        print(json.dumps(got, separators=(",", ":")))
        return 0
    for f in got["files"]:
        print(f"{f['sites']:3d} {f['bytes']:7d} {f['path']}")
    print(f"{got['http_files']} files, {got['http_sites']} request sites, {got['http_bytes']} bytes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
