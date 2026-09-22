#!/usr/bin/env python3
"""Regression tests for scripts/ci/web_complexity_scope.py."""

from __future__ import annotations

import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import web_complexity_scope as scope  # noqa: E402

CHECKER = ROOT / "web" / "scripts" / "check-complexity.mjs"
FAILURES: list[str] = []


def check(name: str, condition: bool, detail: str = "") -> None:
    if condition:
        print(f"PASS: {name}")
    else:
        FAILURES.append(f"{name}{(': ' + detail) if detail else ''}")
        print(f"FAIL: {name}{(': ' + detail) if detail else ''}")


def run(rows: list[list[str]], limit: int = 3000) -> bool:
    needs_scan, _reason, _matched = scope.decide(rows, limit)
    return needs_scan


def mod(path: str) -> list[str]:
    return ["modified", path, ""]


def removed(path: str) -> list[str]:
    return ["removed", path, ""]


def renamed(new: str, old: str) -> list[str]:
    return ["renamed", new, old]


def test_stays_in_sync_with_the_checker() -> None:
    """The checker owns these constants. Drift would silently change the verdict."""
    source = CHECKER.read_text(encoding="utf-8")

    match = re.search(r"const SOURCE_EXTENSIONS = /(.+?)/;", source)
    check("checker SOURCE_EXTENSIONS is readable", match is not None)
    if match:
        check(
            "SOURCE_EXTENSIONS matches the checker",
            match.group(1) == scope.SOURCE_EXTENSIONS.pattern,
            f"checker={match.group(1)!r} scope={scope.SOURCE_EXTENSIONS.pattern!r}",
        )

    block = re.search(r"const EXCLUDED_PREFIXES = \[(.*?)\];", source, re.S)
    check("checker EXCLUDED_PREFIXES is readable", block is not None)
    if block:
        prefixes = tuple(re.findall(r'"([^"]+)"', block.group(1)))
        check(
            "EXCLUDED_PREFIXES matches the checker",
            prefixes == scope.EXCLUDED_PREFIXES,
            f"checker={prefixes} scope={scope.EXCLUDED_PREFIXES}",
        )


def test_skips_when_nothing_relevant_changed() -> None:
    check("swift-only change skips", run([mod("apps/mac/Sources/App.swift")]) is False)
    check("ios-only change skips", run([mod("ios/cmux/ContentView.swift"), mod("Package.resolved")]) is False)
    check(
        "web locales and docs skip",
        run([mod("web/messages/en.json"), mod("web/README.md"), mod("web/public/logo.svg")]) is False,
    )
    check("excluded web prefixes skip", run([mod("web/e2e/login.spec.ts"), mod("web/tests/util.ts")]) is False)
    check("non-source web file skips", run([mod("web/app/styles.css")]) is False)


def test_scans_when_production_source_changed() -> None:
    check("production tsx scans", run([mod("web/app/page.tsx")]) is True)
    check("production ts scans", run([mod("web/orpc/router.ts")]) is True)
    check("mixed change scans", run([mod("ios/a.swift"), mod("web/app/page.tsx")]) is True)
    for ext in ("js", "jsx", "mjs", "cjs", "ts", "tsx", "mts", "cts"):
        check(f"production .{ext} scans", run([mod(f"web/app/thing.{ext}")]) is True)


def test_deletion_preserves_the_stale_baseline_guarantee() -> None:
    """A deleted production file can strand its grandfathered baseline entry."""
    check("deleted production source scans", run([removed("web/app/old.tsx")]) is True)
    check("deleted excluded file skips", run([removed("web/e2e/old.spec.ts")]) is False)


def test_rename_considers_both_sides() -> None:
    check(
        "rename out of production scans",
        run([renamed("web/e2e/moved.ts", "web/app/moved.ts")]) is True,
    )
    check(
        "rename into production scans",
        run([renamed("web/app/moved.ts", "web/e2e/moved.ts")]) is True,
    )
    check(
        "rename between non-production paths skips",
        run([renamed("web/tests/b.ts", "web/e2e/a.ts")]) is False,
    )


def test_policy_and_toolchain_edits_take_the_full_path() -> None:
    for path in sorted(scope.POLICY_FILES):
        check(f"policy file scans: {path}", run([mod(path)]) is True)


def test_fails_conservative() -> None:
    check("empty diff scans", run([]) is True)
    check("truncated list scans", run([mod(f"docs/{i}.md") for i in range(50)], limit=50) is True)
    check("malformed row is ignored, rest still classified", run([["modified"], mod("web/app/p.tsx")]) is True)
    check("malformed row alone scans nothing relevant", run([["modified"]]) is False)


def test_pathological_filenames_are_data() -> None:
    nasty = [
        mod("web/app/../../etc/passwd"),
        mod("web/app/$(rm -rf ~).tsx"),
        mod("web/app/`id`.ts"),
        mod("web/app/a\\'; DROP TABLE x; --.ts"),
        mod("../web/app/escape.tsx"),
        mod("/absolute/web/app/thing.tsx"),
        mod("web/"),
        mod(""),
    ]
    for row in nasty:
        # None of these should crash; each is just a string comparison.
        scope.decide([row], 3000)
    check("traversal outside web/ is not production", scope.is_production_source("../web/app/escape.tsx") is False)
    check("absolute path is not production", scope.is_production_source("/absolute/web/app/thing.tsx") is False)
    check("bare web/ is not production", scope.is_production_source("web/") is False)
    check("empty path is not production", scope.is_production_source("") is False)
    check(
        "shell metacharacters in a production name still scan",
        run([mod("web/app/$(rm -rf ~).tsx")]) is True,
    )


def test_cli_contract() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        listing = Path(tmp) / "files.tsv"
        listing.write_text("modified\tios/a.swift\t\n", encoding="utf-8")
        out = subprocess.run(
            [sys.executable, str(ROOT / "scripts" / "ci" / "web_complexity_scope.py"), "--changed-files", str(listing)],
            capture_output=True,
            text=True,
            check=True,
        )
        check("cli emits scan=false for a non-web change", out.stdout.strip() == "scan=false", out.stdout)

        listing.write_text("modified\tweb/app/page.tsx\t\n", encoding="utf-8")
        out = subprocess.run(
            [sys.executable, str(ROOT / "scripts" / "ci" / "web_complexity_scope.py"), "--changed-files", str(listing)],
            capture_output=True,
            text=True,
            check=True,
        )
        check("cli emits scan=true for a web source change", out.stdout.strip() == "scan=true", out.stdout)

        out = subprocess.run(
            [sys.executable, str(ROOT / "scripts" / "ci" / "web_complexity_scope.py"), "--changed-files", str(Path(tmp) / "missing.tsv")],
            capture_output=True,
            text=True,
            check=True,
        )
        check("cli fails conservative when the listing is unreadable", out.stdout.strip() == "scan=true", out.stdout)


def main() -> int:
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            fn()
    if FAILURES:
        print(f"\n{len(FAILURES)} failure(s)")
        return 1
    print("\nall web complexity scope checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
