#!/usr/bin/env python3
"""scripts/ci/kit_sim_fleet.sh, run as a workflow step runs it (bash -e) against a fake gh and a fake fleet client:
the kit job takes the build fleet's simulator test build only when its artifact is there, and falls back to the Mac
on a missing artifact, a failed job, a repeated API failure and the time bound; the pool run reads a failed exit
and a failed test as a verdict instead of ending the step (review of cmux#59111)."""
from __future__ import annotations

import http.server
import io
import os
import socket
import threading
import subprocess
import tarfile
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/kit_sim_fleet.sh"

FAKE_GH = textwrap.dedent("""\
    #!/usr/bin/env python3
    # Fake `gh api URL --jq E`: answers from $FAKE/<kind> lines, one per call (the last repeats); FAIL fails the call.
    import os, sys
    from pathlib import Path
    url = sys.argv[2]
    kind = "artifacts" if "/artifacts?" in url else "jobs"
    root = Path(os.environ["FAKE"])
    count = root / f"{kind}.n"
    n = int(count.read_text()) if count.exists() else 0
    count.write_text(str(n + 1))
    lines = (root / kind).read_text().splitlines()
    answer = lines[min(n, len(lines) - 1)]
    if answer == "FAIL":
        sys.exit(1)
    print(answer)
""")

FAKE_CLIENT = textwrap.dedent("""\
    # Fake ci-client.py: `run` prints its step and exits $FAKE_RC; `artifact STEP OUT` writes $FAKE_RESULT to OUT.
    import os, shutil, sys
    if sys.argv[1] == "run":
        print("submitted step 0123456789abcdef01234567")
        sys.exit(int(os.environ["FAKE_RC"]))
    if sys.argv[1] == "artifact":
        result = os.environ.get("FAKE_RESULT", "")
        if not result:
            sys.exit(1)
        shutil.copy(result, sys.argv[-1])
""")


class Fake:
    def __init__(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        (self.dir / "bin").mkdir()
        gh = self.dir / "bin/gh"
        gh.write_text(FAKE_GH)
        gh.chmod(0o755)
        (self.dir / "ci-client.py").write_text(FAKE_CLIENT)
        self.output = self.dir / "output"
        self.output.write_text("")

    def run(self, command, **env):
        full = {**os.environ, "PATH": f"{self.dir / 'bin'}:{os.environ['PATH']}", "FAKE": str(self.dir),
                "GITHUB_OUTPUT": str(self.output), "GITHUB_STEP_SUMMARY": str(self.dir / "summary"),
                "RUNNER_TEMP": str(self.dir / "temp"), "RETRY_SLEEP": "0", "POLL": "0",
                "RUN": "repos/o/r/actions/runs/1", "ATTEMPT": "1", "JOB": "kit fleet build",
                "ARTIFACT": "kit-sim-fleet-products-1-1", **env}
        done = subprocess.run(["bash", "-e", str(SCRIPT), command], env=full, capture_output=True, text=True,
                              timeout=60)
        outputs = dict(line.split("=", 1) for line in self.output.read_text().splitlines() if "=" in line)
        return done, outputs

    def answers(self, kind, *lines):
        (self.dir / kind).write_text("\n".join(lines) + "\n")

    def result(self, cases):
        buf = io.BytesIO()
        with tarfile.open(fileobj=buf, mode="w:gz") as tar:
            for name, body in (("summary.txt", "summary\n"),
                               ("junit.xml", "".join(f'<testcase name="t{i}"/>\n' for i in range(cases)))):
                data = body.encode()
                info = tarfile.TarInfo(name)
                info.size = len(data)
                tar.addfile(info, io.BytesIO(data))
        path = self.dir / "result.tgz"
        path.write_bytes(buf.getvalue())
        return str(path)


class Wait(unittest.TestCase):
    def setUp(self):
        self.fake = Fake()
        self.addCleanup(self.fake.tmp.cleanup)

    def test_the_artifact_is_a_hit_by_its_own_name(self):
        self.fake.answers("artifacts", "", "", "42")
        self.fake.answers("jobs", "queued", "in_progress")
        done, out = self.fake.run("wait")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(out, {"hit": "true", "products": "kit-sim-fleet-products-1-1"})

    def test_a_job_that_ended_without_the_artifact_falls_back(self):
        self.fake.answers("artifacts", "")
        self.fake.answers("jobs", "failure")
        done, out = self.fake.run("wait")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(out, {"hit": "false"})
        self.assertIn("Mac fallback", done.stdout)
        # It looked once more after the job ended, for an upload listed in between.
        self.assertEqual((self.fake.dir / "artifacts.n").read_text(), "2")

    def test_an_artifact_listed_as_the_job_ended_is_still_a_hit(self):
        self.fake.answers("artifacts", "", "7")
        self.fake.answers("jobs", "success")
        done, out = self.fake.run("wait")
        self.assertEqual(out.get("hit"), "true", done.stdout)

    def test_a_queued_job_is_waited_on_until_the_bound(self):
        self.fake.answers("artifacts", "")
        self.fake.answers("jobs", "queued")
        done, out = self.fake.run("wait", BOUND="1", POLL="1")
        self.assertEqual(out, {"hit": "false"})
        self.assertIn("none within 1 s", done.stdout)
        self.assertGreaterEqual(int((self.fake.dir / "jobs.n").read_text()), 2)

    def test_one_failed_read_is_retried(self):
        self.fake.answers("artifacts", "FAIL", "9")
        self.fake.answers("jobs", "in_progress")
        done, out = self.fake.run("wait")
        self.assertEqual(out.get("hit"), "true", done.stdout)

    def test_two_failed_reads_fall_back(self):
        self.fake.answers("artifacts", "FAIL")
        self.fake.answers("jobs", "in_progress")
        done, out = self.fake.run("wait")
        self.assertEqual(done.returncode, 0)
        self.assertEqual(out, {"hit": "false"})
        self.assertIn("failed twice", done.stdout)


class Pool(unittest.TestCase):
    def setUp(self):
        self.fake = Fake()
        self.addCleanup(self.fake.tmp.cleanup)

    def pool(self, rc, result):
        return self.fake.run("pool", CI_CLIENT=str(self.fake.dir / "ci-client.py"), FAKE_RC=str(rc),
                             FAKE_RESULT=result, HEAD_SHA="a" * 40, PRODUCTS="1/kit-sim-fleet-products-1-1")

    def test_passed(self):
        done, out = self.pool(0, self.fake.result(3))
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual((out["verdict"], out["cases"]), ("pass", "3"))

    def test_failed_tests_are_a_verdict_not_an_ended_step(self):
        done, out = self.pool(1, self.fake.result(5))
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual((out["verdict"], out["cases"]), ("fail", "5"))
        self.assertIn("seconds", out)

    def test_no_result_is_no_verdict_with_zero_cases(self):
        done, out = self.pool(2, "")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual((out["verdict"], out["cases"]), ("none", "0"))
        self.assertIn("exit 2, 0 test cases", (self.fake.dir / "summary").read_text())


class Reach(unittest.TestCase):
    """`cmux-linux` is also served by GCP pool runners off the tailnet (run 45912028627 timed out there): the job
    asks first and hands the submit to an owned Mac on a no, instead of reading the timeout as a verdict."""

    def setUp(self):
        self.fake = Fake()
        self.addCleanup(self.fake.tmp.cleanup)

    def test_a_controller_that_answers_is_reached(self):
        class Manifest(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                code = 200 if self.path == "/v1/client/manifest" else 404
                self.send_response(code)
                self.end_headers()
                self.wfile.write(b'{"files": {}}')

            def log_message(self, *args):
                pass

        server = http.server.HTTPServer(("127.0.0.1", 0), Manifest)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.shutdown)
        done, out = self.fake.run("reach", CONTROLLER=f"http://127.0.0.1:{server.server_port}")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(out, {"reach": "yes"})

    def test_no_route_is_a_no_and_never_ends_the_step(self):
        with socket.socket() as sock:  # a port nothing listens on: refused, as an off-tailnet route times out
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        done, out = self.fake.run("reach", CONTROLLER=f"http://127.0.0.1:{port}", REACH_TIMEOUT="1",
                                  RUNNER_NAME="cmux-runner-pool-s1a-0001-1")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(out, {"reach": "no"})
        self.assertIn("no route to the controller from cmux-runner-pool-s1a-0001-1", done.stdout)
        self.assertIn("owned Mac", done.stdout)

    def test_no_controller_variable_is_a_no(self):
        done, out = self.fake.run("reach", CONTROLLER="")
        self.assertEqual((done.returncode, out), (0, {"reach": "no"}))


if __name__ == "__main__":
    unittest.main()
