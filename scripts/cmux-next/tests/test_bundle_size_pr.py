#!/usr/bin/env python3
"""Behavior tests of scripts/cmux-next/bundle-size-pr.py on small synthetic git repos."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
TOOL = ROOT / "scripts/cmux-next/bundle-size-pr.py"
REAL_BUDGET = ROOT / "scripts/cmux-next/bundle-size-budget.json"

RULES = {
    "threshold_bytes": 1000,
    "tree_paths": ["Resources", "Packages/*/Resources"],
    "web_outputs": ["pages"],
    "rust": [{"lockfile": "rs/Cargo.lock", "roots": ["app"]}],
}


def sh(repo: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, text=True).stdout.strip()


def lock(*packages: tuple[str, str, list[str], bool]) -> str:
    """A Cargo.lock: (name, version, dependencies, from the registry)."""
    out = ["version = 4", ""]
    for name, version, deps, registry in packages:
        out += ["[[package]]", f'name = "{name}"', f'version = "{version}"']
        if registry:
            out.append('source = "registry+https://github.com/rust-lang/crates.io-index"')
        if deps:
            out.append("dependencies = [" + ", ".join(f'"{d}"' for d in deps) + "]")
        out.append("")
    return "\n".join(out)


APP_TOML = '[package]\nname = "app"\nversion = "0.1.0"\n\n[dependencies]\nserde = "1"\n\n[dev-dependencies]\ninsta = "1"\n'
BASE_LOCK = lock(("app", "0.1.0", ["serde"], False), ("serde", "1.0.0", [], True))


def make_repo(tmp: Path) -> tuple[Path, str]:
    repo = tmp / "repo"
    (repo / "Resources").mkdir(parents=True)
    (repo / "Resources/a.txt").write_bytes(b"a" * 500)
    (repo / "rs").mkdir()
    (repo / "rs/Cargo.toml").write_text(APP_TOML)
    (repo / "rs/Cargo.lock").write_text(BASE_LOCK)
    (repo / "budget.json").write_text(json.dumps({"schema": 1, "variants": {}, "pull_request": RULES}))
    sh(repo.parent, "init", "-q", "-b", "main", str(repo))
    sh(repo, "config", "user.email", "t@example.com")
    sh(repo, "config", "user.name", "t")
    sh(repo, "add", "-A")
    sh(repo, "commit", "-q", "-m", "base")
    return repo, sh(repo, "rev-parse", "HEAD")


def commit(repo: Path, message: str = "change") -> None:
    sh(repo, "add", "-A")
    sh(repo, "commit", "-q", "-m", message)


def run(repo: Path, base: str, *extra: str) -> tuple[subprocess.CompletedProcess, dict]:
    out = repo.parent / "r.json"
    r = subprocess.run([sys.executable, "-I", str(TOOL), "check", "--repo", str(repo), "--budget", str(repo / "budget.json"),
                        "--base", base, "--json", str(out), *extra], capture_output=True, text=True)
    return r, (json.loads(out.read_text()) if out.exists() else {})


def test_growth_over_the_threshold_fails_and_names_the_path(tmp: Path) -> None:
    repo, base = make_repo(tmp)
    (repo / "Packages/Foo/Resources").mkdir(parents=True)
    (repo / "Packages/Foo/Resources/big.bin").write_bytes(b"b" * 1500)
    commit(repo)
    r, data = run(repo, base)
    assert r.returncode == 1, r.stdout + r.stderr
    assert data["growth_bytes"] == 1500, data
    assert "| files | `Packages/*/Resources` | 0 | 1,500 |" in r.stdout, r.stdout
    assert "add a `size: <reason>` line" in r.stdout, r.stdout


def test_a_size_line_in_the_body_passes(tmp: Path) -> None:
    repo, base = make_repo(tmp)
    (repo / "Resources/big.bin").write_bytes(b"b" * 1500)
    commit(repo)
    body = tmp / "body.md"
    body.write_text("Adds the icon set.\n\nsize: the new icons, 1.5 KB, needed by the picker\n")
    r, data = run(repo, base, "--body-file", str(body))
    assert r.returncode == 0, r.stdout + r.stderr
    assert data["over"] is True and data["fails"] is False
    assert "> size: the new icons" in r.stdout, r.stdout


def test_a_size_trailer_in_a_commit_passes(tmp: Path) -> None:
    repo, base = make_repo(tmp)
    (repo / "Resources/big.bin").write_bytes(b"b" * 1500)
    commit(repo, "Add icons\n\nSize: icons the picker needs")
    r, _ = run(repo, base)
    assert r.returncode == 0, r.stdout + r.stderr


def test_growth_under_the_threshold_and_a_cut_pass(tmp: Path) -> None:
    repo, base = make_repo(tmp)
    (repo / "Resources/small.bin").write_bytes(b"s" * 900)
    commit(repo)
    r, data = run(repo, base)
    assert r.returncode == 0 and data["growth_bytes"] == 900, r.stdout
    (repo / "Resources/a.txt").unlink()
    (repo / "Resources/small.bin").unlink()
    commit(repo)
    r, data = run(repo, base)
    assert r.returncode == 0 and data["growth_bytes"] == -500, r.stdout
    assert "within the budget" in r.stdout


def test_files_outside_the_shipped_paths_do_not_count(tmp: Path) -> None:
    repo, base = make_repo(tmp)
    (repo / "docs").mkdir()
    (repo / "docs/huge.md").write_bytes(b"d" * 50000)
    commit(repo)
    r, data = run(repo, base)
    assert r.returncode == 0 and data["growth_bytes"] == 0, r.stdout


def manifest(repo: Path, deps: str, extra: str = "") -> None:
    (repo / "rs/Cargo.toml").write_text(f'[package]\nname = "app"\nversion = "0.1.0"\n\n[dependencies]\n{deps}\n{extra}')


def test_a_new_crate_in_a_shipped_binary_fails_even_when_small(tmp: Path) -> None:
    repo, base = make_repo(tmp)
    manifest(repo, 'serde = "1"\nregex = "1"')
    (repo / "rs/Cargo.lock").write_text(lock(("app", "0.1.0", ["serde", "regex"], False), ("serde", "1.0.0", [], True),
                                             ("regex", "1.10.0", ["aho-corasick"], True), ("aho-corasick", "1.1.0", [], True)))
    commit(repo)
    r, data = run(repo, base)
    assert r.returncode == 1, r.stdout
    assert [c["crate"] for c in data["new_crates"]] == ["regex"], data
    assert "- `regex 1.10.0` (rs/Cargo.lock)" in r.stdout, r.stdout
    # What regex pulls in is listed, not counted: the lockfile cannot say it links on macOS.
    assert [(c["crate"], c["why"]) for c in data["crate_notes"]] == [("aho-corasick", "transitive")], data


def test_a_version_bump_is_not_a_new_crate_but_a_second_version_is(tmp: Path) -> None:
    repo, base = make_repo(tmp)
    (repo / "rs/Cargo.lock").write_text(lock(("app", "0.1.0", ["serde"], False), ("serde", "1.0.9", [], True)))
    commit(repo)
    r, data = run(repo, base)
    assert r.returncode == 0 and data["new_crates"] == [] and data["crate_notes"] == [], r.stdout
    manifest(repo, 'serde = "1"\nserde2 = { package = "serde", version = "2" }\nother = "0.1"')
    (repo / "rs/Cargo.lock").write_text(lock(("app", "0.1.0", ["serde 1.0.9", "serde 2.0.0", "other"], False),
                                             ("serde", "1.0.9", [], True), ("serde", "2.0.0", [], True), ("other", "0.1.0", [], True)))
    commit(repo)
    r, data = run(repo, base)
    assert r.returncode == 1, r.stdout
    # One entry per crate name, with every version the head links.
    assert data["new_crates"] == [
        {"lockfile": "rs/Cargo.lock", "crate": "other", "versions": ["0.1.0"], "second_version": False},
        {"lockfile": "rs/Cargo.lock", "crate": "serde", "versions": ["1.0.9", "2.0.0"], "second_version": True},
    ], data


def test_crates_for_other_targets_and_optional_ones_are_listed_not_counted(tmp: Path) -> None:
    repo, base = make_repo(tmp)
    manifest(repo, 'serde = "1"\nfancy = { version = "1", optional = true }',
             '[target.\'cfg(windows)\'.dependencies]\nwinapi = "0.3"\n'
             '[target.\'cfg(all(unix, not(target_os = "macos")))\'.dependencies]\ninotify = "0.10"\n'
             '[target.\'cfg(any(target_os = "macos", target_os = "ios"))\'.dependencies]\ncore-foundation = "0.10"\n')
    (repo / "rs/Cargo.lock").write_text(lock(
        ("app", "0.1.0", ["serde", "fancy", "winapi", "inotify", "core-foundation"], False), ("serde", "1.0.0", [], True),
        ("fancy", "1.0.0", [], True), ("winapi", "0.3.9", [], True), ("inotify", "0.10.0", [], True),
        ("core-foundation", "0.10.0", [], True)))
    commit(repo)
    r, data = run(repo, base)
    assert r.returncode == 1, r.stdout
    assert [c["crate"] for c in data["new_crates"]] == ["core-foundation"], data
    notes = {c["crate"]: c["why"] for c in data["crate_notes"]}
    assert notes == {"fancy": "optional", "inotify": "transitive", "winapi": "transitive"}, notes


def test_workspace_and_path_dependencies_are_followed(tmp: Path) -> None:
    repo, base = make_repo(tmp)
    (repo / "rs/Cargo.toml").write_text(
        '[workspace]\nmembers = ["crates/core"]\n[workspace.dependencies]\nbytes = "1"\n'
        'core = { path = "crates/core" }\n\n'
        '[package]\nname = "app"\nversion = "0.1.0"\n\n[dependencies]\nserde = "1"\ncore = { workspace = true }\n')
    (repo / "rs/crates/core").mkdir(parents=True)
    (repo / "rs/crates/core/Cargo.toml").write_text(
        '[package]\nname = "core"\nversion = "0.1.0"\n\n[dependencies]\nbytes = { workspace = true }\n'
        '[build-dependencies]\ncc = "1"\n[dev-dependencies]\nproptest = "1"\n')
    (repo / "rs/Cargo.lock").write_text(lock(
        ("app", "0.1.0", ["serde", "core"], False), ("serde", "1.0.0", [], True), ("core", "0.1.0", ["bytes", "cc", "proptest"], False),
        ("bytes", "1.5.0", [], True), ("cc", "1.0.0", [], True), ("proptest", "1.0.0", [], True)))
    commit(repo)
    r, data = run(repo, base)
    assert sorted(c["crate"] for c in data["new_crates"]) == ["bytes", "cc"], data
    assert data["crate_notes"] == [], data  # proptest is a dev-dependency


def test_dev_dependencies_and_crates_off_the_shipped_graph_do_not_count(tmp: Path) -> None:
    repo, base = make_repo(tmp)
    # insta is app's dev-dependency (rs/Cargo.toml); tool is a member nothing shipped depends on.
    (repo / "rs/Cargo.lock").write_text(lock(("app", "0.1.0", ["serde", "insta"], False), ("serde", "1.0.0", [], True),
                                             ("insta", "1.40.0", ["similar"], True), ("similar", "2.0.0", [], True),
                                             ("tool", "0.1.0", ["clap"], False), ("clap", "4.0.0", [], True)))
    commit(repo)
    r, data = run(repo, base)
    assert r.returncode == 0 and data["new_crates"] == [], r.stdout


def test_web_bundles_count_when_both_builds_are_given(tmp: Path) -> None:
    repo, base = make_repo(tmp)
    commit_free = sh(repo, "rev-parse", "HEAD")
    wb, wh = tmp / "web-base", tmp / "web-head"
    for root, n in ((wb, 1000), (wh, 3000)):
        (root / "pages/settings").mkdir(parents=True)
        (root / "pages/settings/index.html").write_bytes(b"h" * n)
    r, data = run(repo, commit_free, "--web-base", str(wb), "--web-head", str(wh))
    assert r.returncode == 1 and data["growth_bytes"] == 2000, r.stdout
    assert "| web | `pages` | 1,000 | 3,000 |" in r.stdout, r.stdout
    r, _ = run(repo, commit_free, "--web-base", str(wb))
    assert r.returncode == 2, r.stdout + r.stderr
    # A head build that never wrote an output is broken (exit 2), not a 1,000-byte cut.
    (wh / "pages/settings/index.html").unlink()
    (wh / "pages/settings").rmdir()
    (wh / "pages").rmdir()
    r, _ = run(repo, commit_free, "--web-base", str(wb), "--web-head", str(wh))
    assert r.returncode == 2 and "has no web output pages" in r.stderr, r.stdout + r.stderr
    r = subprocess.run([sys.executable, "-I", str(TOOL), "web-bytes", str(wh), "--budget", str(repo / "budget.json")],
                       capture_output=True, text=True)
    assert r.returncode == 2 and "has no web output pages" in r.stderr, r.stdout + r.stderr
    # An empty or partial count handed over by a web job is broken too (exit 2), never a pass.
    for text in ("", "{}", '{"pages": "x"}'):
        (tmp / "wh.json").write_text(text)
        r, _ = run(repo, commit_free, "--web-base", str(wb), "--web-head", str(tmp / "wh.json"))
        assert r.returncode == 2 and "lacks a byte count" in r.stderr, (text, r.stdout + r.stderr)


def test_the_real_budget_lists_existing_lockfiles_and_roots(tmp: Path) -> None:
    # Every lockfile the checked-in rules name exists, and names its roots, so a moved crate
    # cannot quietly drop a binary out of the check.
    rules = json.loads(REAL_BUDGET.read_text())["pull_request"]
    for entry in rules["rust"]:
        text = (ROOT / entry["lockfile"]).read_text()
        for root in entry["roots"]:
            assert f'name = "{root}"\n' in text, f"{root} is not in {entry['lockfile']}"
    assert rules["threshold_bytes"] > 0


def main() -> int:
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    failed = 0
    for t in tests:
        with tempfile.TemporaryDirectory() as d:
            try:
                t(Path(d))
                print(f"ok {t.__name__}")
            except AssertionError as e:
                failed += 1
                print(f"FAIL {t.__name__}: {e}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
