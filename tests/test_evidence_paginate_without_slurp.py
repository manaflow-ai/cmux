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
    import json, os, sys
    from urllib.parse import parse_qs, urlsplit
    args = sys.argv[1:]
    if "--paginate" in args:
        sys.stderr.write("the broker refuses --paginate\\n")
        sys.exit(1)
    if args[:2] == ["run", "view"]:
        sys.exit(0)  # gh 2.45 prints nothing for `run view --job --log` on today's log archives
    route = args[1]
    query = parse_qs(urlsplit(route).query)
    page, per_page = int(query.get("page", ["1"])[0]), int(query.get("per_page", ["30"])[0])
    with open(os.environ["FAKE_GH_CALLS"], "a") as calls:
        calls.write(route + "\\n")
    run = lambda i, name: {"id": i, "name": name, "app": {"slug": "github-actions"}}
    if route.endswith("/logs"):
        sys.stdout.write("2026-10-20T03:14:40.1Z ##[group]Run check\\n"
                         "2026-10-20T03:14:44.0Z ##[error]red check: Type scale\\n")
    elif "/repeating/" in route:
        # A double that ignores ?page= and always answers a full page.
        print(json.dumps({"check_runs": [run(i, f"c{i}") for i in range(per_page)]}))
    elif "check-runs" in route and page == 1:
        # A full first page: lint, then 99 others.
        print(json.dumps({"total_count": per_page + 1,
                          "check_runs": [run(1, "lint")] + [run(i, f"c{i}") for i in range(2, per_page + 1)]}))
    elif "check-runs" in route and page == 2:
        print(json.dumps({"total_count": per_page + 1, "check_runs": [run(per_page + 1, "swift test")]}))
    elif "check-runs" in route:
        print(json.dumps({"total_count": per_page + 1, "check_runs": []}))
    elif "/files" in route:
        print(json.dumps([{"filename": "a.py", "patch": "+x"}, {"filename": "b.py", "patch": "+y"}] if page == 1 else []))
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
        self.calls = Path(self.bin.name) / "calls"
        self.calls.touch()
        os.environ["FAKE_GH_CALLS"] = str(self.calls)

    def tearDown(self):
        os.environ["PATH"] = self.path
        os.environ.pop("FAKE_GH_CALLS", None)
        self.bin.cleanup()

    def pages_asked(self):
        return len(self.calls.read_text().splitlines())

    def test_object_pages_are_requested_until_a_short_page(self):
        pages = evidence.GitHub().json("repos/o/r/commits/abc/check-runs?per_page=100", paginate=True)
        self.assertEqual([len(p["check_runs"]) for p in pages], [100, 1])
        self.assertEqual(pages[0]["check_runs"][0]["name"], "lint")
        self.assertEqual(pages[1]["check_runs"][0]["name"], "swift test")
        # The short second page is the last: no third request for an empty one.
        self.assertEqual(self.pages_asked(), 2)

    def test_a_list_that_fits_one_page_is_one_request(self):
        pages = evidence.GitHub().json("repos/o/r/pulls/1/files?per_page=100", paginate=True)
        self.assertEqual(len(pages), 1)
        self.assertEqual(self.pages_asked(), 1)

    def test_a_reader_that_repeats_a_full_page_refuses_instead_of_paging_forever(self):
        # 2026-11-02: tests/test_gh_merge_green.py's recorded GitHub answers every ?page= with the same page,
        # and the walk that stopped only on an empty page hung the CI fast guards until their timeout.
        with self.assertRaises(evidence.Refused):
            evidence.GitHub().json("repos/o/r/repeating/check-runs", paginate=True)
        self.assertEqual(self.pages_asked(), evidence.MAX_PAGES)

    def test_latest_checks_reads_every_page(self):
        checks = evidence.latest_checks("o/r", "abc", evidence.GitHub())
        self.assertEqual(len(checks), 101)
        self.assertIn("lint", checks)
        self.assertIn("swift test", checks)  # on the second page

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
