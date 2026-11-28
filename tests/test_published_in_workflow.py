"""The published-in workflow picks the previous stable tag, not a hotfix tag."""
import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/published-in.yml"


def previous_stable_tag(directory: str, tag: str) -> str:
    # The predecessor command as the workflow runs it.
    match = re.search(r"previous=\"\$\(([^\n]*?) 2>/dev/null\)\"", WORKFLOW.read_text())
    if match is None:
        raise AssertionError("predecessor command not found in published-in.yml")
    command = match.group(1)
    command = command.replace('"$TAG^"', f"{tag}^").replace("$TAG^", f"{tag}^")
    return subprocess.run(["bash", "-c", command], cwd=directory, check=True, capture_output=True, text=True).stdout.strip()


class PublishedInWorkflowTests(unittest.TestCase):
    def previous_of_last(self, tags: list[str]) -> str:
        """The predecessor the workflow picks for the last of `tags`, tagged on consecutive commits."""
        with tempfile.TemporaryDirectory() as directory:
            env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}
            def run(*args: str) -> None:
                subprocess.run(["git", "-C", directory, *args], check=True, capture_output=True, text=True, env=env)

            run("init", "-q")
            for tag in tags:
                run("commit", "-q", "--allow-empty", "-m", tag)
                run("tag", tag)
            return previous_stable_tag(directory, tags[-1])

    def test_previous_tag_skips_non_stable_hotfix_tags(self):
        self.assertEqual(self.previous_of_last(["v0.65.2", "v0.65.2.1", "v0.65.3"]), "v0.65.2")

    def test_previous_tag_skips_prerelease_tags(self):
        # A prerelease such as v0.65.3-rc1 matches the three-part glob; the announcement range must still start at v0.65.2.
        self.assertEqual(self.previous_of_last(["v0.65.2", "v0.65.3-rc1", "v0.65.3rc2", "v0.65.3"]), "v0.65.2")


if __name__ == "__main__":
    unittest.main()
