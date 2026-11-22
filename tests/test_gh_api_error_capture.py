#!/usr/bin/env python3
"""A failed `gh api` read must never become a value in a workflow step.

On an HTTP error (a rate limit, an outage) `gh api` prints the JSON error body
on stdout and skips `--jq`. `VAR="$(gh api ... || true)"` then holds that body.
Run 42798372848 (iOS TestFlight cmux.app, 2026-11-10) wrote it to
GITHUB_OUTPUT as last_upload_sha and failed with "Unable to process file
command 'output'" instead of building.

- The decide step of ios-appstore-upload.yml, run against a rate-limited `gh`,
  must build (upload=true) and write only well-formed outputs.
- Every workflow capture of `gh api` stdout that swallows the exit status must
  check the value's shape on one of the next lines.
"""

import os
import re
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github/workflows"
OFFICIAL = ROOT / ".github/workflows/ios-appstore-upload.yml"

RATE_LIMIT_BODY = (
    '{\n\t"message": "API rate limit exceeded for installation.",\n'
    '\t"documentation_url": "https://docs.github.com/rest/overview/rate-limits-for-the-rest-api",\n'
    '\t"status": "403"\n}\n'
)

# VAR="$(gh api ... || true)" (or `|| :`), on one line.
SWALLOWED = re.compile(r'\b([A-Za-z_][A-Za-z0-9_]*)="\$\(gh api .*\|\| (?:true|:)\)"')
LOOKAHEAD = 4


def _decide_script():
    workflow = yaml.safe_load(OFFICIAL.read_text())
    for step in workflow["jobs"]["decide"]["steps"]:
        if step.get("id") == "decide":
            return step["run"]
    raise AssertionError("ios-appstore-upload.yml has no decide step")


class DecideStepUnderRateLimit(unittest.TestCase):
    def test_rate_limited_reads_build_with_clean_outputs(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            fake_gh = tmp / "bin/gh"
            fake_gh.parent.mkdir()
            body = tmp / "body.json"
            body.write_text(RATE_LIMIT_BODY)
            fake_gh.write_text(
                "#!/bin/sh\n"
                f"cat '{body}'\n"
                "echo 'gh: API rate limit exceeded for installation. (HTTP 403)' >&2\n"
                "exit 1\n"
            )
            fake_gh.chmod(fake_gh.stat().st_mode | stat.S_IEXEC)
            output = tmp / "output"
            summary = tmp / "summary"
            env = {
                **os.environ,
                "PATH": f"{fake_gh.parent}:{os.environ['PATH']}",
                "GH_TOKEN": "unused",
                "REPOSITORY": "manaflow-ai/cmux",
                "EVENT_NAME": "schedule",
                "HEAD_SHA": "a" * 40,
                "GITHUB_OUTPUT": str(output),
                "GITHUB_STEP_SUMMARY": str(summary),
            }
            result = subprocess.run(
                ["bash", "-e", "-c", _decide_script()],
                env=env, capture_output=True, text=True, cwd=tmp,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            lines = output.read_text().splitlines()
            for line in lines:
                self.assertRegex(line, r"^[a-z_]+=[^\"{}]*$", f"malformed output line {line!r}")
            outputs = dict(line.split("=", 1) for line in lines)
            self.assertEqual(outputs.get("last_upload_sha"), "")
            self.assertEqual(outputs.get("upload"), "true")


class SwallowedGhApiCapturesAreChecked(unittest.TestCase):
    def test_every_swallowed_capture_checks_its_shape(self):
        unchecked = []
        for path in sorted(WORKFLOWS.glob("*.y*ml")):
            lines = path.read_text().splitlines()
            for index, line in enumerate(lines):
                match = SWALLOWED.search(line)
                if not match:
                    continue
                name = match.group(1)
                follow = "\n".join(lines[index + 1:index + 1 + LOOKAHEAD])
                if not re.search(r'\[\[ "\$\{?%s\}?" =~ ' % re.escape(name), follow):
                    unchecked.append(f"{path.relative_to(ROOT)}:{index + 1}: {name}")
        self.assertEqual(
            unchecked, [],
            "gh api prints an error body on stdout; check the captured value's shape "
            '(e.g. [[ "$VAR" =~ ^[0-9a-f]{40}$ ]] || VAR="") on the next lines',
        )


if __name__ == "__main__":
    sys.exit(unittest.main())
