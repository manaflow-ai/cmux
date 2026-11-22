#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""The cmux NEXT app asks macOS for no privacy grant: the Screen Sharing helper holds them all.

Leo, 2026-11-22: "who's gonna walk over and click allow on a headless mac mini, or a remote
macbook??? stop having that shit."

One stably signed bundle holds every TCC grant (Screen Recording, Accessibility, Input Monitoring,
PostEvent): `<app>.app/Contents/Library/<app> Screen Sharing.app` (plans/cmux-next/screen-sharing-helper.md).
A call below from anything else makes macOS list that binary too ("cmux NIGHTLY", or a bare "cmux"
with a terminal icon), prompt for it, and relaunch it on a grant. This fails when one appears in:

- the NEXT app's Swift sources (Packages/macOS/CmuxNext/Sources), outside `#if DEBUG` and
  `#if DEBUG || CMUX_BENCH_HOOKS` code (a NIGHTLY or Release has neither: check-no-bench-hooks.sh);
- the Rust crates under cmux-tui/crates that the app's other bundled binaries (`cmux`, `cmux-tui-host`,
  acpmux) link, outside the helper's own code (``RUST_HELPER_ONLY``), and when one of those binaries
  turns on a helper-only feature (``check_cargo``).

A feature that needs a grant asks the helper (`GrantHolding`, CmuxNextComputerUse).

    scripts/cmux-next/check-app-asks-no-grant.py [--root DIR]

Exit 0 when clean, 1 with every hit named (file:line, the call, what to do).
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path

# The calls that read, ask for or use a TCC grant (a capture that prompts counts).
BANNED = (
    "CGRequestScreenCaptureAccess",
    "CGPreflightScreenCaptureAccess",
    "AXIsProcessTrustedWithOptions",
    "AXIsProcessTrusted",
    "CGRequestPostEventAccess",
    "CGPreflightPostEventAccess",
    "CGRequestListenEventAccess",
    "CGPreflightListenEventAccess",
    "IOHIDRequestAccess",
    "IOHIDCheckAccess",
    "SCShareableContent",
    "CGEventTapCreate",
)
SWIFT_BANNED = re.compile(r"\b(" + "|".join(BANNED) + r")\b|\bCGEvent\.tapCreate\b")
RUST_BANNED = re.compile(r"\b(" + "|".join(BANNED) + r")\b")

# The one ScreenCaptureKit content that needs no Screen Recording consent (macOS 14.4): this
# process's own windows (`cmux window screenshot`).
SWIFT_NO_CONSENT = re.compile(r"\bSCShareableContent\.(currentProcess|getCurrentProcessShareableContent)\b")

SWIFT_ROOT = Path("Packages/macOS/CmuxNext/Sources")

# Hits an open pull request removes, each with that PR. Delete a row when its PR lands (a stale row
# is reported, never failed, so the landing PR does not have to know about this file).
SWIFT_PENDING = {
    "CmuxNextMacScreen/MacScreenShareHost.swift": "#49826 and #49829 (the helper asks; the shortcut tap moves)",
    "CmuxNextMacScreen/MacScreenSystemShortcuts.swift": "#49829 (Send System Shortcuts tap in the helper)",
    "CmuxNextRemoteView/Input/RemoteSystemShortcutTap.swift": "#49829 (Send System Shortcuts tap in the helper)",
    "CmuxNextMacScreen/CmuxRemote/CmuxRemoteService.swift": "#49875 (cmux Remote deleted)",
}

RUST_ROOT = Path("cmux-tui/crates")
# Code that runs only in the Screen Sharing helper on a Mac, with the reason.
RUST_HELPER_ONLY = {
    "cmux-rd-host/": "the helper's crate; on a Mac its grant commands refuse outside the helper build "
    "(`mac_helper_only_refusal`, src/lib.rs) and its grant modes are behind `computer-use`",
    "cmux-computer-use/src/platform/macos/": "compiled only with the `desktop` feature, which on a Mac "
    "only the helper turns on (cmux-rd-host's `computer-use`)",
}
# The bundled non-helper binaries' crates: on a Mac none may turn on a helper-only feature.
RUST_BUNDLED = ("cmux-tui", "cmux-tui-core", "acpmux", "cmux-tui-host")
HELPER_FEATURES = {"cmux-rd-host": "computer-use", "cmux-computer-use": "desktop"}


@dataclass(frozen=True)
class Hit:
    path: str
    line: int
    call: str
    why: str

    def __str__(self) -> str:
        return f"{self.path}:{self.line}: {self.call}: {self.why}"


def strip_comments(lines: list[str]) -> list[str]:
    """Each line with `//` and `/* */` comments blanked (string literals are not parsed: a banned
    name inside one is still a hit, which is what a dlsym lookup by name looks like)."""
    out, in_block = [], False
    for line in lines:
        text, i, kept = line, 0, []
        while i < len(text):
            if in_block:
                end = text.find("*/", i)
                if end < 0:
                    i = len(text)
                    break
                in_block, i = False, end + 2
                continue
            if text.startswith("//", i):
                break
            if text.startswith("/*", i):
                in_block, i = True, i + 2
                continue
            kept.append(text[i])
            i += 1
        out.append("".join(kept))
    return out


_DEBUG_CONDITIONS = {"DEBUG", "DEBUG || CMUX_BENCH_HOOKS", "CMUX_BENCH_HOOKS || DEBUG", "CMUX_BENCH_HOOKS"}


def debug_only_lines(lines: list[str]) -> set[int]:
    """The 1-based lines inside a branch that only DEBUG or bench builds compile."""
    stack: list[bool] = []  # per open #if: whether the current branch is debug-only
    debug: set[int] = set()
    for number, raw in enumerate(lines, 1):
        line = raw.strip()
        if line.startswith("#if "):
            stack.append(line[4:].strip() in _DEBUG_CONDITIONS)
        elif line.startswith("#elseif "):
            if stack:
                stack[-1] = line[8:].strip() in _DEBUG_CONDITIONS
        elif line.startswith("#else"):
            if stack:
                stack[-1] = False
        elif line.startswith("#endif"):
            if stack:
                stack.pop()
        elif any(stack):
            debug.add(number)
    return debug


def check_swift(root: Path) -> tuple[list[Hit], list[str]]:
    hits, used_pending = [], set()
    base = root / SWIFT_ROOT
    for path in sorted(base.rglob("*.swift")):
        rel = path.relative_to(base).as_posix()
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
        code = strip_comments(lines)
        debug = debug_only_lines(lines)
        for number, text in enumerate(code, 1):
            if number in debug:
                continue
            for match in SWIFT_BANNED.finditer(SWIFT_NO_CONSENT.sub("", text)):
                if rel in SWIFT_PENDING:
                    used_pending.add(rel)
                    continue
                hits.append(Hit((SWIFT_ROOT / rel).as_posix(), number, match.group(0),
                                "the NEXT app never asks macOS for a grant; ask the Screen Sharing helper "
                                "(GrantHolding, CmuxNextComputerUse) or put it under #if DEBUG"))
    stale = [f"{rel}: {why}" for rel, why in SWIFT_PENDING.items() if rel not in used_pending]
    return hits, stale


def rust_test_file(rel: str) -> bool:
    name = rel.rsplit("/", 1)[-1]
    return "/tests/" in f"/{rel}" or "/benches/" in f"/{rel}" or "/examples/" in f"/{rel}" or name.endswith("_tests.rs") or name == "tests.rs"


def check_rust(root: Path) -> list[Hit]:
    hits = []
    base = root / RUST_ROOT
    for path in sorted(base.rglob("*.rs")):
        rel = path.relative_to(base).as_posix()
        if "/target/" in f"/{rel}" or rust_test_file(rel) or any(rel.startswith(p) for p in RUST_HELPER_ONLY):
            continue
        code = strip_comments(path.read_text(encoding="utf-8", errors="replace").splitlines())
        for number, text in enumerate(code, 1):
            for match in RUST_BANNED.finditer(text):
                hits.append(Hit((RUST_ROOT / rel).as_posix(), number, match.group(0),
                                "a bundled cmux binary never asks macOS for a grant; run it in the Screen "
                                "Sharing helper (cmux-rd-host) instead"))
    return hits


def section_applies_to_mac(header: str) -> bool:
    if header in ("[dependencies]", "[build-dependencies]"):
        return True
    if not header.startswith("[target."):
        return False
    if 'not(target_os = "macos")' in header:
        return False
    return "macos" in header or "cfg(unix)" in header or "all(unix" in header


def check_cargo(root: Path) -> list[Hit]:
    """No bundled non-helper crate turns on a helper-only feature where it builds for a Mac."""
    hits = []
    for crate in RUST_BUNDLED:
        manifest = root / RUST_ROOT / crate / "Cargo.toml"
        if not manifest.exists():
            continue
        header = ""
        for number, line in enumerate(manifest.read_text(encoding="utf-8").splitlines(), 1):
            stripped = line.split("#", 1)[0].strip()
            if stripped.startswith("["):
                header = stripped
                continue
            if not section_applies_to_mac(header):
                continue
            for dep, feature in HELPER_FEATURES.items():
                if re.match(rf"^{re.escape(dep)}\s*=", stripped) and re.search(rf'"{re.escape(feature)}"', stripped):
                    hits.append(Hit((RUST_ROOT / crate / "Cargo.toml").as_posix(), number, f'{dep} "{feature}"',
                                    f"{crate} ships in the app; only the Screen Sharing helper may build {dep} "
                                    f"with {feature} on a Mac"))
    return hits


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    args = parser.parse_args(argv)
    swift_hits, stale = check_swift(args.root)
    hits = swift_hits + check_rust(args.root) + check_cargo(args.root)
    for row in stale:
        print(f"check-app-asks-no-grant: stale pending row (its PR landed; delete it): {row}")
    if hits:
        print("check-app-asks-no-grant: the NEXT app or a bundled binary asks macOS for a privacy grant.", file=sys.stderr)
        print("Only the Screen Sharing helper may (plans/cmux-next/screen-sharing-helper.md).", file=sys.stderr)
        for hit in hits:
            print(f"  {hit}", file=sys.stderr)
        return 1
    print("check-app-asks-no-grant: no NEXT app or bundled binary asks macOS for a privacy grant")
    return 0


if __name__ == "__main__":
    sys.exit(main())
