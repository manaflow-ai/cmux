"""A measure script that fetches a commit by SHA must not need an `origin` remote.

A fleet step's source is a shallow tree with no `origin` (step-source-shallow-v1), so `git fetch origin SHA`
alone fails there with "'origin' does not appear to be a git repository" and the before arm never runs
(cmux#58752's bench died that way on an exclusive Mac after 4 h in the queue). Fetch the commit with
measure_fetch_commit (scripts/measure/fetch-commit.sh), or follow the origin fetch with one from the public
repository (https://github.com/manaflow-ai/cmux.git, $CMUX_MEASURE_FETCH_URL or a $fetch_url holding it) in
the same command. Branch fetches (a literal branch name, a refspec, a $base) are not commits and pass.
"""
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
# `fetch ... origin X` where X is a 40-hex literal or a quoted variable that is not a base branch.
COMMIT_FROM_ORIGIN = re.compile(
    r"\bfetch\b[^|;&]*?\sorigin\s+(?:[0-9a-f]{40}\b|\"\$\{?(?![A-Za-z_]*(?:base|BASE))[A-Za-z_0-9]+\}?\")"
)
FALLBACK = re.compile(r"github\.com/manaflow-ai/cmux|CMUX_MEASURE_FETCH_URL|\$\{?fetch_url\b")


def logical_lines(text):
    lines = text.split("\n")
    i = 0
    while i < len(lines):
        start, line = i, lines[i]
        while line.endswith("\\") and i + 1 < len(lines):
            i += 1
            line = line[:-1] + lines[i]
        yield start + 1, line
        i += 1


def offenders():
    bad = []
    for path in sorted((ROOT / "scripts/measure").rglob("*.sh")):
        if path.name == "fetch-commit.sh":
            continue
        for number, line in logical_lines(path.read_text()):
            if line.lstrip().startswith("#") or not COMMIT_FROM_ORIGIN.search(line):
                continue
            if not FALLBACK.search(line):
                bad.append(f"{path.relative_to(ROOT)}:{number}")
    return bad


class MeasureFetchCommitNoOrigin(unittest.TestCase):
    def test_commit_fetches_fall_back_to_the_public_repository(self):
        bad = offenders()
        self.assertEqual(bad, [], "fetch the commit with measure_fetch_commit (scripts/measure/fetch-commit.sh): " + ", ".join(bad))

    def test_detector_catches_a_bare_origin_fetch(self):
        self.assertTrue(COMMIT_FROM_ORIGIN.search('git fetch -q --depth=1 origin "$sha"'))
        self.assertTrue(COMMIT_FROM_ORIGIN.search("git fetch --no-tags --depth=1 origin " + "a" * 40))
        self.assertFalse(COMMIT_FROM_ORIGIN.search('git fetch -q origin "${base#origin/}"'))
        self.assertFalse(COMMIT_FROM_ORIGIN.search("git fetch -q origin feat-cmux-next main"))


if __name__ == "__main__":
    unittest.main()
