#!/usr/bin/env python3
"""check-webviews-bun-version.test.sh's pre-commit half (#47964): the hook's Bun bootstrap asks the trusted reader's
compatibility predicate and warns when it uses a newer compatible Bun.

Python so the hook is read as text: a shell test that names scripts/git-hooks/pre-commit reads as running it, and the
hook's own `git ls-files` then makes the test a whole-tree command (tests/test_check_pool_whole_baseline.py).
"""
import sys
from pathlib import Path

HOOK = "scripts/git-hooks/pre-commit"
NEEDLES = (
    ('"$BUN_VERSION_READER" --compatible "$have" "$want"', "pre-commit must use the trusted reader's compatibility predicate"),
    ("newer same-major release is compatible", "pre-commit must warn when it uses a newer compatible Bun"),
)

text = (Path(sys.argv[1]) / HOOK).read_text(encoding="utf-8")
missing = [why for needle, why in NEEDLES if needle not in text]
if missing:
    sys.exit("FAIL: " + "; ".join(missing))
