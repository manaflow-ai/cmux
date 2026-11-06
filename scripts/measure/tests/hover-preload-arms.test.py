#!/usr/bin/env python3
"""scripts/measure/hover-preload.sh: an OFF arm is hover preload OFF, also when OFF runs a base build.

Hover preload is the setting browser.wakeTabsOnHover (#37124). With --base-ref or --base-revert the OFF arm launches
the base build; it must launch it with the setting off (--wake-on-hover=0), or "base vs ON" compares ON with ON on a
base that has the setting. The script ran every arm with wake=1 and set 0 only when there was no base build.
No app, no build: the script runs in a temporary git repository with reload.sh and the bench replaced by stubs that
record their arguments, and `git submodule` stubbed out. Run: python3 -I scripts/measure/tests/hover-preload-arms.test.py"""
import json, os, shutil, stat, subprocess, sys, tempfile, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.normpath(os.path.join(HERE, "..", "hover-preload.sh"))

RELOAD = """#!/usr/bin/env bash
# reload.sh stub: makes an empty app for the tag and prints its path as the real one does.
set -eu
tag=""
while [[ $# -gt 0 ]]; do case "$1" in --tag) tag="$2"; shift 2 ;; *) shift ;; esac; done
app="$HOVER_TEST_APPS/cmux DEV $tag.app"
mkdir -p "$app"
printf 'App path:\\n  %s\\n' "$app"
"""

BENCH = """import json, os, sys
with open(os.environ["HOVER_TEST_LOG"], "a") as log:
    log.write(json.dumps(sys.argv[1:]) + "\\n")
"""

GIT = """#!/usr/bin/env bash
# The step's checkout has submodules; this repository has none.
[[ "${1:-}" == submodule ]] && exit 0
exec "$HOVER_TEST_REAL_GIT" "$@"
"""


def write(path, text, mode=0o644):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as handle:
        handle.write(text)
    os.chmod(path, mode)


class Arms(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="hover-arms-")
        self.repo = os.path.join(self.root, "repo")
        self.apps = os.path.join(self.root, "apps")
        self.log = os.path.join(self.root, "bench.log")
        bin_dir = os.path.join(self.root, "bin")
        write(os.path.join(bin_dir, "git"), GIT, 0o755)
        self.env = {**os.environ, "PATH": bin_dir + os.pathsep + os.environ["PATH"], "HOVER_TEST_APPS": self.apps,
                    "HOVER_TEST_LOG": self.log, "HOVER_TEST_REAL_GIT": shutil.which("git"),
                    "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com",
                    "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.com"}
        os.makedirs(self.repo)
        self.git("init", "-q")
        with open(SCRIPT) as handle:
            write(os.path.join(self.repo, "scripts/measure/hover-preload.sh"), handle.read(), 0o755)
        write(os.path.join(self.repo, "scripts/reload.sh"), RELOAD, 0o755)
        write(os.path.join(self.repo, "scripts/cmux-next/bench_hover_preload.py"), BENCH)
        self.commit("base")
        self.base = self.git("rev-parse", "HEAD")
        write(os.path.join(self.repo, "feature.txt"), "hover preload\n")
        self.commit("the change a --base-revert takes out")
        self.change = self.git("rev-parse", "HEAD")
        write(os.path.join(self.repo, "later.txt"), "later\n")
        self.commit("head")
        self.head = self.git("rev-parse", "HEAD")

    def tearDown(self):
        shutil.rmtree(self.root, ignore_errors=True)

    def git(self, *args):
        return subprocess.run(["git", *args], cwd=self.repo, env=self.env, check=True, capture_output=True,
                              text=True).stdout.strip()

    def commit(self, message):
        self.git("add", "-A")
        self.git("commit", "-q", "-m", message)

    def arms(self, *args):
        result = subprocess.run(["bash", "scripts/measure/hover-preload.sh", *args], cwd=self.repo, env=self.env,
                                capture_output=True, text=True, timeout=120)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.git("rev-parse", "HEAD"), self.head, "the script must put the checkout back at head")
        with open(self.log) as handle:
            runs = [json.loads(line) for line in handle]
        out = []
        for argv in runs:
            opts = dict(arg.split("=", 1) if "=" in arg else (arg, None) for arg in argv if arg.startswith("--"))
            label = argv[argv.index("--label") + 1]
            app = os.path.basename(argv[argv.index("--app") + 1])
            out.append((label, app, opts.get("--wake-on-hover")))
        return out

    def test_base_ref_off_arm_runs_the_base_build_with_preload_off(self):
        runs = self.arms(f"--base-ref={self.base}", "--arms=OFF,ON")
        self.assertEqual(runs, [("off", "cmux DEV hoverbase.app", "0"), ("on", "cmux DEV hoverpre.app", "1")])

    def test_base_revert_off_arm_runs_the_reverted_build_with_preload_off(self):
        runs = self.arms(f"--base-revert={self.change}", "--arms=OFF,ON,OFF")
        self.assertEqual(runs, [("off", "cmux DEV hoverbase.app", "0"), ("on", "cmux DEV hoverpre.app", "1"),
                                ("off", "cmux DEV hoverbase.app", "0")])

    def test_no_base_off_arm_is_this_build_with_preload_off(self):
        runs = self.arms("--arms=OFF,ON")
        self.assertEqual(runs, [("off", "cmux DEV hoverpre.app", "0"), ("on", "cmux DEV hoverpre.app", "1")])


if __name__ == "__main__":
    if not shutil.which("git") or not shutil.which("bash"):
        sys.exit("needs git and bash")
    unittest.main()
