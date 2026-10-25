#!/usr/bin/env python3
"""scripts/cmux-next/move-train.py on throwaway repositories with a fake fleet client.

Each test makes a bare "origin" with a target branch, a clone with ready branches, and a fake
cmux-ci that compiles a commit red when its tree contains COMPILE_ERROR. The fake answers only for
commits reachable from a ref of origin (the fleet compiles pushed commits only) and logs every call,
so the tests count fleet compiles. Covered: a dry run of 4 commits with one bad lands 3 and names
the bad one; a real run fast-forwards the target to exactly the 3 green commits; no cmux-ci refuses
the train before it touches git; an all-green train compiles once; a red target tip is reported in
two compiles, not blamed; a target an earlier receipt proved green is not compiled again; a
no-verdict exit lands nothing; a no-verdict during the bisect lands only the proven-green prefix;
later commits of a bad commit's branch, and of a branch made on top of it, are dropped; a commit
that no longer applies is named and so are its descendants; a stale local branch is replaced by the
remote's; --max leaves the rest waiting; the bookkeeping commit lands the lowered app-size cap from
the target's script, not the stack's; a failed app-size step still records the arch ratchet; a
target that moves during the run lands nothing (exit 5); a refused landing push is not reported as
a moved target (exit 6); a git error after compiles still writes the receipt (exit 7); merge-tree
errors are not conflicts; and an exit code without receipt lines is no verdict.

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
    log_path = os.environ["MOVE_TRAIN_FAKE_LOG"]
    with open(log_path, "a") as log:
        log.write(sha + " " + " ".join(args) + "\\n")
    with open(log_path) as log:
        call = len(log.read().splitlines())
    assert args[:2] == ["compile-check", "--app"] and "--package" in args and "--no-cmux-tui" in args, args
    refs = subprocess.run(["git", "--git-dir", remote, "for-each-ref", "--contains", sha],
                          capture_output=True, text=True).stdout
    if not refs.strip():
        print("the build fleet could not give a compile verdict (not pushed)")
        sys.exit(69)
    print("compile check job 0123abcd")
    mode = os.environ.get("MOVE_TRAIN_FAKE_MODE", "")
    if mode == "no-verdict" or (mode.startswith("no-verdict-from-") and call >= int(mode.rsplit("-", 1)[1])):
        print("the build fleet could not give a compile verdict: still queued after 600 s")
        sys.exit(75)
    if mode == "move-target" and call == 1:  # someone lands on the target while the train compiles
        git = ["git", "--git-dir", remote]
        target = "refs/heads/" + os.environ["MOVE_TRAIN_FAKE_ONTO"]
        tree = subprocess.run(git + ["rev-parse", target + "^{tree}"], capture_output=True, text=True).stdout.strip()
        who = {**os.environ, "GIT_AUTHOR_NAME": "Other", "GIT_AUTHOR_EMAIL": "other@example.com",
               "GIT_COMMITTER_NAME": "Other", "GIT_COMMITTER_EMAIL": "other@example.com"}
        moved = subprocess.run(git + ["commit-tree", tree, "-p", target, "-m", "someone else"],
                               capture_output=True, text=True, check=True, env=who).stdout.strip()
        subprocess.run(git + ["update-ref", target, moved], check=True)
    bad = subprocess.run(["git", "--git-dir", remote, "grep", "-q", "COMPILE_ERROR", sha]).returncode == 0
    for target in ("CmuxNext", "app"):
        print(f"compile check {target}: {'failed' if bad else 'passed'} (1 s)")
    sys.exit(1 if bad else 0)
    """)

# A pre-push hook that refuses pushes to refs matching $MOVE_TRAIN_REFUSE (a shell pattern).
REFUSING_HOOK = textwrap.dedent("""\
    #!/usr/bin/env bash
    while read -r local_ref local_sha remote_ref remote_sha; do
      case "$remote_ref" in
        $MOVE_TRAIN_REFUSE) echo "pre-push: refused $remote_ref by the test hook" >&2; exit 1 ;;
      esac
    done
    exit 0
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
            if name.endswith((".sh", ".py")):
                path.chmod(0o755)
        self.git("add", "-A")
        self.git("commit", "--quiet", "--author", author, "-m", subject)
        return self.git("rev-parse", "HEAD")

    def branch(self, name: str, start: str = f"origin/{ONTO}") -> None:
        self.git("fetch", "--quiet", "origin")
        self.git("switch", "--quiet", "-c", name, start)

    def push_target(self) -> str:
        """Commits made on the target branch go to origin; its new tip."""
        self.git("push", "--quiet", "origin", ONTO)
        return self.remote_tip()

    def refuse_pushes(self, pattern: str) -> None:
        hook = self.work / ".git" / "hooks" / "pre-push"
        hook.write_text(REFUSING_HOOK)
        hook.chmod(0o755)
        self.refuse = pattern

    def train(self, *args: str, mode: str = "", cmux_ci: str | None = None) -> subprocess.CompletedProcess[str]:
        env = {**self.git_env, "MOVE_TRAIN_FAKE_REMOTE": str(self.remote), "MOVE_TRAIN_FAKE_LOG": str(self.log),
               "MOVE_TRAIN_FAKE_MODE": mode, "MOVE_TRAIN_FAKE_ONTO": ONTO,
               "MOVE_TRAIN_REFUSE": getattr(self, "refuse", "refs/nothing")}
        ci = ["--cmux-ci", cmux_ci if cmux_ci is not None else str(self.cmux_ci)] if cmux_ci != "" else []
        return subprocess.run([sys.executable, str(SCRIPT), *ci, "--run-id", "t1",
                               "--receipt", str(self.root / "receipt.json"), *args],
                              cwd=self.work, capture_output=True, text=True, env=env)

    def compiles(self) -> list[str]:
        return self.log.read_text().splitlines() if self.log.exists() else []

    def remote_git(self, *args: str) -> str:
        return subprocess.run(["git", "--git-dir", str(self.remote), *args], check=True, capture_output=True,
                              text=True).stdout

    def remote_tip(self) -> str:
        return self.remote_git("rev-parse", f"refs/heads/{ONTO}").strip()

    def remote_refs(self) -> list[str]:
        return self.remote_git("for-each-ref", "--format=%(refname)").split()

    def remote_subjects(self, rev: str) -> list[str]:
        return self.remote_git("log", "--reverse", "--format=%s", rev).split("\n")[:-1]

    def remote_show(self, rev: str, path: str) -> str:
        return self.remote_git("show", f"{rev}:{path}")

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
        # stack of 4 red, target tip green, bisect 2 green, bisect 3 red, restacked [1, 2, 4] green.
        self.assertEqual(len(self.fx.compiles()), 5, self.fx.compiles())
        receipt = self.fx.receipt()
        self.assertEqual([item["subject"] for item in receipt["landed"]], ["move 1", "move 2", "move 4"])
        self.assertEqual([item["sha"] for item in receipt["rejected"]], [shas[2]])
        self.assertEqual([c["verdict"] for c in receipt["compiles"]], ["red", "green", "green", "red", "green"])
        self.assertEqual(receipt["compiles"][1]["sha"], base)
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
        self.assertNotIn("Sources/Move3.swift", self.fx.remote_git("ls-tree", "-r", "--name-only", tip).split())
        author = self.fx.remote_git("log", "-1", "--format=%an <%ae>", tip).strip()
        self.assertEqual(author, "Mover <mover@example.com>", "the author is kept")
        # Every compiled commit was a fleet commit: the landed tip is the one compiled green last.
        self.assertTrue(self.fx.compiles()[-1].startswith(tip))
        self.assertNotIn(shas[2], self.fx.remote_git("rev-list", tip))
        self.assertIn(tip, self.fx.receipt()["green"])

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
        base = self.fx.push_target()
        self.fx.four_ready(bad=0)
        proc = self.fx.train("ready")
        self.assertEqual(proc.returncode, 4, proc.stdout + proc.stderr)
        self.assertIn(f"the target tip {base[:12]} is red", proc.stdout)
        self.assertEqual(self.fx.remote_tip(), base)
        self.assertEqual(len(self.fx.compiles()), 2, "the stack, then the target tip; no bisect of a red base")
        self.assertEqual(self.fx.receipt()["rejected"], [], "the first commit is not blamed for the base")
        self.assertEqual(self.fx.receipt()["landed"], [])

    def test_a_target_an_earlier_train_proved_green_is_not_compiled_again(self) -> None:
        self.fx.four_ready(bad=0)
        self.assertEqual(self.fx.train("ready").returncode, 0)
        landed = self.fx.remote_tip()
        self.fx.log.unlink()
        self.fx.branch("next", start=landed)
        bad = self.fx.commit("next bad", {"Next.swift": "COMPILE_ERROR\n"})
        proc = self.fx.train("next")
        self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)
        self.assertEqual(len(self.fx.compiles()), 1, "the stack only: the earlier receipt proved the target green")
        self.assertEqual([r["sha"] for r in self.fx.receipt()["rejected"]], [bad])

    def test_no_verdict_lands_nothing(self) -> None:
        self.fx.four_ready()
        base = self.fx.remote_tip()
        proc = self.fx.train("ready", mode="no-verdict")
        self.assertEqual(proc.returncode, 3, proc.stdout + proc.stderr)
        self.assertEqual(self.fx.remote_tip(), base)
        self.assertEqual(len(self.fx.compiles()), 1, "no retry: the train stops")

    def test_no_verdict_during_the_bisect_lands_the_proven_green_prefix(self) -> None:
        shas = self.fx.four_ready(bad=3)
        base = self.fx.remote_tip()
        # stack red, target tip green, bisect 2 green, bisect 3 no verdict.
        proc = self.fx.train(*shas, mode="no-verdict-from-4")
        self.assertEqual(proc.returncode, 3, proc.stdout + proc.stderr)
        self.assertEqual(self.fx.remote_subjects(f"{base}..{self.fx.remote_tip()}"), ["move 1", "move 2"])
        self.assertEqual(self.fx.receipt()["rejected"], [], "no verdict blames nothing")

    def test_drops_the_later_commits_of_a_bad_commit_and_branches_made_on_it(self) -> None:
        self.fx.branch("a")
        a1 = self.fx.commit("a1", {"A1.swift": "a1\n"})
        a2 = self.fx.commit("a2 bad", {"A2.swift": "COMPILE_ERROR\n"})
        a3 = self.fx.commit("a3", {"A3.swift": "a3\n"})
        self.fx.branch("b", start=a2)  # b builds on a2 and applies cleanly without it
        b1 = self.fx.commit("b1 uses a2", {"B1.swift": "b1\n"})
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
        self.assertEqual(reasons[b1], f"follows bad commit {a2[:12]}")
        self.assertNotIn("B1.swift", self.fx.remote_git("ls-tree", "-r", "--name-only", self.fx.remote_tip()))

    def test_names_a_commit_that_no_longer_applies_and_drops_its_descendants(self) -> None:
        self.fx.branch("x")
        x = self.fx.commit("x bad", {"X.swift": "COMPILE_ERROR\n", "Shared.swift": "one\n"})
        y = self.fx.commit("y edits shared", {"Shared.swift": "two\n"})
        # Named by sha, y is independent of x: it is restacked without x and then does not apply.
        proc = self.fx.train("--dry-run", x, y)
        self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)
        reasons = {r["sha"]: r["reason"] for r in self.fx.receipt()["rejected"]}
        self.assertIn("first red commit", reasons[x])
        self.assertIn("does not apply", reasons[y])
        # A branch made on a commit that does not apply is dropped with it, before any compile.
        self.fx.log.unlink()
        self.fx.git("switch", "--quiet", ONTO)
        self.fx.branch("p")
        p1 = self.fx.commit("p1 edits README", {"README": "p\n"})
        self.fx.branch("q", start="p")
        q1 = self.fx.commit("q1", {"Q.swift": "q\n"})
        self.fx.git("switch", "--quiet", ONTO)
        self.fx.commit("README moves on", {"README": "base 2\n"})
        self.fx.push_target()
        proc = self.fx.train("--dry-run", "p", "q")
        self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)
        reasons = {r["sha"]: r["reason"] for r in self.fx.receipt()["rejected"]}
        self.assertIn("does not apply", reasons[p1])
        self.assertEqual(reasons[q1], f"follows {p1[:12]}, which {reasons[p1]}")
        self.assertEqual(self.fx.compiles(), [])

    def test_a_branch_ref_is_the_remote_branch_not_a_stale_local_copy(self) -> None:
        self.fx.branch("cp/x")
        x1 = self.fx.commit("x1", {"X1.swift": "x1\n"})
        x2 = self.fx.commit("x2", {"X2.swift": "x2\n"})
        self.fx.git("push", "--quiet", "origin", "cp/x")
        self.fx.git("switch", "--quiet", ONTO)
        self.fx.git("branch", "--quiet", "-f", "cp/x", x1)  # the local copies are one commit behind
        for ref in ("cp/x", "origin/cp/x"):
            self.fx.git("update-ref", "refs/remotes/origin/cp/x", x1)
            proc = self.fx.train("--dry-run", ref)
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
            receipt = self.fx.receipt()
            self.assertEqual([i["sha"] for i in receipt["landed"]], [x1, x2], ref)
            self.assertEqual(receipt["refs"], [{"ref": ref, "tip": x2, "from": "origin/cp/x"}])

    def test_max_leaves_the_rest_waiting(self) -> None:
        shas = self.fx.four_ready(bad=0)
        proc = self.fx.train("--max", "2", "ready")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("2 wait for the next train", proc.stdout)
        self.assertEqual(self.fx.receipt()["waiting"], shas[2:])
        self.assertEqual(self.fx.remote_subjects(self.fx.remote_tip())[-1], "move 2")

    def test_bookkeeping_commit_lowers_the_app_size_cap_with_the_target_script(self) -> None:
        self.fx.commit("app-size script", {
            "scripts/cmux-next/app-size-baseline.txt": "100\n",
            "scripts/cmux-next/check-app-size.sh": "#!/usr/bin/env bash\necho 90 > \"$2/scripts/cmux-next/app-size-baseline.txt\"\n",
        })
        self.fx.push_target()
        self.fx.four_ready(bad=0)
        # A ready commit's own copy of the script is not what the train runs.
        self.fx.commit("move 5 edits the script", {
            "scripts/cmux-next/check-app-size.sh": "#!/usr/bin/env bash\necho 1 > \"$2/scripts/cmux-next/app-size-baseline.txt\"\n",
        })
        proc = self.fx.train("ready")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        tip = self.fx.remote_tip()
        self.assertTrue(self.fx.remote_subjects(tip)[-1].startswith("move-train: lower the app-size cap"), proc.stdout)
        self.assertEqual(self.fx.remote_show(tip, "scripts/cmux-next/app-size-baseline.txt"), "90\n")
        self.assertEqual(self.fx.remote_subjects(f"{tip}~1")[-1], "move 5 edits the script",
                         "bookkeeping sits on the green tip")
        self.assertIn(tip, self.fx.receipt()["green"], "a data-only bookkeeping commit on a green tip is green")

    def test_a_failed_app_size_step_still_records_the_arch_ratchet(self) -> None:
        self.fx.commit("bookkeeping scripts", {
            "scripts/cmux-next/app-size-baseline.txt": "100\n",
            "scripts/cmux-next/check-app-size.sh": "#!/usr/bin/env bash\n"
                                                   "echo 999 > \"$2/scripts/cmux-next/app-size-baseline.txt\"\n"
                                                   "echo 'over the cap' >&2; exit 1\n",
            "scripts/cmux-next/arch-ratchet.py": textwrap.dedent("""\
                import pathlib, sys
                repo = pathlib.Path(sys.argv[sys.argv.index("--repo") + 1])
                assert "--update" in sys.argv
                (repo / "plans/cmux-next").mkdir(parents=True, exist_ok=True)
                (repo / "plans/cmux-next/arch-ratchet.json").write_text('{"recorded": true}\\n')
                """),
        })
        self.fx.push_target()
        self.fx.four_ready(bad=0)
        proc = self.fx.train("ready")
        self.assertEqual(proc.returncode, 8, proc.stdout + proc.stderr)
        tip = self.fx.remote_tip()
        self.assertEqual(self.fx.remote_subjects(f"{tip}~1")[-1], "move 4", "the green stack landed")
        self.assertEqual(self.fx.remote_show(tip, "plans/cmux-next/arch-ratchet.json"), '{"recorded": true}\n')
        self.assertEqual(self.fx.remote_show(tip, "scripts/cmux-next/app-size-baseline.txt"), "100\n",
                         "the failed step records nothing")
        steps = {entry["step"]: entry for entry in self.fx.receipt()["bookkeeping"]}
        self.assertEqual((steps["scripts/cmux-next/check-app-size.sh"]["ok"],
                          steps["scripts/cmux-next/check-app-size.sh"]["exit"]), (False, 1))
        self.assertIn("over the cap", steps["scripts/cmux-next/check-app-size.sh"]["detail"])
        self.assertTrue(steps["scripts/cmux-next/arch-ratchet.py"]["ok"])

    def test_a_target_that_moves_during_the_run_lands_nothing(self) -> None:
        self.fx.four_ready(bad=0)
        base = self.fx.remote_tip()
        proc = self.fx.train("ready", mode="move-target")
        self.assertEqual(proc.returncode, 5, proc.stdout + proc.stderr)
        self.assertIn("moved since", proc.stdout)
        moved = self.fx.remote_tip()
        self.assertNotEqual(moved, base)
        self.assertEqual(self.fx.remote_subjects(moved)[-1], "someone else", "the other landing is kept")
        self.assertFalse(self.fx.receipt()["pushed"])

    def test_a_refused_landing_push_is_not_a_moved_target(self) -> None:
        self.fx.four_ready(bad=0)
        base = self.fx.remote_tip()
        self.fx.refuse_pushes("refs/heads/perf/*")
        proc = self.fx.train("ready")
        self.assertEqual(proc.returncode, 6, proc.stdout + proc.stderr)
        self.assertIn("was refused", proc.stdout)
        self.assertIn("refused refs/heads/perf/chrome-parity by the test hook", proc.stdout)
        self.assertNotIn("rerun", proc.stdout)
        self.assertEqual(self.fx.remote_tip(), base)
        self.assertEqual(self.fx.receipt()["exit"], 6)

    def test_a_git_error_after_compiles_still_writes_the_receipt(self) -> None:
        shas = self.fx.four_ready(bad=3)
        self.fx.refuse_pushes("refs/heads/move-train/t1-2")  # the restacked round's scratch push fails
        proc = self.fx.train("--dry-run", *shas)
        self.assertEqual(proc.returncode, 7, proc.stdout + proc.stderr)
        receipt = self.fx.receipt()
        self.assertEqual(receipt["exit"], 7)
        self.assertIn("refs/heads/move-train/t1-2", receipt["error"])
        self.assertEqual(len(receipt["compiles"]), 4, "the compiles before the error are kept")
        self.assertEqual([r["sha"] for r in receipt["rejected"]], [shas[2]])
        self.assertEqual(receipt["landed"], [])
        self.assertEqual(self.fx.remote_refs(), [f"refs/heads/{ONTO}"], "scratch refs are deleted")

    def test_merge_tree_errors_are_not_conflicts(self) -> None:
        train = load_module()
        git = train.Git(self.fx.work)
        self.fx.branch("one")
        one = self.fx.commit("one", {"README": "one\n"})
        self.fx.branch("two")
        two = self.fx.commit("two", {"README": "two\n"})
        self.assertIsNone(git.pick(one, two), "a conflict is None")
        with self.assertRaises(train.TrainError) as raised:
            git.pick("0" * 40, two)  # no such object: merge-tree exits 1 like a conflict, but prints no tree
        self.assertEqual(raised.exception.code, train.EXIT_RUN_ERROR)
        self.assertIn("not something we can merge", str(raised.exception))

        class OldGit(train.Git):  # git < 2.40 has no merge-tree --merge-base: a usage error, exit 129
            def run(self, *args, **kwargs):
                if args[0] == "merge-tree":
                    return subprocess.CompletedProcess(args, 129, "", "error: unknown option `merge-base=...'")
                return super().run(*args, **kwargs)

        with self.assertRaises(train.TrainError) as raised:
            OldGit(self.fx.work).pick(one, two)
        self.assertIn("exited 129", str(raised.exception))
        self.assertTrue(train.git_version_ok("git version 2.43.0"))
        self.assertFalse(train.git_version_ok("git version 2.39.5 (Apple Git-154)"))

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
