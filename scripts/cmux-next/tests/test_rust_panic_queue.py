#!/usr/bin/env python3
"""rust_panic_ratchet.py --queue: the Q10 fix queue (chrome-parity task p10-stability-210).

Fixture clippy JSON and a fixture checkout (OWNERS.md and crate sources) drive the generator: every deny-lint
hit lands in exactly one task, no task holds more than 50 hits, a large file splits into balanced line ranges,
small files of one directory and owner pack together, and each task names its crate, module, owner, class
and boundary error type. Merged Linux and macOS runs count a shared line once and mark the hits one run saw.

Not a CI job (Lawrence 2026-10-23: no new CI gates): run it yourself after a change to the ratchet:
  python3 -I scripts/cmux-next/tests/test_rust_panic_queue.py      (or: python3 -m pytest <this file>)
"""

from __future__ import annotations

import collections
import contextlib
import importlib.util
import io
import json
import random
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]

OWNERS = """# owners

| Area | Paths | Owner | Read first |
|---|---|---|---|
| cmux-tui daemon | `cmux-tui/crates/cmux-tui-core/`, `cmux-tui/crates/cmux-pty/` | PL-daemon (session cmux-b6): request speed | x |
| Holder | `cmux-tui/crates/cmux-tui-core/src/holder_runtime.rs` | PL-daemon holder (session cmux-4f) | x |
| Glob row | `cmux-tui/crates/acpmux/src/hub/*.rs` | Performance Lead (PL-acpmux) | x |
"""

SOURCES = {
    # Q14 entry point: input class; returns its own error type.
    "cmux-tui/crates/cmux-tui-core/src/mux/frame.rs":
        "pub enum FrameError { Short }\npub fn parse_frame(b: &[u8]) -> Result<Frame, FrameError> { todo!() }\n"
        "fn other() -> Result<(), FrameError> { Ok(()) }\nfn generic<E>() -> Result<(), E> { todo!() }\n",
    # No input signal, no Result: invariant; error found in the directory's mod.rs.
    "cmux-tui/crates/cmux-tui-core/src/mux/layout.rs": "fn split(v: &[u8]) -> u8 { v[0] }\n",
    "cmux-tui/crates/cmux-tui-core/src/mux/mod.rs": "pub(crate) enum MuxError { Gone }\n",
    "cmux-tui/crates/cmux-tui-core/src/mux/tree.rs": "fn walk() -> std::io::Result<Vec<u8>> { Ok(vec![]) }\n",
    "cmux-tui/crates/cmux-tui-core/src/holder_runtime.rs":
        "fn load(p: &Path) -> anyhow::Result<String> { Ok(std::fs::read_to_string(p)?) }\n",
    # A daemon-row file next to the holder-row file: same crate and directory, another owner.
    "cmux-tui/crates/cmux-tui-core/src/store.rs": "fn get(v: &[u8]) -> u8 { v[0] }\n",
    # The crate alias `type Result<T> = Result<T, PtyError>` names the error of `-> Result<T>`.
    "cmux-tui/crates/cmux-pty/src/error.rs":
        "pub enum PtyError { Io }\npub type Result<T> = std::result::Result<T, PtyError>;\n",
    "cmux-tui/crates/cmux-pty/src/lib.rs": "pub fn open() -> Result<Fd> { todo!() }\n",
    # No error type anywhere in the crate, no OWNERS row: PL-stability, "none".
    "cmux-tui/crates/cmux-motion/src/spring.rs": "fn step(x: f64) -> f64 { x }\n",
    "cmux-tui/crates/acpmux/src/hub/route.rs": "fn route() {}\n",
    "cmux-tui/crates/acpmux/src/main.rs": "fn main() {}\n",
}


def load_ratchet():
    spec = importlib.util.spec_from_file_location("rust_panic_ratchet", SCRIPTS / "rust_panic_ratchet.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def artifact(crate):
    return {"reason": "compiler-artifact", "package_id": f"path+file:///w/cmux-tui/crates/{crate}#0.1.0",
            "target": {"kind": ["lib"]}}


def hit(file_name, line, lint="unwrap_used", column=5):
    crate = file_name.split("crates/", 1)[1].split("/", 1)[0]
    return {"reason": "compiler-message", "package_id": f"path+file:///w/cmux-tui/crates/{crate}#0.1.0",
            "target": {"kind": ["lib"]},
            "message": {"code": {"code": f"clippy::{lint}"},
                        "spans": [{"is_primary": True, "file_name": file_name, "line_start": line,
                                   "column_start": column}]}}


FINISHED = {"reason": "build-finished", "success": True}


def fixture_hits():
    """(clippy items, deny-hit count): 120 hits in one file, small files to pack, and a tracked lint."""
    items = [artifact(c) for c in ("cmux-tui-core", "cmux-pty", "cmux-motion", "acpmux", "cmux-gone")]
    items += [hit("crates/cmux-tui-core/src/mux/layout.rs", line, "indexing_slicing") for line in range(1, 121)]
    items += [hit("crates/cmux-tui-core/src/mux/frame.rs", line) for line in range(1, 31)]
    items += [hit("crates/cmux-tui-core/src/mux/mod.rs", line, "expect_used") for line in range(1, 16)]
    items += [hit("crates/cmux-tui-core/src/mux/tree.rs", line, "panic") for line in range(1, 11)]
    items += [hit("crates/cmux-tui-core/src/holder_runtime.rs", 3)]
    items += [hit("crates/cmux-tui-core/src/store.rs", line) for line in range(1, 4)]
    items += [hit("crates/cmux-pty/src/lib.rs", 1), hit("crates/cmux-pty/src/lib.rs", 1, column=9)]
    items += [hit("crates/cmux-motion/src/spring.rs", 1, "unreachable")]
    items += [hit("crates/acpmux/src/hub/route.rs", 1), hit("crates/acpmux/src/main.rs", 1)]
    items += [hit("crates/cmux-gone/src/lib.rs", 4)]  # not in the checkout: unreadable
    items += [hit("crates/cmux-motion/src/spring.rs", 1, "arithmetic_side_effects")]  # tracked, not queued
    return items + [FINISHED], 120 + 30 + 15 + 10 + 1 + 3 + 2 + 1 + 2 + 1


def assert_partition(test, queue, limit=50):
    """Every deny hit of the queue in exactly one task, no task above the limit."""
    seen = collections.Counter(h["loc"] + " " + h["lint"] for task in queue["tasks"] for h in task["hits"])
    test.assertTrue(all(n == 1 for n in seen.values()), [k for k, n in seen.items() if n > 1])
    test.assertEqual(sum(seen.values()), queue["total_hits"])
    for task in queue["tasks"]:
        test.assertLessEqual(task["hit_count"], limit, task["id"])
        test.assertEqual(task["hit_count"], len(task["hits"]))
        test.assertEqual(task["hit_count"], sum(f["hits"] for f in task["files"]))
        test.assertEqual(sum(task["counts"].values()), task["hit_count"])
    return seen


class QueueTests(unittest.TestCase):
    def setUp(self):
        self.ratchet = load_ratchet()
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self.tmp.name)
        (self.repo / "plans/cmux-next").mkdir(parents=True)
        (self.repo / "plans/cmux-next/OWNERS.md").write_text(OWNERS)
        for path, text in SOURCES.items():
            (self.repo / path).parent.mkdir(parents=True, exist_ok=True)
            (self.repo / path).write_text(text)
        self.baseline = self.repo / "baseline.json"
        self.baseline.write_text(json.dumps({"crates": {}}))
        self.ratchet.BASELINE = str(self.baseline)

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, name, items):
        path = self.repo / name
        path.write_text("".join(json.dumps(item) + "\n" for item in items))
        return str(path)

    def queue(self, *paths):
        runs = [self.ratchet.read_run(path, label) for label, path in paths]
        return self.ratchet.build_queue(runs, self.ratchet.QueueSource(str(self.repo)))

    def run_main(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        old = sys.argv
        sys.argv = ["rust_panic_ratchet.py", "--repo", str(self.repo), *argv]
        try:
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                try:
                    rc = self.ratchet.main()
                except SystemExit as exit_:
                    rc = exit_.code
        finally:
            sys.argv = old
        return rc, out.getvalue(), err.getvalue()

    def by_file(self, queue):
        tasks = collections.defaultdict(list)
        for task in queue["tasks"]:
            for info in task["files"]:
                tasks[info["path"]].append(task)
        return tasks

    def test_every_hit_in_exactly_one_task_and_none_above_50(self):
        items, deny = fixture_hits()
        queue = self.queue(("linux", self.write("linux.jsonl", items)))
        self.assertEqual(queue["total_hits"], deny)
        seen = assert_partition(self, queue)
        self.assertNotIn("arithmetic_side_effects", " ".join(seen))

    def test_large_file_splits_into_balanced_line_ranges(self):
        items, _ = fixture_hits()
        tasks = self.by_file(self.queue(("linux", self.write("linux.jsonl", items))))
        layout = tasks["cmux-tui/crates/cmux-tui-core/src/mux/layout.rs"]
        self.assertEqual([t["hit_count"] for t in layout], [40, 40, 40])
        self.assertEqual([t["files"][0]["lines"] for t in layout], ["1-40", "41-80", "81-120"])
        self.assertTrue(all(len(t["files"]) == 1 for t in layout))
        self.assertIn("part 2/3, lines 41-80", layout[1]["title"])

    def test_small_files_of_one_directory_pack_up_to_the_limit(self):
        items, _ = fixture_hits()
        tasks = self.by_file(self.queue(("linux", self.write("linux.jsonl", items))))
        frame = tasks["cmux-tui/crates/cmux-tui-core/src/mux/frame.rs"]
        self.assertEqual(len(frame), 1)
        # frame.rs 30 + mod.rs 15 = 45; tree.rs (10) would pass 50, so it starts the next task.
        self.assertEqual([f["path"].rsplit("/", 1)[1] for f in frame[0]["files"]], ["frame.rs", "mod.rs"])
        self.assertEqual(frame[0]["hit_count"], 45)
        self.assertEqual(frame[0]["module"], "cmux_tui_core::mux")
        self.assertEqual([f["path"].rsplit("/", 1)[1] for f in tasks["cmux-tui/crates/cmux-tui-core/src/mux/tree.rs"][0]["files"]],
                         ["tree.rs"])

    def test_task_fields_crate_module_owner_class_and_error(self):
        items, _ = fixture_hits()
        tasks = self.by_file(self.queue(("linux", self.write("linux.jsonl", items))))
        files = {info["path"]: info for ts in tasks.values() for t in ts for info in t["files"]}
        core = "cmux-tui/crates/cmux-tui-core/src/"
        frame, layout, tree = files[core + "mux/frame.rs"], files[core + "mux/layout.rs"], files[core + "mux/tree.rs"]
        self.assertEqual((frame["crate"], frame["module"], frame["owner"]), ("cmux-tui-core", "cmux_tui_core::mux::frame",
                                                                             "PL-daemon"))
        self.assertEqual((frame["class"], frame["boundary_error"]), ("input", "FrameError"))
        self.assertEqual(frame["boundary_error_source"], "returned here")
        self.assertEqual((layout["class"], layout["boundary_error"]), ("invariant", "MuxError"))
        self.assertEqual(layout["boundary_error_source"], f"defined in {core}mux/mod.rs")
        self.assertEqual(tree["boundary_error"], "std::io::Error")
        holder = files[core + "holder_runtime.rs"]
        # The most specific OWNERS row wins; fs::read_to_string makes it input.
        self.assertEqual((holder["owner"], holder["owner_row"]), ("PL-daemon holder", core + "holder_runtime.rs"))
        store = files[core + "store.rs"]
        self.assertEqual((store["owner"], store["owner_row"]), ("PL-daemon", "cmux-tui/crates/cmux-tui-core/"))
        self.assertEqual((holder["class"], holder["boundary_error"]), ("input", "anyhow::Error"))
        pty = files["cmux-tui/crates/cmux-pty/src/lib.rs"]
        self.assertEqual((pty["module"], pty["boundary_error"]), ("cmux_pty", "PtyError"))
        spring = files["cmux-tui/crates/cmux-motion/src/spring.rs"]
        self.assertEqual((spring["owner"], spring["owner_row"]), ("PL-stability", None))
        self.assertEqual((spring["class"], spring["boundary_error"]), ("invariant", None))
        route = files["cmux-tui/crates/acpmux/src/hub/route.rs"]
        self.assertEqual(route["owner"], "PL-acpmux")
        self.assertEqual(files["cmux-tui/crates/acpmux/src/main.rs"]["module"], "acpmux (bin)")
        self.assertEqual(files["cmux-tui/crates/acpmux/src/main.rs"]["owner"], "PL-stability")
        gone = files["cmux-tui/crates/cmux-gone/src/lib.rs"]
        self.assertEqual(gone["class"], "input")  # unreadable: never sent to the INVARIANT path unread
        task = tasks[core + "mux/frame.rs"][0]
        self.assertEqual((task["crate"], task["owner"], task["class"]), ("cmux-tui-core", "PL-daemon", "input"))
        self.assertEqual(task["boundary_error"], "FrameError")  # 30 hits outweigh mod.rs's 15

    def test_different_owners_never_share_a_task(self):
        items, _ = fixture_hits()
        queue = self.queue(("linux", self.write("linux.jsonl", items)))
        for task in queue["tasks"]:
            self.assertEqual({f["owner"] for f in task["files"]}, {task["owner"]}, task["id"])
            self.assertEqual({f["crate"] for f in task["files"]}, {task["crate"]}, task["id"])

    def test_holder_file_and_daemon_files_of_one_directory_never_share_a_task(self):
        items, _ = fixture_hits()
        tasks = self.by_file(self.queue(("linux", self.write("linux.jsonl", items))))
        core = "cmux-tui/crates/cmux-tui-core/src/"
        holder, store = tasks[core + "holder_runtime.rs"], tasks[core + "store.rs"]
        self.assertEqual((len(holder), len(store)), (1, 1))
        self.assertNotEqual(holder[0]["id"], store[0]["id"])
        self.assertEqual((holder[0]["owner"], store[0]["owner"]), ("PL-daemon holder", "PL-daemon"))

    def test_owner_label_keeps_the_owner_before_its_notes(self):
        label = self.ratchet.owner_label
        self.assertEqual(label("PL-daemon holder (session cmux-4f)"), "PL-daemon holder")
        self.assertEqual(label("PL-daemon (session cmux-b6): request speed, journal"), "PL-daemon")
        self.assertEqual(label("PL-holder (session cmux-1c); PL-daemon migrates its own crates"), "PL-holder")
        self.assertEqual(label("PL-instant, session cmux-1c (interim)"), "PL-instant")
        self.assertEqual(label("Performance Lead (PL-guardrails)"), "PL-guardrails")
        self.assertEqual(label("Performance Lead (chrome-parity program p14-energy, task 021)"), "Performance Lead")
        self.assertEqual(label("Aziz's agent and the Performance Lead"), "Aziz's agent and the Performance Lead")

    def test_split_cuts_only_between_lines(self):
        # Line 1 has 1 hit, lines 2-26 have 2 (51 hits): two parts, and no line in both.
        layout = "crates/cmux-tui-core/src/mux/layout.rs"
        items = [artifact("cmux-tui-core"), hit(layout, 1)]
        items += [hit(layout, line, column=c) for line in range(2, 27) for c in (5, 9)]
        tasks = self.by_file(self.queue(("linux", self.write("pairs.jsonl", items + [FINISHED]))))
        parts = tasks["cmux-tui/crates/cmux-tui-core/src/mux/layout.rs"]
        self.assertEqual([t["hit_count"] for t in parts], [25, 26])
        self.assertEqual([t["files"][0]["lines"] for t in parts], ["1-13", "14-26"])
        lines = [{h["loc"].rsplit(":", 2)[1] for h in t["hits"]} for t in parts]
        self.assertFalse(lines[0] & lines[1])

    def test_split_keeps_a_line_above_the_limit_whole(self):
        layout = "crates/cmux-tui-core/src/mux/layout.rs"
        items = [artifact("cmux-tui-core")] + [hit(layout, 1, column=c) for c in range(1, 61)]
        items += [hit(layout, line) for line in range(2, 32)]
        tasks = self.by_file(self.queue(("linux", self.write("wide.jsonl", items + [FINISHED]))))
        parts = tasks["cmux-tui/crates/cmux-tui-core/src/mux/layout.rs"]
        self.assertEqual([(t["hit_count"], t["files"][0]["lines"]) for t in parts], [(60, "1-1"), (30, "2-31")])

    def test_merged_runs_count_a_shared_line_once_and_mark_one_run_hits(self):
        linux = self.write("linux.jsonl", [artifact("cmux-pty"), hit("crates/cmux-pty/src/lib.rs", 1),
                                           hit("crates/cmux-pty/src/linux.rs", 2), FINISHED])
        mac = self.write("mac.jsonl", [artifact("cmux-pty"), hit("crates/cmux-pty/src/lib.rs", 1),
                                       hit("/Users/fleet/w/cmux-tui/crates/cmux-pty/src/macos.rs", 3, "panic"),
                                       FINISHED])
        queue = self.queue(("linux", linux), ("macos", mac))
        self.assertEqual(queue["runs"], ["linux", "macos"])
        self.assertEqual(queue["total_hits"], 3)
        hits = {h["loc"]: h for task in queue["tasks"] for h in task["hits"]}
        self.assertNotIn("only_in", hits["cmux-tui/crates/cmux-pty/src/lib.rs:1:5"])
        self.assertEqual(hits["cmux-tui/crates/cmux-pty/src/linux.rs:2:5"]["only_in"], "linux")
        self.assertEqual(hits["cmux-tui/crates/cmux-pty/src/macos.rs:3:5"]["only_in"], "macos")
        single = self.queue(("linux", linux))
        self.assertTrue(all("only_in" not in h for task in single["tasks"] for h in task["hits"]))

    def test_random_hit_sets_partition(self):
        rng = random.Random(210)
        names = [f"crates/cmux-tui-core/src/{d}/{f}.rs" for d in ("a", "b", "c") for f in "pqrstu"]
        for round_ in range(25):
            items = [artifact("cmux-tui-core")]
            for _ in range(rng.randint(1, 600)):
                items.append(hit(rng.choice(names), rng.randint(1, 400), rng.choice(self.ratchet.DENY_LINTS),
                                 rng.randint(1, 3)))
            queue = self.queue(("linux", self.write(f"r{round_}.jsonl", items + [FINISHED])))
            distinct = {(i["message"]["spans"][0]["file_name"], i["message"]["spans"][0]["line_start"],
                         i["message"]["spans"][0]["column_start"], i["message"]["code"]["code"])
                        for i in items if i["reason"] == "compiler-message"}
            self.assertEqual(queue["total_hits"], len(distinct))
            assert_partition(self, queue)
            owners = collections.defaultdict(set)
            for task in queue["tasks"]:
                for h in task["hits"]:
                    owners[h["loc"].rsplit(":", 1)[0]].add(task["id"])
            self.assertTrue(all(len(ids) == 1 for ids in owners.values()))

    def test_cli_queue_json_and_md_exit_zero_above_the_baseline(self):
        items, deny = fixture_hits()
        path = self.write("linux.jsonl", items)
        rc, out, err = self.run_main("--clippy-json", path, "--queue")
        self.assertEqual(rc, 0, err)  # every crate is above the empty baseline; --queue never judges
        self.assertEqual(json.loads(out)["total_hits"], deny)
        rc, out, _ = self.run_main("--clippy-json", path, "--queue", "md")
        self.assertEqual(rc, 0)
        self.assertIn(f"Q10 rust-panic-deny queue: {deny} hits in", out)
        self.assertIn("| task | crate | module | files | hits | class | owner | boundary error |", out)
        self.assertIn("| PL-stability | none: add one |", out)
        self.assertEqual(self.baseline.read_text(), json.dumps({"crates": {}}))

    def test_cli_refuses_queue_with_other_outputs_and_partial_runs(self):
        items, _ = fixture_hits()
        path = self.write("linux.jsonl", items)
        for extra in (["--report", "md"], ["--update-baseline"], ["--init-baseline"]):
            rc, _, err = self.run_main("--clippy-json", path, "--queue", *extra)
            self.assertEqual(rc, 2, extra)
            self.assertIn("--queue prints only the queue", err)
        partial = self.write("partial.jsonl", items[:-1])
        rc, out, err = self.run_main("--clippy-json", partial, "--queue")
        self.assertEqual((rc, out), (2, ""))
        self.assertIn("did not finish successfully", err)


if __name__ == "__main__":
    unittest.main()
