#!/usr/bin/env python3
"""Fail if a file in the test targets constructs a window.

Only cmuxTests/TestWindowFactory.swift may. A window built anywhere else has
`isReleasedWhenClosed = true`, and closing it then releases memory ARC already owns, which
segfaults the test host and loses every verdict pending in it.

The check reads two things, because neither is sufficient alone:

  The source, which sees `NSWindow()`. The argument-less form emits the selector `init`, which is
  too generic to look for in a binary.

  The compiled object files, when a build is present, which see what the source cannot. The
  compiler has already resolved aliases, subclasses, wrapper types and cross-file factories, so a
  construction reduces to whether the object file references NSWindow's designated initializer.

Neither half asks whether a window is closed or whether it sets the flag. The question is only
whether a file constructs a window, so there is no state to get wrong.

Usage:
  scripts/lint-test-window-construction.py                  # source check
  scripts/lint-test-window-construction.py --objects DIR    # also check compiled object files
  scripts/lint-test-window-construction.py --write          # rewrite the allowlist from the tree
  scripts/lint-test-window-construction.py --self-test
"""

from __future__ import annotations

import re
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
ALLOWLIST = REPO / "scripts" / "lint-test-window-construction-allowlist.tsv"
SANCTIONED = "cmuxTests/TestWindowFactory.swift"
DESIGNATED_INIT = "initWithContentRect:styleMask:backing:defer:"

# Reuse the type resolution and comment handling from the sibling check rather than restate them.
_sibling = REPO / "scripts" / "lint-test-window-release.py"
_spec = __import__("importlib.util", fromlist=["util"]).spec_from_file_location("release_check", _sibling)
_release = __import__("importlib.util", fromlist=["util"]).module_from_spec(_spec)
_spec.loader.exec_module(_release)


def constructing_lines(path: Path) -> list[tuple[int, str]]:
    """Lines in this file that construct a window, by any spelling of any window type."""
    text = path.read_text(encoding="utf-8", errors="replace")
    types = _release.local_window_types(text)
    alternation = "|".join(sorted(re.escape(t) for t in types))
    # `NSWindow(`, `NSWindow.init(`, `NSWindow()` — all of them.
    pattern = re.compile(rf"\b({alternation})\s*(?:\.init)?\s*\(")
    hits = []
    for index, raw in enumerate(text.splitlines()):
        line = _release.strip_comment(raw)
        stripped = line.strip()
        if not stripped or stripped.startswith("*"):
            continue
        match = pattern.search(line)
        if match:
            hits.append((index + 1, match.group(1)))
    return hits


def source_offenders() -> dict[str, list[tuple[int, str]]]:
    out: dict[str, list[tuple[int, str]]] = {}
    for root in _release.test_roots():
        for path in sorted(root.rglob("*.swift")):
            rel = str(path.relative_to(REPO))
            if rel == SANCTIONED:
                continue
            hits = constructing_lines(path)
            if hits:
                out[rel] = hits
    return out


def object_offenders(objects_dir: Path) -> list[str]:
    """Object files that reference the designated initializer.

    The sanctioned factory is expected to; nothing else in the test target should.
    """
    offenders = []
    sanctioned_stem = Path(SANCTIONED).stem
    for obj in sorted(objects_dir.rglob("*.o")):
        if obj.stem == sanctioned_stem:
            continue
        # Read bytes: an object file's string table is not valid UTF-8, and decoding it throws.
        try:
            dump = subprocess.run(
                ["strings", "-a", str(obj)], capture_output=True, timeout=120
            ).stdout
        except (OSError, subprocess.SubprocessError):
            continue
        if DESIGNATED_INIT.encode() in dump:
            offenders.append(obj.stem)
    return offenders


def read_allowlist() -> set[str]:
    if not ALLOWLIST.exists():
        return set()
    return {
        line.strip()
        for line in ALLOWLIST.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.startswith("#")
    }


def write_allowlist(paths: list[str]) -> int:
    head = [
        "# Files in the test targets that still construct their own windows.",
        "# The sanctioned factory is cmuxTests/TestWindowFactory.swift; everything here predates it.",
        "# This list may shrink and never grow. Migrate a file to TestWindow.make(...) and drop its",
        "# line. A file not listed here may not construct a window at all.",
        "# Regenerate with: scripts/lint-test-window-construction.py --write",
    ]
    body = sorted(set(paths))
    ALLOWLIST.write_text("\n".join(head + body) + "\n", encoding="utf-8")
    return len(body)


def self_test() -> int:
    """Check the source rule against files whose answers are known by construction."""
    cases = {
        "plain": ("let w = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)", 1),
        "argument_less": ("let w = NSWindow()", 1),
        "init_spelling": ("let w = NSWindow.init(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)", 1),
        "panel": ("let p = NSPanel()", 1),
        "commented_out": ("// let w = NSWindow()", 0),
        "cast_only": ("let w = thing as? NSWindow\nw?.close()", 0),
        "type_only": ("var window: NSWindow?", 0),
        "factory_call": ("let w = TestWindow.make()", 0),
        "alias": ("typealias ProbeWindow = NSWindow\nlet w = ProbeWindow()", 1),
        "subclass": ("final class SubWindow: NSWindow {}\nlet w = SubWindow()", 1),
    }
    failures = 0
    with tempfile.TemporaryDirectory() as directory:
        for name, (source, want) in cases.items():
            path = Path(directory) / f"{name}.swift"
            path.write_text("import AppKit\n" + source + "\n", encoding="utf-8")
            got = len(constructing_lines(path))
            ok = (got > 0) == (want > 0)
            failures += 0 if ok else 1
            print(f"  {'ok  ' if ok else 'FAIL'} {name}: constructs={got} (want {'yes' if want else 'no'})")
    print("self-test passed" if not failures else f"self-test FAILED ({failures})")
    return 1 if failures else 0


def main() -> int:
    if "--self-test" in sys.argv:
        return self_test()

    offenders = source_offenders()
    if "--write" in sys.argv:
        count = write_allowlist(list(offenders))
        print(f"wrote {ALLOWLIST.relative_to(REPO)}: {count} files still construct their own windows")
        return 0

    allowed = read_allowlist()
    new = {path: hits for path, hits in offenders.items() if path not in allowed}
    stale = allowed - set(offenders)

    code = 0
    if new:
        print("A test file constructs its own window. Use the sanctioned factory instead.\n")
        for path, hits in sorted(new.items()):
            for line, kind in hits:
                print(f"  {path}:{line}: constructs {kind}")
        print(
            "\n    let window = TestWindow.make()                 // or .make(contentRect:styleMask:)\n"
            "    let window = TestWindow.hosting(someView)\n"
            "\nThe factory clears isReleasedWhenClosed, so closing the window no longer releases\n"
            "memory ARC still owns and takes the test host down with it. See\n"
            "cmuxTests/TestWindowFactory.swift for why that matters more than a failed test."
        )
        code = 1

    if stale and not new:
        print("These files no longer construct a window. Drop them from the allowlist:\n")
        for path in sorted(stale):
            print(f"  {path}")
        print("\n  scripts/lint-test-window-construction.py --write")
        code = 1

    objects_flag = "--objects"
    if objects_flag in sys.argv:
        index = sys.argv.index(objects_flag)
        if index + 1 < len(sys.argv):
            objects_dir = Path(sys.argv[index + 1])
            if objects_dir.is_dir():
                # An object file is named for its Swift file, so the allowlist maps straight over.
                allowed_stems = {Path(path).stem for path in allowed}
                bad = [stem for stem in object_offenders(objects_dir) if stem not in allowed_stems]
                if bad:
                    print(
                        "\nCompiled object files construct a window outside the sanctioned factory.\n"
                        "The source did not show it, so it is reached through an alias, a subclass,\n"
                        "or a factory in another file:\n"
                    )
                    for stem in sorted(bad):
                        print(f"  {stem}.o")
                    code = 1
                else:
                    print(f"objects: clean ({objects_dir})")
            else:
                print(f"objects: {objects_dir} is not a directory; skipped", file=sys.stderr)

    if code == 0:
        print(f"OK: only {SANCTIONED} constructs windows ({len(allowed)} files still allowlisted)")
    return code


if __name__ == "__main__":
    sys.exit(main())
