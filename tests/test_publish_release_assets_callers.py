#!/usr/bin/env python3
"""Every workflow call of publish-release-assets.py passes at least one --immutable.

plan() in scripts/ci/publish-release-assets.py refuses a call with no immutable asset
("At least one immutable release asset is required"), so a call with only --alias and
--feed fails on every run. publish-nightly-next-github-names shipped that way (#25656):
the nightly-next release's rolling DMG name and feed copy stayed at an old build while
the R2 feed moved on. This reads each call from the workflow text, follows the bash
arrays it expands ("${args[@]}"), and requires an --immutable among them.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW_DIR = ROOT / ".github" / "workflows"
SCRIPT = "publish-release-assets.py"

# `publisher=.publish-tooling/scripts/ci/publish-release-assets.py`, then `python3 "$publisher"`.
SCRIPT_VARIABLE = re.compile(r"\b([A-Za-z_][A-Za-z0-9_]*)=\S*" + re.escape(SCRIPT))
ARRAY_EXPANSION = re.compile(r'"\$\{([A-Za-z_][A-Za-z0-9_]*)\[@\]\}"')


def calls(text: str) -> list[tuple[int, str, str]]:
    """(line number, the full command, the run block before it) for each call of the publisher."""
    lines = text.splitlines()
    found = []
    block_start = 0
    variables: set[str] = set()
    for index, line in enumerate(lines):
        stripped = line.strip()
        if re.match(r"^(-\s+)?run:", stripped):
            block_start = index
            variables = set()
        variables.update(SCRIPT_VARIABLE.findall(line))
        if not re.match(r"^python3?\s", stripped):
            continue
        target = stripped.split(None, 2)[1] if len(stripped.split()) > 1 else ""
        if SCRIPT not in target and target.strip('"${}') not in variables:
            continue
        command = [line]
        end = index
        while lines[end].rstrip().endswith("\\") and end + 1 < len(lines):
            end += 1
            command.append(lines[end])
        found.append((index + 1, "\n".join(command), "\n".join(lines[block_start:index])))
    return found


def passes_an_immutable(command: str, block: str) -> bool:
    if re.search(r"(^|\s)--immutable(\s|=)", command):
        return True
    for array in ARRAY_EXPANSION.findall(command):
        if re.search(r"\b" + re.escape(array) + r'\+?=\(\s*"?--immutable\b', block):
            return True
    return False


class PublishReleaseAssetsCallers(unittest.TestCase):
    def test_every_workflow_call_passes_an_immutable(self):
        seen = 0
        for workflow in sorted(WORKFLOW_DIR.glob("*.yml")):
            text = workflow.read_text(encoding="utf-8")
            for line, command, block in calls(text):
                seen += 1
                with self.subTest(workflow=workflow.name, line=line):
                    self.assertTrue(
                        passes_an_immutable(command, block),
                        f"{workflow.name}:{line} calls {SCRIPT} with no --immutable; "
                        "plan() refuses that on every run:\n" + command,
                    )
        # The publishers in nightly.yml, release.yml and auto-resume-nightly-notarization.yml.
        self.assertGreaterEqual(seen, 9, "the call finder stopped seeing the workflows' publishers")

    def test_names_job_passes_the_versioned_dmg(self):
        text = (WORKFLOW_DIR / "nightly.yml").read_text(encoding="utf-8")
        job = text[text.index("\n  publish-nightly-next-github-names:\n"):]
        step = job[job.index("- name: Publish the rolling DMG name and the feed copy"):]
        step = step[:step.index("\n      - name:")]
        self.assertIn('--immutable "nightly-out/${CHANNEL_DMG_PREFIX}-arm64-${NIGHTLY_BUILD}.dmg"', step)
        # The job reads that file from the same variant artifacts the upload job published.
        self.assertIn("- *download-nightly-variant-artif", job[:job.index(step)])

    def test_finder_refuses_the_alias_and_feed_only_call(self):
        text = """
        run: |
          feeds=()
          for feed in $NIGHTLY_FEEDS; do feeds+=(--feed "nightly-out/$feed"); done
          python3 "$PUBLISH_TOOLING/ci/publish-release-assets.py" \\
            --repo "$GITHUB_REPOSITORY" --tag "$CHANNEL_RELEASE_TAG" \\
            --alias "nightly-out/${CHANNEL_DMG_PREFIX}-arm64.dmg" --replace-feeds "${feeds[@]}"
        run: |
          deltas=()
          for delta in nightly-deltas/*.delta; do deltas+=(--immutable "$delta"); done
          publisher=.publish-tooling/scripts/ci/publish-release-assets.py
          python3 "$publisher" \\
            --repo "$GITHUB_REPOSITORY" --tag "$CHANNEL_RELEASE_TAG" \\
            "${deltas[@]}" --replace-feeds "${feeds[@]}"
        """
        found = calls(text)
        self.assertEqual(len(found), 2)
        self.assertFalse(passes_an_immutable(found[0][1], found[0][2]))
        self.assertTrue(passes_an_immutable(found[1][1], found[1][2]))


if __name__ == "__main__":
    unittest.main()
