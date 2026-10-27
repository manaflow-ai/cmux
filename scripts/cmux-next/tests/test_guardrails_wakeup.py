#!/usr/bin/env python3
"""guardrails.py's wakeup-ext rule (p14-energy-006): the push may not add an idle wakeup outside CmuxNext Sources.

Each case commits into a throwaway repository and runs `guardrails.check` on what the commit adds. The rules and
the escape vocabulary are wakeup-audit.py's (beside guardrails.py); base hits never refuse. Not on CI (Lawrence
2026-10-23: no new CI tests): run it yourself after a change to guardrails.py's wakeup-ext or to wakeup-audit.py:

  python3 scripts/cmux-next/tests/test_guardrails_wakeup.py
"""
from __future__ import annotations

import contextlib
import importlib.util
import io
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]

_spec = importlib.util.spec_from_file_location("cmux_next_guardrails_p14_006", SCRIPTS / "guardrails.py")
guardrails = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = guardrails
_spec.loader.exec_module(guardrails)

MANIFEST = """// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "CmuxNext",
    dependencies: [
        .package(path: "../../Shared/CmuxLinked"),
        .package(path: "../CmuxUpdater"),
    ],
    targets: []
)
"""
BUDGET = '{"allowed_periodic": [{"owner": "PL-idle-sampler", "period_s": 60, "why": "fixture"}]}\n'
SHARED = "Packages/Shared/CmuxLinked/Sources/CmuxLinked"
UPDATER = "Packages/macOS/CmuxUpdater/Sources/CmuxUpdater"
CRATE = "cmux-tui/crates/fixture/src"
WEB = "webviews/src"
SHIM = "Packages/macOS/CmuxNext/CEFShim/src"

RUST_BASE = """use std::time::Duration;

pub fn retry() {
    std::thread::sleep(Duration::from_millis(5));
}

pub fn quiet() {}
"""
WEB_BASE = """export function start(tick: () => void): number {
  return setInterval(tick, 1000);
}

export const name = "old";
"""
SHIM_BASE = """#include <unistd.h>

void ShimQuiet() {}
"""
LIB_RS = "pub mod helpers;\n#[cfg(test)]\nmod fixtures;\n"


class WakeupExtTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="cmux-guardrails-wakeup-")
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        self.repo = root / "repository"
        self.repo.mkdir()
        config = root / "gitconfig"
        config.write_text("[user]\n\tname = Fixture\n\temail = fixture@example.com\n[maintenance]\n\tauto = false\n"
                          "[gc]\n\tauto = 0\n")
        self.env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
        self.env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=str(config), HOME=str(root))
        self.git("init", "--quiet", "--initial-branch=feat-cmux-next")
        self.write("Packages/macOS/CmuxNext/Package.swift", MANIFEST)
        self.write("scripts/cmux-next/idle-budget.json", BUDGET)
        self.write(f"{CRATE}/lib.rs", LIB_RS)
        self.write(f"{CRATE}/helpers.rs", RUST_BASE)
        self.write(f"{CRATE}/fixtures.rs", "pub fn none() {}\n")
        self.write(f"{WEB}/poll.ts", WEB_BASE)
        self.write(f"{SHARED}/Clock.swift", "import Foundation\npublic struct Clock {}\n")
        self.write(f"{UPDATER}/Updater.swift", "import Foundation\npublic struct Updater {}\n")
        self.write("Packages/Shared/CmuxUnlinked/Sources/CmuxUnlinked/Other.swift", "public struct Other {}\n")
        self.write(f"{SHIM}/shim_process.mm", SHIM_BASE)
        self.base = self.commit("base")

    # ------------------------------------------------------------------ helpers

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.repo), *args], env=self.env, text=True, capture_output=True,
                              check=True).stdout

    def write(self, path, text):
        target = self.repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)

    def commit(self, message):
        self.git("add", "-A")
        self.git("commit", "--quiet", "--allow-empty", "-m", message)
        return self.git("rev-parse", "HEAD").strip()

    def wakeups(self, **files):
        """The wakeup-ext hits of one commit writing FILES ({path: text}) over the base."""
        for path, text in files.items():
            self.write(path, text)
        head = self.commit("change")
        refusals, warnings = guardrails.check(self.repo, self.base, head)
        failures = [text for kind, text in warnings if kind == "guardrails"]
        self.assertEqual(failures, [], "a rule failed open")
        return [hit for rule, hits in refusals if rule.id == "wakeup-ext" for hit in hits]

    def assertRefused(self, hits, path, line):
        self.assertIn((path, line), [(h.path, h.number) for h in hits], hits)

    # ------------------------------------------------------------------ rule list

    def test_list_names_the_rule_with_why_do_and_escape(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(guardrails.main(["--list"]), 0)
        block = re.search(r"^wakeup-ext: .*\n  why: .+\n  do:  .+\n  escape: (.+)$", out.getvalue(), re.MULTILINE)
        self.assertIsNotNone(block, out.getvalue())
        for word in guardrails.wakeup_audit().ESCAPE_WORDS:
            self.assertIn(word, block.group(1))

    # ------------------------------------------------------------------ refused

    def test_added_set_interval_in_webviews_src_is_refused(self):
        hits = self.wakeups(**{f"{WEB}/blink.ts": "export function blink(f: () => void) {\n  setInterval(f, 500);\n}\n"})
        self.assertRefused(hits, f"{WEB}/blink.ts", 2)
        self.assertIn("set-interval", hits[0].cause)

    def test_added_css_infinite_animation_is_refused(self):
        hits = self.wakeups(**{f"{WEB}/spin.css": ".spin {\n  animation: spin 1s linear infinite;\n}\n"})
        self.assertRefused(hits, f"{WEB}/spin.css", 2)

    def test_added_thread_sleep_in_a_crate_src_is_refused(self):
        hits = self.wakeups(**{f"{CRATE}/helpers.rs": RUST_BASE.replace(
            "pub fn quiet() {}", "pub fn quiet() {\n    std::thread::sleep(Duration::from_secs(1));\n}")})
        self.assertRefused(hits, f"{CRATE}/helpers.rs", 8)
        self.assertEqual(len(hits), 1, hits)  # the base sleep on line 4 is not the push's

    def test_added_timer_in_an_app_linked_shared_package_is_refused(self):
        text = "import Foundation\nfunc tick() {\n    _ = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in }\n}\n"
        hits = self.wakeups(**{f"{SHARED}/Tick.swift": text, f"{UPDATER}/Check.swift": text})
        self.assertRefused(hits, f"{SHARED}/Tick.swift", 3)
        self.assertRefused(hits, f"{UPDATER}/Check.swift", 3)
        self.assertIn("loop", hits[0].cause)  # `repeats: true` is a repeating source

    def test_added_dispatch_after_in_the_cef_shim_is_refused(self):
        with cxx_rules():
            hits = self.wakeups(**{f"{SHIM}/shim_process.mm": SHIM_BASE.replace(
                "void ShimQuiet() {}",
                "void ShimQuiet() {\n    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0), q, ^{ Pump(); });\n}")})
        self.assertRefused(hits, f"{SHIM}/shim_process.mm", 4)

    def test_an_escape_word_outside_the_vocabulary_is_refused(self):
        hits = self.wakeups(**{f"{CRATE}/helpers.rs": RUST_BASE.replace(
            "pub fn quiet() {}",
            "pub fn quiet() {\n    // wakeup-allow: later we fix it\n    std::thread::sleep(Duration::from_secs(1));\n}")})
        self.assertRefused(hits, f"{CRATE}/helpers.rs", 9)
        self.assertIn("bad-escape `later`", hits[0].cause)

    def test_a_periodic_escape_needs_an_owner_in_the_idle_budget(self):
        line = "  // wakeup-allow: periodic {owner} samples idle wakeups\n  setInterval(sample, 60000);\n"
        listed = self.wakeups(**{f"{WEB}/listed.ts": line.format(owner="PL-idle-sampler")})
        self.assertEqual(listed, [])
        unlisted = self.wakeups(**{f"{WEB}/unlisted.ts": line.format(owner="PL-nobody")})
        self.assertRefused(unlisted, f"{WEB}/unlisted.ts", 2)
        self.assertIn("periodic-unlisted", unlisted[0].cause)

    def test_deleting_the_escape_of_an_unchanged_hit_is_refused(self):
        escaped = RUST_BASE.replace("pub fn quiet() {}", "pub fn quiet() {\n    // wakeup-allow: deadline one-shot "
                                    "connect timeout\n    std::thread::sleep(Duration::from_secs(1));\n}")
        self.write(f"{CRATE}/helpers.rs", escaped)
        self.base = self.commit("escaped base")
        hits = self.wakeups(**{f"{CRATE}/helpers.rs": escaped.replace(
            "    // wakeup-allow: deadline one-shot connect timeout\n", "")})
        self.assertRefused(hits, f"{CRATE}/helpers.rs", 8)

    def test_removing_cfg_test_around_a_sleep_is_refused(self):
        tested = "pub fn quiet() {}\n\n#[cfg(test)]\nmod tests {\n    fn wait() {\n" \
                 "        std::thread::sleep(std::time::Duration::from_millis(1));\n    }\n}\n"
        self.write(f"{CRATE}/quiet.rs", tested)
        self.base = self.commit("test base")
        hits = self.wakeups(**{f"{CRATE}/quiet.rs": tested.replace("#[cfg(test)]\n", "")})
        self.assertRefused(hits, f"{CRATE}/quiet.rs", 5)

    def test_dropping_cfg_test_from_a_mod_declaration_alone_opens_the_unchanged_module(self):
        sleep = "pub fn wait() {\n    std::thread::sleep(std::time::Duration::from_millis(1));\n}\n"
        self.write(f"{CRATE}/fixtures.rs", "mod deep;\n" + sleep)
        self.write(f"{CRATE}/fixtures/deep.rs", sleep)
        self.base = self.commit("test-only module base")
        hits = self.wakeups(**{f"{CRATE}/lib.rs": LIB_RS.replace("#[cfg(test)]\n", "")})
        self.assertRefused(hits, f"{CRATE}/fixtures.rs", 3)
        self.assertRefused(hits, f"{CRATE}/fixtures/deep.rs", 2)  # a module of the module: test-only at base too
        self.assertEqual(len(hits), 2, hits)

    def test_deleting_a_test_only_mod_declaration_opens_the_module_wakeup_audit_then_reads(self):
        sleep = "pub fn wait() {\n    std::thread::sleep(std::time::Duration::from_millis(1));\n}\n"
        self.write(f"{CRATE}/fixtures.rs", sleep)
        self.base = self.commit("test-only module base")
        hits = self.wakeups(**{f"{CRATE}/lib.rs": "pub mod helpers;\n"})
        self.assertRefused(hits, f"{CRATE}/fixtures.rs", 2)

    def test_an_owner_added_to_the_idle_budget_in_the_same_push_does_not_count(self):
        budget = BUDGET.replace("]}", ', {"owner": "PL-me", "period_s": 60, "why": "my sampler"}]}')
        hits = self.wakeups(**{"scripts/cmux-next/idle-budget.json": budget, f"{WEB}/mine.ts":
                               "// wakeup-allow: periodic PL-me samples\nsetInterval(sample, 60000);\n"})
        self.assertRefused(hits, f"{WEB}/mine.ts", 2)
        self.assertIn("periodic-unlisted", hits[0].cause)

    def test_an_idle_budget_entry_below_its_limits_is_refused(self):
        budget = BUDGET.replace("]}", ', {"owner": "PL-me", "period_s": 0.5, "why": "fast"}]}')
        hits = self.wakeups(**{"scripts/cmux-next/idle-budget.json": budget})
        self.assertEqual([h.path for h in hits], ["scripts/cmux-next/idle-budget.json"], hits)
        self.assertIn("period_s below", hits[0].text)
        broken = self.wakeups(**{"scripts/cmux-next/idle-budget.json": "{not json"})
        self.assertEqual([h.path for h in broken], ["scripts/cmux-next/idle-budget.json"], broken)

    def test_taking_an_owner_off_the_idle_budget_opens_its_unchanged_escapes(self):
        self.write(f"{WEB}/sampler.ts", "// wakeup-allow: periodic PL-idle-sampler samples\nsetInterval(s, 60000);\n")
        self.base = self.commit("periodic base")
        hits = self.wakeups(**{"scripts/cmux-next/idle-budget.json": '{"allowed_periodic": []}\n'})
        self.assertRefused(hits, f"{WEB}/sampler.ts", 2)

    def test_a_removed_sleep_does_not_pay_for_a_timed_receive(self):
        hits = self.wakeups(**{f"{CRATE}/helpers.rs": RUST_BASE.replace(
            "std::thread::sleep(Duration::from_millis(5));", "let _ = rx.recv_timeout(Duration::from_millis(5));")})
        self.assertRefused(hits, f"{CRATE}/helpers.rs", 4)
        self.assertIn("recv-timeout", hits[0].cause)

    def test_a_loop_around_a_one_shot_sleep_is_refused(self):
        hits = self.wakeups(**{f"{CRATE}/helpers.rs": RUST_BASE.replace(
            "    std::thread::sleep(Duration::from_millis(5));\n",
            "    loop {\n        std::thread::sleep(Duration::from_millis(5));\n    }\n")})
        self.assertRefused(hits, f"{CRATE}/helpers.rs", 5)
        self.assertIn("loop", hits[0].cause)

    def test_linking_a_package_in_the_manifest_alone_opens_its_sources(self):
        timer = "import Foundation\nlet t = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in }\n"
        self.write("Packages/Shared/CmuxUnlinked/Sources/CmuxUnlinked/Tick.swift", timer)
        self.base = self.commit("unlinked timer base")
        hits = self.wakeups(**{"Packages/macOS/CmuxNext/Package.swift": MANIFEST.replace(
            '        .package(path: "../CmuxUpdater"),\n',
            '        .package(path: "../CmuxUpdater"),\n        .package(path: "../../Shared/CmuxUnlinked"),\n')})
        self.assertRefused(hits, "Packages/Shared/CmuxUnlinked/Sources/CmuxUnlinked/Tick.swift", 2)

    # ------------------------------------------------------------------ passes

    def test_putting_a_mod_declaration_under_cfg_test_passes(self):
        sleep = "pub fn wait() {\n    std::thread::sleep(std::time::Duration::from_millis(1));\n}\n"
        self.write(f"{CRATE}/lib.rs", LIB_RS.replace("#[cfg(test)]\n", ""))
        self.write(f"{CRATE}/fixtures.rs", sleep)
        self.base = self.commit("compiled module base")
        self.assertEqual(self.wakeups(**{f"{CRATE}/lib.rs": LIB_RS}), [])

    def test_a_loop_made_one_shot_by_its_event_passes(self):
        looped = RUST_BASE.replace("    std::thread::sleep(Duration::from_millis(5));\n",
                                   "    loop {\n        std::thread::sleep(Duration::from_millis(5));\n    }\n")
        self.write(f"{CRATE}/helpers.rs", looped)
        self.base = self.commit("loop base")
        hits = self.wakeups(**{f"{CRATE}/helpers.rs": looped.replace(
            "    loop {\n", "    loop {\n        let _ = rx.recv();\n")})
        self.assertEqual(hits, [])

    def test_the_same_line_with_a_deadline_escape_passes(self):
        hits = self.wakeups(**{f"{CRATE}/helpers.rs": RUST_BASE.replace(
            "pub fn quiet() {}",
            "pub fn quiet() {\n    std::thread::sleep(Duration::from_secs(1)); // wakeup-allow: deadline one-shot "
            "connect timeout\n}")})
        self.assertEqual(hits, [])

    def test_unchanged_base_hits_are_not_refused(self):
        hits = self.wakeups(**{f"{WEB}/poll.ts": WEB_BASE.replace('"old"', '"new"'),
                               f"{CRATE}/helpers.rs": RUST_BASE.replace("pub fn quiet() {}", "pub fn quiet() -> u8 { 0 }")})
        self.assertEqual(hits, [])

    def test_editing_a_base_hit_line_is_not_new_debt(self):
        hits = self.wakeups(**{f"{WEB}/poll.ts": WEB_BASE.replace("1000", "2000"),
                               f"{CRATE}/helpers.rs": RUST_BASE.replace("from_millis(5)", "from_millis(10)")})
        self.assertEqual(hits, [])

    def test_moving_a_hit_to_another_file_is_free(self):
        hits = self.wakeups(**{f"{WEB}/poll.ts": 'export const name = "old";\n',
                               f"{WEB}/start.ts": WEB_BASE.split("\n\n")[0] + "\n"})
        self.assertEqual(hits, [])

    def test_test_only_code_and_unlinked_packages_are_not_judged(self):
        sleep = "pub fn wait() {\n    std::thread::sleep(std::time::Duration::from_millis(1));\n}\n"
        timer = "import Foundation\nlet t = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in }\n"
        hits = self.wakeups(**{
            f"{CRATE}/fixtures.rs": sleep,  # declared under #[cfg(test)] in lib.rs
            f"{CRATE}/inline.rs": "#[cfg(test)]\nmod tests {\n" + sleep + "}\n",
            "cmux-tui/crates/fixture/tests/it.rs": sleep,
            f"{WEB}/blink.test.ts": "setInterval(() => {}, 5);\n",
            f"{WEB}/gallery/demo.tsx": "setInterval(() => {}, 5);\n",
            "Packages/Shared/CmuxUnlinked/Sources/CmuxUnlinked/Tick.swift": timer,
            "Packages/Shared/CmuxLinked/Tests/CmuxLinkedTests/TickTests.swift": timer,
        })
        self.assertEqual(hits, [])

    def test_a_module_lib_rs_no_longer_declares_test_only_is_judged(self):
        sleep = "pub fn wait() {\n    std::thread::sleep(std::time::Duration::from_millis(1));\n}\n"
        hits = self.wakeups(**{f"{CRATE}/fixtures.rs": sleep, f"{CRATE}/lib.rs": LIB_RS.replace("#[cfg(test)]\n", "")})
        self.assertRefused(hits, f"{CRATE}/fixtures.rs", 2)

    def test_cmux_next_sources_are_left_to_check_concurrency(self):
        hits = self.wakeups(**{"Packages/macOS/CmuxNext/Sources/CmuxNextKit/Tick.swift":
                               "import Foundation\nlet t = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in }\n"})
        self.assertEqual(hits, [])


@contextlib.contextmanager
def cxx_rules():
    """wakeup-audit's cxx language (p14-energy-113): its own rules once it has them, else a stand-in with the same
    interface (CXX_ROOTS, CXX_SUFFIXES, CXX_RULES) so the guardrail's wiring is tested before 113 lands."""
    wa = guardrails.wakeup_audit()
    if getattr(wa, "CXX_RULES", None):
        yield
        return
    stand_in = {
        "CXX_ROOTS": {"shim": "Packages/macOS/CmuxNext/CEFShim/src"},
        "CXX_SUFFIXES": (".mm", ".m", ".h", ".cc", ".cpp"),
        "CXX_RULES": [wa.Rule("dispatch-after", "dispatch_after (post on the event)",
                              re.compile(r"\bdispatch_after(?:_f)?\("), literal="dispatch_after")],
    }
    for name, value in stand_in.items():
        setattr(wa, name, value)
    guardrails.wakeup_rules.cache_clear()
    try:
        yield
    finally:
        for name in stand_in:
            delattr(wa, name)
        guardrails.wakeup_rules.cache_clear()


if __name__ == "__main__":
    unittest.main()
