"""Base-red evidence pages GitHub lists without gh's broker-refused --paginate flag."""
import importlib.util
import os
import stat
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("main_fix_evidence", ROOT / "scripts/ci/main_fix_evidence.py")
evidence = importlib.util.module_from_spec(spec)
spec.loader.exec_module(evidence)

FAKE_GH = textwrap.dedent("""\
    #!/usr/bin/env python3
    import sys
    from urllib.parse import parse_qs, urlsplit
    args = sys.argv[1:]
    if "--paginate" in args:
        sys.stderr.write("the broker refuses --paginate\\n")
        sys.exit(1)
    if args[:2] == ["run", "view"]:
        sys.exit(0)  # gh 2.45 prints nothing for `run view --job --log` on today's log archives
    route = args[1]
    page = int(parse_qs(urlsplit(route).query).get("page", ["1"])[0])
    if route.endswith("/logs"):
        sys.stdout.write("2026-10-20T03:14:40.1Z ##[group]Run check\\n"
                         "2026-10-20T03:14:44.0Z ##[error]red check: Type scale\\n")
    elif "check-runs" in route and page == 1:
        sys.stdout.write('{"total_count":2,"check_runs":[{"id":1,"name":"lint","app":{"slug":"github-actions"}}]}\\n')
    elif "check-runs" in route and page == 2:
        sys.stdout.write('{"total_count":2,"check_runs":[{"id":2,"name":"swift test","app":{"slug":"github-actions"}}]}\\n')
    elif "check-runs" in route:
        sys.stdout.write('{"total_count":2,"check_runs":[]}\\n')
    elif "/files" in route:
        sys.stdout.write('[{"filename":"a.py","patch":"+x"}]\\n' if page == 1 else '[{"filename":"b.py","patch":"+y"}]\\n' if page == 2 else '[]\\n')
    else:
        sys.stdout.write('{"sha":"abc","parents":[]}\\n')
""")


class PaginateWithoutSlurp(unittest.TestCase):
    def setUp(self):
        self.bin = tempfile.TemporaryDirectory()
        gh = Path(self.bin.name) / "gh"
        gh.write_text(FAKE_GH)
        gh.chmod(gh.stat().st_mode | stat.S_IEXEC)
        self.path = os.environ["PATH"]
        os.environ["PATH"] = f"{self.bin.name}{os.pathsep}{self.path}"

    def tearDown(self):
        os.environ["PATH"] = self.path
        self.bin.cleanup()

    def test_object_pages_are_requested_until_empty(self):
        pages = evidence.GitHub().json("repos/o/r/commits/abc/check-runs?per_page=100", paginate=True)
        self.assertEqual([[c["name"] for c in p["check_runs"]] for p in pages], [["lint"], ["swift test"]])

    def test_latest_checks_reads_every_page(self):
        checks = evidence.latest_checks("o/r", "abc", evidence.GitHub())
        self.assertEqual(sorted(checks), ["lint", "swift test"])

    def test_array_pages_iterate_as_files(self):
        pages = evidence.GitHub().json("repos/o/r/pulls/1/files?per_page=100", paginate=True)
        self.assertEqual([f["filename"] for page in pages for f in page], ["a.py", "b.py"])

    def test_an_empty_run_view_log_falls_back_to_the_job_log_without_step_names(self):
        log = evidence.GitHub().log("o/r", {"id": 7, "run_id": 3, "name": "checks"})
        self.assertEqual(log.splitlines(), [
            "checks\tUNKNOWN STEP\t2026-10-20T03:14:40.1Z ##[group]Run check",
            "checks\tUNKNOWN STEP\t2026-10-20T03:14:44.0Z ##[error]red check: Type scale"])

    def test_an_unpaginated_read_is_one_document(self):
        self.assertEqual(evidence.GitHub().json("repos/o/r/commits/abc")["sha"], "abc")


if __name__ == "__main__":
    unittest.main()
