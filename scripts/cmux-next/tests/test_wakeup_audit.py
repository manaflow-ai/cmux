#!/usr/bin/env python3
"""wakeup-audit.py finds idle wakeups over the full tree (CmuxNext Sources, the app-linked Shared packages,
cmux-tui crate sources, webviews/src) and judges escapes by the closed vocabulary. Each case writes a small
fixture repository to a temp dir and runs the script on it with --root.

  python3 scripts/cmux-next/tests/test_wakeup_audit.py
"""
from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE.parent / "wakeup-audit.py"
CHECK_CONCURRENCY = HERE.parent / "check-concurrency.sh"

PACKAGE_SWIFT = """// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "CmuxNext",
    dependencies: [
        .package(path: "../../Shared/CmuxLinked"),
        .package(path: "../CmuxUpdater"),
        .package(path: "../../iOS/CmuxMobileRPC"),
    ],
    targets: []
)
"""

RUST_LIB = """\
use std::time::Duration;

pub fn serve(rx: std::sync::mpsc::Receiver<u8>) {
    let _ = rx.recv_timeout(Duration::from_secs(1));
}

pub fn spin(rx: std::sync::mpsc::Receiver<u8>) {
    loop {
        if rx.recv_timeout(Duration::from_millis(400)).is_ok() {
            break;
        }
    }
}

pub fn evented(rx: std::sync::mpsc::Receiver<u8>) {
    loop {
        let _ = rx.recv();
        std::thread::sleep(Duration::from_millis(5));
    }
}

pub fn escaped(rx: std::sync::mpsc::Receiver<u8>) {
    // wakeup-allow: deadline the handshake answer arrives within 2 s or the peer is gone
    let _ = rx.recv_timeout(Duration::from_secs(2));
}

pub fn excuse() {
    std::thread::sleep(Duration::from_secs(1)); // wakeup-allow: because it is short
}

pub fn heartbeat() {
    loop {
        // wakeup-allow: periodic Unlisted.heartbeat every 30 s
        std::thread::sleep(Duration::from_secs(30));
    }
}

pub fn renewal() {
    loop {
        // wakeup-allow: periodic Lease.renewal every 60 s
        std::thread::sleep(Duration::from_secs(60));
    }
}

/// Docs that mention `thread::sleep(` are not code.
pub fn text() -> &'static str {
    "thread::sleep(Duration::ZERO)"
}

fn wait_timeout(_d: Duration) {}

#[cfg(feature = "test-support")]
pub mod support;

#[cfg(test)]
#[path = "pathed_tests.rs"]
mod pathed;

#[cfg(test)]
mod tests {
    use std::time::Duration;

    #[test]
    fn waits() {
        let (_tx, rx) = std::sync::mpsc::channel::<u8>();
        let _ = rx.recv_timeout(Duration::from_millis(1));
    }

    mod nested;
}
"""


def write(root: Path, rel: str, text: str) -> None:
    path = root / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(textwrap.dedent(text), encoding="utf-8")


def fixture(root: Path, periodic: list[dict] | None = None) -> None:
    (root / "scripts/cmux-next").mkdir(parents=True)
    shutil.copy(CHECK_CONCURRENCY, root / "scripts/cmux-next/check-concurrency.sh")
    budget = {"kinds": {}}
    if periodic is not None:
        budget["allowed_periodic"] = periodic
    write(root, "scripts/cmux-next/idle-budget.json", json.dumps(budget))
    write(root, "Packages/macOS/CmuxNext/Package.swift", PACKAGE_SWIFT)
    write(root, "cmux-tui/crates/demo/src/lib.rs", RUST_LIB)
    write(root, "cmux-tui/crates/demo/src/support.rs", "pub fn pause() { std::thread::sleep(std::time::Duration::ZERO); }\n")
    write(root, "cmux-tui/crates/demo/src/pathed_tests.rs", "fn t() { std::thread::sleep(std::time::Duration::ZERO); }\nmod deeper;\n")
    write(root, "cmux-tui/crates/demo/src/deeper.rs", "fn d() { std::thread::sleep(std::time::Duration::ZERO); }\n")
    write(root, "cmux-tui/crates/demo/src/tests/nested.rs", "fn n() { std::thread::sleep(std::time::Duration::ZERO); }\n")
    write(root, "cmux-tui/crates/demo/tests/integration.rs", "fn i() { std::thread::sleep(std::time::Duration::ZERO); }\n")
    write(root, "cmux-tui/crates/demo/benches/bench.rs", "fn b() { std::thread::sleep(std::time::Duration::ZERO); }\n")
    write(root, "cmux-tui/crates/demo/src/ticker.rs", """\
        pub async fn tick() {
            let mut every = tokio::time::interval(std::time::Duration::from_secs(1));
            every.tick().await;
        }
        """)


class Audit:
    def __init__(self, root: Path) -> None:
        self.root = root

    def run(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run([sys.executable, "-I", str(SCRIPT), "--root", str(self.root), *args],
                              capture_output=True, text=True, check=False)

    def hits(self, *args: str) -> list[dict]:
        result = self.run("--json", *args)
        assert result.returncode == 0, result.stderr
        return json.loads(result.stdout)["hits"]

    def at(self, file: str, *args: str) -> list[dict]:
        return [h for h in self.hits(*args) if h["file"].endswith(file)]


class WakeupAuditTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        fixture(self.root, periodic=[{"owner": "Lease.renewal", "period_s": 60, "why": "lease expires at 120 s"}])
        self.audit = Audit(self.root)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def line_of(self, rel: str, needle: str) -> int:
        lines = (self.root / rel).read_text(encoding="utf-8").split("\n")
        return next(i + 1 for i, line in enumerate(lines) if needle in line)

    # Rust ---------------------------------------------------------------------------------------------------

    def test_rust_recv_timeout_in_src_is_reported_and_in_cfg_test_mod_is_ignored(self) -> None:
        lib = "cmux-tui/crates/demo/src/lib.rs"
        hits = {(h["line"], h["rule"]): h for h in self.audit.at("demo/src/lib.rs", "--lang", "rust")}
        served = self.line_of(lib, "recv_timeout(Duration::from_secs(1))")
        self.assertEqual(hits[(served, "recv-timeout")]["status"], "hit")
        in_test = self.line_of(lib, "recv_timeout(Duration::from_millis(1))")
        self.assertNotIn((in_test, "recv-timeout"), hits)

    def test_rust_test_only_module_files_tests_and_benches_are_skipped(self) -> None:
        files = {h["file"] for h in self.audit.hits("--lang", "rust")}
        for skipped in ("pathed_tests.rs", "deeper.rs", "tests/nested.rs", "support.rs", "tests/integration.rs",
                        "benches/bench.rs"):
            self.assertFalse(any(f.endswith(skipped) for f in files), skipped)
        self.assertTrue(any(f.endswith("demo/src/ticker.rs") for f in files))

    def test_rust_comments_strings_and_definitions_are_not_hits(self) -> None:
        lib = "cmux-tui/crates/demo/src/lib.rs"
        lines = {h["line"] for h in self.audit.at("demo/src/lib.rs", "--lang", "rust")}
        for needle in ("Docs that mention", '"thread::sleep(Duration::ZERO)"', "fn wait_timeout("):
            self.assertNotIn(self.line_of(lib, needle), lines, needle)

    def test_rust_escaped_hit_is_not_in_the_queue(self) -> None:
        lib = "cmux-tui/crates/demo/src/lib.rs"
        line = self.line_of(lib, "recv_timeout(Duration::from_secs(2))")
        hit = next(h for h in self.audit.at("demo/src/lib.rs", "--lang", "rust") if h["line"] == line)
        self.assertEqual((hit["status"], hit["escape"]), ("escaped", "deadline"))
        queue = self.audit.run("--lang", "rust", "--queue").stdout
        self.assertNotIn(f"{lib}:{line}\t", queue)

    def test_rust_hits_are_tagged_loop_or_oneshot(self) -> None:
        lib = "cmux-tui/crates/demo/src/lib.rs"
        shapes = {(h["line"], h["rule"]): h["shape"] for h in self.audit.at("demo/src/lib.rs", "--lang", "rust")}
        self.assertEqual(shapes[(self.line_of(lib, "recv_timeout(Duration::from_secs(1))"), "recv-timeout")], "oneshot")
        self.assertEqual(shapes[(self.line_of(lib, "from_millis(400)"), "recv-timeout")], "loop")
        # The loop blocks on an untimed recv(): it wakes on messages, not on a period.
        self.assertEqual(shapes[(self.line_of(lib, "from_millis(5)"), "thread-sleep")], "oneshot")
        ticker = self.audit.at("demo/src/ticker.rs", "--lang", "rust")
        self.assertEqual([(h["rule"], h["shape"]) for h in ticker], [("tokio-interval", "loop")])

    def test_queue_lines_are_group_file_line_rule_shape(self) -> None:
        lines = self.audit.run("--lang", "rust", "--queue").stdout.splitlines()
        self.assertTrue(lines)
        for line in lines:
            group, where, rule, shape, *status = line.split("\t")
            self.assertIn(status, ([], ["bad-escape"], ["no-reason"], ["periodic-unlisted"]), line)
            self.assertTrue(group.startswith("rust:demo/"), group)
            self.assertRegex(where, r"^cmux-tui/crates/demo/src/\S+\.rs:\d+$")
            self.assertIn(shape, ("loop", "oneshot"))
            self.assertTrue(rule)

    # Escape vocabulary and --strict ------------------------------------------------------------------------

    def test_escape_word_outside_the_vocabulary_fails_strict(self) -> None:
        lib = "cmux-tui/crates/demo/src/lib.rs"
        line = self.line_of(lib, "because it is short")
        hit = next(h for h in self.audit.at("demo/src/lib.rs", "--lang", "rust") if h["line"] == line)
        self.assertEqual((hit["status"], hit["escape"]), ("bad-escape", "because"))
        # The work list holds what --strict refuses: the escape to reword, marked in a 5th column.
        self.assertIn(f"{lib}:{line}\tthread-sleep\toneshot\tbad-escape\n", self.audit.run("--lang", "rust", "--queue").stdout)
        strict = self.audit.run("--lang", "rust", "--strict")
        self.assertEqual(strict.returncode, 1)
        self.assertIn(f"{lib}:{line}: thread-sleep", strict.stdout)
        self.assertIn("bad-escape because", strict.stdout)

    def test_periodic_escape_needs_an_allowed_periodic_owner(self) -> None:
        by_escape = {h["escape"]: h["status"] for h in self.audit.at("demo/src/lib.rs", "--lang", "rust")}
        self.assertEqual(by_escape["periodic Unlisted.heartbeat"], "periodic-unlisted")
        self.assertEqual(by_escape["periodic"], "escaped")  # Lease.renewal is listed
        strict = self.audit.run("--lang", "rust", "--strict").stdout
        self.assertIn("periodic-unlisted periodic Unlisted.heartbeat", strict)
        self.assertNotIn("Lease.renewal", strict)

    def test_strict_passes_when_every_hit_is_escaped_with_the_vocabulary(self) -> None:
        write(self.root, "cmux-tui/crates/demo/src/lib.rs", """\
            pub fn f(rx: std::sync::mpsc::Receiver<u8>) {
                // wakeup-allow: bounded three tries, then the caller reports the failure
                let _ = rx.recv_timeout(std::time::Duration::from_secs(1));
                std::thread::sleep(std::time::Duration::ZERO); // wakeup-allow: cli-only the CLI waits for its child
            }
            """)
        write(self.root, "cmux-tui/crates/demo/src/ticker.rs", "pub fn none() {}\n")
        for test_only in ("support.rs", "pathed_tests.rs", "deeper.rs", "tests/nested.rs"):
            (self.root / "cmux-tui/crates/demo/src" / test_only).unlink()
        result = self.audit.run("--lang", "rust", "--strict")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_strict_refuses_an_allowed_periodic_list_over_its_limits(self) -> None:
        budget = self.root / "scripts/cmux-next/idle-budget.json"
        budget.write_text(json.dumps({"allowed_periodic": [{"owner": "Fast", "period_s": 1, "why": "x"}]}))
        write(self.root, "cmux-tui/crates/demo/src/lib.rs", "pub fn none() {}\n")
        write(self.root, "cmux-tui/crates/demo/src/ticker.rs", "pub fn none() {}\n")
        result = self.audit.run("--lang", "rust", "--strict")
        self.assertEqual(result.returncode, 1)
        self.assertIn("Fast: period_s below 15", result.stderr)

    # Swift ---------------------------------------------------------------------------------------------------

    def test_swift_rules_cover_cmuxnext_and_skip_the_wakeups_module(self) -> None:
        write(self.root, "Packages/macOS/CmuxNext/Sources/CmuxNextApp/Clock.swift", """\
            import SwiftUI
            struct Clock: View {
                var body: some View { TimelineView(.periodic(from: .now, by: 1)) { _ in Text("") } }
                func watch() {
                    _ = NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification,
                                                               object: nil, queue: nil) { _ in }
                    _ = NSTrackingArea(rect: .zero, options: [.activeAlways], owner: nil)
                }
                func poll() async {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(1))
                    }
                }
                // wakeup-allow: debug the Debug menu's latency HUD refresh
                let hud = Timer.publish(every: 1, on: .main, in: .common)
                let text = "Task.sleep(for: .seconds(1))"
            }
            """)
        write(self.root, "Packages/macOS/CmuxNext/Sources/CmuxNextWakeups/DemandTimer.swift",
              "func f() async { try? await Task.sleep(for: .seconds(1)) }\n")
        hits = self.audit.hits("--lang", "swift")
        self.assertFalse(any("CmuxNextWakeups" in h["file"] for h in hits))
        rules = {(h["rule"], h["shape"], h["status"]) for h in hits}
        for expected in (("timeline-view", "loop", "hit"), ("did-update", "loop", "hit"),
                         ("active-always", "oneshot", "hit"), ("sleep", "loop", "hit"),
                         ("loop-that-can-spin", "loop", "hit"), ("timer", "loop", "escaped")):
            self.assertIn(expected, rules)
        self.assertEqual(sum(h["rule"] == "sleep" for h in hits), 1)  # not the string

    def test_swift_shared_reads_linked_packages_from_package_swift(self) -> None:
        sleep = "func f() async { try? await Task.sleep(for: .seconds(1)) }\n"
        write(self.root, "Packages/Shared/CmuxLinked/Sources/CmuxLinked/A.swift", sleep)
        write(self.root, "Packages/Shared/CmuxLinked/Sources/CmuxLinked/Mock/MockSource.swift", sleep)
        write(self.root, "Packages/Shared/CmuxLinked/Tests/CmuxLinkedTests/ATests.swift", sleep)
        write(self.root, "Packages/Shared/CmuxUnlinked/Sources/CmuxUnlinked/B.swift", sleep)
        write(self.root, "Packages/macOS/CmuxUpdater/Sources/CmuxUpdater/U.swift", sleep)
        write(self.root, "Packages/iOS/CmuxMobileRPC/Sources/CmuxMobileRPC/R.swift", sleep)
        files = sorted(h["file"] for h in self.audit.hits("--lang", "swift-shared"))
        self.assertEqual(files, [
            "Packages/Shared/CmuxLinked/Sources/CmuxLinked/A.swift",
            # Inside the library target, so linked into the app.
            "Packages/Shared/CmuxLinked/Sources/CmuxLinked/Mock/MockSource.swift",
            "Packages/macOS/CmuxUpdater/Sources/CmuxUpdater/U.swift",
        ])

    def test_demand_sync_lists_main_actor_closures_without_await(self) -> None:
        write(self.root, "Packages/macOS/CmuxNext/Sources/CmuxNextApp/Toast.swift", """\
            @MainActor final class Toast {
                private let timer = DemandTimer(owner: "toast")
                func show() {
                    timer.schedule(after: .seconds(2)) { @MainActor [weak self] in self?.hide() }
                    timer.scheduleIfIdle(after: .seconds(3)) { @MainActor [weak self] in
                        await self?.load()
                    }
                    timer.schedule(after: .seconds(4)) { self.hide() }
                }
                func hide() {}
                func load() async {}
            }
            """)
        lines = self.audit.run("--queue", "demand-sync").stdout.splitlines()
        self.assertEqual(lines, ["swift:CmuxNextApp\tPackages/macOS/CmuxNext/Sources/CmuxNextApp/Toast.swift:4\t"
                                 "demand-sync\toneshot"])

    # Web -----------------------------------------------------------------------------------------------------

    def test_web_set_interval_and_infinite_animations(self) -> None:
        write(self.root, "webviews/src/pages/poll.ts", """\
            // setInterval( in a comment is not code
            const id = setInterval(() => refresh(), 1200);
            const spin = { animation: "cmux-spin 1s linear infinite" };
            // wakeup-allow: fixture the gallery clock
            setInterval(tick, 1000);
            """)
        write(self.root, "webviews/src/pages/spin.css", """\
            /* infinite in a comment */
            .dot { animation: pulse 2s ease-in-out infinite; }
            """)
        write(self.root, "webviews/src/pages/poll.test.ts", "setInterval(() => {}, 1);\n")
        write(self.root, "webviews/src/gallery/demo.ts", "setInterval(() => {}, 1);\n")
        hits = sorted((h["file"].rsplit("/", 1)[1], h["line"], h["rule"], h["status"])
                      for h in self.audit.hits("--lang", "web"))
        self.assertEqual(hits, [
            ("poll.ts", 2, "set-interval", "hit"),
            ("poll.ts", 3, "css-infinite", "hit"),
            ("poll.ts", 5, "set-interval", "escaped"),
            ("spin.css", 2, "css-infinite", "hit"),
        ])

    def test_unknown_lang_is_an_error(self) -> None:
        result = self.audit.run("--lang", "zig")
        self.assertEqual(result.returncode, 2)
        self.assertIn("unknown --lang zig", result.stderr)


class FocusedFixtureTests(unittest.TestCase):
    """One small source per case, in a fixture repository with nothing else in it."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        fixture(self.root, periodic=[{"owner": "Lease.renewal", "period_s": 60, "why": "lease expires at 120 s"}])
        for rel in ("lib.rs", "ticker.rs", "support.rs", "pathed_tests.rs", "deeper.rs", "tests/nested.rs"):
            (self.root / "cmux-tui/crates/demo/src" / rel).unlink()
        self.audit = Audit(self.root)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def rust(self, text: str, rel: str = "lib.rs") -> list[dict]:
        write(self.root, f"cmux-tui/crates/demo/src/{rel}", text)
        return self.audit.at(f"demo/src/{rel}", "--lang", "rust")

    def swift(self, text: str) -> list[dict]:
        write(self.root, "Packages/macOS/CmuxNext/Sources/CmuxNextApp/Case.swift", text)
        return self.audit.at("CmuxNextApp/Case.swift", "--lang", "swift")

    def shapes(self, hits: list[dict]) -> dict[tuple[int, str], str]:
        return {(h["line"], h["rule"]): h["shape"] for h in hits}

    # cfg(test) on a field, a variant or a struct-literal field ends at that field ------------------------

    def test_cfg_test_struct_field_does_not_hide_the_impl_after_it(self) -> None:
        hits = self.rust("""\
            struct W {
                c: std::sync::Condvar,
                #[cfg(test)]
                o: Option<u8>,
            }
            impl W {
                fn run(&self, g: std::sync::MutexGuard<'_, ()>) {
                    loop {
                        let _ = self.c.wait_timeout(g, std::time::Duration::from_millis(50));
                    }
                }
            }
            """)
        self.assertEqual([(h["line"], h["rule"], h["shape"]) for h in hits], [(9, "wait-timeout", "loop")])

    def test_cfg_test_last_field_without_comma_does_not_hide_the_impl_after_it(self) -> None:
        hits = self.rust("""\
            struct Q { cv: std::sync::Condvar, #[cfg(test)] hook: Option<u8> }
            impl Q {
                fn w(&self, rx: std::sync::mpsc::Receiver<u8>) {
                    let _ = rx.recv_timeout(std::time::Duration::from_secs(1));
                }
            }
            """)
        self.assertEqual([(h["line"], h["rule"]) for h in hits], [(4, "recv-timeout")])

    def test_cfg_test_enum_variants_do_not_hide_the_impl_after_them(self) -> None:
        hits = self.rust("""\
            enum E {
                Real,
                #[cfg(test)]
                Probe { n: u8 },
                #[cfg(test)]
                Tuple(u8),
            }
            impl E {
                fn w(&self, rx: std::sync::mpsc::Receiver<u8>) {
                    let _ = rx.recv_timeout(std::time::Duration::from_secs(1));
                }
            }
            """)
        self.assertEqual([(h["line"], h["rule"]) for h in hits], [(10, "recv-timeout")])

    def test_cfg_test_struct_literal_field_does_not_hide_the_next_function(self) -> None:
        hits = self.rust("""\
            fn make() -> Q {
                Q {
                    #[cfg(test)]
                    hook: None,
                    real: 1,
                }
            }
            fn later(rx: std::sync::mpsc::Receiver<u8>) {
                let _ = rx.recv_timeout(std::time::Duration::from_secs(1));
            }
            #[cfg(test)]
            fn only_in_tests(rx: std::sync::mpsc::Receiver<u8>) {
                let _ = rx.recv_timeout(std::time::Duration::from_secs(1));
            }
            """)
        self.assertEqual([(h["line"], h["rule"]) for h in hits], [(9, "recv-timeout")])

    def test_cfg_predicates_that_need_test_are_test_only(self) -> None:
        write(self.root, "cmux-tui/crates/demo/src/unix_tests.rs", "fn t() { std::thread::sleep(D); }\n")
        write(self.root, "cmux-tui/crates/demo/src/any_tests.rs", "fn t() { std::thread::sleep(D); }\n")
        write(self.root, "cmux-tui/crates/demo/src/shipped.rs", "fn s() { std::thread::sleep(D); }\n")
        write(self.root, "cmux-tui/crates/demo/src/not_test.rs", "fn s() { std::thread::sleep(D); }\n")
        hits = self.rust("""\
            #[cfg(all(unix, test))]
            mod unix_tests;
            #[cfg(all(any(unix, windows), test))]
            mod t {
                fn w(rx: std::sync::mpsc::Receiver<u8>) { let _ = rx.recv_timeout(D); }
            }
            #[cfg(any(test, feature = "test-support"))]
            mod any_tests;
            #[cfg(any(unix, test))]
            mod shipped;
            #[cfg(not(test))]
            mod not_test;
            fn live(rx: std::sync::mpsc::Receiver<u8>) { let _ = rx.recv_timeout(D); }
            """)
        self.assertEqual([(h["line"], h["rule"]) for h in hits], [(13, "recv-timeout")])
        files = {h["file"].rsplit("/", 1)[-1] for h in self.audit.hits("--lang", "rust")}
        self.assertEqual(files, {"lib.rs", "shipped.rs", "not_test.rs"})

    def test_mod_declared_after_a_cfg_test_field_is_audited(self) -> None:
        write(self.root, "cmux-tui/crates/demo/src/worker.rs", "pub fn w() { std::thread::sleep(std::time::Duration::ZERO); }\n")
        self.rust("""\
            struct S {
                #[cfg(test)]
                probe: u8,
            }
            mod worker;
            """)
        self.assertEqual([h["rule"] for h in self.audit.at("demo/src/worker.rs", "--lang", "rust")], ["thread-sleep"])

    # loop vs oneshot: a wait in a branch that leaves the loop is not on the looping path ---------------------

    def test_try_wait_poll_with_wait_in_the_kill_arm_is_a_loop(self) -> None:
        hits = self.rust("""\
            fn probe(mut child: std::process::Child) -> bool {
                loop {
                    match child.try_wait() {
                        Ok(Some(status)) => return status.success(),
                        Ok(None) => {
                            std::thread::sleep(std::time::Duration::from_millis(5));
                        }
                        _ => {
                            let _ = child.kill();
                            let _ = child.wait();
                            return false;
                        }
                    }
                }
            }
            """)
        self.assertEqual(self.shapes(hits), {(3, "try-wait"): "loop", (6, "thread-sleep"): "loop"})

    def test_recv_timeout_poll_with_join_only_on_exit_paths_is_a_loop(self) -> None:
        hits = self.rust("""\
            fn run(rx: std::sync::mpsc::Receiver<u8>, writer: std::thread::JoinHandle<()>) -> anyhow::Result<()> {
                loop {
                    if done() {
                        let _ = writer.join();
                        return Ok(());
                    }
                    if late() {
                        let _ = writer.join();
                        anyhow::bail!("timed out");
                    }
                    match rx.recv_timeout(std::time::Duration::from_millis(10)) {
                        Ok(_) => {
                            let _ = writer.join();
                            return Ok(());
                        }
                        Err(_) => {}
                    }
                }
            }
            """)
        self.assertEqual(self.shapes(hits), {(11, "recv-timeout"): "loop"})

    def test_untimed_wait_on_the_looping_path_keeps_oneshot(self) -> None:
        hits = self.rust("""\
            fn pump(rx: std::sync::mpsc::Receiver<u8>, deadline: Option<std::time::Duration>) {
                loop {
                    match deadline {
                        Some(d) => {
                            let _ = rx.recv_timeout(d);
                        }
                        None => {
                            let _ = rx.recv();
                        }
                    }
                }
            }
            """)
        self.assertEqual(self.shapes(hits), {(5, "recv-timeout"): "oneshot"})

    def test_read_of_a_stream_with_a_read_timeout_is_not_an_event(self) -> None:
        hits = self.rust("""\
            use std::io::Read;
            fn answer(mut stream: std::net::TcpStream) {
                let mut chunk = [0u8; 64];
                loop {
                    stream.set_read_timeout(Some(std::time::Duration::from_millis(50))).ok();
                    if stream.read(&mut chunk).is_err() {
                        continue;
                    }
                }
            }
            fn blocking(mut stream: std::net::TcpStream) {
                let mut chunk = [0u8; 64];
                loop {
                    let _ = stream.read(&mut chunk);
                    std::thread::sleep(std::time::Duration::from_millis(5));
                }
            }
            """)
        self.assertEqual(self.shapes(hits), {(5, "read-timeout"): "loop", (15, "thread-sleep"): "oneshot"})

    def test_rpc_read_and_a_changed_query_are_not_events(self) -> None:
        hits = self.rust("""\
            fn pump(connection: &mut Connection, done: &Done) {
                loop {
                    let _ = connection.read(Operation::List, json!({"limit": 50}));
                    if done.changed() || late() {
                        break;
                    }
                    std::thread::sleep(POLL);
                }
            }
            """)
        self.assertEqual(self.shapes(hits), {(7, "thread-sleep"): "loop"})

    # select!: a timed arm races the other arms; an arm that leaves the loop is not on the looping path -------

    def test_select_timer_with_a_stop_arm_that_returns_is_a_loop(self) -> None:
        hits = self.rust("""\
            async fn usage(stop: Notify, d: std::time::Duration) {
                loop {
                    tokio::select! {
                        _ = stop.notified() => return,
                        _ = tokio::time::sleep(d) => {}
                    }
                    poll().await;
                }
            }
            async fn braced(stop: Notify, d: std::time::Duration) {
                loop {
                    tokio::select! {
                        _ = stop.notified() => {
                            return;
                        }
                        _ = tokio::time::sleep(d) => {}
                    }
                }
            }
            """)
        self.assertEqual(self.shapes(hits), {(5, "tokio-sleep"): "loop", (16, "tokio-sleep"): "loop"})

    def test_select_heartbeat_and_poll_raced_against_an_event_are_loops(self) -> None:
        hits = self.rust("""\
            async fn heartbeat(mut close: tokio::sync::watch::Receiver<bool>, d: std::time::Duration) {
                loop {
                    tokio::select! {
                        _ = tokio::time::sleep(d) => {}
                        _ = close.changed() => return,
                    }
                    beat();
                }
            }
            async fn show(mut finished: tokio::sync::watch::Receiver<bool>) {
                loop {
                    print();
                    tokio::select! {
                        _ = finished.changed() => {},
                        _ = tokio::time::sleep(std::time::Duration::from_millis(100)) => {},
                    }
                }
            }
            """)
        self.assertEqual(self.shapes(hits), {(4, "tokio-sleep"): "loop", (15, "tokio-sleep"): "loop"})

    def test_select_timer_whose_arm_returns_is_a_oneshot_deadline(self) -> None:
        hits = self.rust("""\
            async fn read(mut rx: tokio::sync::mpsc::Receiver<u8>, d: std::time::Duration) -> Result<(), E> {
                loop {
                    tokio::select! {
                        m = rx.recv() => handle(m),
                        _ = tokio::time::sleep(d) => return Err(E),
                    }
                }
            }
            """)
        self.assertEqual(self.shapes(hits), {(5, "tokio-sleep"): "oneshot"})

    def test_pinned_timer_raced_in_an_async_block_is_a_loop(self) -> None:
        # acpmux server/wait.rs: a 1 s re-evaluate made again on every turn, raced against an event.
        hits = self.rust("""\
            async fn wait(mut events: tokio::sync::broadcast::Receiver<u8>, deadline: Option<tokio::time::Instant>) {
                loop {
                    if done() {
                        return;
                    }
                    let poll = tokio::time::sleep(std::time::Duration::from_millis(1000));
                    tokio::pin!(poll);
                    let wake = async {
                        tokio::select! {
                            _ = &mut poll => {}
                            r = events.recv() => {
                                note(r);
                            }
                        }
                    };
                    match deadline {
                        Some(d) => {
                            if tokio::time::timeout_at(d, wake).await.is_err() {
                                return;
                            }
                        }
                        None => wake.await,
                    }
                }
            }
            """)
        self.assertEqual(self.shapes(hits), {(6, "tokio-sleep"): "loop"})

    def test_a_wait_in_a_spawned_body_does_not_make_the_loop_evented(self) -> None:
        hits = self.rust("""\
            fn threads(rx: std::sync::mpsc::Receiver<u8>) {
                loop {
                    let h = std::thread::spawn(move || {
                        rx.recv()
                    });
                    std::thread::sleep(std::time::Duration::from_secs(1));
                }
            }
            async fn tasks(mut x: tokio::sync::mpsc::Receiver<u8>) {
                loop {
                    tokio::spawn(async move {
                        x.recv().await
                    });
                    tokio::time::sleep(std::time::Duration::from_secs(1)).await;
                }
            }
            async fn awaited(mut x: tokio::sync::mpsc::Receiver<u8>) {
                loop {
                    let w = async {
                        x.recv().await
                    };
                    w.await;
                    tokio::time::sleep(std::time::Duration::from_secs(1)).await;
                }
            }
            """)
        self.assertEqual(self.shapes(hits), {
            (6, "thread-sleep"): "loop", (14, "tokio-sleep"): "loop", (23, "tokio-sleep"): "oneshot",
        })

    def test_swift_loop_after_a_statement_is_a_loop(self) -> None:
        hits = self.swift("""\
            func poll() async {
                let interval = Duration.seconds(1)
                while !Task.isCancelled {
                    let x = 1
                    if x > 0 {
                        try? await Task.sleep(for: interval)
                    }
                }
            }
            func drain() async {
                var n = 0
                repeat {
                    n += 1
                    try? await Task.sleep(for: .seconds(1))
                } while true
            }
            """)
        self.assertEqual(self.shapes(hits), {
            (3, "loop-that-can-spin"): "loop", (6, "sleep"): "loop",
            (12, "loop-that-can-spin"): "loop", (14, "sleep"): "loop", (15, "loop-that-can-spin"): "loop",
        })

    def test_swift_repeating_timers_are_loops(self) -> None:
        hits = self.swift("""\
            import Foundation
            final class Clock {
                let a = Timer(timeInterval: 1, repeats: true) { _ in }
                let b = Timer.scheduledTimer(withTimeInterval: 1,
                                             repeats: true) { _ in }
                let c = Timer.publish(every: 1, on: .main, in: .common)
                let d = Timer(timeInterval: 1, repeats: false) { _ in }
                func source(t: DispatchSourceTimer) {
                    t.schedule(deadline: .now(), repeating: .seconds(1))
                    t.schedule(deadline: .now(), repeating: .never)
                }
            }
            """)
        self.assertEqual(self.shapes(hits), {
            (3, "timer"): "loop", (4, "timer"): "loop", (6, "timer"): "loop", (7, "timer"): "oneshot",
            (9, "timer"): "loop", (10, "timer"): "oneshot",
        })

    # Escapes --------------------------------------------------------------------------------------------------

    def test_escape_needs_a_reason_and_may_continue_on_the_next_comment_line(self) -> None:
        hits = self.rust("""\
            fn a(rx: std::sync::mpsc::Receiver<u8>) {
                // wakeup-allow: deadline
                let _ = rx.recv_timeout(std::time::Duration::from_secs(1));
            }
            fn b(rx: std::sync::mpsc::Receiver<u8>) {
                // wakeup-allow: deadline
                // the handshake answers within 2 s or the peer is gone
                let _ = rx.recv_timeout(std::time::Duration::from_secs(2));
            }
            """)
        self.assertEqual([(h["line"], h["status"]) for h in hits], [(3, "no-reason"), (8, "escaped")])
        strict = self.audit.run("--lang", "rust", "--strict")
        self.assertEqual(strict.returncode, 1)
        self.assertIn("lib.rs:3: recv-timeout (oneshot) no-reason deadline", strict.stdout)
        self.assertNotIn("lib.rs:8:", strict.stdout)

    def test_an_escape_on_one_match_arm_does_not_cover_the_next_arm(self) -> None:
        hits = self.rust("""\
            fn a(x: u8) {
                match x {
                    1 => std::thread::sleep(std::time::Duration::from_secs(1)), // wakeup-allow: bounded three tries
                    2 => std::thread::sleep(std::time::Duration::from_secs(5)),
                    // wakeup-allow: deadline the peer answers within 2 s or it is gone
                    _ => std::thread::sleep(std::time::Duration::from_secs(2)),
                }
                let v = vec![
                    1, // wakeup-allow: debug a comment on the entry above
                    std::thread::sleep(std::time::Duration::from_secs(3)),
                ];
            }
            """)
        self.assertEqual([(h["line"], h["status"]) for h in hits],
                         [(3, "escaped"), (4, "hit"), (6, "escaped"), (10, "hit")])

    def test_escape_inside_a_string_literal_does_not_count(self) -> None:
        hits = self.rust("""\
            fn a() {
                std::thread::sleep(std::time::Duration::from_secs(1)); let _ = "wakeup-allow: debug x";
            }
            """)
        self.assertEqual([(h["line"], h["status"]) for h in hits], [(2, "hit")])

    def test_escape_above_a_multi_line_statement_covers_its_continuation_line(self) -> None:
        hits = self.rust("""\
            fn a(rx: std::sync::mpsc::Receiver<u8>) {
                // wakeup-allow: deadline the reply comes within 1 s or the peer is gone
                let r = rx
                    .recv_timeout(std::time::Duration::from_secs(1));
                let s = rx
                    .recv_timeout(std::time::Duration::from_secs(1));
            }
            """)
        self.assertEqual([(h["line"], h["status"]) for h in hits], [(4, "escaped"), (6, "hit")])

    def test_periodic_escape_without_an_owner_is_unlisted(self) -> None:
        hits = self.rust("""\
            fn a() {
                // wakeup-allow: periodic
                std::thread::sleep(std::time::Duration::from_secs(60));
            }
            """)
        self.assertEqual([(h["status"], h["escape"]) for h in hits], [("periodic-unlisted", "periodic (no owner)")])

    def test_one_unlisted_periodic_escape_alone_fails_strict(self) -> None:
        source = """\
            fn a() {
                loop {
                    // wakeup-allow: periodic OWNER every 60 s
                    std::thread::sleep(std::time::Duration::from_secs(60));
                }
            }
            """
        self.rust(source.replace("OWNER", "Unlisted.renewal"))
        strict = self.audit.run("--lang", "rust", "--strict")
        self.assertEqual(strict.returncode, 1, strict.stdout)
        self.assertEqual(strict.stdout.count("wakeup-audit: cmux-tui"), 1)
        self.assertIn("periodic-unlisted periodic Unlisted.renewal", strict.stdout)
        self.rust(source.replace("OWNER", "Lease.renewal"))
        listed = self.audit.run("--lang", "rust", "--strict")
        self.assertEqual(listed.returncode, 0, listed.stdout + listed.stderr)

    def test_queue_lists_what_strict_refuses_with_the_escape_status_in_a_fifth_column(self) -> None:
        self.rust("""\
            fn a(rx: std::sync::mpsc::Receiver<u8>) {
                let _ = rx.recv_timeout(std::time::Duration::from_secs(1));
                std::thread::sleep(std::time::Duration::from_secs(1)); // wakeup-allow: because short
                // wakeup-allow: deadline
                std::thread::sleep(std::time::Duration::from_secs(2));
                // wakeup-allow: periodic Unlisted.tick every 60 s
                std::thread::sleep(std::time::Duration::from_secs(60));
                // wakeup-allow: bounded three tries, then the caller reports it
                std::thread::sleep(std::time::Duration::from_secs(3));
            }
            """)
        expected = [
            "rust:demo/lib\tcmux-tui/crates/demo/src/lib.rs:2\trecv-timeout\toneshot",
            "rust:demo/lib\tcmux-tui/crates/demo/src/lib.rs:3\tthread-sleep\toneshot\tbad-escape",
            "rust:demo/lib\tcmux-tui/crates/demo/src/lib.rs:5\tthread-sleep\toneshot\tno-reason",
            "rust:demo/lib\tcmux-tui/crates/demo/src/lib.rs:7\tthread-sleep\toneshot\tperiodic-unlisted",
        ]
        strict = self.audit.run("--lang", "rust", "--strict", "--queue")
        self.assertEqual(strict.returncode, 1)
        self.assertEqual(strict.stdout.splitlines(), expected)
        plain = self.audit.run("--lang", "rust", "--queue")
        self.assertEqual(plain.returncode, 0)
        self.assertEqual(plain.stdout.splitlines(), expected)

    # Q13 ------------------------------------------------------------------------------------------------------

    def test_demand_sync_finds_the_paren_when_after_is_on_the_next_line(self) -> None:
        write(self.root, "Packages/macOS/CmuxNext/Sources/CmuxNextApp/Toast.swift", """\
            @MainActor final class Toast {
                private let timer = DemandTimer(owner: "toast")
                func show() {
                    timer.schedule(
                        after: .seconds(2)
                    ) { @MainActor [weak self] in self?.hide() }
                }
                func hide() {}
            }
            """)
        lines = self.audit.run("--queue", "demand-sync").stdout.splitlines()
        self.assertEqual(lines, ["swift:CmuxNextApp\tPackages/macOS/CmuxNext/Sources/CmuxNextApp/Toast.swift:4\t"
                                 "demand-sync\toneshot"])


if __name__ == "__main__":
    unittest.main()
