#!/usr/bin/env python3
"""stories/qos_static_rust.py: production Rust thread starts with no declared QoS, over a fixture tree, and its result-v1.

  python3 -m unittest scripts/perf-lab/tests/test_qos_static_rust.py
"""
from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
LAB = HERE.parent
ROOT = LAB.parent.parent

_SPEC = importlib.util.spec_from_file_location("perf_lab_qos_static_rust_under_test",
                                               LAB / "stories" / "qos_static_rust.py")
story = importlib.util.module_from_spec(_SPEC)
sys.modules[_SPEC.name] = story
_SPEC.loader.exec_module(story)

CRATE = "cmux-tui/crates/demo/src/"
LIB = """//! Demo crate.
use std::thread;

mod worker;
mod helpers;
#[cfg(test)]
mod tests;
#[cfg(all(test, unix))]
#[path = "pathed_tests.rs"]
mod pathed;
#[cfg(not(test))]
mod live;

pub fn plain() {
    thread::spawn(move || {
        work();
    });
}

pub fn named() {
    let _ = std::thread::Builder::new()
        .name("demo-named".into())
        .spawn(move || {
            cmux_threads::set_current(cmux_threads::ThreadQos::Utility);
            work();
        });
}

pub fn late() {
    let _ = std::thread::Builder::new().name("demo-late".into()).spawn(move || {
        work();
        work();
        work();
        work();
        cmux_threads::set_current(cmux_threads::ThreadQos::Utility);
    });
}

// qos: inherits the caller's class on purpose; it only forwards the caller's own bytes
pub fn commented() {
    thread::spawn(|| work()); // qos: forwards the caller's bytes at the caller's class
}

pub fn through_seam() {
    let _ = cmux_threads::spawn("demo-seam", cmux_threads::ThreadQos::Utility, || work());
}

pub fn masked() {
    let _text = "thread::spawn(|| {})";
    // thread::spawn(|| {}) in a comment
    /* thread::Builder::new() in /* a nested */ block */
}

#[cfg(test)]
fn in_test_item() {
    thread::spawn(|| work());
}

#[test]
fn a_test() {
    thread::spawn(|| work());
}

fn work() {}
"""
WORKER = """use std::thread::{self, spawn};

pub fn bare() {
    spawn(move || {});
}

pub fn named_fn_body() {
    let _ = thread::Builder::new().name("demo-listen".into()).spawn(listen);
}

pub fn helper_body() {
    let _ = thread::Builder::new().name("demo-helper".into()).spawn(move || {
        run_at_utility();
    });
}

fn listen() {
    loop {}
}

fn run_at_utility() {
    // SAFETY: own thread.
    unsafe { libc::pthread_set_qos_class_self_np(libc::qos_class_t::QOS_CLASS_UTILITY, 0) };
}
"""
HELPERS = """pub fn pool() {
    std::thread::spawn(|| {
        let _qos = cmux_tui_platform::qos::WorkQos::enter(cmux_threads::ThreadQos::Utility);
    });
}

#[cfg(test)]
mod tests {
    #[test]
    fn spawns() {
        std::thread::spawn(|| {});
    }
}
"""
TESTS = """use std::thread;
mod more;

fn helper() {
    thread::spawn(|| {});
}
"""
FIXTURE = {
    CRATE + "lib.rs": LIB,
    CRATE + "worker.rs": WORKER,
    CRATE + "helpers.rs": HELPERS,
    CRATE + "tests.rs": TESTS,
    CRATE + "tests/more.rs": "pub fn x() { std::thread::spawn(|| {}); }\n",
    CRATE + "pathed_tests.rs": "mod deeper;\nfn y() { std::thread::spawn(|| {}); }\n",
    CRATE + "pathed_tests/deeper.rs": "fn z() { std::thread::spawn(|| {}); }\n",
    CRATE + "live.rs": "pub fn on() { std::thread::spawn(|| {}); }\n",
    CRATE + "whole.rs": "#![cfg(test)]\nfn w() { std::thread::spawn(|| {}); }\n",
    CRATE + "orphan.rs": "fn o() { std::thread::spawn(|| {}); }\n",
    "cmux-tui/crates/demo/tests/integration.rs": "fn i() { std::thread::spawn(|| {}); }\n",
    "cmux-tui/crates/demo/examples/e.rs": "fn main() { std::thread::spawn(|| {}); }\n",
    "cmux-tui/crates/other/src/main.rs": "fn main() {\n    std::thread::spawn(|| {});\n}\n",
}
# (path, line) of every site the story must count in FIXTURE, in path and line order.
EXPECTED = [
    (CRATE + "lib.rs", 15),  # plain: nothing declares a class
    (CRATE + "lib.rs", 30),  # late: the class is set after the first lines
    (CRATE + "live.rs", 1),  # cfg(not(test)) is production
    (CRATE + "orphan.rs", 1),  # no crate root reaches it: it cannot be proved test-only
    (CRATE + "worker.rs", 4),  # a bare `spawn` imported from std::thread
    (CRATE + "worker.rs", 8),  # its named body `listen` sets no class
    ("cmux-tui/crates/other/src/main.rs", 2),
]


class QosStaticRustTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self.tmp.name)
        env = {**os.environ, "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1"}
        self.git = lambda *args: subprocess.run(["git", "-C", str(self.repo), *args], check=True, env=env,
                                                capture_output=True, text=True).stdout.strip()
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.email", "t@example.com")
        self.git("config", "user.name", "t")

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def commit(self, files: dict[str, str]) -> str:
        for path, text in files.items():
            target = self.repo / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(text, encoding="utf-8")
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "fixture")
        return self.git("rev-parse", "HEAD")

    def test_counts_only_undeclared_production_sites_in_path_and_line_order(self) -> None:
        sha = self.commit(FIXTURE)
        report = story.count(self.repo)
        self.assertEqual(report.sha, sha)
        self.assertEqual([(site.path, site.line) for site in report.sites], EXPECTED)
        self.assertEqual(report.per_crate, {"demo": 6, "other": 1})
        self.assertEqual(report.sites[0].text, "thread::spawn(move || {")

    def test_the_list_is_the_same_on_every_run(self) -> None:
        self.commit(FIXTURE)
        first = json.dumps(story.count(self.repo).record(), sort_keys=True)
        self.assertEqual(json.dumps(story.count(self.repo).record(), sort_keys=True), first)

    def test_counts_the_named_revision_not_the_working_tree(self) -> None:
        old = self.commit(FIXTURE)
        self.commit({CRATE + "lib.rs": "pub fn none() {}\n"})
        (self.repo / CRATE / "worker.rs").write_text("fn dirty() { std::thread::spawn(|| {}); }\n", encoding="utf-8")
        self.assertEqual([(site.path, site.line) for site in story.count(self.repo, old).sites], EXPECTED)
        head = {(site.path, site.line) for site in story.count(self.repo).sites}
        self.assertIn((CRATE + "worker.rs", 4), head)  # the committed file, not the edited one
        self.assertNotIn((CRATE + "worker.rs", 1), head)
        self.assertNotIn((CRATE + "lib.rs", 15), head)

    def test_a_crate_root_that_drops_its_modules_leaves_them_unproven(self) -> None:
        """With lib.rs declaring nothing, no file is reached through a test edge, so only `#![cfg(test)]` and
        inline test items stay out: the story never drops a file it cannot prove test-only."""
        self.commit({**FIXTURE, CRATE + "lib.rs": "pub fn none() {}\n"})
        paths = {site.path for site in story.count(self.repo).sites}
        self.assertIn(CRATE + "tests.rs", paths)
        self.assertNotIn(CRATE + "whole.rs", paths)
        self.assertNotIn(CRATE + "helpers.rs", paths)  # its one site sets a class; its test module is inline

    def test_follows_include_and_inline_module_paths(self) -> None:
        self.commit({
            CRATE + "lib.rs": "#[cfg(test)]\nmod t;\nmod outer {\n    mod inner;\n}\n",
            CRATE + "t.rs": 'include!("t_more.rs");\n',
            CRATE + "t_more.rs": "fn a() { std::thread::spawn(|| {}); }\n",
            CRATE + "outer/inner.rs": "fn b() { std::thread::spawn(|| {}); }\n",
        })
        self.assertEqual([(site.path, site.line) for site in story.count(self.repo).sites],
                         [(CRATE + "outer/inner.rs", 1)])

    def test_masks_comments_and_literals_without_moving_lines(self) -> None:
        source = 'let a = "x // y \\" thread::spawn"; // thread::spawn\n/* /* n */ thread::spawn */ let c = \'"\';\n' \
                 "let r = r#\"thread::spawn \" \"#; fn f<'a>(x: &'a str) {}\nthread::spawn(|| {});\n"
        masked = story.mask(source)
        self.assertEqual(len(masked), len(source))
        self.assertEqual(masked.count("\n"), source.count("\n"))
        self.assertEqual(masked.count("thread::spawn"), 1)
        self.assertIn("fn f<'a>(x: &'a str)", masked)

    def test_cfg_predicates_that_need_test(self) -> None:
        for predicate, expected in [("test", True), ("all(test, unix)", True), ("any(test, unix)", False),
                                    ("any(test, all(test, unix))", True), ("not(test)", False),
                                    ('feature = "test"', False), ("unix", False)]:
            with self.subTest(predicate=predicate):
                self.assertEqual(story.needs_test(predicate), expected)

    def test_refuses_an_unknown_revision(self) -> None:
        self.commit(FIXTURE)
        with self.assertRaises(story.StoryError):
            story.count(self.repo, "no-such-rev")

    def test_writes_a_valid_result_claiming_qos_rust_and_the_sites_beside_it(self) -> None:
        sha = self.commit(FIXTURE)
        report = story.count(self.repo)
        with tempfile.TemporaryDirectory() as out:
            path = story.write(report, Path(out), self.repo)
            [result] = story.perf_result.read_file(path)
            self.assertEqual((result.story, result.metric, result.unit, result.samples),
                             ("qos-static-rust", "qos.undeclared_rust", "count", [len(EXPECTED)]))
            self.assertEqual(result.target_ref.target, "qos.rust")
            self.assertEqual((result.build.sha, result.build.config, result.engine), (sha, "release", "none"))
            sites = json.loads((Path(out) / story.SITES_FILE).read_text(encoding="utf-8"))
            self.assertEqual(sites["count"], len(EXPECTED))
            self.assertEqual([(s["path"], s["line"]) for s in sites["sites"]], EXPECTED)
            self.assertEqual(sorted(p.name for p in Path(out).iterdir()), sorted([path.name, story.SITES_FILE]))

    def test_the_story_file_claims_the_metric_it_writes(self) -> None:
        catalog = json.loads((LAB / "stories.d" / "qos-static-rust.json").read_text(encoding="utf-8"))
        self.assertEqual(catalog["id"], story.STORY)
        self.assertEqual(catalog["config"], story.STATIC_CONFIG)
        self.assertEqual(catalog["command"], ["scripts/perf-lab/stories/qos_static_rust.py"])
        [metric] = catalog["metrics"]
        self.assertRegex(story.METRIC, "^" + metric["name"] + "$")
        self.assertEqual(metric["target_ref"], {"target": story.TARGET_ROW})

    def run_cli(self, *args: str, env: dict[str, str] | None = None) -> subprocess.CompletedProcess:
        base = {k: v for k, v in os.environ.items() if not k.startswith("PERF_LAB_")}
        env = {**base, "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1", **(env or {})}
        return subprocess.run([sys.executable, str(LAB / "stories" / "qos_static_rust.py"), *args],
                              cwd=self.repo, env=env, capture_output=True, text=True)

    def test_lists_sites_per_crate_and_filters_by_crate(self) -> None:
        self.commit(FIXTURE)
        done = self.run_cli("--repo", str(self.repo), "--list")
        self.assertEqual(done.returncode, 0, done.stderr)
        lines = done.stdout.splitlines()
        self.assertEqual(lines[0], "demo 6")
        self.assertEqual(lines[7], "other 1")
        self.assertEqual(lines[1], f"  {CRATE}lib.rs:15: thread::spawn(move || {{")
        only = self.run_cli("--repo", str(self.repo), "--list", "--crate", "other")
        self.assertEqual(only.stdout.splitlines(), ["other 1", "  cmux-tui/crates/other/src/main.rs:2: "
                                                               "std::thread::spawn(|| {});"])

    def test_runs_with_the_runner_argv_and_counts_the_measured_sha(self) -> None:
        measured = self.commit(FIXTURE)
        self.commit({CRATE + "lib.rs": "pub fn none() {}\n"})
        out = Path(self.tmp.name) / "run-out"
        done = self.run_cli("--app", str(Path(self.tmp.name) / "cmux DEV t.app"), "--tag", "t", "--out", str(out),
                            "light", env={"PERF_LAB_SHA": measured, "PERF_LAB_SESSION": "light"})
        self.assertEqual(done.returncode, 0, done.stderr)
        [result] = [r for path in sorted(out.glob("*.ndjson")) for r in story.perf_result.read_file(path)]
        self.assertEqual((result.build.sha, result.samples, result.session), (measured, [len(EXPECTED)], "light"))
        refused = self.run_cli("--repo", str(self.repo), env={"PERF_LAB_SESSION": "stress"})
        self.assertEqual(refused.returncode, 2)
        self.assertIn("stress", refused.stderr)


if __name__ == "__main__":
    unittest.main()
