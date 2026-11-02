"""gh_pages.py reads a GitHub list one bounded page per `gh api` call, and nothing under scripts/
asks gh to paginate on its own: the gh quota wrapper refuses an unbounded paginating call, which
left the merge gate unable to read freezes (cmux#26647)."""
import importlib.util
import io
import json
import re
import subprocess
import sys
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("gh_pages", ROOT / "scripts/ci/gh_pages.py")
gh_pages = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gh_pages)

# Files that still pass the flag, each with the reason. The list only shrinks: an entry whose file
# no longer has the flag fails too, so it is removed when the file is converted.
ALLOWED = {
}


def flag_lines(text: str) -> list[int]:
    """Lines that pass the flag: not a comment, and not inside a `code span` (prose about it)."""
    hits = []
    for number, line in enumerate(text.splitlines(), 1):
        if line.lstrip().startswith(("#", "//")):
            continue
        if "--paginate" in re.sub(r"`[^`]*`", "", line):
            hits.append(number)
    return hits


def fake(total, wrapped=None):
    calls = []

    def fetch(url):
        calls.append(url)
        query = dict(part.split("=", 1) for part in url.split("?", 1)[1].split("&"))
        start = (int(query["page"]) - 1) * int(query["per_page"])
        page = [{"n": i} for i in range(start, min(total, start + int(query["per_page"])))]
        return {"total_count": total, wrapped: page} if wrapped else page
    return fetch, calls


class PageTests(unittest.TestCase):
    def test_pages_are_bounded_calls_and_a_short_page_ends_the_list(self):
        fetch, calls = fake(250)
        self.assertEqual(len(gh_pages.items(fetch, "repos/o/r/pulls/1/files?per_page=30")), 250)
        self.assertEqual(calls, [f"repos/o/r/pulls/1/files?per_page=100&page={n}" for n in (1, 2, 3)])

    def test_the_query_is_kept_and_its_own_page_size_replaced(self):
        fetch, calls = fake(0)
        gh_pages.items(fetch, "repos/o/r/actions/runs/1/jobs?filter=latest&per_page=100&page=4")
        self.assertEqual(calls, ["repos/o/r/actions/runs/1/jobs?filter=latest&per_page=100&page=1"])

    def test_a_wrapped_list_is_read_from_its_one_list_field(self):
        fetch, _ = fake(130, wrapped="check_runs")
        pages = gh_pages.pages(fetch, "repos/o/r/commits/x/check-runs")
        self.assertEqual([len(p["check_runs"]) for p in pages], [100, 30])
        self.assertEqual(len(gh_pages.items(fetch, "repos/o/r/commits/x/check-runs")), 130)

    def test_an_exact_multiple_reads_one_empty_page_more(self):
        fetch, calls = fake(200)
        self.assertEqual(len(gh_pages.items(fetch, "x")), 200)
        self.assertEqual(len(calls), 3)

    def test_a_list_past_the_cap_fails_closed(self):
        fetch, calls = fake(10**6)
        with self.assertRaisesRegex(gh_pages.PageCapError, "more than 30 pages"):
            gh_pages.items(fetch, "x")
        self.assertEqual(len(calls), gh_pages.MAX_PAGES)

    def test_an_unexpected_page_shape_raises(self):
        with self.assertRaises(TypeError):
            gh_pages.items(lambda url: {"a": [], "b": []}, "x")

    def test_the_command_line_exits_2_at_the_cap_and_prints_fields(self):
        original = gh_pages.gh_json
        self.addCleanup(setattr, gh_pages, "gh_json", original)
        gh_pages.gh_json, _ = fake(10**6)
        with redirect_stderr(io.StringIO()) as err:
            self.assertEqual(gh_pages.main(["x"]), 2)
        self.assertIn("cut short", err.getvalue())
        gh_pages.gh_json = lambda url: [{"filename": "a"}, {"filename": ""}, {"filename": "b"}]
        with redirect_stdout(io.StringIO()) as out:
            self.assertEqual(gh_pages.main(["x", "--field", "filename"]), 0)
        self.assertEqual(out.getvalue(), "a\nb\n")
        with redirect_stdout(io.StringIO()) as out:
            self.assertEqual(gh_pages.main(["x", "--slurp"]), 0)
        self.assertEqual(json.loads(out.getvalue()), [[{"filename": "a"}, {"filename": ""}, {"filename": "b"}]])


class NoPaginateFlagTests(unittest.TestCase):
    def test_nothing_under_scripts_passes_the_paginate_flag(self):
        listed = subprocess.run(["git", "ls-files", "scripts"], cwd=ROOT, check=True,
                                capture_output=True, text=True).stdout.splitlines()
        offenders = []
        for name in listed:
            path = ROOT / name
            if not path.is_file():
                continue
            try:
                text = path.read_text()
            except (UnicodeDecodeError, OSError):
                continue
            hits = flag_lines(text)
            if hits and name not in ALLOWED:
                offenders.append(f"{name}:{','.join(map(str, hits))}")
            if not hits and name in ALLOWED:
                offenders.append(f"{name} no longer passes the flag: remove it from ALLOWED")
        self.assertEqual(offenders, [], "gh api's paginate flag is one unbounded call the gh quota wrapper "
                                        "refuses; read pages with scripts/ci/gh_pages.py instead")

    def test_the_lint_sees_the_flag_and_ignores_prose(self):
        self.assertEqual(flag_lines('gh api --paginate "x"\n# gh api --paginate\nNot `gh api --paginate`.\n'
                                    'args = ["api", "--paginate"]\n'), [1, 4])


if __name__ == "__main__":
    unittest.main()
