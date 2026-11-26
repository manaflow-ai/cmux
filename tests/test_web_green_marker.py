"""web_subareas.green_key: the reuse key of a pull request's React inputs (ci500k)."""

import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("web_subareas", ROOT / "scripts/ci/web_subareas.py")
web_subareas = importlib.util.module_from_spec(spec)
sys.modules["web_subareas"] = web_subareas
spec.loader.exec_module(web_subareas)


def git(cwd, *args):
    subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@t", *args], cwd=cwd, check=True, capture_output=True)


def commit(cwd, files, message):
    for name, text in files.items():
        path = Path(cwd, name)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
    git(cwd, "add", "-A")
    git(cwd, "commit", "-m", message)


class GreenKeyTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.repo = Path(self.tmp.name)
        git(self.repo, "init", "-q")
        # an empty scripts/cmux-next/web-bundle-key.py is absent here: the matcher is None, the declared prefixes decide
        commit(self.repo, {"webviews/a.ts": "1", "Sources/a.swift": "1", "cmux-tui/x.rs": "1"}, "base")

    def key(self, kind):
        old = os.getcwd()
        os.chdir(self.repo)
        try:
            web_subareas.web_bundle_input_matcher.cache_clear()
            return web_subareas.green_key(kind, self.repo)
        finally:
            os.chdir(old)

    def merge_with(self, files):
        """Move to a child commit, the way a PR's merge commit is a child of its base."""
        commit(self.repo, files, "merge")

    def test_non_react_change_keeps_key(self):
        self.merge_with({"Sources/a.swift": "2"})
        before = self.key("react")
        self.merge_with({"Sources/a.swift": "3"})
        self.assertEqual(before, self.key("react"))
        self.assertNotEqual(before, "")

    def test_react_change_moves_key(self):
        self.merge_with({"Sources/a.swift": "2"})
        before = self.key("react")
        self.merge_with({"webviews/a.ts": "2"})
        self.assertNotEqual(before, self.key("react"))

    def test_parent_react_change_moves_key(self):
        self.merge_with({"Sources/a.swift": "2"})
        before = self.key("react")
        # same head inputs, different merge parent inputs
        git(self.repo, "reset", "-q", "--hard", "HEAD~1")
        commit(self.repo, {"webviews/b.ts": "1"}, "parent")
        commit(self.repo, {"Sources/a.swift": "2"}, "merge")
        self.assertNotEqual(before, self.key("react"))

    def test_cmux_tui_moves_agent_key_only(self):
        self.merge_with({"Sources/a.swift": "2"})
        react, agent = self.key("react"), self.key("agent")
        self.merge_with({"cmux-tui/x.rs": "2"})
        self.assertEqual(react, self.key("react"))
        self.assertNotEqual(agent, self.key("agent"))

    def test_workflow_wires_markers(self):
        text = (ROOT / ".github/workflows/ci-web.yml").read_text()
        for needle in (
            "webviews-react-green-${{ steps.scope.outputs.react_key }}",
            "webviews-react-green-${{ needs.web-subarea-scope.outputs.react_key }}",
            "webviews-agent-green-${{ steps.scope.outputs.agent_key }}",
            "webviews-agent-green-${{ needs.web-subarea-scope.outputs.agent_key }}",
            "react_apps: ${{ steps.reuse.outputs.react_apps }}",
        ):
            self.assertIn(needle, text)
        # a full-ci pull request never reuses a marker
        self.assertEqual(text.count("!contains(github.event.pull_request.labels.*.name, 'full-ci') }}\n        continue-on-error: true\n        uses: actions/cache/restore"), 2)


if __name__ == "__main__":
    unittest.main()
