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
    def test_previous_tag_skips_non_stable_hotfix_tags(self):
        with tempfile.TemporaryDirectory() as directory:
            env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}
            def run(*args: str) -> None:
                subprocess.run(["git", "-C", directory, *args], check=True, capture_output=True, text=True, env=env)

            run("init", "-q")
            for tag in ["v0.65.2", "v0.65.2.1", "v0.65.3"]:
                run("commit", "-q", "--allow-empty", "-m", tag)
                run("tag", tag)
            self.assertEqual(previous_stable_tag(directory, "v0.65.3"), "v0.65.2")


if __name__ == "__main__":
    unittest.main()
