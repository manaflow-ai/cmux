#!/usr/bin/env python3
"""Fail if a test window that gets closed can free itself first.

An NSWindow built in code is `isReleasedWhenClosed = true` by default, and `-[NSWindow close]`
autoreleases rather than releases. So a test that builds one and closes it drops the only
strong reference at scope exit, the object deallocs, and the pending pool pop releases freed
memory — SIGSEGV in `objc_release` under `objc_autoreleasePoolPop`, inside the test host. When
the host dies mid-run xcodebuild relaunches it and prints a summary covering only the last
launch, so every verdict still pending in the dead host is lost and the run can read as a pass.

Six pull requests have now fixed this one file at a time, each finding it again in a suite
nobody had run headless. Nothing fails when a new window goes in without the flag, so the next
suite to grow one starts the cycle over.

Two rules, because the two cases are not equally dangerous:

  A window that is closed, or that escapes to a caller who may close it, MUST set the flag.
  There is no baseline for this and no exception list — it is the crash.

  A window that is only ever built and abandoned cannot double-release, so those are counted
  in a baseline the check reads. A count may shrink but never grow. They are still worth
  fixing: an ordered-front window that is never closed leaks its appearance animation, which
  is what wedges a suite rather than crashing it.

The first rule is deliberately not satisfiable by the baseline. An earlier version of this
check counted both kinds together, and its baseline absorbed all eighteen closed-without-flag
sites — it reported OK over the exact bug it was written for.

Usage:
  scripts/lint-test-window-release.py            # check; exit 1 on a violation
  scripts/lint-test-window-release.py --write    # rewrite the baseline from the tree
  scripts/lint-test-window-release.py --self-test
"""

from __future__ import annotations

import re
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
BASELINE = REPO / "scripts" / "lint-test-window-release-baseline.tsv"
TEST_DIRS = ("cmuxTests", "cmuxUITests")


def test_roots() -> list[Path]:
    """Every directory whose windows this check governs.

    The app's two test targets, plus each package's Tests directory. Scoping to the app targets
    alone left six package test files building windows with nothing watching them, and one of those
    had already been fixed by hand — the pattern spreads to wherever the check is not looking.
    """
    roots = [REPO / name for name in TEST_DIRS]
    roots += sorted(
        path
        for path in (REPO / "Packages").glob("*/*/Tests")
        if path.is_dir()
    )
    return [path for path in roots if path.is_dir()]

CLASS_DECL = re.compile(r"^\s*(?:public|internal|private|fileprivate|final|@\w+|\s)*class\s+(\w+)\s*:\s*([^{]+)")
ALIAS_DECL = re.compile(r"^\s*(?:public|internal|private|fileprivate|\s)*typealias\s+(\w+)\s*=\s*([\w.]+)")
SKIP_DIRS = {".git", "node_modules", ".build", "DerivedData", "web", "ghostty", ".zig-cache"}


def strip_comment(line: str) -> str:
    """Drop a trailing // comment, leaving quoted slashes alone.

    Comments prove nothing. A commented-out flag line and a helper whose comment merely mentions
    the flag both read as "flagged" if the raw text is searched.
    """
    in_string = False
    index = 0
    while index < len(line) - 1:
        char = line[index]
        if char == "\\" and in_string:
            index += 2
            continue
        if char == '"':
            in_string = not in_string
        elif char == "/" and line[index + 1] == "/" and not in_string:
            return line[:index]
        index += 1
    return line


def swift_files() -> list[Path]:
    return [
        path
        for path in REPO.rglob("*.swift")
        if not any(part in SKIP_DIRS for part in path.parts)
    ]


def window_types() -> set[str]:
    """NSWindow, NSPanel, and every class or alias in the repo that resolves to one of them.

    Matching on a name ending in Window or Panel is wrong: `BrowserPanel` is a cmux view type
    whose `close()` has nothing to do with AppKit's, and treating it as a window produced dozens
    of false reports. The inheritance graph is the only reliable answer.

    Declarations are read from a form that joins continuation lines, because a base class written
    on the line after the colon is a style this repo already uses, and a line-at-a-time scan does
    not see it. Aliases count too, since `typealias ProbeWindow = NSWindow` builds a real NSWindow.
    """
    types = {"NSWindow", "NSPanel"}
    parents: dict[str, list[str]] = {}
    for path in swift_files():
        text = path.read_text(encoding="utf-8", errors="replace")
        # Join a declaration split across lines: `class X:` / `    NSWindow {`.
        joined = re.sub(r":\s*\n\s*", ": ", text)
        joined = re.sub(r",\s*\n\s*", ", ", joined)
        for line in joined.splitlines():
            match = CLASS_DECL.match(line)
            if match:
                bases = [b.strip() for b in match.group(2).split(",")]
                parents.setdefault(match.group(1), []).extend(bases)
                continue
            match = ALIAS_DECL.match(line)
            if match:
                parents.setdefault(match.group(1), []).append(match.group(2).split(".")[-1])
    # Resolve transitively; the graph is tiny, so iterate to a fixed point.
    changed = True
    while changed:
        changed = False
        for name, bases in parents.items():
            if name not in types and any(b in types for b in bases):
                types.add(name)
                changed = True
    return types


REPO_TYPES = window_types()


def patterns_for(types: set[str]) -> tuple[str, re.Pattern, re.Pattern]:
    """Build the construction patterns for a type set.

    The set is per file: a suite that declares its own NSWindow subclass or aliases one locally
    still builds a real window, and a repo-wide set computed once would miss a declaration that
    only exists in the file being read.
    """
    alternation = "|".join(sorted(re.escape(t) for t in types))
    return (
        alternation,
        re.compile(
            rf"(?:\b(?:let|var)\s+)?(\w+)\s*(?::[^=]+)?=\s*(?:try\s+)?\w*\(?\s*(?:{alternation})\s*(?:\.init)?\s*\("
        ),
        re.compile(rf"\b(?:{alternation})\s*(?:\.init)?\s*\("),
    )


TYPE, ASSIGNED, CONSTRUCTS = patterns_for(REPO_TYPES)
FUNC = re.compile(r"^(\s*)(?:@\w+\s+)*(?:private|internal|public|fileprivate|static|final|\s)*func\s+(\w+)")
RETURNS_WINDOW = re.compile(rf"->\s*[\w.]*(?:Window|Panel)[?!]?\s*\{{?\s*$")
FLAG = "isReleasedWhenClosed = false"
FLAG_RE = r"isReleasedWhenClosed\s*=\s*false\b"


class Site:
    def __init__(self, path: str, line: int, window: str, func: str):
        self.path, self.line, self.window, self.func = path, line, window, func
        self.closed = False
        self.escapes = False
        self.flagged = False
        self.ordered_front = False

    @property
    def key(self) -> str:
        return f"{self.path}\t{self.func}\t{self.window}"

    @property
    def must_flag(self) -> bool:
        return (self.closed or self.escapes) and not self.flagged


def function_blocks(lines: list[str]) -> list[tuple[str, int, int, str]]:
    """Return (name, start, end, signature) for each func, by indentation."""
    blocks = []
    for i, line in enumerate(lines):
        match = FUNC.match(line)
        if not match:
            continue
        indent, name = len(match.group(1)), match.group(2)
        end = len(lines)
        for j in range(i + 1, len(lines)):
            stripped = lines[j].strip()
            if not stripped:
                continue
            if len(lines[j]) - len(lines[j].lstrip()) <= indent and stripped.startswith("}"):
                end = j
                break
        blocks.append((name, i, end, line))
    return blocks


def enclosing(blocks, index: int) -> tuple[str, int, int, str]:
    """The innermost function containing this line."""
    best = ("<file scope>", 0, 1 << 30, "")
    for name, start, end, sig in blocks:
        if start <= index <= end and (end - start) < (best[2] - best[1]):
            best = (name, start, end, sig)
    return best


def local_window_types(text: str) -> set[str]:
    """Window classes and aliases declared in this file, resolved against the repo-wide set."""
    types = set(REPO_TYPES)
    joined = re.sub(r":\s*\n\s*", ": ", text)
    joined = re.sub(r",\s*\n\s*", ", ", joined)
    pending: dict[str, list[str]] = {}
    for line in joined.splitlines():
        match = CLASS_DECL.match(line)
        if match:
            pending.setdefault(match.group(1), []).extend(
                b.strip() for b in match.group(2).split(",")
            )
            continue
        match = ALIAS_DECL.match(line)
        if match:
            pending.setdefault(match.group(1), []).append(match.group(2).split(".")[-1])
    changed = True
    while changed:
        changed = False
        for name, bases in pending.items():
            if name not in types and any(b in types for b in bases):
                types.add(name)
                changed = True
    return types


def sites_in(path: Path, rel: str | None = None) -> list[Site]:
    text = path.read_text(encoding="utf-8", errors="replace")
    lines = text.splitlines()
    TYPE, ASSIGNED, CONSTRUCTS = patterns_for(local_window_types(text))
    blocks = function_blocks(lines)
    rel = rel or str(path)
    found: list[Site] = []

    # A helper that sets the flag on the window it is handed (or returns) makes every call
    # site safe, even though the flag is nowhere near the construction. `trackTestWindow` in
    # TerminalAndGhosttyTests is the repo's own version of this.
    flagging_helpers = {
        name
        for name, start, end, _ in blocks
        if any(re.search(FLAG_RE, strip_comment(b)) for b in lines[start : end + 1])
    }

    for i, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith("//") or stripped.startswith("*"):
            continue
        if not CONSTRUCTS.search(line):
            continue
        match = ASSIGNED.search(line)
        window = match.group(1) if match else "<inline>"
        name, start, end, sig = enclosing(blocks, i)
        site = Site(rel, i + 1, window, name)
        body = lines[start : end + 1]
        # Comments prove nothing. A commented-out flag line, or a helper whose comment merely
        # mentions the flag, both read as "flagged" against the raw text.
        code = [strip_comment(b) for b in body]

        # The flag may be set before the construction — a `trackTestWindow`-style wrapper sets it
        # on the way in — so the whole enclosing function is searched, and a wrapper counts only
        # if it sets the flag in code.
        wrapper = re.search(rf"=\s*(?:try\s+)?(\w+)\(\s*(?:{TYPE})\s*(?:\.init)?\s*\(", line)
        if wrapper and wrapper.group(1) in flagging_helpers:
            site.flagged = True
            found.append(site)
            continue

        if window == "<inline>":
            site.flagged = any(FLAG in b for b in code)
        else:
            w = re.escape(window)
            # The name needs a boundary in front of it: without one, `w` is a suffix of `preview`
            # and the flag set on `preview` marks `w` flagged.
            set_false = [
                j for j, b in enumerate(code) if re.search(rf"(?<![\w.]){w}\s*\.\s*{FLAG_RE}", b)
            ]
            set_true = [
                j
                for j, b in enumerate(code)
                if re.search(rf"(?<![\w.]){w}\s*\.\s*isReleasedWhenClosed\s*=\s*true\b", b)
            ]
            # Setting it back to true undoes the fix, so the last assignment is the one that counts.
            site.flagged = bool(set_false) and (not set_true or max(set_false) > max(set_true))

        if window != "<inline>":
            w = re.escape(window)
            # `window?.close()` is a close. The optional chain is already used in cmuxTests, and
            # a regex with a literal dot silently files those windows as never-closed.
            site.closed = any(
                re.search(rf"\b{w}\s*\??\.\s*(?:close|performClose)\b", b)
                or re.search(rf"\b\w*(?:close|teardown|dismiss)\w*\([^)]*\b{w}\b", b, re.I)
                # Handed to something that closes it later: `holder.window = held`.
                or re.search(rf"\.\w*[Ww]indow\w*\s*=\s*{w}\b", b)
                for b in code
            )
            # A window that leaves the function is closed somewhere this analysis cannot see, so
            # returning one is enough on its own — the return type may be a tuple, an optional, a
            # protocol, or carry a trailing comment, none of which a signature match catches.
            site.escapes = any(re.search(rf"\breturn\b[^/]*\b{w}\b", b) for b in code) or (
                bool(RETURNS_WINDOW.search(sig)) and window in sig
            )
            site.ordered_front = any(
                re.search(rf"\b{w}\s*\??\.\s*(?:makeKeyAndOrderFront|orderFront|orderFrontRegardless)\b", b)
                for b in code
            )
        else:
            site.closed = any(re.search(r"\??\.(?:close|performClose)\(", b) for b in code)
            site.escapes = bool(RETURNS_WINDOW.search(sig)) or any(
                re.search(r"^\s*return\b", b) for b in code
            )

        found.append(site)
    return found


def scan() -> list[Site]:
    out: list[Site] = []
    for root in test_roots():
        for path in sorted(root.rglob("*.swift")):
            out += sites_in(path, str(path.relative_to(REPO)))
    return out


def read_baseline() -> set[str]:
    if not BASELINE.exists():
        return set()
    return {
        line.rstrip("\n")
        for line in BASELINE.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.startswith("#")
    }


def write_baseline(abandoned: list[Site]) -> int:
    head = [
        "# Windows built in the test targets that are never closed, and do not clear",
        "# isReleasedWhenClosed. These cannot double-release, so they are recorded rather than",
        "# fixed. Keyed by file, function and variable so a fix and a new violation cannot",
        "# cancel out. A window that IS closed is never allowed here — see the script.",
        "# Regenerate with: scripts/lint-test-window-release.py --write",
    ]
    body = sorted({s.key for s in abandoned})
    BASELINE.write_text("\n".join(head + body) + "\n", encoding="utf-8")
    return len(body)


def report(must_flag: list[Site], new_abandoned: list[Site], stale: set[str]) -> int:
    if must_flag:
        print("A test window is closed while it can still free itself, which kills the host.\n")
        for s in sorted(must_flag, key=lambda s: (s.path, s.line)):
            how = "closed here" if s.closed else "returned to a caller that closes it"
            extra = " (ordered front, so it also carries a window animation)" if s.ordered_front else ""
            print(f"  {s.path}:{s.line}: {s.window} in {s.func}() — {how}{extra}")
        print(
            "\nSet the flag before the window is closed:\n"
            f"\n    window.{FLAG}\n"
            "\nThe local reference keeps it alive for the rest of the test, so closing it no\n"
            "longer releases memory ARC still owns. For a window that is ordered front, also\n"
            "set `window.animationBehavior = .none` so no appearance animation outlives it."
        )
        return 1

    if new_abandoned:
        print("New windows in the test targets do not clear isReleasedWhenClosed.\n")
        for s in sorted(new_abandoned, key=lambda s: (s.path, s.line)):
            print(f"  {s.path}:{s.line}: {s.window} in {s.func}()")
        print(
            f"\nSet `{FLAG}` on each. They are not closed today, so they cannot\n"
            "double-release yet — but the next edit that closes one turns it into a host death."
        )
        return 1

    if stale:
        print("Windows were fixed but the baseline still lists them:\n")
        for key in sorted(stale):
            print("  " + key.replace("\t", " :: "))
        print("\n  scripts/lint-test-window-release.py --write")
        return 1
    return 0


def self_test() -> int:
    """Check both rules against sources whose answers are known by construction."""
    cases = {
        "closed_no_flag": ("""
final class T {
    func a() {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        window.makeKeyAndOrderFront(nil)
        window.close()
    }
}
""", 1, 0),
        "closed_with_flag": ("""
final class T {
    func a() {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.close()
    }
}
""", 0, 0),
        "flag_set_before_by_wrapper": ("""
final class T {
    func track<W: NSWindow>(_ w: W) -> W {
        w.isReleasedWhenClosed = false
        return w
    }
    func a() {
        let window = track(NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false))
        window.close()
    }
}
""", 0, 0),
        "returned_to_caller": ("""
final class T {
    private func make() -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        return window
    }
}
""", 1, 0),
        "abandoned_only": ("""
final class T {
    func a() {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        window.makeKeyAndOrderFront(nil)
    }
}
""", 0, 1),
        "subclass_closed": ("""
final class T {
    func a() {
        let window = CmuxMainWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        window.performClose(nil)
    }
}
""", 1, 0),
        "controller_is_not_a_window": ("""
final class T {
    func a() {
        let c = NSWindowController(window: nil)
        c.close()
    }
}
""", 0, 0),
        "closed_via_helper_call": ("""
final class T {
    func a() {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        closeWindow(window)
    }
}
""", 1, 0),
    }
    failures = 0
    with tempfile.TemporaryDirectory() as directory:
        for name, (source, want_hard, want_soft) in cases.items():
            path = Path(directory) / f"{name}.swift"
            path.write_text(source, encoding="utf-8")
            sites = sites_in(path, name)
            hard = [s for s in sites if s.must_flag]
            soft = [s for s in sites if not s.must_flag and not s.flagged]
            ok = len(hard) == want_hard and len(soft) == want_soft
            failures += 0 if ok else 1
            print(
                f"  {'ok  ' if ok else 'FAIL'} {name}: must-flag={len(hard)} (want {want_hard}), "
                f"abandoned={len(soft)} (want {want_soft})"
            )
    print("self-test passed" if not failures else f"self-test FAILED ({failures})")
    return 1 if failures else 0


def main() -> int:
    if "--self-test" in sys.argv:
        return self_test()

    sites = scan()
    must_flag = [s for s in sites if s.must_flag]
    abandoned = [s for s in sites if not s.must_flag and not s.flagged]

    if "--write" in sys.argv:
        if must_flag:
            print("Refusing to record a closed window in the baseline. Fix these first:\n")
            for s in sorted(must_flag, key=lambda s: (s.path, s.line)):
                print(f"  {s.path}:{s.line}: {s.window} in {s.func}()")
            return 1
        written = write_baseline(abandoned)
        print(f"wrote {BASELINE.relative_to(REPO)}: {written} never-closed windows")
        return 0

    allowed = read_baseline()
    keys = {s.key for s in abandoned}
    code = report(
        must_flag,
        [s for s in abandoned if s.key not in allowed],
        allowed - keys,
    )
    if code == 0:
        print(
            f"OK: every closed test window clears the flag "
            f"({len(abandoned)} never-closed windows recorded)"
        )
    return code


if __name__ == "__main__":
    sys.exit(main())
