#!/usr/bin/env python3
"""No new inline test modules in cmux-tui's Rust (#38898's convention; cmuxterm-hq goals/next-code-shrinks.md).

A unit test module lives in its own file, declared beside the code:

    #[cfg(test)]
    #[path = "foo_tests.rs"]
    mod tests;

not as an inline `#[cfg(test)] mod tests { .. }` block. Inline blocks make a source file read as larger than its
code (the godfile caps, NOW's code_shape.source_mb, which leaves `_tests.rs` files out), and moves of them never
landed while new ones kept arriving: 4.85 MB on 2026-11-09, 6.5 MB on 2026-11-20.

Prints one line per top-level inline `#[cfg(test)] mod NAME {` block in a Rust source file under cmux-tui/ (not
a `_tests.rs`/`tests.rs` file, nor a file under tests/, benches/ or examples/) and exits 1 when there is any.
The pre-push gate runs it on the base and head copies of the files a push changes and refuses only the lines the
push adds, so blocks already on the base pass until their own move. Fix: put the module in its own file;
`scripts/cmux-next/move-inline-tests.py --apply FILE` does it for a block at the end of a file.

Usage: scripts/cmux-next/check-no-inline-tests.py [repo-root]
"""
import re
import subprocess
import sys
from pathlib import Path

SCOPE = "cmux-tui/"
SKIP = re.compile(r"(^|/)(tests?|benches|examples)/|(^|/)tests?\.rs$|_tests?\.rs$")
BLOCK = re.compile(r"^#\[cfg\(test\)\]\n(?:#\[[^\n]*\]\n)*(?:pub(?:\([^)\n]*\))? )?mod (\w+) \{", re.M)


def files(root: Path) -> list[str]:
    try:
        out = subprocess.run(["git", "-C", str(root), "ls-files", "-z", "--", SCOPE], capture_output=True,
                             check=True).stdout.decode()
        listed = [p for p in out.split("\0") if p]
    except (OSError, subprocess.CalledProcessError):
        listed = []
    if not listed:  # not a git checkout (the gate's exported trees may have no index): walk the folder
        listed = [str(p.relative_to(root)) for p in (root / SCOPE).rglob("*.rs")] if (root / SCOPE).is_dir() else []
    return sorted(p for p in listed if p.endswith(".rs") and not SKIP.search(p))


def main(argv: list[str]) -> int:
    root = Path(argv[1] if len(argv) > 1 else ".")
    found = 0
    for rel in files(root):
        try:
            text = (root / rel).read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for m in BLOCK.finditer(text):
            print(f"{rel}: inline #[cfg(test)] mod {m.group(1)} {{ .. }}; move it to its own _tests.rs file "
                  f"(scripts/cmux-next/move-inline-tests.py --apply {rel})")
            found += 1
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
