#!/usr/bin/env python3
"""React pages are listed (plans/cmux-next/language-layers.md).

Native chrome and Home are Swift; only the agent chat pane and full tab pages are React. Every
directory under webviews/src/pages/ needs a row in scripts/cmux-next/react-pages.tsv:

  page    a full tab page (question 6 of the decision test)
  debt    native chrome or Home drawn in React today; it goes back to Swift
  review  hosted inside native chrome, not judged yet

Fails when a page directory has no row, when a row's kind is unknown, and, with --base, when a row
that is new since the base is not `page` (no change adds debt). A row whose directory is gone is a
note: delete the row.

  python3 scripts/cmux-next/check-react-pages.py [--base REV] [ROOT]
"""
from __future__ import annotations

import argparse
import pathlib
import subprocess
import sys

LIST = "scripts/cmux-next/react-pages.tsv"
PAGES = "webviews/src/pages"
KINDS = ("page", "debt", "review")
# Not pages: code the pages share.
SHARED = {"shared"}


def rows(text: str) -> dict[str, tuple[str, str]]:
    """Directory name -> (kind, why) for each row of the list's text."""
    found: dict[str, tuple[str, str]] = {}
    for line in text.splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        parts = line.split("\t")
        name = parts[0].strip()
        kind = parts[1].strip() if len(parts) > 1 else ""
        why = parts[2].strip() if len(parts) > 2 else ""
        found[name] = (kind, why)
    return found


def base_rows(root: pathlib.Path, base: str) -> dict[str, tuple[str, str]] | None:
    """The list at `base`, or None when the base has no list (the first commit of the rule)."""
    shown = subprocess.run(["git", "-C", str(root), "show", f"{base}:{LIST}"], capture_output=True, text=True)
    return rows(shown.stdout) if shown.returncode == 0 else None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("root", nargs="?", default=".")
    parser.add_argument("--base", help="the revision this change is judged against")
    args = parser.parse_args()
    root = pathlib.Path(args.root).resolve()

    try:
        listed = rows((root / LIST).read_text())
    except OSError:
        print(f"REACT-PAGES: {LIST} is missing", file=sys.stderr)
        return 1
    pages = root / PAGES
    present = sorted(p.name for p in pages.iterdir() if p.is_dir() and p.name not in SHARED) if pages.is_dir() else []

    findings: list[str] = []
    for name in present:
        if name not in listed:
            findings.append(f"{PAGES}/{name} has no row in {LIST}: answer the decision test "
                            f"(plans/cmux-next/language-layers.md); native chrome and Home are Swift")
    for name, (kind, why) in sorted(listed.items()):
        if kind not in KINDS:
            findings.append(f"{LIST}: {name} has kind '{kind}'; use one of {', '.join(KINDS)}")
        elif not why:
            findings.append(f"{LIST}: {name} has no reason")
        if name not in present:
            print(f"note: {LIST}: {name} has no directory now; delete its row", file=sys.stderr)

    before = base_rows(root, args.base) if args.base else None
    if before is not None:
        for name, (kind, _) in sorted(listed.items()):
            if name not in before and kind in ("debt", "review"):
                findings.append(f"{LIST}: {name} is a new '{kind}' row since {args.base}; a change adds no "
                                f"React page for native chrome or Home (build it in Swift)")

    if findings:
        print("REACT-PAGES: the layer rule fails:", file=sys.stderr)
        for finding in findings:
            print(f"  {finding}", file=sys.stderr)
        return 1
    count = {kind: sum(1 for k, _ in listed.values() if k == kind) for kind in KINDS}
    print(f"REACT-PAGES: ok, {count['page']} page(s), {count['debt']} debt, {count['review']} to review")
    return 0


if __name__ == "__main__":
    sys.exit(main())
