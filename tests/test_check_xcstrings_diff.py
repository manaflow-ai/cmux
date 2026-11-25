#!/usr/bin/env python3
"""String catalogs change in place (cmux#55547).

cmux#51769 added 3 keys to webviews/src/agent-session/acpmux/Localizable.xcstrings and its diff showed
+147,735 -133,744: its merges of feat-cmux-next ran main's older trusted merge driver, which kept the branch's text
and order over the base's. These tests drive the real commands on real git repositories:

- scripts/cmux-next/check-xcstrings-diff.py (`staged`, `range`, `files`) refuses moved keys, entries rewritten with
  no value change, changed separators and a re-rendered frame, and passes adds, removes and value edits;
- scripts/xcstrings-edit.py adds and removes entries in each catalog style the repository has and leaves every
  other byte alone (an add then a remove gives the original file back);
- the pre-push gate's check (prepush-gate.py xcstrings_rewrites) judges the push against its merge base with
  origin/feat-cmux-next, so a base merge's own changes never count.
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

ROOT = Path(__file__).resolve().parents[1]
CHECK = ROOT / "scripts/cmux-next/check-xcstrings-diff.py"
EDIT = ROOT / "scripts/xcstrings-edit.py"
GATE = ROOT / "scripts/cmux-next/prepush-gate.py"
CATALOG = "Res/Localizable.xcstrings"


def entry(text: str, comment: str | None = None) -> dict:
    record: dict = {"extractionState": "manual",
                    "localizations": {"en": {"stringUnit": {"state": "translated", "value": text}},
                                      "ja": {"stringUnit": {"state": "translated", "value": text + " (ja)"}}}}
    return {"comment": comment, **record} if comment else record


def compact(entries: dict) -> str:
    """The agent pane catalog's style: one compact line per entry."""
    body = ",\n".join(f"    {json.dumps(k, ensure_ascii=False)}: {json.dumps(v, ensure_ascii=False, separators=(',', ':'))}"
                      for k, v in entries.items())
    return '{\n  "sourceLanguage": "en",\n  "strings": {\n' + body + '\n  },\n  "version": "1.0"\n}\n'


def nested(entries: dict) -> str:
    """The package catalogs' style: json.dumps(indent=2)."""
    return json.dumps({"sourceLanguage": "en", "strings": entries, "version": "1.0"}, ensure_ascii=False, indent=2) + "\n"


def xcode(entries: dict) -> str:
    """Xcode's own style: `"key" : value`."""
    return json.dumps({"sourceLanguage": "en", "strings": entries, "version": "1.0"}, ensure_ascii=False, indent=2,
                      separators=(",", " : ")) + "\n"


BASE = {"alpha": entry("Alpha", "first"), "beta": entry("Beta"), "gamma": entry("Gamma"), "delta": entry("Delta")}


def run(cmd: list[str], cwd: Path, env: dict | None = None) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, env=env)


class Repo:
    def __init__(self, root: Path):
        self.root = root
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(("GIT_", "CMUX_XCSTRINGS"))}
        self.env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull, HOME=str(root),
                        GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t", GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@t")
        self.git("init", "-q", "--initial-branch=feat-cmux-next")

    def git(self, *args: str) -> str:
        result = run(["git", *args], self.root, self.env)
        if result.returncode != 0:
            raise AssertionError(f"git {' '.join(args)}: {result.stderr}")
        return result.stdout.strip()

    def write(self, text: str, path: str = CATALOG) -> None:
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding="utf-8")

    def commit(self, message: str, text: str | None = None) -> str:
        if text is not None:
            self.write(text)
        self.git("add", "-A")
        self.git("commit", "-q", "--no-verify", "--allow-empty", "-m", message)
        return self.git("rev-parse", "HEAD")

    def check(self, *args: str, extra_env: dict | None = None) -> subprocess.CompletedProcess:
        return run([sys.executable, "-I", str(CHECK), *args], self.root, {**self.env, **(extra_env or {})})


class CheckerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="xcstrings-diff-")
        self.addCleanup(self.tmp.cleanup)
        self.repo = Repo(Path(self.tmp.name))
        self.base = self.repo.commit("base", compact(BASE))

    def range_result(self, text: str, message: str = "change") -> subprocess.CompletedProcess:
        head = self.repo.commit(message, text)
        return self.repo.check("range", self.base, head)

    def test_adding_removing_and_editing_entries_passes(self):
        changed = dict(BASE)
        del changed["beta"]
        changed["gamma"] = entry("Gamma, edited")
        text = compact(changed).replace('    "delta"', '    "new.key": {"comment":"x"},\n    "delta"')
        result = self.range_result(text)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_a_whole_file_re_render_is_refused(self):
        """The #51769 shape: the same keys plus one, re-rendered by json.dump."""
        result = self.range_result(nested({**BASE, "new.key": entry("New")}))
        self.assertEqual(result.returncode, 1)
        self.assertIn("4 existing entries rewritten with no value change", result.stderr)
        self.assertIn(f"{CATALOG}: ", result.stderr)

    def test_moved_keys_are_refused(self):
        moved = {"gamma": BASE["gamma"], "alpha": BASE["alpha"], "beta": BASE["beta"], "delta": BASE["delta"]}
        result = self.range_result(compact(moved))
        self.assertEqual(result.returncode, 1)
        self.assertIn("1 existing key(s) moved: gamma", result.stderr)

    def test_a_changed_separator_and_frame_are_refused(self):
        text = compact(BASE).replace('},\n    "beta"', '},\n  "beta"').replace('  },\n  "version"', '},\n  "version"')
        result = self.range_result(text)
        self.assertEqual(result.returncode, 1)
        self.assertIn("the separator after 1 entry changed: alpha", result.stderr)
        self.assertIn("footer re-serialized", result.stderr)

    def test_a_reformat_trailer_or_the_environment_lets_a_deliberate_reformat_through(self):
        result = self.range_result(nested(BASE), "Compact the catalog\n\nXcstrings-Reformat: one style for every entry\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("one style for every entry", result.stderr)
        self.repo.git("commit", "-q", "--amend", "-m", "no trailer")
        head = self.repo.git("rev-parse", "HEAD")
        self.assertEqual(self.repo.check("range", self.base, head).returncode, 1)
        allowed = self.repo.check("range", self.base, head, extra_env={"CMUX_XCSTRINGS_REFORMAT_REASON": "tooling"})
        self.assertEqual(allowed.returncode, 0, allowed.stderr)

    def test_staged_compares_with_head_and_a_merge_with_merge_head(self):
        self.repo.write(nested(BASE))
        self.repo.git("add", CATALOG)
        self.assertEqual(self.repo.check("staged").returncode, 1)
        self.repo.git("reset", "-q", "--hard")

        # A branch adds a key; the base adds its own key at the top; the branch merges the base. A resolution that keeps the base's text and order, plus the branch's key, passes; one that
        # keeps the branch's re-rendered copy (what the stale driver produced) is refused.
        self.repo.git("checkout", "-q", "-b", "pr")
        self.repo.commit("pr adds a key", compact({**BASE, "pr.key": entry("PR")}))
        self.repo.git("checkout", "-q", "feat-cmux-next")
        self.repo.commit("base adds a key", compact({"base.key": entry("Base"), **BASE}))
        self.repo.git("checkout", "-q", "pr")
        merged = run(["git", "merge", "--no-ff", "--no-commit", "-s", "ours", "feat-cmux-next"], self.repo.root,
                     self.repo.env)
        self.assertEqual(merged.returncode, 0, merged.stderr)
        self.repo.write(nested({**BASE, "pr.key": entry("PR"), "base.key": entry("Base")}))
        self.repo.git("add", CATALOG)
        refused = self.repo.check("staged")
        self.assertEqual(refused.returncode, 1)
        self.assertIn("against MERGE_HEAD", refused.stderr)
        self.repo.write(compact({"base.key": entry("Base"), **BASE, "pr.key": entry("PR")}))
        self.repo.git("add", CATALOG)
        passed = self.repo.check("staged")
        self.assertEqual(passed.returncode, 0, passed.stderr)

    def test_range_with_merge_base_ignores_what_a_base_merge_brings(self):
        """The base reorders its own catalog; a branch that merged it and adds one key passes against the merge base,
        and fails if its merge kept its old order over the base's (the stale driver's result)."""
        self.repo.git("checkout", "-q", "-b", "pr")
        self.repo.commit("pr adds a key", compact({**BASE, "pr.key": entry("PR")}))
        self.repo.git("checkout", "-q", "feat-cmux-next")
        reordered = {"delta": BASE["delta"], "alpha": BASE["alpha"], "beta": BASE["beta"], "gamma": BASE["gamma"]}
        self.repo.commit("base reorders", compact(reordered))
        self.repo.git("checkout", "-q", "pr")
        self.repo.git("merge", "-q", "--no-ff", "--no-commit", "-s", "ours", "feat-cmux-next")
        self.repo.commit("merge, kept the base's order", compact({**reordered, "pr.key": entry("PR")}))
        good = self.repo.check("range", "feat-cmux-next", "HEAD", "--merge-base")
        self.assertEqual(good.returncode, 0, good.stderr)
        self.repo.git("reset", "-q", "--hard", "HEAD^")
        self.repo.git("merge", "-q", "--no-ff", "--no-commit", "-s", "ours", "feat-cmux-next")
        self.repo.commit("merge, kept the branch's order", compact({**BASE, "pr.key": entry("PR")}))
        bad = self.repo.check("range", "feat-cmux-next", "HEAD", "--merge-base")
        self.assertEqual(bad.returncode, 1)
        self.assertIn("existing key(s) moved", bad.stderr)


class EditTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="xcstrings-edit-")
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / "Localizable.xcstrings"

    def edit(self, *args: str) -> subprocess.CompletedProcess:
        return run([sys.executable, "-I", str(EDIT), *args], Path(self.tmp.name))

    def test_add_and_remove_leave_every_other_byte_in_each_style(self):
        for name, render in (("compact", compact), ("nested", nested), ("xcode", xcode)):
            with self.subTest(style=name):
                original = render(BASE)
                self.path.write_text(original, encoding="utf-8")
                entries = Path(self.tmp.name) / "new.json"
                entries.write_text(json.dumps({"two.a": entry("A"), "two.b": entry("B")}), encoding="utf-8")
                steps = (
                    ("add", str(self.path), "new.end", "--en", "End", "--comment", "for translators"),
                    ("add", str(self.path), "new.first", "--entry", json.dumps(entry("First")), "--before", "alpha"),
                    ("add", str(self.path), "--entries-file", str(entries), "--after", "beta"),
                )
                for step in steps:
                    result = self.edit(*step)
                    self.assertEqual(result.returncode, 0, result.stderr)
                edited = self.path.read_text(encoding="utf-8")
                keys = list(json.loads(edited)["strings"])
                self.assertEqual(keys, ["new.first", "alpha", "beta", "two.a", "two.b", "gamma", "delta", "new.end"])
                # Every new entry took its neighbour's style: the whole file now reads as one render of it.
                self.assertEqual(edited, render(json.loads(edited)["strings"]))
                result = self.edit("remove", str(self.path), "new.end", "new.first", "two.a", "two.b")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.path.read_text(encoding="utf-8"), original)

    def test_replace_keeps_the_position_and_a_duplicate_add_is_refused(self):
        self.path.write_text(compact(BASE), encoding="utf-8")
        refused = self.edit("add", str(self.path), "beta", "--en", "Beta again")
        self.assertEqual(refused.returncode, 1)
        self.assertIn("already exists", refused.stderr)
        result = self.edit("add", str(self.path), "beta", "--en", "Beta again", "--replace")
        self.assertEqual(result.returncode, 0, result.stderr)
        replaced = {**BASE, "beta": {"extractionState": "manual",
                                    "localizations": {"en": {"stringUnit": {"state": "translated",
                                                                            "value": "Beta again"}}}}}
        self.assertEqual(self.path.read_text(encoding="utf-8"), compact(replaced))

    def test_a_crlf_catalog_keeps_its_line_endings(self):
        original = nested(BASE).replace("\n", "\r\n").encode("utf-8")
        self.path.write_bytes(original)
        result = self.edit("add", str(self.path), "new.end", "--en", "End")
        self.assertEqual(result.returncode, 0, result.stderr)
        result = self.edit("remove", str(self.path), "new.end")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.path.read_bytes(), original)

    def test_removing_every_entry_and_a_missing_key(self):
        self.path.write_text(nested(BASE), encoding="utf-8")
        self.assertEqual(self.edit("remove", str(self.path), "nope").returncode, 1)
        result = self.edit("remove", str(self.path), *BASE)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.path.read_text(encoding="utf-8"))["strings"], {})
        result = self.edit("add", str(self.path), "only", "--en", "Only")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(list(json.loads(self.path.read_text(encoding="utf-8"))["strings"]), ["only"])


class GateTests(unittest.TestCase):
    """The pre-push gate's check, on a clone whose origin/feat-cmux-next is the base."""

    def test_the_gate_refuses_a_re_rendered_catalog_and_passes_an_added_key(self):
        sys.path.insert(0, str(GATE.parent))
        spec = importlib.util.spec_from_file_location("prepush_gate_for_xcstrings", GATE)
        gate = importlib.util.module_from_spec(spec)
        assert spec.loader is not None
        spec.loader.exec_module(gate)
        with tempfile.TemporaryDirectory(prefix="xcstrings-gate-") as tmp:
            repo = Repo(Path(tmp))
            repo.write(CHECK.read_text(encoding="utf-8"), "scripts/cmux-next/check-xcstrings-diff.py")
            base = repo.commit("base", compact(BASE))
            repo.git("update-ref", "refs/remotes/origin/feat-cmux-next", base)
            repo.git("checkout", "-q", "-b", "pr")
            good = repo.commit("adds a key", compact({**BASE, "pr.key": entry("PR")}))
            self.assertEqual(gate.xcstrings_rewrites(Path(tmp), base, good), [])
            bad = repo.commit("re-renders", nested({**BASE, "pr.key": entry("PR")}))
            found = gate.xcstrings_rewrites(Path(tmp), good, bad)
            self.assertEqual(len(found), 1, found)
            self.assertTrue(found[0].startswith(f"{CATALOG}: 5 existing entries rewritten"), found)
            self.assertIn(gate.XCSTRINGS_CHECK, {name for name, _ in gate.gate(
                Path(tmp), good, bad, {"xcstrings"}, False)})
            # A later push merges a base that reordered its own catalog: only the push's merge base counts.
            repo.git("checkout", "-q", "-B", "pr", good)
            repo.git("checkout", "-q", "-b", "next", base)
            reordered = {"delta": BASE["delta"], "alpha": BASE["alpha"], "beta": BASE["beta"], "gamma": BASE["gamma"]}
            moved = repo.commit("base reorders", compact(reordered))
            repo.git("update-ref", "refs/remotes/origin/feat-cmux-next", moved)
            repo.git("checkout", "-q", "pr")
            repo.git("merge", "-q", "--no-ff", "--no-commit", "-s", "ours", "next")
            merged = repo.commit("merge the base", compact({**reordered, "pr.key": entry("PR")}))
            self.assertEqual(gate.xcstrings_rewrites(Path(tmp), good, merged), [])
            # CI's shape: BASE..MERGE with no feat-cmux-next ref at all.
            repo.git("update-ref", "-d", "refs/remotes/origin/feat-cmux-next")
            self.assertEqual(gate.xcstrings_rewrites(Path(tmp), moved, merged), [])
            self.assertEqual(len(gate.xcstrings_rewrites(Path(tmp), good, bad)), 1)


if __name__ == "__main__":
    unittest.main()
