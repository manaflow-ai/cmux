#!/usr/bin/env python3
"""Tests for schemas/terminal-corpus/generate.py (p15-oracle-101).

Run: python3 -I schemas/terminal-corpus/generate_test.py
"""
from __future__ import annotations

import hashlib
import importlib.util
import json
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
spec = importlib.util.spec_from_file_location("terminal_corpus_generate", HERE / "generate.py")
gen = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gen)

STREAMS, MANIFEST, CASES = gen.build()


def stream_of(case: dict) -> str:
    return case["steps"][1]["args"]["params"]["argv"][4]


def flat_manifest_cases(text: str) -> list:
    """The case names that the Rust fidelity tests read (ghostty-vt tests/terminal_corpus.rs and
    cold_pages.rs): from the first "cases" key on, one object per "name" key, up to its first '}'."""
    rest = text[text.index('"cases"'):]
    names = []
    for chunk in rest.split('"name"')[1:]:
        names.append(re.search(r':\s*"([^"]*)"', chunk[:chunk.index("}")]).group(1))
    return names


class GenerateTest(unittest.TestCase):
    def test_checked_in_files_are_current(self):
        for file, data in STREAMS.items():
            self.assertEqual((HERE / file).read_bytes(), data, file)
        self.assertEqual((HERE / "manifest.json").read_text(), MANIFEST)
        # The oracle cases are not committed: corpus_store.py writes them, and they must be what build() makes.
        sys.path.insert(0, str(REPO / "scripts" / "cmux-next" / "oracle"))
        import corpus_store  # noqa: PLC0415

        corpus_store.ensure(gen.ORACLE_DIR.parent, ["terminal"])
        on_disk = {path.stem: path.read_text(encoding="utf-8") for path in gen.ORACLE_DIR.glob("*.json")}
        self.assertEqual(sorted(on_disk), sorted(CASES), "run schemas/terminal-corpus/generate.py")
        for case_id, case in CASES.items():
            self.assertEqual(on_disk[case_id], gen.case_text(case), case_id)

    def test_output_is_deterministic(self):
        self.assertEqual(gen.build(), (STREAMS, MANIFEST, CASES))

    def test_at_least_200_cases_and_every_family_is_there(self):
        self.assertGreaterEqual(len(CASES), 200)
        for family, (_, count, _) in gen.ORACLE_FAMILIES.items():
            self.assertEqual(sum(1 for c in CASES if c.startswith(f"{family}-")), count, family)
        recorded = {c for c in CASES if c.startswith("recorded-")}
        self.assertEqual(recorded, {f"recorded-{name}" for name in gen.CASES if name not in gen.RECORDED_LEFT_OUT})

    def test_manifest_lists_the_oracle_suite_and_keeps_the_fidelity_list_flat(self):
        manifest = json.loads(MANIFEST)
        self.assertEqual(flat_manifest_cases(MANIFEST), list(gen.CASES))
        self.assertEqual([c["name"] for c in manifest["cases"]], list(gen.CASES))
        oracle = manifest["oracle"]
        self.assertEqual(oracle["total"], len(CASES))
        self.assertEqual(sum(f["count"] for f in oracle["families"]), len(CASES))
        self.assertEqual(oracle["dir"], gen.ORACLE_DIR.relative_to(REPO).as_posix())

    def test_each_gap_is_a_filed_task_and_no_family_claims_it(self):
        self.assertEqual(json.loads(MANIFEST)["oracle"]["gaps"], gen.ORACLE_GAPS)
        work = (REPO / "plans/cmux-next/chrome-parity/WORK.tsv").read_text(encoding="utf-8")
        filed = {line.split("\t", 1)[0] for line in work.splitlines()}
        claimed = {feature for _, _, features in gen.ORACLE_FAMILIES.values() for feature in features}
        for gap in gen.ORACLE_GAPS:
            self.assertIn(gap["task"], filed, f"{gap['spec']}: file {gap['task']} in WORK.tsv")
            self.assertNotIn(gap["spec"].replace(" ", "-"), claimed, f"a family claims the gap {gap['spec']!r}")
        self.assertFalse([f for f in claimed if "during-output" in f], "an in-band switch is not a PTY resize")

    def test_streams_fit_one_exec_argument_and_have_no_nul(self):
        for case_id, case in CASES.items():
            stream = stream_of(case)
            self.assertNotIn("\x00", stream, case_id)
            self.assertLessEqual(len(stream.encode()), gen.MAX_STREAM_BYTES, case_id)

    def test_each_family_exercises_its_sequences(self):
        wanted = {
            "sgr": ("38;5;", "48;2;", ":2::", "4:", "\x1b[K"),
            "wide": ("‍", "️", "\x1b[?2027h", "\x1b[?7l", "́"),
            "alt": ("\x1b[?1049h", "\x1b[?1047h", "\x1b[?47h", "\x1b[?1049l", "\x1b[?1048h"),
            "region": ("r", "\x1bD", "\x1bM", "\x1b[?69h", "\x1b[?6h"),
            "osc": ("\x1b]8;", "\x1b]7;file://localhost/", "\x1b]133;D;", "\x1b]4;", "\x1b]2;"),
            "deccolm": ("\x1b[?40h", "\x1b[?3h", "\x1b[?3l", "\x1b[?40l"),
            "scrollback": ("\x1b[3J",),
        }
        for family, needles in wanted.items():
            joined = "".join(stream_of(c) for cid, c in CASES.items() if cid.startswith(f"{family}-"))
            for needle in needles:
                self.assertIn(needle, joined, f"{family} never writes {needle!r}")
        sizes = {tuple(CASES[c]["steps"][1]["args"]["params"][k] for k in ("cols", "rows")) for c in CASES}
        self.assertTrue(set(gen.SIZES) <= sizes)

    def test_the_hash_terminal_reads_the_two_replies_of_its_case(self):
        for case_id, case in CASES.items():
            steps = {step["id"]: step for step in case["steps"]}
            self.assertEqual(steps["state"]["args"]["method"], "terminal.state.read")
            self.assertEqual(steps["screen"]["args"]["method"], "terminal.screen.read")
            self.assertTrue(steps["state"]["readOnly"] and steps["screen"]["readOnly"])
            argv = steps["hash"]["args"]["params"]["argv"]
            self.assertEqual(argv[3:], ["sh", "$step:state#/state_base64", "$step:screen#/text"], case_id)
            self.assertEqual(steps["hash"]["args"]["params"]["on_exit"], "keep")
            self.assertEqual(steps["hash"]["args"]["params"]["cwd"], "/", "OSC 7 folders do not exist")
            self.assertEqual(case["switches"], ["terminal-holder"])
            self.assertEqual(case["suite"], "terminal")

    def test_feed_script_prints_the_stream_byte_for_byte_then_the_title(self):
        stream = stream_of(CASES["wide-000"]) + "%s %d \\n \\033 -- $HOME `x`"
        out = subprocess.run(["/bin/sh", "-c", gen.FEED_SCRIPT, "sh", stream, gen.FED_TITLE],
                             stdin=subprocess.DEVNULL, capture_output=True, check=True, timeout=10).stdout
        self.assertEqual(out, stream.encode() + f"\x1b]2;{gen.FED_TITLE}\x07".encode())

    def test_hash_script_titles_the_sha256_of_both_replies(self):
        state, screen = "AAEC/w==", "line one\nline two  漢字"
        out = subprocess.run(["/bin/sh", "-c", gen.HASH_SCRIPT, "sh", state, screen],
                             stdin=subprocess.DEVNULL, capture_output=True, check=True, timeout=10).stdout
        digest = lambda text: hashlib.sha256(text.encode()).hexdigest()  # noqa: E731
        self.assertEqual(out, f"\x1b]2;vt:{digest(state)} screen:{digest(screen)}\x07".encode())

    def test_the_waits_name_the_titles_the_scripts_set(self):
        for case in CASES.values():
            fed = next(step for step in case["steps"] if step["id"] == "fed")
            self.assertEqual(fed["waitFor"]["equals"],
                             "sha256:" + hashlib.sha256(gen.FED_TITLE.encode()).hexdigest())

    def test_oracle_check_accepts_every_case(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "terminal"
            gen.write_oracle(out, CASES)
            files = sorted(str(path) for path in out.glob("*.json"))
            result = subprocess.run([sys.executable, "-I", str(REPO / "scripts/cmux-next/oracle/oracle.py"), "check",
                                     *files], capture_output=True, text=True, timeout=600)
            self.assertEqual(result.returncode, 0, result.stdout[-2000:] + result.stderr[-2000:])


if __name__ == "__main__":
    unittest.main()
