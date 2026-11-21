#!/usr/bin/env python3
"""Behavior tests of scripts/cmux-next/source-growth-pr.py on small synthetic git repos."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
TOOL = ROOT / "scripts/cmux-next/source-growth-pr.py"
REAL_BUDGET = ROOT / "scripts/cmux-next/source-growth-budget.json"
SWIFT = "Packages/macOS/CmuxNext/Sources/Foo/Foo.swift"
RUST = "cmux-tui/crates/core/src/lib.rs"


def sh(repo: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, text=True).stdout.strip()


def write(repo: Path, path: str, size: int) -> None:
    (repo / path).parent.mkdir(parents=True, exist_ok=True)
    (repo / path).write_bytes(b"x" * size)


def make_repo(tmp: Path) -> tuple[Path, str]:
    repo = tmp / "repo"
    repo.mkdir()
    write(repo, SWIFT, 30000)
    write(repo, RUST, 5000)
    (repo / "budget.json").write_text(json.dumps({"schema": 1, "allowance_bytes": 1000}))
    sh(repo, "init", "-q", "-b", "main")
    sh(repo, "config", "user.email", "t@example.com")
    sh(repo, "config", "user.name", "t")
    commit(repo)
    return repo, sh(repo, "rev-parse", "HEAD")


def commit(repo: Path) -> None:
    sh(repo, "add", "-A")
    sh(repo, "commit", "-q", "-m", "change")


def run(repo: Path, base: str, *extra: str) -> tuple[subprocess.CompletedProcess, dict]:
    out = repo.parent / "r.json"
    r = subprocess.run([sys.executable, "-I", str(TOOL), "check", "--repo", str(repo), "--budget",
                        str(repo / "budget.json"), "--base", base, "--json", str(out), *extra],
                       capture_output=True, text=True)
    return r, (json.loads(out.read_text()) if out.exists() else {})


def test_growth_over_the_allowance_warns_and_exits_zero(tmp_path: Path) -> None:
    repo, base = make_repo(tmp_path)
    write(repo, "cmux-tui/crates/core/src/new.rs", 4000)
    write(repo, "webviews/src/pages/Home.tsx", 500)
    commit(repo)
    r, data = run(repo, base)
    assert r.returncode == 0, r.stdout + r.stderr
    assert data["net_bytes"] == 4500 and data["over"] and data["offset_needed"] == 3500, data
    assert data["languages"]["rust"]["net"] == 4000 and data["languages"]["web"]["net"] == 500, data
    assert data["areas"][0] == {"area": "cmux-tui/crates/core", "net": 4000}, data
    assert "over the 1,000-byte allowance" in r.stdout and "offset of 3,500 bytes" in r.stdout, r.stdout
    assert "move-inline-tests.py" in r.stdout and "No stated reason" in r.stdout, r.stdout


def test_shrink_is_within(tmp_path: Path) -> None:
    repo, base = make_repo(tmp_path)
    write(repo, SWIFT, 10000)
    write(repo, "cmux-tui/crates/core/src/port.rs", 3000)
    commit(repo)
    r, data = run(repo, base)
    assert r.returncode == 0, r.stdout + r.stderr
    assert data["net_bytes"] == -17000 and not data["over"], data
    assert data["languages"]["swift"]["net"] == -20000, data
    assert "within the 1,000-byte allowance" in r.stdout and "offset" not in r.stdout, r.stdout


def test_tests_vendor_and_non_app_paths_are_not_counted(tmp_path: Path) -> None:
    repo, base = make_repo(tmp_path)
    for path in ("Packages/macOS/CmuxNext/Tests/FooTests/FooTests.swift", "cmux-tui/crates/core/src/tests.rs",
                 "cmux-tui/crates/core/src/parse_tests.rs", "cmux-tui/crates/core/tests/it.rs",
                 "cmux-tui/vendor/dep/src/lib.rs", "webviews/src/Home.test.tsx", "webviews/src/Home.gallery.tsx",
                 "webviews/src/types.d.ts", "webviews/src/generated/api.ts", "webviews/fixtures/a.ts",
                 "Packages/macOS/CmuxNext/Sources/Foo/Foo+Generated.swift", "Packages/iOS/App/Sources/A.swift",
                 "Packages/macOS/CmuxNext/Package.swift", "web/app/page.tsx", "scripts/x.py"):
        write(repo, path, 50000)
    commit(repo)
    r, data = run(repo, base)
    assert r.returncode == 0, r.stdout + r.stderr
    assert data["net_bytes"] == 0 and data["changed_files"] == 0, data


def test_stated_reason_is_shown(tmp_path: Path) -> None:
    repo, base = make_repo(tmp_path)
    write(repo, "Packages/Shared/Core/Sources/Core/Big.swift", 9000)
    commit(repo)
    body = repo.parent / "body.md"
    body.write_text("Adds Big.\n\nSource: the port's Swift goes in step B (#123)\n")
    r, data = run(repo, base, "--body-file", str(body))
    assert r.returncode == 0, r.stdout + r.stderr
    assert data["reasons"] == ["the port's Swift goes in step B (#123)"], data
    assert "Stated reason: the port's Swift goes in step B (#123)" in r.stdout, r.stdout


def test_a_bad_ref_is_a_broken_check(tmp_path: Path) -> None:
    repo, _ = make_repo(tmp_path)
    r, _ = run(repo, "no-such-ref")
    assert r.returncode == 2, r.stdout + r.stderr


def test_the_real_budget_reads() -> None:
    data = json.loads(REAL_BUDGET.read_text())
    assert data["allowance_bytes"] == 20000 and data["reason"], data


def main() -> int:
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    failed = 0
    for t in tests:
        with tempfile.TemporaryDirectory() as d:
            try:
                t(Path(d)) if t.__code__.co_argcount else t()
                print(f"ok {t.__name__}")
            except AssertionError as e:
                failed += 1
                print(f"FAIL {t.__name__}: {e}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
