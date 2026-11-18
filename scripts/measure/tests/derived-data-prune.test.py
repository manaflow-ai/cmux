#!/usr/bin/env python3
"""Per-commit DerivedData caches are capped per checkout (review of cmux#45193, P2).

app-at-commit.sh builds each --build-at commit into the checkout's .build/DerivedData/cmux-measure-at-<sha12>
(arm-derived-data.sh). A warm fleet checkout keeps its .build between steps, so without a cap it gains one full
DerivedData (several GB) per commit it ever built. The cap: when measure_app_at_commit returns (built or failed),
measure_prune_derived_data keeps the most recently used caches of that pattern (3 by default), never one a live run
has marked in use, removes the rest, and prints DERIVED-DATA-PRUNE kept=K removed=R freed_gb=X on stderr. It removes
only real directories named cmux-measure-at-<12 lowercase hex> directly under the checkout's .build/DerivedData.

Run: python3 -I scripts/measure/tests/derived-data-prune.test.py"""
import os, re, subprocess, tempfile, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
MEASURE = os.path.normpath(os.path.join(HERE, ".."))
APP_AT = os.path.join(MEASURE, "app-at-commit.sh")
HELPER = os.path.join(MEASURE, "arm-derived-data.sh")
OLD = 1_000_000_000  # an mtime older than any cache a run makes

FAKE_RELOAD = """#!/usr/bin/env bash
# Writes 64 KiB into the --derived-data folder (a build's output) and prints an app path.
dd=""
while [ $# -gt 0 ]; do [ "$1" = --derived-data ] && dd="$2"; shift; done
mkdir -p "$dd/Build" && head -c 65536 /dev/zero >"$dd/Build/blob"
mkdir -p "$dd/app.app"
echo "App path:"
echo "  $dd/app.app"
"""


def git(repo, *args):
    return subprocess.run(["git", "-C", repo, *args], check=True, capture_output=True, text=True).stdout.strip()


def at_caches(dd):
    return sorted(n for n in os.listdir(dd) if re.fullmatch(r"cmux-measure-at-[0-9a-f]{12}", n)
                  and os.path.isdir(os.path.join(dd, n)) and not os.path.islink(os.path.join(dd, n)))


class DerivedDataPrune(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = os.path.realpath(self.tmp.name)
        self.repo = os.path.join(self.root, "repo")
        os.makedirs(os.path.join(self.repo, "scripts"))
        git(self.repo, "init", "-q")
        git(self.repo, "config", "user.email", "test@example.com")
        git(self.repo, "config", "user.name", "test")
        self.dd = os.path.join(self.repo, ".build", "DerivedData")
        os.makedirs(self.dd)

    def tearDown(self):
        self.tmp.cleanup()

    def commit(self, i):
        path = os.path.join(self.repo, "scripts", "reload.sh")
        with open(path, "w") as f:
            f.write(FAKE_RELOAD + f"# commit {i}\n")
        os.chmod(path, 0o755)
        git(self.repo, "add", "scripts/reload.sh")
        git(self.repo, "commit", "-q", "-m", f"c{i}")
        return git(self.repo, "rev-parse", "HEAD")

    def decoys(self):
        """Things next to the caches (and one elsewhere) that a prune must never touch, all older than any cache."""
        outside = os.path.join(self.root, "outside")
        os.makedirs(outside)
        with open(os.path.join(outside, "keep"), "w") as f:
            f.write("x")
        made = []
        for name in ("cmux-measure", "cmux-measure-base", "cmux-measure-head", "cmux-measure-at",
                     "cmux-measure-at-0123456789abc", "cmux-measure-at-0123456789AB", "cmux-measure-at-01234567zzzz",
                     "other-at-0123456789ab"):
            os.makedirs(os.path.join(self.dd, name, "Build"))
            made.append(os.path.join(self.dd, name))
        with open(os.path.join(self.dd, "cmux-measure-at-aaaaaaaaaaaa"), "w") as f:
            f.write("a file, not a cache")
        made.append(os.path.join(self.dd, "cmux-measure-at-aaaaaaaaaaaa"))
        os.symlink(outside, os.path.join(self.dd, "cmux-measure-at-bbbbbbbbbbbb"))
        elsewhere = os.path.join(self.repo, ".build", "other", "cmux-measure-at-cccccccccccc")
        os.makedirs(elsewhere)
        made.append(elsewhere)
        for p in made:
            os.utime(p, (OLD, OLD))
        return made, outside

    def test_six_commits_leave_at_most_three_caches_and_the_current_one(self):
        made, outside = self.decoys()
        shas = [self.commit(i) for i in range(6)]
        git(self.repo, "checkout", "-q", "--detach", shas[-1])
        last = None
        for i, sha in enumerate(shas):
            tree = os.path.join(self.root, f"scratch-{i}")
            cmd = f'source "{APP_AT}" && measure_app_at_commit {sha} t{i} "{tree}"'
            last = subprocess.run(["bash", "-c", cmd], cwd=self.repo, capture_output=True, text=True)
            self.assertEqual(last.returncode, 0, last.stderr[-2000:])
            self.assertEqual(last.stdout.strip(), os.path.join(self.dd, f"cmux-measure-at-{sha[:12]}", "app.app"))
            self.assertIn(f"cmux-measure-at-{sha[:12]}", at_caches(self.dd), "the run's own cache is gone")
            self.assertLessEqual(len(at_caches(self.dd)), 3, f"after commit {i}: {at_caches(self.dd)}")
        self.assertEqual(at_caches(self.dd), sorted(f"cmux-measure-at-{s[:12]}" for s in shas[-3:]))
        lines = [l for l in last.stderr.splitlines() if l.startswith("DERIVED-DATA-PRUNE ")]
        self.assertEqual(len(lines), 1, last.stderr[-2000:])
        m = re.fullmatch(r"DERIVED-DATA-PRUNE kept=(\d+) removed=(\d+) freed_gb=(\d+\.\d\d)", lines[0])
        self.assertTrue(m, lines[0])
        self.assertEqual((m.group(1), m.group(2)), ("3", "1"))
        for p in made:
            self.assertTrue(os.path.lexists(p), f"removed {p}, which the scheme did not create")
        self.assertTrue(os.path.islink(os.path.join(self.dd, "cmux-measure-at-bbbbbbbbbbbb")))
        self.assertTrue(os.path.exists(os.path.join(outside, "keep")))

    def test_a_failed_build_still_prunes(self):
        shas = [self.commit(i) for i in range(5)]
        for i, sha in enumerate(shas[:-1]):
            os.makedirs(os.path.join(self.dd, f"cmux-measure-at-{sha[:12]}"))
            os.utime(os.path.join(self.dd, f"cmux-measure-at-{sha[:12]}"), (OLD + i, OLD + i))
        with open(os.path.join(self.repo, "scripts", "reload.sh"), "w") as f:
            f.write("#!/usr/bin/env bash\necho 'error: no build' >&2\nexit 65\n")
        git(self.repo, "commit", "-qam", "broken")
        sha = git(self.repo, "rev-parse", "HEAD")
        cmd = f'source "{APP_AT}" && measure_app_at_commit {sha} t "{self.root}/scratch"'
        res = subprocess.run(["bash", "-c", cmd], cwd=self.repo, capture_output=True, text=True)
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("DERIVED-DATA-PRUNE kept=3 removed=2 ", res.stderr)
        self.assertEqual(len(at_caches(self.dd)), 3)
        self.assertIn(f"cmux-measure-at-{sha[:12]}", at_caches(self.dd))

    def test_a_cache_a_live_run_marked_is_kept_past_the_cap(self):
        dead = subprocess.Popen(["true"])
        dead.wait()
        names = [f"cmux-measure-at-{i:012x}" for i in range(5)]
        for i, name in enumerate(names):
            os.makedirs(os.path.join(self.dd, name))
        open(os.path.join(self.dd, names[0], f".measure-in-use.{os.getpid()}"), "w").close()
        open(os.path.join(self.dd, names[1], f".measure-in-use.{dead.pid}"), "w").close()
        for i, name in enumerate(names):
            os.utime(os.path.join(self.dd, name), (OLD + i, OLD + i))
        res = subprocess.run(["bash", "-c", f'source "{HELPER}" && measure_prune_derived_data 2'],
                             cwd=self.repo, capture_output=True, text=True)
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertEqual(at_caches(self.dd), sorted([names[0], names[3], names[4]]))
        self.assertIn("DERIVED-DATA-PRUNE kept=3 removed=2 ", res.stderr)


if __name__ == "__main__":
    unittest.main()
