#!/usr/bin/env python3
"""Tests for route.py (p15-oracle-118) on a synthetic set: only confirmed divergences reach an owner.

Run: python3 -I scripts/cmux-next/oracle/route_test.py (stdlib unittest; a throwaway git repo with its own
OWNERS.md and switch registry, no oracle run).
"""

from __future__ import annotations

import io
import json
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import route  # noqa: E402

OWNERS_MD = """# owners

| Area | Paths | Owner | Read first |
|---|---|---|---|
| Daemon | `cmux-tui/crates/cmux-tui-core/` | PL-daemon (chrome-parity program p02-daemon) | [daemon.md](daemon.md) |
| Holder | `cmux-tui/crates/cmux-tui-core/src/holder_runtime/` | PL-holder | [pty-holder.md](pty-holder.md) |
| Tabs | `Packages/macOS/CmuxNext/Sources/CmuxNextTabs/TabStrip*.swift` | PL-tabs | [tabs.md](tabs.md) |
| Oracle | `scripts/cmux-next/oracle/`, `plans/cmux-next/chrome-parity/p15-oracle.md` | PL-oracle (chrome-parity program p15-oracle) | [oracle-DESIGN.md](oracle-DESIGN.md) |

Not listed: no owner yet.
"""

VERDICTS_OK = {"head": {"verdict": "fail", "run": "r-head"}, "head_retry": {"verdict": "fail", "run": "r-retry"},
               "base": {"verdict": "pass", "run": "r-base"}}


def git(repo: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(repo), *args], check=True, stdout=subprocess.PIPE, text=True,
                          env={"GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t",
                               "GIT_COMMITTER_EMAIL": "t@t", "HOME": str(repo), "PATH": "/usr/bin:/bin"}).stdout.strip()


def finding(case: str, pointer: str = "/facets/tabs/0/title", **extra):
    item = {"journey": case, "step": "s1", "checkpoint": "settled", "pointer": pointer, "a": "x", "b": "y",
            "replay": f"python3 -I scripts/cmux-next/oracle/diff.py A B --case {case}", "evidence": ["A#1"],
            "source": "f" * 40, "confidence": "confirmed", "verdicts": VERDICTS_OK}
    item.update(extra)
    return item


class RouteTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        git(self.repo, "init", "-q")
        self.write("plans/cmux-next/OWNERS.md", OWNERS_MD)
        self.write("README", "base\n")
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-q", "-m", "base")
        self.base = git(self.repo, "rev-parse", "HEAD")
        self.registry = self.repo / "plans" / "cmux-next" / "refactor-switches"
        self.switch("holderV3", plan="plans/cmux-next/pty-holder.md#f6", owner="PL-holder-switch",
                    old_paths=["cmux-tui/crates/cmux-tui-core/src/holder_runtime/v2.rs"])
        self.switch("intents", plan="plans/cmux-next/chrome-parity/p09-intents.md", owner="PL-intents")

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def write(self, rel: str, text: str) -> None:
        path = self.repo / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def switch(self, name: str, **entry) -> None:
        self.registry.mkdir(parents=True, exist_ok=True)
        (self.registry / f"{name}.json").write_text(json.dumps({"name": name, **entry}), encoding="utf-8")

    def commit(self, files) -> str:
        for rel in files:
            self.write(rel, f"{rel}\n")
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-q", "-m", "head")
        return git(self.repo, "rev-parse", "HEAD")

    def run_route(self, items, *extra: str):
        source = self.root / "confirmed.jsonl"
        source.write_text("".join(json.dumps(item) + "\n" for item in items), encoding="utf-8")
        out = self.root / "route.jsonl"
        stdout, stderr = io.StringIO(), io.StringIO()
        with redirect_stdout(stdout), redirect_stderr(stderr):
            code = route.main([str(source), "--out", str(out), "--repo", str(self.repo), *extra])
        lines = [json.loads(line) for line in out.read_text().splitlines()] if out.is_file() else None
        return code, lines, stdout.getvalue() + stderr.getvalue()

    def test_only_confirmed_lines_are_routed(self) -> None:
        head = self.commit(["cmux-tui/crates/cmux-tui-core/src/store.rs"])
        bad = dict(VERDICTS_OK, base={"verdict": "fail", "run": "r-base"})
        no_run = dict(VERDICTS_OK, head_retry={"verdict": "fail"})
        items = [finding("daemon-ops/real", base=self.base, head=head),
                 finding("daemon-ops/flaky", confidence="flaky", base=self.base, head=head),
                 finding("daemon-ops/base-red", confidence="base-red", base=self.base, head=head),
                 finding("daemon-ops/raw", confidence="unconfirmed", base=self.base, head=head),
                 finding("daemon-ops/nolabel", confidence=None, base=self.base, head=head),
                 finding("daemon-ops/base-fails", verdicts=bad, base=self.base, head=head),
                 finding("daemon-ops/no-run", verdicts=no_run, base=self.base, head=head),
                 finding("daemon-ops/no-verdicts", verdicts=None, base=self.base, head=head)]
        code, lines, output = self.run_route(items)
        self.assertEqual(code, 0, output)
        self.assertEqual([line["case"] for line in lines], ["daemon-ops/real"])
        [line] = lines
        self.assertEqual(line["owner"], "PL-daemon (chrome-parity program p02-daemon)")
        self.assertEqual(line["program"], "p02-daemon")
        self.assertEqual(line["mapped_from"], "changed-files")
        self.assertEqual(line["verdicts"], VERDICTS_OK)
        self.assertEqual((line["base"], line["head"]), (self.base, head))
        self.assertIn(f"--base {self.base} --head {head} --filter daemon-ops/real --fresh", line["rerun"])
        self.assertTrue(line["replay"].startswith("python3 -I scripts/cmux-next/oracle/diff.py"))
        for reason in ("flaky", "base-red", "unconfirmed"):
            self.assertIn(f"not routed ({reason}): ", output)
        self.assertIn("base verdict is 'fail'", output)
        self.assertIn("without a head_retry verdict and run id", output)

    def test_most_specific_row_wins_and_most_files_owns(self) -> None:
        head = self.commit(["cmux-tui/crates/cmux-tui-core/src/holder_runtime/a.rs",
                            "cmux-tui/crates/cmux-tui-core/src/holder_runtime/b.rs",
                            "cmux-tui/crates/cmux-tui-core/src/store.rs",
                            "Packages/macOS/CmuxNext/Sources/CmuxNextTabs/TabStripView.swift"])
        code, [line], output = self.run_route([finding("tabs/close", base=self.base, head=head)])
        self.assertEqual(code, 0, output)
        self.assertEqual(line["owner"], "PL-holder")
        owners = {o["owner"]: o["files"] for o in line["owners"]}
        self.assertEqual(sorted(owners), ["PL-daemon (chrome-parity program p02-daemon)", "PL-holder", "PL-tabs"])
        # The holder files belong to the holder row only, never to the crate row too.
        self.assertEqual(owners["PL-daemon (chrome-parity program p02-daemon)"],
                         ["cmux-tui/crates/cmux-tui-core/src/store.rs"])
        self.assertEqual([o["owner"] for o in line["owners"]][0], "PL-holder")

    def test_tie_goes_to_the_row_listed_first(self) -> None:
        head = self.commit(["cmux-tui/crates/cmux-tui-core/src/store.rs",
                            "Packages/macOS/CmuxNext/Sources/CmuxNextTabs/TabStripCell.swift"])
        _, [line], _ = self.run_route([finding("tabs/tie", base=self.base, head=head)])
        self.assertEqual(line["area"], "Daemon")

    def test_switch_maps_through_its_plan_and_old_paths(self) -> None:
        code, [line], output = self.run_route([finding("tabs/switch", switch="holderV3")])
        self.assertEqual(code, 0, output)
        self.assertEqual(line["mapped_from"], "switch-plan")
        self.assertEqual(line["owner"], "PL-holder")
        self.assertEqual(line["switch_owner"], "PL-holder-switch")
        self.assertEqual(line["plan"], "plans/cmux-next/pty-holder.md#f6")
        self.assertIn(f"--switch holderV3 --ref {'f' * 40} --filter tabs/switch --fresh", line["rerun"])

    def test_switch_with_no_owned_files_goes_to_registry_owner(self) -> None:
        _, [line], _ = self.run_route([finding("tabs/intent")], "--switch", "intents")
        self.assertEqual((line["owner"], line["mapped_from"], line["program"]), ("PL-intents", "switch-owner", "p09-intents"))

    def test_unlisted_change_goes_to_performance_lead(self) -> None:
        head = self.commit(["somewhere/new.txt"])
        _, [line], _ = self.run_route([finding("misc/a")], "--base", self.base, "--head", head)
        self.assertEqual((line["owner"], line["mapped_from"]), ("Performance Lead", "changed-files (unlisted)"))

    def test_duplicates_route_once(self) -> None:
        head = self.commit(["scripts/cmux-next/oracle/x.py"])
        items = [finding("a/b", base=self.base, head=head), finding("a/b", base=self.base, head=head),
                 finding("a/b", pointer="/other", base=self.base, head=head)]
        _, lines, output = self.run_route(items)
        self.assertEqual([line["pointer"] for line in lines], ["/facets/tabs/0/title", "/other"])
        self.assertIn("duplicates dropped: 1", output)
        self.assertEqual(lines[0]["program"], "p15-oracle")

    def test_line_commits_win_over_command_line_switch(self) -> None:
        head = self.commit(["Packages/macOS/CmuxNext/Sources/CmuxNextTabs/TabStripView.swift"])
        items = [finding("tabs/own-pair", base=self.base, head=head), finding("tabs/no-target")]
        code, lines, output = self.run_route(items, "--switch", "intents")
        self.assertEqual(code, 0, output)
        own, default = lines
        self.assertEqual((own["case"], own["switch"], own["mapped_from"], own["owner"]),
                         ("tabs/own-pair", None, "changed-files", "PL-tabs"))
        self.assertEqual((own["base"], own["head"]), (self.base, head))
        self.assertIn(f"--base {self.base} --head {head} ", own["rerun"])
        self.assertNotIn("--switch", own["rerun"])
        self.assertEqual((default["case"], default["switch"], default["owner"]), ("tabs/no-target", "intents", "PL-intents"))

    def test_half_commit_pair_is_unroutable_not_completed_from_command_line(self) -> None:
        middle = self.commit(["scripts/cmux-next/oracle/x.py"])
        head = self.commit(["cmux-tui/crates/cmux-tui-core/src/store.rs"])
        items = [finding("a/base-only", base=self.base), finding("a/head-only", head=head), finding("a/none")]
        code, lines, output = self.run_route(items, "--base", middle, "--head", head)
        self.assertEqual(code, 1, output)
        self.assertEqual([(line["case"], line["base"], line["head"]) for line in lines], [("a/none", middle, head)])
        self.assertIn("a/base-only: names a base commit but no head", output)
        self.assertIn("a/head-only: names a head commit but no base", output)

    def test_same_case_on_two_products_or_two_refs_routes_each(self) -> None:
        head = self.commit(["scripts/cmux-next/oracle/x.py"])
        items = [finding("a/b", base=self.base, head=head), finding("a/b", base=self.base, head=head, product="app"),
                 finding("a/b", base=self.base, head=head, product="daemon"),
                 finding("s/c", switch="intents"), finding("s/c", switch="intents", source="e" * 40),
                 finding("s/c", switch="intents", product="app")]
        code, lines, output = self.run_route(items)
        self.assertEqual(code, 0, output)
        self.assertEqual(len(lines), 5, output)
        self.assertIn("duplicates dropped: 1", output)
        self.assertEqual(len({line["key"] for line in lines}), 5)
        reruns = [line["rerun"] for line in lines]
        self.assertNotIn("--product", reruns[0])
        self.assertIn("--product app", reruns[1])
        self.assertIn(f"--ref {'f' * 40}", reruns[2])
        self.assertIn(f"--ref {'e' * 40}", reruns[3])
        self.assertIn("--product app --switch intents", reruns[4])

    def test_confirmed_line_with_nothing_to_map_exits_1(self) -> None:
        head = self.commit(["scripts/cmux-next/oracle/x.py"])
        items = [finding("a/none"), finding("a/same", base=head, head=head), finding("a/ok", base=self.base, head=head)]
        code, lines, output = self.run_route(items)
        self.assertEqual(code, 1)
        self.assertEqual([line["case"] for line in lines], ["a/ok"])
        self.assertIn("a/none: no switch and no base/head", output)
        self.assertIn("a/same: base and head are one commit", output)

    def test_bad_inputs_exit_2(self) -> None:
        code, _, output = self.run_route([finding("a/b", switch="missing")])
        self.assertEqual(code, 2)
        self.assertIn("no registry file", output)
        code, _, output = self.run_route([finding("a/b", base="nope", head="HEAD")])
        self.assertEqual(code, 2)
        self.assertIn("nope: not a commit", output)
        doc = self.root / "divergence.json"
        doc.write_text(json.dumps({"schema": "oracle-divergence-v1", "divergences": []}, indent=1))
        with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()) as err:
            code = route.main([str(doc), "--out", str(self.root / "r.jsonl"), "--repo", str(self.repo)])
        self.assertEqual(code, 2)
        self.assertIn("run `oracle.py confirm`", err.getvalue())

    def test_empty_input_writes_an_empty_queue(self) -> None:
        out = self.root / "route.jsonl"
        out.write_text("stale\n")
        code, lines, _ = self.run_route([])
        self.assertEqual((code, lines), (0, []))

    def test_owner_parse_matches_the_repo_table(self) -> None:
        """The real OWNERS.md parses into rows, and an oracle file routes to PL-oracle there."""
        guardrails = route.load_guardrails()
        rows = route.owner_rows(route.Roots().owners.read_text(encoding="utf-8"), guardrails)
        [(row, files)] = route.group_by_owner(["scripts/cmux-next/oracle/route.py"], rows, guardrails)
        self.assertEqual(row.program, "p15-oracle")
        self.assertEqual(files, ["scripts/cmux-next/oracle/route.py"])


if __name__ == "__main__":
    unittest.main()
