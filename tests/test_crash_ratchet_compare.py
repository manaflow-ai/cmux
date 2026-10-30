"""Behavior tests for scripts/ci/crash_ratchet_compare.py (the PR crash-ratchet job).

A fake ratchet stands in for scripts/cmux-next/crash_ratchet.py: it prints the text in
<repo>/ratchet.out and exits with the code in <repo>/ratchet.rc, so each case states exactly what
the real ratchet would print for the head and for the base. Its baseline judgment
(--baseline-against) prints <repo>/baseline.out and exits with <repo>/baseline.rc (default: the
`baseline ok` line, exit 0).
"""
import json
import os
import subprocess
import sys
import tempfile
import textwrap
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
COMPARE = os.path.join(HERE, "..", "scripts", "ci", "crash_ratchet_compare.py")

FAKE = textwrap.dedent("""\
    import argparse, os, sys
    p = argparse.ArgumentParser()
    p.add_argument("--repo")
    p.add_argument("--exported-tree", action="store_true")
    p.add_argument("--baseline-against")
    o = p.parse_args()
    if o.baseline_against:
        if os.path.basename(o.baseline_against) != "base" or os.path.basename(o.repo) != "head":
            print("the head's baseline must be judged against the base tree"); sys.exit(9)
        path = os.path.join(o.repo, "baseline.out")
        if not os.path.exists(path):
            print("crash-ratchet: baseline ok"); sys.exit(0)
        print(open(path).read(), end="")
        sys.exit(int(open(os.path.join(o.repo, "baseline.rc")).read()))
    if os.path.basename(o.repo) == "base" and not o.exported_tree:
        print("the base must be scanned as an exported tree"); sys.exit(9)
    print(open(os.path.join(o.repo, "ratchet.out")).read(), end="")
    sys.exit(int(open(os.path.join(o.repo, "ratchet.rc")).read()))
""")

OK = "crash-ratchet: ok\n"
UNWRAP_3 = "crash-ratchet: rust cmux-tui: unwrap 30 -> 33\ncrash-ratchet: 1 module(s) or crate(s) gained a crash-class hit\n"
UNWRAP_31 = "crash-ratchet: rust cmux-tui: unwrap 30 -> 31\ncrash-ratchet: 1 module(s) or crate(s) gained a crash-class hit\n"
TWO = UNWRAP_3 + "crash-ratchet: swift CmuxNextApp: unchecked 5 -> 6\n"


class CrashRatchetCompare(unittest.TestCase):
    def run_case(self, head, base, baseline=None):
        with tempfile.TemporaryDirectory() as tmp:
            fake = os.path.join(tmp, "crash_ratchet.py")
            with open(fake, "w") as f:
                f.write(FAKE)
            for name, (text, rc) in (("head", head), ("base", base)):
                os.makedirs(os.path.join(tmp, name))
                with open(os.path.join(tmp, name, "ratchet.out"), "w") as f:
                    f.write(text)
                with open(os.path.join(tmp, name, "ratchet.rc"), "w") as f:
                    f.write(str(rc))
            if baseline is not None:
                text, rc = baseline
                with open(os.path.join(tmp, "head", "baseline.out"), "w") as f:
                    f.write(text)
                with open(os.path.join(tmp, "head", "baseline.rc"), "w") as f:
                    f.write(str(rc))
            out = subprocess.run([sys.executable, COMPARE, "--script", fake, "--head", os.path.join(tmp, "head"),
                                  "--base", os.path.join(tmp, "base")], capture_output=True, text=True)
            return out.returncode, out.stdout + out.stderr

    def test_green_head_passes(self):
        rc, out = self.run_case((OK, 0), ("garbage", 1))
        self.assertEqual(rc, 0, out)

    def test_a_raised_baseline_is_red_even_when_the_head_is_green(self):
        raised = "crash-ratchet: baseline raised: swift M: dynamic_dispatch base 1, head 2\n"
        rc, out = self.run_case((OK, 0), (OK, 0), baseline=(raised, 1))
        self.assertEqual(rc, 1, out)
        self.assertIn("::error::crash-safety-baseline.json may only go down: swift M: dynamic_dispatch base 1, head 2", out)
        self.assertIn("crash-ratchet: ok on the head", out)

    def test_a_recorded_waiver_is_a_warning(self):
        waiver = "crash-ratchet: waiver recorded: swift M: unchecked.waived base 0, head 1\ncrash-ratchet: baseline ok\n"
        rc, out = self.run_case((OK, 0), (OK, 0), baseline=(waiver, 0))
        self.assertEqual(rc, 0, out)
        self.assertIn("::warning::a reviewed crash-allow waiver is recorded in the baseline: swift M: unchecked.waived", out)

    def test_a_failed_baseline_judgment_is_red(self):
        for text, code in (("Traceback: broke\n", 1), ("nothing\n", 0), ("crash-ratchet: baseline ok\n", 2)):
            rc, out = self.run_case((OK, 0), (OK, 0), baseline=(text, code))
            self.assertEqual(rc, 1, out)
            self.assertIn("could not be judged", out)

    def test_head_red_on_green_base_fails_with_both_counts(self):
        rc, out = self.run_case((UNWRAP_3, 1), (OK, 0))
        self.assertEqual(rc, 1, out)
        self.assertIn("rust cmux-tui: unwrap: head 33, base ok", out)
        self.assertIn("turns the crash ratchet red", out)

    def test_base_red_and_head_not_worse_warns(self):
        rc, out = self.run_case((UNWRAP_3, 1), (UNWRAP_3, 1))
        self.assertEqual(rc, 0, out)
        self.assertIn("::warning::", out)

    def test_head_worse_than_red_base_fails(self):
        rc, out = self.run_case((UNWRAP_3, 1), (UNWRAP_31, 1))
        self.assertEqual(rc, 1, out)
        self.assertIn("head 33, base 31", out)

    def test_new_line_on_red_base_fails(self):
        rc, out = self.run_case((TWO, 1), (UNWRAP_3, 1))
        self.assertEqual(rc, 1, out)
        self.assertIn("swift CmuxNextApp: unchecked head 6, base not red", out)

    def test_exit_zero_without_ok_line_is_not_green(self):
        rc, out = self.run_case(("Traceback: something broke\n", 0), (OK, 0))
        self.assertEqual(rc, 1, out)
        self.assertIn("did not run on the head", out)

    def test_failed_base_run_refuses_with_its_output(self):
        rc, out = self.run_case((UNWRAP_3, 1), ("crash-ratchet: refused, not a checkout\n", 2))
        self.assertEqual(rc, 1, out)
        self.assertIn("did not run on the base", out)
        self.assertIn("refused, not a checkout", out)


RATCHET = os.path.join(HERE, "..", "scripts", "cmux-next", "crash_ratchet.py")
GRANDFATHERED = "Packages/macOS/CmuxNext/Sources/M/A.swift"


class RealRatchetAgainstBase(unittest.TestCase):
    """The real crash_ratchet.py on a fixture, compared the way the PR job compares it.

    After a stale absolute baseline is refreshed, the base is green with grandfathered hits: a
    banned class allowed at its current count in crash-allowlist.json, and a ratchet class in the
    baseline. A pull request that adds one more hit of either kind must still be red.
    """

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(lambda: subprocess.run(["rm", "-rf", self.tmp]))
        self.head = os.path.join(self.tmp, "head")
        self.base = os.path.join(self.tmp, "base")
        scripts = os.path.join(self.head, "scripts", "cmux-next")
        os.makedirs(scripts)
        os.makedirs(os.path.join(self.head, "cmux-tui", "crates", "x", "src"))
        self.write("cmux-tui/crates/x/src/lib.rs", "pub fn f() {}\n")
        with open(RATCHET) as src, open(os.path.join(scripts, "crash_ratchet.py"), "w") as dst:
            dst.write(src.read())
        self.write(GRANDFATHERED, "final class A {\n    unowned let owner: Owner\n"
                                  "    let s = NSSelectorFromString(\"run\")\n}\n")
        self.write("scripts/cmux-next/crash-allowlist.json", json.dumps({
            "banned": ["swift.unowned"],
            "allow": [{"path": GRANDFATHERED, "class": "swift.unowned", "count": 1,
                       "reason": "grandfathered", "reviewer": "fixture"}]}))
        self.git("init", "-q")
        self.git("add", ".")
        subprocess.run([sys.executable, os.path.join(scripts, "crash_ratchet.py"), "--repo", self.head,
                        "--update-baseline"], check=True, capture_output=True)
        with open(os.path.join(scripts, "crash-safety-baseline.json")) as f:
            self.assertEqual(json.load(f)["swift"]["dynamic_dispatch"], {"M": 1})
        self.git("add", ".")
        self.git("commit", "-qm", "base")
        # The base as the job builds it: an exported tree of tracked files (git archive).
        archive = subprocess.run(["git", "-C", self.head, "archive", "--format=tar", "HEAD"],
                                 check=True, capture_output=True).stdout
        os.makedirs(self.base)
        subprocess.run(["tar", "-x", "-C", self.base], input=archive, check=True)

    def write(self, rel, text):
        path = os.path.join(self.head, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(text)

    def git(self, *args):
        subprocess.run(["git", "-C", self.head, "-c", "user.name=t", "-c", "user.email=t@t",
                        "-c", "commit.gpgsign=false", *args], check=True, capture_output=True)

    def compare(self):
        self.git("add", ".")
        out = subprocess.run([sys.executable, COMPARE, "--script",
                              os.path.join(self.head, "scripts", "cmux-next", "crash_ratchet.py"),
                              "--head", self.head, "--base", self.base], capture_output=True, text=True)
        return out.returncode, out.stdout + out.stderr

    def test_grandfathered_base_is_green(self):
        rc, out = self.compare()
        self.assertEqual(rc, 0, out)
        self.assertIn("crash-ratchet: ok on the head", out)

    def test_extra_banned_hit_in_grandfathered_file_fails(self):
        self.write(GRANDFATHERED, "final class A {\n    unowned let owner: Owner\n    unowned let other: Owner\n"
                                  "    let s = NSSelectorFromString(\"run\")\n}\n")
        rc, out = self.compare()
        self.assertEqual(rc, 1, out)
        self.assertIn("swift M: unowned: head 2, base ok", out)

    def test_banned_hit_in_new_file_fails(self):
        self.write("Packages/macOS/CmuxNext/Sources/M/B.swift", "final class B {\n    unowned let owner: Owner\n}\n")
        rc, out = self.compare()
        self.assertEqual(rc, 1, out)
        self.assertIn("turns the crash ratchet red", out)

    def test_extra_ratchet_class_hit_over_refreshed_baseline_fails(self):
        self.write("Packages/macOS/CmuxNext/Sources/M/B.swift", "let t = NSSelectorFromString(\"stop\")\n")
        rc, out = self.compare()
        self.assertEqual(rc, 1, out)
        self.assertIn("swift M: dynamic_dispatch: head 2, base ok", out)


class WaivedHitsCount(unittest.TestCase):
    """A `// crash-allow:` waiver must not make a hit disappear from the count.

    B1 (ba5e6df99f9) moved RunningProcess (`@unchecked Sendable`) from CmuxNextApp to
    CmuxNextFilesUI and appended a crash-allow on the way: CmuxNextApp's count went 4 -> 3, FilesUI
    counted nothing, and --update-baseline recorded the drop as a reduction while the construct was
    unchanged. The real crash_ratchet.py, judged the way the CI job judges it, must see that move."""

    OLD = "Packages/macOS/CmuxNext/Sources/App/RunningProcess.swift"
    NEW = "Packages/macOS/CmuxNext/Sources/FilesUI/RunningProcess.swift"
    WRAPPER = "final class RunningProcess: @unchecked Sendable {\n    let process = Process()\n}\n"

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(lambda: subprocess.run(["rm", "-rf", self.tmp]))
        self.head = os.path.join(self.tmp, "head")
        self.base = os.path.join(self.tmp, "base")
        self.ratchet = os.path.join(self.head, "scripts", "cmux-next", "crash_ratchet.py")
        with open(RATCHET) as src:
            self.write("scripts/cmux-next/crash_ratchet.py", src.read())
        self.write("cmux-tui/crates/x/src/lib.rs", "pub fn f() {}\n")
        self.write(self.OLD, self.WRAPPER)
        self.write("Packages/macOS/CmuxNext/Sources/FilesUI/Search.swift", "let limit = 500\n")
        self.git("init", "-q")
        self.git("add", ".")
        self.update_baseline()
        self.assertEqual(self.baseline()["swift"]["unchecked"], {"App": 1})
        self.git("add", ".")
        self.git("commit", "-qm", "base")
        archive = subprocess.run(["git", "-C", self.head, "archive", "--format=tar", "HEAD"],
                                 check=True, capture_output=True).stdout
        os.makedirs(self.base)
        subprocess.run(["tar", "-x", "-C", self.base], input=archive, check=True)
        # The move, with a waiver added on the way.
        self.git("mv", self.OLD, self.NEW)
        self.write(self.NEW, self.WRAPPER.replace(
            "@unchecked Sendable {", "@unchecked Sendable { // crash-allow: moved with its owner"))
        self.git("add", ".")

    def write(self, rel, text):
        path = os.path.join(self.head, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(text)

    def git(self, *args):
        subprocess.run(["git", "-C", self.head, "-c", "user.name=t", "-c", "user.email=t@t",
                        "-c", "commit.gpgsign=false", *args], check=True, capture_output=True)

    def update_baseline(self, *flags):
        subprocess.run([sys.executable, self.ratchet, "--repo", self.head, "--update-baseline", *flags],
                       check=True, capture_output=True)

    def baseline(self):
        with open(os.path.join(self.head, "scripts", "cmux-next", "crash-safety-baseline.json")) as f:
            return json.load(f)

    def test_a_waiver_added_in_a_move_is_red_against_the_base(self):
        out = subprocess.run([sys.executable, COMPARE, "--script", self.ratchet, "--head", self.head,
                              "--base", self.base], capture_output=True, text=True)
        text = out.stdout + out.stderr
        self.assertEqual(out.returncode, 1, text)
        self.assertIn("swift FilesUI: unchecked.waived: head 1, base ok", text)

    def test_the_refreshed_baseline_records_the_waiver_not_a_reduction(self):
        # --update-baseline never raises a row; the waiver is recorded on purpose, with --record-waivers.
        refused = subprocess.run([sys.executable, self.ratchet, "--repo", self.head, "--update-baseline"],
                                 capture_output=True, text=True)
        self.assertEqual(refused.returncode, 1, refused.stdout + refused.stderr)
        self.assertIn("swift FilesUI: unchecked.waived 0 -> 1", refused.stdout + refused.stderr)
        self.assertNotIn("FilesUI", self.baseline().get("waived", {}).get("swift", {}).get("unchecked", {}))
        self.update_baseline("--record-waivers")
        baseline = self.baseline()
        self.assertNotIn("App", baseline["swift"].get("unchecked", {}))
        self.assertEqual(baseline["waived"]["swift"]["unchecked"], {"FilesUI": 1})
        out = subprocess.run([sys.executable, self.ratchet, "--repo", self.head], capture_output=True, text=True)
        self.assertEqual(out.returncode, 0, out.stdout + out.stderr)
        # Fixing the hit lowers the waived count like any other.
        self.write(self.NEW, "final class RunningProcess {}\n")
        self.git("add", ".")
        out = subprocess.run([sys.executable, self.ratchet, "--repo", self.head], capture_output=True, text=True)
        self.assertEqual(out.returncode, 0, out.stdout + out.stderr)
        self.assertIn("count(s) went down", out.stdout)


class FixtureRepo:
    """A throwaway git repository with the real crash_ratchet.py and crash_ratchet_compare.py."""

    def make_repo(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(lambda: subprocess.run(["rm", "-rf", self.tmp]))
        self.repo = os.path.join(self.tmp, "repo")
        for rel, src in (("scripts/cmux-next/crash_ratchet.py", RATCHET), ("scripts/ci/crash_ratchet_compare.py", COMPARE)):
            with open(src) as f:
                self.write(rel, f.read())
        self.write("cmux-tui/crates/x/src/lib.rs", "pub fn f() {}\n")
        self.git("init", "-q")
        self.ratchet = os.path.join(self.repo, "scripts", "cmux-next", "crash_ratchet.py")
        self.baseline_path = os.path.join(self.repo, "scripts", "cmux-next", "crash-safety-baseline.json")

    def write(self, rel, text):
        path = os.path.join(self.repo, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(text)

    def git(self, *args):
        return subprocess.run(["git", "-C", self.repo, "-c", "user.name=t", "-c", "user.email=t@t",
                               "-c", "commit.gpgsign=false", *args], check=True, capture_output=True,
                              text=True).stdout.strip()

    def move(self, rel, to):
        """git mv REL TO (the destination folder may be new)."""
        os.makedirs(os.path.dirname(os.path.join(self.repo, to)), exist_ok=True)
        self.git("mv", rel, to)

    def run_ratchet(self, *flags):
        self.git("add", "-A")
        out = subprocess.run([sys.executable, self.ratchet, "--repo", self.repo, *flags], capture_output=True, text=True)
        return out.returncode, out.stdout + out.stderr

    def commit(self, message, update_baseline=False):
        self.git("add", "-A")
        if update_baseline:
            rc, out = self.run_ratchet("--update-baseline")
            self.assertEqual(rc, 0, out)
            self.git("add", "-A")
        self.git("commit", "-qm", message)
        return self.git("rev-parse", "HEAD")

    def baseline(self):
        with open(self.baseline_path) as f:
            return json.load(f)

    def set_row(self, kind, module, hits, waived=False):
        """Writes one swift row of the baseline by hand (what any writer, or an editor, can do)."""
        data = self.baseline()
        section = data.setdefault("waived", {}) if waived else data
        modules = section.setdefault("swift", {}).setdefault(kind, {})
        if hits:
            modules[module] = hits
        else:
            modules.pop(module, None)
        with open(self.baseline_path, "w") as f:
            json.dump(data, f, indent=1, sort_keys=True)


SELECTOR = "let {name} = NSSelectorFromString(\"{name}\")\n"


class BaselineOnlyGoesDown(FixtureRepo, unittest.TestCase):
    """crash_ratchet.py --update-baseline lowers rows and never raises one.

    It used to write the raw counts, so an agent who ran it to record a waiver (as the red message
    said) also raised every counted row that was red at that moment, other agents' regressions
    included. A counted row now rises only with a proven move (--base REF: the same hit lines left
    another module), a waived row only with --record-waivers; every other row stays at the baseline."""

    M = "Packages/macOS/CmuxNext/Sources/M/A.swift"
    K = "Packages/macOS/CmuxNext/Sources/K/A.swift"

    def setUp(self):
        self.make_repo()
        self.write(self.M, SELECTOR.format(name="run"))
        self.write(self.K, SELECTOR.format(name="go") + SELECTOR.format(name="stop"))
        self.base = self.commit("base", update_baseline=True)
        self.assertEqual(self.baseline()["swift"]["dynamic_dispatch"], {"M": 1, "K": 2})

    def test_it_lowers_a_fixed_row_and_refuses_to_raise_a_red_one(self):
        self.write(self.M, SELECTOR.format(name="run") + SELECTOR.format(name="halt"))
        self.write(self.K, SELECTOR.format(name="go"))
        rc, out = self.run_ratchet("--update-baseline")
        self.assertEqual(rc, 1, out)
        self.assertIn("swift M: dynamic_dispatch 1 -> 2", out)
        self.assertEqual(self.baseline()["swift"]["dynamic_dispatch"], {"M": 1, "K": 1})
        rc, out = self.run_ratchet()
        self.assertEqual(rc, 1, out)
        self.assertIn("crash-ratchet: swift M: dynamic_dispatch 1 -> 2", out)

    def test_a_waiver_is_recorded_only_with_record_waivers(self):
        self.write(self.M, SELECTOR.format(name="run") + "let h = NSSelectorFromString(\"halt\") // crash-allow: reviewed\n")
        rc, out = self.run_ratchet("--update-baseline")
        self.assertEqual(rc, 1, out)
        self.assertIn("swift M: dynamic_dispatch.waived 0 -> 1", out)
        self.assertNotIn("waived", json.dumps(self.baseline().get("waived", {}).get("swift", {})))
        rc, out = self.run_ratchet("--record-waivers")
        self.assertEqual(rc, 0, out)
        self.assertEqual(self.baseline()["waived"]["swift"]["dynamic_dispatch"], {"M": 1})
        self.assertEqual(self.baseline()["swift"]["dynamic_dispatch"], {"M": 1, "K": 2})

    def test_record_waivers_does_not_raise_a_counted_row(self):
        self.write(self.M, SELECTOR.format(name="run") + SELECTOR.format(name="halt")
                   + "let h = NSSelectorFromString(\"x\") // crash-allow: reviewed\n")
        rc, out = self.run_ratchet("--record-waivers")
        self.assertEqual(rc, 1, out)
        self.assertIn("swift M: dynamic_dispatch 1 -> 2", out)
        self.assertEqual(self.baseline()["swift"]["dynamic_dispatch"]["M"], 1)
        self.assertEqual(self.baseline()["waived"]["swift"]["dynamic_dispatch"], {"M": 1})

    def test_a_move_carries_its_row_when_proven_against_the_base(self):
        self.move(self.M, "Packages/macOS/CmuxNext/Sources/N/A.swift")
        rc, out = self.run_ratchet("--update-baseline")
        self.assertEqual(rc, 1, out)
        self.assertIn("swift N: dynamic_dispatch 0 -> 1", out)
        rc, out = self.run_ratchet("--update-baseline", "--base", self.base)
        self.assertEqual(rc, 0, out)
        self.assertIn("moved", out)
        self.assertEqual(self.baseline()["swift"]["dynamic_dispatch"], {"N": 1, "K": 2})

    def test_a_move_does_not_carry_a_hit_the_base_was_already_red_on(self):
        # The base's M is red: 2 hits over a baseline of 1. Moving both to N carries only 1.
        self.write(self.M, SELECTOR.format(name="run") + SELECTOR.format(name="halt"))
        red = self.commit("adds a hit past the baseline")
        self.move(self.M, "Packages/macOS/CmuxNext/Sources/N/A.swift")
        rc, out = self.run_ratchet("--update-baseline", "--base", red)
        self.assertEqual(rc, 1, out)
        self.assertIn("swift N: dynamic_dispatch 1 -> 2", out)
        self.assertEqual(self.baseline()["swift"]["dynamic_dispatch"], {"N": 1, "K": 2})


class CrashRatchetCIStepTests(FixtureRepo, unittest.TestCase):
    """scripts/ci/crash-ratchet-against-base.sh, the workflow step, on throwaway repositories with
    the real ratchet and compare scripts.

    The head's own script and baseline judge both trees, so a change that raised its baseline was
    green against it ("ok on the head"). The step also compares the head's baseline with the base's:
    a counted row may only go down (or move, with the same hit lines leaving another module), and a
    waived row that rises is a recorded waiver, annotated."""

    STEP = os.path.join(HERE, "..", "scripts", "ci", "crash-ratchet-against-base.sh")
    SOURCE = "Packages/macOS/CmuxNext/Sources/M/A.swift"

    def setUp(self):
        self.make_repo()

    def step(self, event, before=""):
        runner = os.path.join(self.tmp, f"runner-{event}")
        os.makedirs(runner, exist_ok=True)
        env = {**os.environ, "EVENT_NAME": event, "BEFORE": before, "RUNNER_TEMP": runner}
        out = subprocess.run(["bash", self.STEP], cwd=self.repo, env=env, capture_output=True, text=True)
        return out.returncode, out.stdout + out.stderr

    def green_base(self):
        self.write(self.SOURCE, SELECTOR.format(name="run"))
        return self.commit("baseline", update_baseline=True)

    def red_base(self):
        """A baseline commit with one ratchet-class hit, then a push that added a second one past
        the baseline (the red tip)."""
        self.green_base()
        self.write(self.SOURCE, SELECTOR.format(name="run") + SELECTOR.format(name="stop"))
        return self.commit("adds a hit past the baseline")

    def test_a_pull_request_merged_with_a_red_base_is_excused(self):
        self.red_base()
        # The checkout of a pull request is its merge commit; HEAD^1 is the base.
        self.write("notes.txt", "the pull request's change\n")
        self.commit("the pull request's merge")
        rc, out = self.step("pull_request")
        self.assertEqual(rc, 0, out)
        self.assertIn("::warning::the crash ratchet is already red on the base", out)

    def test_a_push_that_adds_a_hit_on_a_green_base_is_red(self):
        green = self.green_base()
        self.write("Packages/macOS/CmuxNext/Sources/M/B.swift", SELECTOR.format(name="stop"))
        self.commit("adds a hit")
        rc, out = self.step("push", green)
        self.assertEqual(rc, 1, out)
        self.assertIn("turns the crash ratchet red", out)

    def test_a_push_that_adds_a_hit_and_raises_the_baseline_is_red(self):
        green = self.green_base()
        self.write("Packages/macOS/CmuxNext/Sources/M/B.swift", SELECTOR.format(name="stop"))
        self.set_row("dynamic_dispatch", "M", 2)
        self.commit("adds a hit and raises the baseline")
        rc, out = self.step("push", green)
        self.assertEqual(rc, 1, out)
        self.assertIn("swift M: dynamic_dispatch base 1, head 2", out)
        self.assertIn("may only go down", out)

    def test_a_pull_request_that_raises_the_baseline_is_red(self):
        self.green_base()
        self.write("Packages/macOS/CmuxNext/Sources/M/B.swift", SELECTOR.format(name="stop"))
        self.set_row("dynamic_dispatch", "M", 2)
        self.commit("the pull request's merge")
        rc, out = self.step("pull_request")
        self.assertEqual(rc, 1, out)
        self.assertIn("may only go down", out)

    def test_a_recorded_waiver_is_green_and_annotated(self):
        green = self.green_base()
        self.write("Packages/macOS/CmuxNext/Sources/M/B.swift",
                   "let t = NSSelectorFromString(\"stop\") // crash-allow: reviewed\n")
        self.set_row("dynamic_dispatch", "M", 1, waived=True)
        self.commit("a reviewed waiver")
        rc, out = self.step("push", green)
        self.assertEqual(rc, 0, out)
        self.assertIn("::warning::", out)
        self.assertIn("swift M: dynamic_dispatch.waived base 0, head 1", out)

    def test_a_base_without_a_waived_section_records_it_for_the_first_time(self):
        # The base predates waived counting: its waivers are recorded once, as one note.
        self.write(self.SOURCE, SELECTOR.format(name="run") + "let t = NSSelectorFromString(\"stop\") // crash-allow: old\n")
        rc, out = self.run_ratchet("--update-baseline")
        self.assertEqual(rc, 0, out)
        data = self.baseline()
        del data["waived"]
        with open(self.baseline_path, "w") as f:
            json.dump(data, f)
        before = self.commit("a base from before waived counting")
        rc, out = self.run_ratchet("--record-waivers")
        self.assertEqual(rc, 0, out)
        self.commit("records the waived section")
        rc, out = self.step("push", before)
        self.assertEqual(rc, 0, out)
        self.assertIn("records it for the first time (1 rows, 1 waived hits)", out)
        self.assertNotIn("::warning::", out)

    def test_a_push_that_moves_a_hit_to_another_module_carries_its_row(self):
        green = self.green_base()
        self.move(self.SOURCE, "Packages/macOS/CmuxNext/Sources/N/A.swift")
        self.set_row("dynamic_dispatch", "M", 0)
        self.set_row("dynamic_dispatch", "N", 1)
        self.commit("moves the file to module N")
        rc, out = self.step("push", green)
        self.assertEqual(rc, 0, out)
        self.assertIn("moved", out)

    def test_a_move_that_keeps_the_old_row_is_red(self):
        # The move carries the row: the old module's row must go down by what moved out.
        green = self.green_base()
        self.move(self.SOURCE, "Packages/macOS/CmuxNext/Sources/N/A.swift")
        self.set_row("dynamic_dispatch", "N", 1)
        self.commit("moves the file and keeps M's row")
        rc, out = self.step("push", green)
        self.assertEqual(rc, 1, out)
        self.assertIn("swift M: dynamic_dispatch base 1, head 1 (0 after the move)", out)

    def test_a_move_does_not_carry_a_hit_the_base_was_already_red_on(self):
        self.green_base()
        self.write(self.SOURCE, SELECTOR.format(name="run") + SELECTOR.format(name="halt"))
        red = self.commit("adds a hit past the baseline")
        self.move(self.SOURCE, "Packages/macOS/CmuxNext/Sources/N/A.swift")
        self.set_row("dynamic_dispatch", "M", 0)
        self.set_row("dynamic_dispatch", "N", 2)
        self.commit("moves both hits and records both")
        rc, out = self.step("push", red)
        self.assertEqual(rc, 1, out)
        self.assertIn("swift N: dynamic_dispatch base 0, head 2 (1 after the move)", out)


if __name__ == "__main__":
    unittest.main()
