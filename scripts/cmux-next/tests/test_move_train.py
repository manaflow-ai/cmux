#!/usr/bin/env python3
"""scripts/cmux-next/move-train.py on throwaway repositories with a fake fleet client.

Each test makes a bare "origin" with a target branch, a clone with ready branches, and a fake
cmux-ci that compiles a commit red when its tree contains COMPILE_ERROR. The fake answers only for
commits reachable from a ref of origin (the fleet compiles pushed commits only) and logs every call,
so the tests count fleet compiles. Covered: a dry run of 4 commits with one bad lands 3 and names
the bad one; a real run fast-forwards the target to exactly the 3 green commits; no cmux-ci refuses
the train before it touches git; an all-green train compiles once; a red target tip is reported,
not blamed; a no-verdict exit lands nothing; later commits of a bad commit's branch are dropped and
a commit that no longer applies is named; --max leaves the rest waiting; the bookkeeping commit
lands the lowered app-size cap; and an exit code without receipt lines is no verdict.

Not a CI job (Lawrence 2026-10-23: no new CI gates): run it yourself after a change to the train:
  python3 -I scripts/cmux-next/tests/test_move_train.py
"""

from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "move-train.py"
ONTO = "perf/chrome-parity"

FAKE_CMUX_CI = textwrap.dedent("""\
    #!/usr/bin/env python3
    import os, subprocess, sys
    args = sys.argv[1:]
    sha = args[args.index("--ref") + 1]
    remote = os.environ["MOVE_TRAIN_FAKE_REMOTE"]
    with open(os.environ["MOVE_TRAIN_FAKE_LOG"], "a") as log:
        log.write(sha + " " + " ".join(args) + "\\n")
    assert args[:2] == ["compile-check", "--app"] and "--package" in args, args
    refs = subprocess.run(["git", "--git-dir", remote, "for-each-ref", "--contains", sha],
                          capture_output=True, text=True).stdout
    if not refs.strip():
        print("the build fleet could not give a compile verdict (not pushed)")
        sys.exit(69)
    print("compile check job 0123abcd")
    if os.environ.get("MOVE_TRAIN_FAKE_MODE") == "no-verdict":
        print("the build fleet could not give a compile verdict: still queued after 600 s")
        sys.exit(75)
    bad = subprocess.run(["git", "--git-dir", remote, "grep", "-q", "COMPILE_ERROR", sha]).returncode == 0
    for target in ("CmuxNext", "app"):
        print(f"compile check {target}: {'failed' if bad else 'passed'} (1 s)")
    sys.exit(1 if bad else 0)
    """)


def load_module():
    spec = importlib.util.spec_from_file_location("move_train", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    sys.modules["move_train"] = module
    spec.loader.exec_module(module)
    return module


class Fixture:
    def __init__(self, root: Path):
        self.root = root
        self.remote = root / "origin.git"
        self.work = root / "work"
        self.log = root / "fleet.log"
        self.cmux_ci = root / "bin" / "cmux-ci"
        self.cmux_ci.parent.mkdir()
        self.cmux_ci.write_text(FAKE_CMUX_CI)
        self.cmux_ci.chmod(0o755)
        self.git_env = {**os.environ, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"}
        subprocess.run(["git", "init", "--quiet", "--bare", str(self.remote)], check=True, env=self.git_env)
        subprocess.run(["git", "init", "--quiet", "-b", ONTO, str(self.work)], check=True, env=self.git_env)
        self.git("config", "user.name", "Train Runner")
        self.git("config", "user.email", "runner@example.com")
        self.git("remote", "add", "origin", str(self.remote))
        self.commit("base", {"README": "base\n"})
        self.git("push", "--quiet", "origin", ONTO)

    def git(self, *args: str) -> str:
        return subprocess.run(["git", "-C", str(self.work), *args], check=True, capture_output=True, text=True,
                              env=self.git_env).stdout.strip()

    def commit(self, subject: str, files: dict[str, str], author: str = "Mover <mover@example.com>") -> str:
        for name, text in files.items():
            path = self.work / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        self.git("add", "-A")
        self.git("commit", "--quiet", "--author", author, "-m", subject)
        return self.git("rev-parse", "HEAD")

    def branch(self, name: str, start: str = f"origin/{ONTO}") -> None:
        self.git("fetch", "--quiet", "origin")
        self.git("switch", "--quiet", "-c", name, start)

    def train(self, *args: str, mode: str = "", cmux_ci: str | None = None) -> subprocess.CompletedProcess[str]:
        env = {**self.git_env, "MOVE_TRAIN_FAKE_REMOTE": str(self.remote), "MOVE_TRAIN_FAKE_LOG": str(self.log),
               "MOVE_TRAIN_FAKE_MODE": mode}
        ci = ["--cmux-ci", cmux_ci if cmux_ci is not None else str(self.cmux_ci)] if cmux_ci != "" else []
        return subprocess.run([sys.executable, str(SCRIPT), *ci, "--run-id", "t1",
                               "--receipt", str(self.root / "receipt.json"), *args],
                              cwd=self.work, capture_output=True, text=True, env=env)

    def compiles(self) -> list[str]:
        return self.log.read_text().splitlines() if self.log.exists() else []

    def remote_tip(self) -> str:
        return subprocess.run(["git", "--git-dir", str(self.remote), "rev-parse", f"refs/heads/{ONTO}"],
                              check=True, capture_output=True, text=True).stdout.strip()

    def remote_refs(self) -> list[str]:
        out = subprocess.run(["git", "--git-dir", str(self.remote), "for-each-ref", "--format=%(refname)"],
                             check=True, capture_output=True, text=True).stdout
        return out.split()

    def remote_subjects(self, rev: str) -> list[str]:
        return subprocess.run(["git", "--git-dir", str(self.remote), "log", "--reverse", "--format=%s", rev],
                              check=True, capture_output=True, text=True).stdout.split("\n")[:-1]

    def receipt(self) -> dict:
        return json.loads((self.root / "receipt.json").read_text())

    def four_ready(self, bad: int = 3) -> list[str]:
        """Four commits on branch `ready`; passed as four shas they are four independent ready commits."""
        self.branch("ready")
        return [self.commit(f"move {i}", {f"Sources/Move{i}.swift":
                                          ("let x: Int = \"COMPILE_ERROR\"\n" if i == bad else f"let m{i} = {i}\n")})
                for i in range(1, 5)]


class MoveTrainTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory(prefix="move-train-test-")
        self.fx = Fixture(Path(self.tmp.name))

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_dry_run_lands_three_and_names_the_bad_commit(self) -> None:
        shas = self.fx.four_ready(bad=3)
        base = self.fx.remote_tip()
        proc = self.fx.train("--dry-run", *shas)
        self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)
        self.assertIn("would land 3 of 4", proc.stdout)
        self.assertRegex(proc.stdout, rf"rejected {shas[2][:12]} move 3: first red commit: compile red")
        self.assertEqual(self.fx.remote_tip(), base, "a dry run pushes nothing to the target")
        self.assertEqual(self.fx.remote_refs(), [f"refs/heads/{ONTO}"], "scratch refs are deleted")
        # stack of 4 red, bisect 2 green, bisect 3 red, restacked [1, 2, 4] green.
        self.assertEqual(len(self.fx.compiles()), 4, self.fx.compiles())
        receipt = self.fx.receipt()
        self.assertEqual([item["subject"] for item in receipt["landed"]], ["move 1", "move 2", "move 4"])
        self.assertEqual([item["sha"] for item in receipt["rejected"]], [shas[2]])
        self.assertEqual([c["verdict"] for c in receipt["compiles"]], ["red", "green", "red", "green"])
        self.assertTrue(all(c["job"] == "0123abcd" for c in receipt["compiles"]))

    def test_real_run_fast_forwards_the_target_to_the_green_commits(self) -> None:
        shas = self.fx.four_ready(bad=3)
        base = self.fx.remote_tip()
        proc = self.fx.train(*shas)
        self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)
        self.assertIn("landed 3 of 4", proc.stdout)
        tip = self.fx.remote_tip()
        self.assertEqual(self.fx.remote_subjects(f"{base}..{tip}"), ["move 1", "move 2", "move 4"])
        self.assertEqual(self.fx.receipt()["landed_tip"], tip)
        files = subprocess.run(["git", "--git-dir", str(self.fx.remote), "ls-tree", "-r", "--name-only", tip],
                               check=True, capture_output=True, text=True).stdout.split()
        self.assertNotIn("Sources/Move3.swift", files)
        author = subprocess.run(["git", "--git-dir", str(self.fx.remote), "log", "-1", "--format=%an <%ae>", tip],
                                check=True, capture_output=True, text=True).stdout.strip()
        self.assertEqual(author, "Mover <mover@example.com>", "the author is kept")
        # Every compiled commit was a fleet commit: the landed tip is the one compiled green last.
        self.assertTrue(self.fx.compiles()[-1].startswith(tip))
        self.assertNotIn(shas[2], subprocess.run(["git", "--git-dir", str(self.fx.remote), "rev-list", tip],
                                                 capture_output=True, text=True).stdout)

    def test_refuses_without_cmux_ci(self) -> None:
        self.fx.four_ready()
        proc = self.fx.train("--dry-run", "ready", cmux_ci=str(self.fx.root / "missing" / "cmux-ci"))
        self.assertEqual(proc.returncode, 2)
        self.assertIn("needs cmux-ci", proc.stderr)
        self.assertIn("never builds locally", proc.stderr)
        # Without --cmux-ci, nothing on PATH, $CMUX_CI or ~/.local/bin.
        env = {**self.fx.git_env, "PATH": "/usr/bin:/bin", "HOME": str(self.fx.root), "CMUX_CI": ""}
        proc = subprocess.run([sys.executable, str(SCRIPT), "--dry-run", "ready"], cwd=self.fx.work,
                              capture_output=True, text=True, env=env)
        self.assertEqual(proc.returncode, 2)
        self.assertIn("needs cmux-ci", proc.stderr)
        self.assertEqual(self.fx.compiles(), [])
        self.assertEqual(self.fx.remote_refs(), [f"refs/heads/{ONTO}"])

    def test_all_green_compiles_once_and_lands_all(self) -> None:
        self.fx.four_ready(bad=0)
        proc = self.fx.train("ready")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("landed 4 of 4", proc.stdout)
        self.assertEqual(len(self.fx.compiles()), 1)

    def test_red_target_tip_is_reported_not_blamed(self) -> None:
        self.fx.commit("broken base", {"Broken.swift": "COMPILE_ERROR\n"})
        self.fx.git("push", "--quiet", "origin", ONTO)
        base = self.fx.remote_tip()
        self.fx.four_ready(bad=0)
        proc = self.fx.train("ready")
        self.assertEqual(proc.returncode, 4, proc.stdout + proc.stderr)
        self.assertIn(f"the target tip {base[:12]} is red", proc.stdout)
        self.assertEqual(self.fx.remote_tip(), base)
        self.assertEqual(self.fx.receipt()["rejected"], [], "the first commit is not blamed for the base")
        self.assertEqual(self.fx.receipt()["landed"], [])

    def test_no_verdict_lands_nothing(self) -> None:
        self.fx.four_ready()
        base = self.fx.remote_tip()
        proc = self.fx.train("ready", mode="no-verdict")
        self.assertEqual(proc.returncode, 3, proc.stdout + proc.stderr)
        self.assertEqual(self.fx.remote_tip(), base)
        self.assertEqual(len(self.fx.compiles()), 1, "no retry: the train stops")

    def test_drops_later_commits_of_the_bad_branch_and_names_ones_that_no_longer_apply(self) -> None:
        self.fx.branch("a")
        a1 = self.fx.commit("a1", {"A1.swift": "a1\n"})
        a2 = self.fx.commit("a2 bad", {"A2.swift": "COMPILE_ERROR\n", "Shared.swift": "one\n"})
        a3 = self.fx.commit("a3", {"A3.swift": "a3\n"})
        self.fx.branch("b", start="a")  # b builds on a2's Shared.swift
        b1 = self.fx.commit("b1 edits shared", {"Shared.swift": "two\n"})
        self.fx.branch("c")
        c1 = self.fx.commit("c1", {"C1.swift": "c1\n"})
        proc = self.fx.train("a", "b", "c")
        self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)
        receipt = self.fx.receipt()
        self.assertEqual([i["sha"] for i in receipt["landed"]], [a1, c1])
        reasons = {r["sha"]: r["reason"] for r in receipt["rejected"]}
        self.assertEqual(set(reasons), {a2, a3, b1})
        self.assertIn("first red commit", reasons[a2])
        self.assertEqual(reasons[a3], f"follows bad commit {a2[:12]}")
        self.assertIn("does not apply", reasons[b1])

    def test_max_leaves_the_rest_waiting(self) -> None:
        shas = self.fx.four_ready(bad=0)
        proc = self.fx.train("--max", "2", "ready")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("2 wait for the next train", proc.stdout)
        self.assertEqual(self.fx.receipt()["waiting"], shas[2:])
        self.assertEqual(self.fx.remote_subjects(self.fx.remote_tip())[-1], "move 2")

    def test_bookkeeping_commit_lowers_the_app_size_cap(self) -> None:
        self.fx.commit("app-size script", {
            "scripts/cmux-next/app-size-baseline.txt": "100\n",
            "scripts/cmux-next/check-app-size.sh": "#!/usr/bin/env bash\necho 90 > \"$2/scripts/cmux-next/app-size-baseline.txt\"\n",
        })
        self.fx.git("push", "--quiet", "origin", ONTO)
        self.fx.four_ready(bad=0)
        proc = self.fx.train("ready")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        tip = self.fx.remote_tip()
        self.assertTrue(self.fx.remote_subjects(tip)[-1].startswith("move-train: lower the app-size cap"), proc.stdout)
        baseline = subprocess.run(["git", "--git-dir", str(self.fx.remote), "show",
                                   f"{tip}:scripts/cmux-next/app-size-baseline.txt"],
                                  check=True, capture_output=True, text=True).stdout
        self.assertEqual(baseline, "90\n")
        self.assertEqual(self.fx.remote_subjects(f"{tip}~1")[-1], "move 4", "bookkeeping sits on the green tip")

    def test_exit_code_without_receipt_lines_is_no_verdict(self) -> None:
        train = load_module()
        self.assertEqual(train.verdict_from(0, ["compile check job 1234ab"]).result, train.NO_VERDICT)
        self.assertEqual(train.verdict_from(1, ["oops"]).result, train.NO_VERDICT)
        green = train.verdict_from(0, ["compile check job 1234ab", "compile check app: passed (3 s)"])
        self.assertEqual((green.result, green.job), (train.GREEN, "1234ab"))
        red = train.verdict_from(1, ["compile check CmuxNext: passed (3 s)", "compile check app: failed (3 s)"])
        self.assertEqual(red.result, train.RED)


if __name__ == "__main__":
    unittest.main()
