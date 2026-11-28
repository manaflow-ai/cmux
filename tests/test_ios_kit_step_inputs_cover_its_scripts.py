"""The ios-kit step routes on its `inputs`: a change to a script its run reaches must start it.

The step's run calls scripts/ci/ios_link_ffi.sh and scripts/ci/ios-sim-pool.sh, and those call more
(the pool phone runs scripts/ci/ios-sim-linux-test.sh at this commit). A script missing from the inputs
changes what the step does with no ios-kit run on the pull request, and the first red lands on an unrelated
iOS change. This walks the run's scripts/ references, then theirs, and checks each against inputs/ignore.
"""

import fnmatch
import re
import tomllib
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
# An invocation, not a mention: `bash X`, `python3 [-I] X`, `--script X` (what the pool phone runs).
REF = re.compile(r"(?:\bbash|\bpython3(?: -I)?|--script)\s+((?:cmux-next-ios/rust/)?scripts/[A-Za-z0-9_./-]+\.(?:sh|py))\b")


def step():
    with open(ROOT / "ci/steps.toml", "rb") as f:
        return tomllib.load(f)["step"]["ios-kit"]


def routes(path, inputs, ignore):
    """inputs match and the ignore list (last match wins, `!` re-includes) does not drop it."""
    if not any(fnmatch.fnmatchcase(path, p) for p in inputs):
        return False
    dropped = False
    for p in ignore:
        neg = p.startswith("!")
        if fnmatch.fnmatchcase(path, p[1:] if neg else p):
            dropped = not neg
    return not dropped


def reached(run):
    seen, todo = set(), REF.findall(run)
    while todo:
        p = todo.pop()
        if p in seen or not (ROOT / p).is_file():
            continue
        seen.add(p)
        todo += REF.findall((ROOT / p).read_text(errors="replace"))
    return seen


class IosKitInputsCoverScripts(unittest.TestCase):
    def test_every_reached_script_routes(self):
        s = step()
        found = reached(s["run"])
        self.assertIn("scripts/ci/ios-sim-linux-test.sh", found)
        missing = sorted(p for p in found if not routes(p, s["inputs"], s.get("ignore", [])))
        self.assertEqual(missing, [], "add these to [step.ios-kit] inputs in ci/steps.toml")


if __name__ == "__main__":
    unittest.main()
