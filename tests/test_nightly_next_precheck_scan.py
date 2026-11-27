#!/usr/bin/env python3
"""The nightly-next tick reads the precheck once and walks to the newest prechecked commit.

Tick 45821041380 (2026-11-26 12:38Z) ran request-nightly-next.sh on 15 feat-cmux-next commits
newest-first, 82-101 s each: every one searched for its cmux-tui tree (and an older one) before it
read the build fleet's Release compile verdict, and every one was refused "not prechecked yet". The
900 s walk budget ran out before an older, prechecked commit, and nothing was promoted.

scripts/ci/nightly_next_precheck_scan.py reads those verdicts for the whole walk first, and the
tick's walk passes over a commit its script would refuse on the precheck. These tests check the
scan against precheck()'s rules (a scratch repository and a local results service) and the tick's
step against a fake scan and a fake request script.
"""
from __future__ import annotations

import http.server
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
SCAN = ROOT / "scripts" / "ci" / "nightly_next_precheck_scan.py"
TICK = ROOT / ".github" / "workflows" / "nightly-next-tick.yml"
STEP = "Request nightly-next promotion on main"
REPO = "example/repo"

# The checkout's own helpers, as the scan finds them on feat-cmux-next: a path under app/ reaches
# the app, and every commit has one tree key.
FAKE_CLASSIFIER = '''
def build_inputs_changed(paths, root=None):
    hit = next((p for p in paths if p.startswith("app/")), None)
    return (hit is not None, f"{hit} reaches the app" if hit else "nothing reaches the app")
'''
FAKE_TREE_KEY = 'import sys\nprint("f" * 40)\n'
REQUEST_WITH_PRECHECK = "#!/usr/bin/env bash\nfleet_verdict() { :; }\n"


class Results(http.server.BaseHTTPRequestHandler):
    records: dict[str, tuple[int, dict | None]] = {}
    hits: list[str] = []

    def do_GET(self) -> None:  # noqa: N802
        sha = self.path.split("?")[0].rsplit("/", 1)[-1]
        Results.hits.append(sha)
        code, record = Results.records.get(sha, (404, None))
        body = json.dumps(record).encode() if record is not None else b"not found"
        self.send_response(code)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args) -> None:
        pass


def record(sha: str, state: str) -> tuple[int, dict]:
    return 200, {"sha": sha, "repo": REPO, "recipe_version": 2, "configuration": "release-onone", "state": state}


class ScanTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Results)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.url = f"http://127.0.0.1:{cls.server.server_address[1]}/compile-checks/v1"

    @classmethod
    def tearDownClass(cls) -> None:
        cls.server.shutdown()

    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="precheck-scan-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.repo = self.tmp / "repo"
        self.repo.mkdir()
        Results.records = {}
        Results.hits = []
        self.git("init", "-q", "-b", "main")
        (self.repo / "scripts/ci").mkdir(parents=True)
        (self.repo / "scripts/cmux-next").mkdir(parents=True)
        (self.repo / "scripts/ci/nightly_build_inputs.py").write_text(FAKE_CLASSIFIER)
        (self.repo / "scripts/ci/cmux_tui_tree_key.py").write_text(FAKE_TREE_KEY)
        (self.repo / "scripts/cmux-next/request-nightly-next.sh").write_text(REQUEST_WITH_PRECHECK)
        self.commits: list[str] = []  # oldest first

    def git(self, *args: str) -> str:
        return subprocess.run(
            ["git", "-C", str(self.repo), "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", *args],
            check=True, capture_output=True, text=True,
        ).stdout.strip()

    def commit(self, path: str) -> str:
        target = self.repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(f"{len(self.commits)}\n")
        self.git("add", "-A")
        self.git("commit", "-q", "-m", f"c{len(self.commits)}")
        sha = self.git("rev-parse", "HEAD")
        self.commits.append(sha)
        return sha

    def scan(self, *extra: str) -> dict[str, tuple[str, str]]:
        env = {k: v for k, v in os.environ.items() if not k.startswith(("GITHUB_", "CMUX_NIGHTLY_NEXT_"))}
        env["CMUX_NIGHTLY_NEXT_PRECHECK_RESULTS"] = self.url
        out = subprocess.run(
            [sys.executable, str(SCAN), "--repo", REPO, "--workspace", str(self.repo), *extra],
            env=env, capture_output=True, text=True, timeout=60,
        )
        self.assertEqual(out.returncode, 0, out.stderr)
        plan: dict[str, tuple[str, str]] = {}
        for line in out.stdout.splitlines():
            sha, verdict, reason = line.split(" ", 2)
            plan[sha] = (verdict, reason)
        return plan

    def test_tick_45821041380_walks_past_unchecked_commits_to_the_newest_green_one(self) -> None:
        green = self.commit("app/a.swift")
        Results.records[green] = record(green, "pass")
        unchecked = [self.commit("app/b.swift") for _ in range(5)]
        plan = self.scan()
        for sha in unchecked:
            self.assertEqual(plan[sha][0], "skip", plan[sha])
            self.assertIn("not prechecked yet", plan[sha][1])
            self.assertIn(green[:12], plan[sha][1])
        self.assertEqual(plan[green], ("ask", "the build fleet compiled it in Release"))

    def test_a_compile_break_is_passed_over_for_the_newest_green_commit(self) -> None:
        green = self.commit("app/a.swift")
        Results.records[green] = record(green, "pass")
        red = self.commit("app/b.swift")
        Results.records[red] = record(red, "fail")
        after_red = self.commit("docs/readme.md")  # no app change: the red verdict stands for it
        plan = self.scan()
        self.assertEqual(plan[red][0], "skip")
        self.assertIn("precheck red", plan[red][1])
        self.assertEqual(plan[after_red][0], "skip")
        self.assertIn(f"compile of {red[:12]} failed", plan[after_red][1])
        self.assertEqual(plan[green][0], "ask")

    def test_an_app_unchanged_descendant_of_a_green_commit_is_asked(self) -> None:
        green = self.commit("app/a.swift")
        Results.records[green] = record(green, "pass")
        docs = self.commit("docs/readme.md")
        plan = self.scan()
        self.assertEqual(plan[docs][0], "ask")
        self.assertIn(f"compiled {green[:12]} in Release", plan[docs][1])

    def test_a_superseded_commit_is_covered_by_the_next_checked_tip(self) -> None:
        base = self.commit("app/a.swift")
        superseded = self.commit("app/b.swift")
        covering = self.commit("app/c.swift")
        Results.records[superseded] = record(superseded, "superseded")
        Results.records[covering] = record(covering, "pass")
        plan = self.scan()
        self.assertEqual(plan[superseded][0], "ask")
        self.assertIn(covering[:12], plan[superseded][1])
        self.assertEqual(plan[base][0], "skip")

    def test_an_unreadable_service_asks_every_commit(self) -> None:
        sha = self.commit("app/a.swift")
        Results.records[sha] = (500, None)
        plan = self.scan()
        self.assertEqual(plan[sha][0], "ask")
        self.assertIn("did not answer", plan[sha][1])

    def test_a_busy_answer_is_read_again_before_a_commit_is_passed_over(self) -> None:
        sha = self.commit("app/a.swift")
        Results.records[sha] = (429, None)
        self.scan()
        self.assertEqual(Results.hits.count(sha), 2)

    def test_a_commit_whose_script_has_no_precheck_is_asked(self) -> None:
        (self.repo / "scripts/cmux-next/request-nightly-next.sh").write_text("#!/usr/bin/env bash\n")
        sha = self.commit("app/a.swift")
        plan = self.scan()
        self.assertEqual(plan[sha][0], "ask")

    def test_the_walk_stops_at_nightly_next(self) -> None:
        promoted = self.commit("app/a.swift")
        newer = self.commit("app/b.swift")
        plan = self.scan("--promoted", promoted)
        self.assertEqual(plan[newer][0], "skip")
        self.assertEqual(plan[promoted][0], "stop")
        self.assertEqual(len(plan), 2)

    def test_an_app_already_published_is_asked_so_its_script_ends_the_walk(self) -> None:
        published = self.commit("app/a.swift")
        docs = self.commit("docs/readme.md")
        plan = self.scan("--published", published)
        self.assertEqual(plan[docs][0], "ask")
        self.assertIn("published nightly-next", plan[docs][1])

    def test_verdicts_go_into_the_scripts_per_run_cache(self) -> None:
        green = self.commit("app/a.swift")
        Results.records[green] = record(green, "pass")
        env = {k: v for k, v in os.environ.items() if not k.startswith(("GITHUB_", "CMUX_NIGHTLY_NEXT_"))}
        env.update(CMUX_NIGHTLY_NEXT_PRECHECK_RESULTS=self.url, GITHUB_RUN_ID="7", GITHUB_RUN_ATTEMPT="1", RUNNER_TEMP=str(self.tmp))
        subprocess.run([sys.executable, str(SCAN), "--repo", REPO, "--workspace", str(self.repo)], env=env, check=True, capture_output=True)
        self.assertEqual((self.tmp / "nightly-next-precheck-7-1" / green).read_text().strip(), "pass")

    def test_the_whole_walk_reads_each_verdict_once(self) -> None:
        for i in range(40):
            self.commit(f"app/{i}.swift")
        started = time.monotonic()
        self.scan()
        self.assertLess(time.monotonic() - started, 30)
        self.assertEqual(len(Results.hits), len(set(Results.hits)))


# The tick's step with a fake scan (its plan from $PLAN) and a fake request script.
FAKE_SCAN = """import os, sys
sys.stdout.write(open(os.environ["PLAN"]).read())
sys.exit(int(os.environ.get("SCAN_RC", "0")))
"""
FAKE_REQUEST = """#!/usr/bin/env bash
sha="$2"
echo "$sha" >> "$ASKED"
case "$(cat "$BEHAVIOR/$sha" 2>/dev/null)" in
  request) echo "requested nightly-next promotion of ${sha:0:12}" ;;
  *) echo "not promoting ${sha:0:12}: the nightly cannot resolve a published cmux-tui tree for it yet" ;;
esac
"""


def request_step() -> dict:
    steps = yaml.safe_load(TICK.read_text(encoding="utf-8"))["jobs"]["request"]["steps"]
    return next(step for step in steps if step.get("name") == STEP)


@unittest.skipUnless(shutil.which("timeout") and shutil.which("git"), "needs coreutils timeout and git")
class TickWalkTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="tick-walk-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.repo = self.tmp / "repo"
        self.behavior = self.tmp / "behavior"
        self.bin = self.tmp / "bin"
        self.runner_temp = self.tmp / "runner"
        for d in (self.repo, self.behavior, self.bin, self.runner_temp):
            d.mkdir()
        gh = self.bin / "gh"
        gh.write_text("#!/usr/bin/env bash\nexit 0\n")
        gh.chmod(0o755)
        git = ["git", "-C", str(self.repo), "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"]
        subprocess.run([*git, "init", "-q", "-b", "main"], check=True)
        script = self.repo / "scripts/cmux-next/request-nightly-next.sh"
        script.parent.mkdir(parents=True)
        script.write_text(FAKE_REQUEST)
        script.chmod(0o755)
        self.shas: list[str] = []
        for i in range(5):
            (self.repo / "n.txt").write_text(str(i))
            subprocess.run([*git, "add", "-A"], check=True)
            subprocess.run([*git, "commit", "-q", "-m", f"c{i}"], check=True)
            self.shas.append(subprocess.run([*git, "rev-parse", "HEAD"], check=True, capture_output=True, text=True).stdout.strip())
        self.shas.reverse()  # newest first, as the walk goes
        # main's tooling, untracked beside the walked checkout as in the job.
        tooling = self.repo / ".tick-tooling/scripts/ci"
        tooling.mkdir(parents=True)
        (tooling / "nightly_next_precheck_scan.py").write_text(FAKE_SCAN)
        self.plan = self.tmp / "plan.txt"
        self.asked = self.tmp / "asked.txt"
        self.asked.write_text("")
        self.script = self.tmp / "step.sh"
        self.script.write_text(request_step()["run"])

    def run_step(self, plan: list[tuple[int, str]], behave: dict[int, str], **env: str) -> subprocess.CompletedProcess:
        self.plan.write_text("".join(f"{self.shas[i]} {verdict} because\n" for i, verdict in plan))
        for i, kind in behave.items():
            (self.behavior / self.shas[i]).write_text(kind)
        full = {k: str(v) for k, v in request_step().get("env", {}).items()}
        full.update(os.environ)
        full.update(
            PATH=f"{self.bin}{os.pathsep}{os.environ['PATH']}",
            RUNNER_TEMP=str(self.runner_temp),
            GITHUB_REPOSITORY=REPO,
            BEHAVIOR=str(self.behavior),
            PLAN=str(self.plan),
            ASKED=str(self.asked),
            GIT_TERMINAL_PROMPT="0",
        )
        full.update(env)
        return subprocess.run(["bash", str(self.script)], cwd=self.repo, env=full, capture_output=True, text=True, timeout=60)

    def asked_commits(self) -> list[str]:
        return self.asked.read_text().split()

    def test_unprechecked_commits_are_passed_over_without_their_request(self) -> None:
        result = self.run_step([(0, "skip"), (1, "skip"), (2, "skip"), (3, "ask"), (4, "ask")], {3: "request"})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.asked_commits(), [self.shas[3]])
        self.assertIn(f"requested nightly-next promotion of {self.shas[3][:12]}", result.stdout)
        self.assertIn(f"not promoting {self.shas[0][:12]}: because (read before the walk; its request was not run)", result.stdout)
        self.assertIn("precheck scan: 2 to ask, 3 passed over", result.stdout)

    def test_an_asked_commit_refused_on_its_tree_moves_the_walk_on(self) -> None:
        result = self.run_step([(0, "skip"), (1, "ask"), (2, "skip"), (3, "ask"), (4, "ask")], {3: "request"})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.asked_commits(), [self.shas[1], self.shas[3]])

    def test_the_walk_ends_at_nightly_next(self) -> None:
        result = self.run_step([(0, "skip"), (1, "stop")], {})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.asked_commits(), [])
        self.assertIn("::warning title=nightly-next tick::no newer feat-cmux-next commit is promotable (1 refused)", result.stdout)

    def test_a_failed_scan_asks_every_commit(self) -> None:
        result = self.run_step([(0, "skip"), (1, "skip")], {2: "request"}, SCAN_RC="1")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("the precheck scan failed; every commit is asked", result.stdout)
        self.assertEqual(self.asked_commits(), self.shas[:3])

    def test_a_commit_the_scan_did_not_name_is_asked(self) -> None:
        result = self.run_step([(0, "skip")], {1: "request"})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.asked_commits(), [self.shas[1]])


class TickStepBoundTests(unittest.TestCase):
    def test_the_scan_fits_the_step_with_the_walk(self) -> None:
        step = request_step()
        env = step["env"]
        total = int(env["TICK_SCAN_SECONDS"]) + int(env["TICK_WALK_BUDGET_SECONDS"]) + int(env["TICK_COMMIT_SECONDS"])
        self.assertLess(total, int(step["timeout-minutes"]) * 60)
        self.assertIn(".tick-tooling/scripts/ci/nightly_next_precheck_scan.py", step["run"])


if __name__ == "__main__":
    unittest.main()
