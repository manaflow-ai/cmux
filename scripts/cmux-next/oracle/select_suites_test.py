#!/usr/bin/env python3
"""Tests for select_suites.py: globs, the Cargo graph, the built-in corpus rules, determinism, --range and check.

Run: python3 -I scripts/cmux-next/oracle/select_suites_test.py (stdlib unittest; the Cargo graph cases need
Python 3.11+ for tomllib and are skipped on an older python3). Not in CI (spec rule 1): agents run it.
"""

from __future__ import annotations

import json
import random
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Dict, List, Optional

HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "select_suites.py"
sys.path.insert(0, str(HERE))

import select_suites as sel  # noqa: E402

HAS_TOML = sel.tomllib is not None
CAPS = {"daemon": frozenset({"resource_api", "restart"}),
        "app": frozenset({"resource_api", "actions", "keys", "gui", "chromium", "restart", "mcp"})}

FILES: Dict[str, str] = {
    "rust/Cargo.toml": '[workspace]\nmembers = ["crates/*"]\n[workspace.dependencies]\nwsdep = { path = "crates/wsdep" }\n',
    "rust/Cargo.lock": "# lock\n",
    "rust/crates/daemon/Cargo.toml": (
        '[package]\nname = "daemon"\n[dependencies]\ncore = { path = "../core" }\nwsdep = { workspace = true }\n'
        '[dev-dependencies]\ntestonly = { path = "../testonly" }\n'
        "[target.'cfg(unix)'.build-dependencies]\ngen = { path = \"../gen\" }\n"),
    "rust/crates/daemon/src/main.rs": "fn main() {}\n",
    "rust/crates/daemon/tests/it.rs": "#[test] fn t() {}\n",
    "rust/crates/core/Cargo.toml": '[package]\nname = "core"\n',
    "rust/crates/core/src/lib.rs": "pub fn f() {}\n",
    "rust/crates/wsdep/Cargo.toml": '[package]\nname = "wsdep"\n',
    "rust/crates/wsdep/src/lib.rs": "\n",
    "rust/crates/gen/Cargo.toml": '[package]\nname = "gen"\n',
    "rust/crates/gen/src/lib.rs": "\n",
    "rust/crates/testonly/Cargo.toml": '[package]\nname = "testonly"\n',
    "rust/crates/testonly/src/lib.rs": "\n",
    "rust/crates/appffi/Cargo.toml": '[package]\nname = "appffi"\n[workspace]\n',
    "rust/crates/appffi/src/lib.rs": "\n",
    "rust/docs/notes.txt": "notes\n",
    "app/Sources/App.swift": "let x = 1\n",
    "app/Tests/AppTests.swift": "let y = 1\n",
    "docs/guide.md": "# guide\n",
    "tools/random.sh": "echo\n",
    "tools/family.sh": "echo\n",
    "tests/oracle/corpus/daemon-ops/a.json": '{"id": "a", "requires": ["resource_api"]}\n',
    "tests/oracle/corpus/daemon-ops/b.json": '{"id": "b", "requires": ["resource_api"]}\n',
    "tests/oracle/corpus/actions/fam/_tuning.json": "{}\n",
    "tests/oracle/corpus/actions/fam/x.json": '{"id": "x", "requires": ["actions"]}\n',
    "tests/oracle/corpus/actions/fam/y.json": '{"id": "y", "requires": ["actions"]}\n',
    "tests/oracle/corpus/actions/top.json": '{"id": "top", "requires": ["actions", "gui"]}\n',
    "tests/oracle/corpus/actions/coverage.json": "{}\n",
    "tests/oracle/Expectations.d/daemon-ops.txt": "\n",
    "tests/oracle/baselines/platform/mac/arm/new/actions/fam/x.expected.jsonl": "\n",
}

MAP = {
    "schema": sel.MAP_SCHEMA,
    "products": {
        "daemon": {"suites": ["daemon-ops"], "cargo_roots": ["rust/crates/daemon"]},
        "app": {"suites": ["actions"], "cargo_roots": ["rust/crates/daemon", "rust/crates/appffi"]},
    },
    "cargo": {"scope": ["rust/**"], "not_linked": ["tests", "benches", "examples"], "reason": "linked"},
    "rules": [
        {"id": "swift", "paths": ["app/**"], "except": ["app/Tests/**"], "products": ["app"], "reason": "the app"},
        {"id": "workspace", "paths": ["rust/Cargo.toml", "rust/Cargo.lock"], "products": ["all"], "reason": "lock"},
        {"id": "one-family", "paths": ["tools/family.sh"], "products": ["app"], "cases": ["actions/fam/*"],
         "reason": "one family"},
    ],
    "ignore": [
        {"id": "prose", "paths": ["**/*.md", "rust/docs/**"], "reason": "prose"},
        {"id": "tests", "paths": ["app/Tests/**"], "reason": "tests"},
    ],
    "unmapped": "all",
}


def git(repo: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(repo), *args], check=True, stdout=subprocess.PIPE, text=True,
                          env={"GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "PATH": "/usr/bin:/bin",
                               "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.invalid",
                               "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.invalid",
                               "GIT_AUTHOR_DATE": "2026-01-01T00:00:00Z",
                               "GIT_COMMITTER_DATE": "2026-01-01T00:00:00Z"}).stdout


class Fixture:
    def __init__(self, root: Path, map_doc: Optional[dict] = None, files: Optional[Dict[str, str]] = None) -> None:
        self.repo = root / "repo"
        for rel, text in (files or FILES).items():
            path = self.repo / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8")
        self.map_path = root / "suite-map.json"
        self.map_path.write_text(json.dumps(map_doc or MAP), encoding="utf-8")
        git(self.repo, "init", "-q", "-b", "main")
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-q", "-m", "c0")
        sel.read_toml.cache_clear()
        sel.is_package.cache_clear()
        sel.root_package_sources.cache_clear()
        self.smap = sel.load_map(self.map_path)
        self.graph = sel.load_cargo_graph(self.repo, self.smap.cargo_roots)
        self.cases = sel.load_cases(self.repo / "tests/oracle/corpus")

    def select(self, paths: List[str], **kw) -> dict:
        return sel.select(self.smap, self.graph, self.repo, paths, cases=self.cases, capabilities=CAPS, **kw)

    def cli(self, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run([sys.executable, "-I", str(SCRIPT), "--repo", str(self.repo), "--map", str(self.map_path),
                               "--corpus", str(self.repo / "tests/oracle/corpus"), *args],
                              check=False, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)


def verdict(document: dict, path: str) -> dict:
    return next(row for row in document["paths"] if row["path"] == path)


class GlobTest(unittest.TestCase):
    def test_segments(self) -> None:
        cases = [
            ("a/*.py", "a/b.py", True), ("a/*.py", "a/b/c.py", False), ("a/**", "a/b/c.py", True),
            ("a/**", "a", True), ("**/*.md", "x.md", True), ("**/*.md", "d/e/x.md", True),
            ("a/**/z", "a/z", True), ("a/**/z", "a/b/c/z", True), ("a/?.py", "a/bb.py", False),
            ("a.b", "aXb", False), ("ghostty", "ghostty-next", False), ("Packages/*/*/Tests/**", "Packages/m/C/Tests/T.swift", True),
        ]
        for pattern, path, expected in cases:
            with self.subTest(pattern=pattern, path=path):
                self.assertEqual(bool(sel.glob_regex(pattern).fullmatch(path)), expected)

    def test_refuses_absolute_and_dot(self) -> None:
        for pattern in ("/a", "./a", "", "a\\b"):
            with self.assertRaises(sel.UsageError):
                sel.glob_regex(pattern)


class SelectTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.fx = Fixture(Path(self.tmp.name))

    def tearDown(self) -> None:
        self.tmp.cleanup()

    @unittest.skipUnless(HAS_TOML, "tomllib (Python 3.11+)")
    def test_cargo_closure(self) -> None:
        doc = self.fx.select(["rust/crates/core/src/lib.rs"])
        self.assertEqual(doc["status"], "all")
        self.assertEqual(verdict(doc, "rust/crates/core/src/lib.rs")["because"][0]["rule"], "cargo")
        self.assertIn("rust/crates/core is linked by app, daemon", verdict(doc, "rust/crates/core/src/lib.rs")["because"][0]["reason"])
        for path in ("rust/crates/wsdep/src/lib.rs", "rust/crates/gen/src/lib.rs"):
            with self.subTest(path=path):
                self.assertEqual(verdict(self.fx.select([path]), path)["status"], "selected")
        only_app = self.fx.select(["rust/crates/appffi/src/lib.rs"])
        self.assertEqual([r["product"] for r in only_app["runs"]], ["app"])
        self.assertEqual(only_app["status"], "found")

    @unittest.skipUnless(HAS_TOML, "tomllib (Python 3.11+)")
    def test_unlinked_and_test_dirs_select_nothing(self) -> None:
        for path, why in (("rust/crates/testonly/src/lib.rs", "no product's cargo_roots link rust/crates/testonly"),
                          ("rust/crates/daemon/tests/it.rs", "rust/crates/daemon/tests/ is not linked")):
            with self.subTest(path=path):
                doc = self.fx.select([path])
                self.assertEqual(doc["status"], "none")
                self.assertEqual(verdict(doc, path)["status"], "ignored")
                self.assertIn(why, verdict(doc, path)["because"][0]["reason"])

    def test_rules_ignore_and_unmapped(self) -> None:
        doc = self.fx.select(["app/Sources/App.swift"])
        self.assertEqual(doc["status"], "found")
        self.assertEqual(doc["runs"][0]["command"],
                         ["python3", "-I", "scripts/cmux-next/oracle/oracle.py", "run", "--product", "app", "--suite", "actions"])
        self.assertEqual(doc["runs"][0]["cases"], 3)
        for path, rule in (("app/Tests/AppTests.swift", "tests"), ("docs/guide.md", "prose"), ("rust/docs/notes.txt", "prose")):
            with self.subTest(path=path):
                doc = self.fx.select([path])
                self.assertEqual((doc["status"], verdict(doc, path)["because"][0]["rule"]), ("none", rule))
        doc = self.fx.select(["tools/random.sh", "docs/guide.md"])
        self.assertEqual(doc["status"], "all")
        self.assertEqual(doc["counts"], {"selected": 0, "ignored": 1, "unmapped": 1})

    def test_unmapped_none_policy(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        fx = Fixture(Path(tmp.name), {**MAP, "unmapped": "none"})
        doc = fx.select(["tools/random.sh"])
        self.assertEqual((doc["status"], doc["runs"], doc["counts"]["unmapped"]), ("none", [], 1))

    def test_corpus_rules_select_cases(self) -> None:
        doc = self.fx.select(["tests/oracle/corpus/daemon-ops/a.json", "tests/oracle/corpus/actions/fam/_tuning.json",
                              "tests/oracle/baselines/platform/mac/arm/new/actions/fam/x.expected.jsonl"])
        self.assertEqual(doc["selection"]["daemon"]["daemon-ops"]["cases"], ["daemon-ops/a"])
        self.assertEqual(doc["selection"]["app"]["actions"]["cases"], ["actions/fam/*", "actions/fam/x"])
        self.assertEqual(doc["selection"]["app"]["actions"]["selected"], 2)
        app_run = next(r for r in doc["runs"] if r["product"] == "app")
        self.assertEqual(app_run["command"][-2:], ["--filter", "actions/fam/*,actions/fam/x"])
        rules = {verdict(doc, p)["because"][0]["rule"] for p in [r["path"] for r in doc["paths"]]}
        self.assertEqual(rules, {"corpus-case", "corpus-dir", "baselines"})
        whole = self.fx.select(["tests/oracle/Expectations.d/daemon-ops.txt", "tests/oracle/corpus/actions/coverage.json"])
        self.assertTrue(whole["selection"]["daemon"]["daemon-ops"]["whole"])
        self.assertTrue(whole["selection"]["app"]["actions"]["whole"])

    def test_whole_suite_wins_over_cases(self) -> None:
        doc = self.fx.select(["tools/family.sh", "app/Sources/App.swift"])
        entry = doc["selection"]["app"]["actions"]
        self.assertEqual((entry["whole"], entry["cases"], entry["selected"]), (True, [], 3))
        self.assertEqual(sorted(r["rule"] for r in entry["reasons"]), ["one-family", "swift"])

    def test_base_head_command_is_a_diff(self) -> None:
        doc = self.fx.select(["app/Sources/App.swift"], base="a" * 40, head="b" * 40)
        self.assertEqual(doc["runs"][0]["command"][3:8], ["diff", "--base", "a" * 40, "--head", "b" * 40])

    def test_deterministic_over_order_and_repeats(self) -> None:
        paths = ["app/Sources/App.swift", "docs/guide.md", "tools/random.sh", "tests/oracle/corpus/daemon-ops/b.json",
                 "rust/crates/core/src/lib.rs", "rust/crates/testonly/src/lib.rs", "tools/family.sh"]
        first = json.dumps(self.fx.select(paths), sort_keys=True)
        rng = random.Random(9)
        for _ in range(5):
            shuffled = paths * 2
            rng.shuffle(shuffled)
            self.assertEqual(json.dumps(self.fx.select(shuffled), sort_keys=True), first)
        one = self.fx.cli("--json", *paths)
        two = self.fx.cli("--json", *reversed(paths))
        self.assertEqual((one.returncode, one.stderr), (0, ""))
        self.assertEqual(one.stdout, two.stdout)

    def test_conservative_without_tomllib(self) -> None:
        saved = sel.tomllib
        sel.tomllib = None
        try:
            graph = sel.load_cargo_graph(self.fx.repo, self.fx.smap.cargo_roots)
            doc = sel.select(self.fx.smap, graph, self.fx.repo, ["rust/crates/testonly/src/lib.rs"], cases=self.fx.cases,
                             capabilities=CAPS)
        finally:
            sel.tomllib = saved
        self.assertFalse(doc["graph"]["available"])
        self.assertEqual(doc["status"], "all")

    def test_paths_must_be_repo_relative(self) -> None:
        for bad in ("/etc/passwd", "./a", "a/../b"):
            with self.subTest(path=bad):
                proc = self.fx.cli(bad)
                self.assertEqual(proc.returncode, 2)
                self.assertIn("repo-relative", proc.stderr)


# The workspace root is itself a package that a linked crate depends on (cmux-tui's source-watch package, through
# cmux-build-identity's `path = "../.."`): it owns its manifest and its targets' dirs, not the whole workspace dir.
ROOT_PACKAGE_FILES: Dict[str, str] = {
    **FILES,
    "rust/Cargo.toml": ('[package]\nname = "source-watch"\nbuild = "build-support/watch-build.rs"\n'
                        '[lib]\npath = "build-support/watch.rs"\n'
                        '[workspace]\nmembers = ["crates/*"]\n[workspace.dependencies]\nwsdep = { path = "crates/wsdep" }\n'),
    "rust/build-support/watch.rs": "\n",
    "rust/build-support/watch-build.rs": "fn main() {}\n",
    "rust/crates/core/Cargo.toml": '[package]\nname = "core"\n[dependencies]\nsource-watch = { path = "../.." }\n',
    "rust/frontends/web/src/App.tsx": "export {}\n",
    "rust/README.md": "# rust\n",
    "rust/crates/README.md": "# crates\n",
}
ROOT_PACKAGE_MAP = {**MAP, "ignore": MAP["ignore"] + [{"id": "frontends", "paths": ["rust/frontends/**"], "reason": "web"}]}


@unittest.skipUnless(HAS_TOML, "tomllib (Python 3.11+)")
class WorkspaceRootPackageTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.fx = Fixture(Path(self.tmp.name), ROOT_PACKAGE_MAP, ROOT_PACKAGE_FILES)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_root_package_is_linked(self) -> None:
        self.assertEqual(self.fx.graph.linked_by["rust"], ("app", "daemon"))

    def test_frontends_and_prose_under_the_root_select_nothing(self) -> None:
        for path, rule in (("rust/frontends/web/src/App.tsx", "frontends"), ("rust/README.md", "prose"),
                           ("rust/crates/README.md", "prose")):
            with self.subTest(path=path):
                doc = self.fx.select([path])
                self.assertEqual((doc["status"], doc["runs"]), ("none", []))
                self.assertEqual(verdict(doc, path)["because"][0]["rule"], rule)

    def test_root_package_sources_still_select_their_users(self) -> None:
        for path in ("rust/build-support/watch.rs", "rust/build-support/watch-build.rs"):
            with self.subTest(path=path):
                because = verdict(self.fx.select([path]), path)["because"]
                self.assertEqual([b["rule"] for b in because], ["cargo"])
                self.assertIn("rust is linked by app, daemon", because[0]["reason"])
        manifest = verdict(self.fx.select(["rust/Cargo.toml"]), "rust/Cargo.toml")["because"]
        self.assertIn("cargo", [b["rule"] for b in manifest])

    def test_check_names_an_ignore_rule_the_cargo_graph_always_overrides(self) -> None:
        clean = self.fx.cli("check")
        self.assertEqual(clean.returncode, 0, clean.stderr)
        shadowed = {**ROOT_PACKAGE_MAP,
                    "ignore": ROOT_PACKAGE_MAP["ignore"] + [{"id": "core-src", "paths": ["rust/crates/core/src/**"],
                                                             "reason": "r"}]}
        self.fx.map_path.write_text(json.dumps(shadowed))
        proc = self.fx.cli("check")
        self.assertEqual(proc.returncode, 1)
        self.assertIn("ignore core-src: the cargo graph selects every tracked path it matches", proc.stderr)


class RangeTest(unittest.TestCase):
    """The task's VM test, in small: one selection per commit of a 10-commit batch, first parent by default."""

    def test_ten_commits(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            fx = Fixture(Path(tmp))
            base = git(fx.repo, "rev-parse", "HEAD").strip()
            plan = ["app/Sources/App.swift", "docs/guide.md", "tools/random.sh", "tests/oracle/corpus/daemon-ops/a.json",
                    "app/Tests/AppTests.swift", "tests/oracle/corpus/actions/fam/y.json", "rust/docs/notes.txt",
                    "tests/oracle/Expectations.d/daemon-ops.txt", "app/Sources/Second.swift"]
            for i, rel in enumerate(plan, 1):
                path = fx.repo / rel
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(path.read_text() + f"// {i}\n" if path.exists() else f"// {i}\n")
                git(fx.repo, "add", "-A")
                git(fx.repo, "commit", "-q", "-m", f"c{i} {rel}")
            # The 10th commit is a merge: --first-parent judges it by its whole change.
            git(fx.repo, "checkout", "-q", "-b", "side", "HEAD~1")
            (fx.repo / "tools/random.sh").write_text("echo side\n")
            git(fx.repo, "commit", "-q", "-am", "side change")
            git(fx.repo, "checkout", "-q", "main")
            git(fx.repo, "merge", "-q", "--no-ff", "-m", "c10 merge side", "side")
            proc = fx.cli("--range", f"{base}..main", "--json")
            self.assertEqual(proc.returncode, 0, proc.stderr)
            document = json.loads(proc.stdout)
            statuses = [(c["subject"].split()[0], c["status"]) for c in document["commits"]]
            self.assertEqual(statuses, [("c1", "found"), ("c2", "none"), ("c3", "all"), ("c4", "found"), ("c5", "none"),
                                        ("c6", "found"), ("c7", "none"), ("c8", "found"), ("c9", "found"), ("c10", "all")])
            self.assertEqual(document["commits"][5]["selection"]["app"]["actions"]["cases"], ["actions/fam/y"])
            self.assertEqual(document["union"]["status"], "all")
            again = fx.cli("--range", f"{base}..main", "--json")
            self.assertEqual(again.stdout, proc.stdout)
            every = json.loads(fx.cli("--range", f"{base}..main", "--json", "--all-parents").stdout)
            self.assertEqual(len(every["commits"]), 11)


class CheckTest(unittest.TestCase):
    def test_fixture_map_is_clean_and_problems_are_named(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            fx = Fixture(Path(tmp))
            clean = fx.cli("check")
            self.assertEqual(clean.returncode, 0, clean.stderr)
            broken = json.loads(json.dumps(MAP))
            broken["rules"].append({"id": "stale", "paths": ["gone/**"], "products": ["app"], "reason": "r"})
            broken["rules"].append({"id": "bad-suite", "paths": ["app/**"], "products": ["daemon"], "suites": ["actions"],
                                    "reason": "r"})
            broken["products"]["daemon"]["suites"].append("nope")
            broken["products"]["app"]["cargo_roots"].append("rust/crates/missing")
            fx.map_path.write_text(json.dumps(broken))
            proc = fx.cli("check")
            self.assertEqual(proc.returncode, 1)
            for needle in ("rule stale paths: 'gone/**' matches no tracked file",
                           "rule bad-suite: no product of the rule runs suite actions",
                           "products.daemon: suite nope is not a directory of the corpus"):
                self.assertIn(needle, proc.stderr)
            if HAS_TOML:
                self.assertIn("rust/crates/missing has no Cargo.toml", proc.stderr)

    def test_map_refuses_duplicate_ids_and_missing_reasons(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "m.json"
            for doc, needle in (({**MAP, "ignore": [{"id": "swift", "paths": ["x"], "reason": "r"}]}, "used twice"),
                                ({**MAP, "rules": [{"id": "r", "paths": ["x"], "products": ["app"]}]}, "no reason"),
                                ({**MAP, "unmapped": "some"}, "unmapped")):
                path.write_text(json.dumps(doc))
                with self.assertRaisesRegex(sel.UsageError, needle):
                    sel.load_map(path)

    def test_checked_in_map_is_clean(self) -> None:
        proc = subprocess.run([sys.executable, "-I", str(SCRIPT), "check"], check=False, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, text=True)
        self.assertEqual(proc.returncode, 0, proc.stderr)


class NoStdlibShadowTest(unittest.TestCase):
    """A script named like a stdlib module breaks every oracle script run without -I (bisect.py breaks `random`)."""

    @unittest.skipIf(sys.version_info < (3, 10), "sys.stdlib_module_names is 3.10+")
    def test_no_oracle_module_shadows_the_stdlib(self) -> None:
        names = {p.stem for p in HERE.glob("*.py")} | {p.name for p in HERE.iterdir() if p.is_dir()}
        self.assertEqual(sorted(names & set(sys.stdlib_module_names)), [])


if __name__ == "__main__":
    unittest.main()
