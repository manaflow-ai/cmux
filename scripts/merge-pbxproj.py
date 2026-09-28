#!/usr/bin/env python3
"""Git merge driver for Xcode project files (project.pbxproj).

No target in this project is filesystem-synchronized, so every added source
file needs four explicit pbxproj entries: a PBXBuildFile, a PBXFileReference,
a child in its group, and a member of the target's Sources phase. Two branches
that each add a different file therefore append to the same four regions and
collide positionally, even though the entries are disjoint. That is the single
most common conflict in this repository and never a semantic disagreement.

The three-way union this performs is the one scripts/ci/catch_up_pr.py already
applies during PR catch-up, reused here rather than reimplemented. Exposing it
as a merge driver is what makes it available to everyone else: a local `git
merge main`, a rebase, and pull requests from forks, which catch-up refuses by
design and which consequently re-conflict on this file every time main moves.

It is deliberately conservative. A hunk is merged only when both sides purely
added distinct lines; if either side changed or removed a line the merge is
abandoned and git writes normal conflict markers. The union is then checked for
repeated object ids and handed to scripts/normalize-pbxproj.py, which rejects
broken syntax and duplicate entries, so a result that would not open in Xcode
is never written.

Usage (git passes these): merge-pbxproj.py %O %A %B %P
"""
from __future__ import annotations

import importlib.util
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CATCH_UP = ROOT / "scripts" / "ci" / "catch_up_pr.py"
NORMALIZER = ROOT / "scripts" / "normalize-pbxproj.py"


def load_union():
    """The union used by PR catch-up, so both paths resolve conflicts identically."""
    spec = importlib.util.spec_from_file_location("merge_pbxproj_catch_up", CATCH_UP)
    if spec is None or spec.loader is None:
        raise ImportError(f"cannot load {CATCH_UP}")
    module = importlib.util.module_from_spec(spec)
    # catch_up_pr.py declares dataclasses, and @dataclass resolves a field's
    # type through sys.modules[cls.__module__], so the module has to be
    # registered before it is executed or the decorator raises.
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module.union_pbxproj


def normalized(text: str, name: str) -> str | None:
    """The merged text after scripts/normalize-pbxproj.py, or None if it rejects it.

    The normalizer rewrites in place and reports broken syntax or duplicate
    entries, so it runs on a temporary copy: a rejected union must never leave
    a half-written project file behind.
    """
    if not NORMALIZER.exists():
        # A worktree without the normalizer still gets the union; the pre-commit
        # hook and CI check the file again before it can land.
        return text
    with tempfile.TemporaryDirectory() as directory:
        scratch = Path(directory) / "project.pbxproj"
        scratch.write_text(text, encoding="utf-8")
        completed = subprocess.run(
            [sys.executable, str(NORMALIZER), str(scratch)],
            capture_output=True,
            text=True,
            check=False,
        )
        if completed.returncode != 0:
            lines = (completed.stderr or completed.stdout).strip().splitlines()
            detail = lines[-1] if lines else f"exit {completed.returncode}"
            print(f"merge-pbxproj: {name}: normalizer rejected the union ({detail})",
                  file=sys.stderr)
            return None
        return scratch.read_text(encoding="utf-8")


def main(argv: list[str]) -> int:
    if len(argv) < 4:
        print("usage: merge-pbxproj.py %O %A %B [%P]", file=sys.stderr)
        return 2
    base_path, ours_path, theirs_path = (Path(p) for p in argv[1:4])
    name = argv[4] if len(argv) > 4 else str(ours_path)
    try:
        union_pbxproj = load_union()
        merged = union_pbxproj(
            base_path.read_text(encoding="utf-8"),
            ours_path.read_text(encoding="utf-8"),
            theirs_path.read_text(encoding="utf-8"),
        )
    except ValueError as error:
        print(f"merge-pbxproj: {name}: {error}; falling back", file=sys.stderr)
        return 1
    except (OSError, ImportError, AttributeError, UnicodeDecodeError) as error:
        print(f"merge-pbxproj: {name}: cannot merge ({error}); falling back", file=sys.stderr)
        return 1
    settled = normalized(merged, name)
    if settled is None:
        return 1
    ours_path.write_text(settled, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
