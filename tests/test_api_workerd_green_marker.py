"""api_workerd_key.key and backend.yml's green marker for the api-workerd shards (ci500k)."""

import importlib.util
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("api_workerd_key", ROOT / "scripts/ci/api_workerd_key.py")
mod = importlib.util.module_from_spec(spec)
sys.modules["api_workerd_key"] = mod
spec.loader.exec_module(mod)


def git(cwd, *args):
    subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@t", *args], cwd=cwd, check=True, capture_output=True)


def commit(cwd, files, message="c"):
    for name, text in files.items():
        path = Path(cwd, name)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
    git(cwd, "add", "-A")
    git(cwd, "commit", "-m", message)


class KeyTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.repo = tmp.name
        git(self.repo, "init", "-q")
        commit(self.repo, {"backend/apps/api/a.ts": "1", "libs/svix-webhook/src/s.ts": "1", "web/page.tsx": "1"})

    def key(self):
        return mod.key("HEAD", self.repo)

    def test_unrelated_change_keeps_key(self):
        before = self.key()
        commit(self.repo, {"web/page.tsx": "2", "webviews/x.ts": "1"})
        self.assertEqual(before, self.key())
        self.assertRegex(before, r"^[0-9a-f]{40}$")

    def test_backend_change_moves_key(self):
        before = self.key()
        commit(self.repo, {"backend/apps/api/a.ts": "2"})
        self.assertNotEqual(before, self.key())

    def test_outside_input_moves_key(self):
        before = self.key()
        commit(self.repo, {"libs/svix-webhook/src/s.ts": "2"})
        self.assertNotEqual(before, self.key())

    def test_no_inputs_means_no_reuse(self):
        git(self.repo, "rm", "-rq", "backend", "libs")
        git(self.repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "rm")
        self.assertEqual(self.key(), "")


class WorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text = (ROOT / ".github/workflows/backend.yml").read_text()

    def job(self, name):
        start = self.text.index(f"\n  {name}:\n")
        nxt = self.text.find("\n  # ", start + 1)
        rest = self.text[start + 1 :]
        m = re.search(r"\n  [a-z0-9-]+:\n", rest[1:])
        return rest[: m.start() + 1] if m else rest

    def test_inputs_cover_the_workflow_and_backend(self):
        self.assertIn("backend", mod.INPUTS)
        self.assertIn(".github/workflows/backend.yml", mod.INPUTS)
        self.assertIn(f'bun-version: "{mod.BUN_VERSION}"', self.job("api-workerd"))
        self.assertIn(f'node-version: "{mod.NODE_VERSION}"', self.job("api-workerd"))
        self.assertIn(f'api-workerd-shard.sh" ${{{{ matrix.shard }}}} {mod.SHARDS}', self.job("api-workerd"))
        self.assertIn("scripts/ci/api-workerd-shard.sh", mod.INPUTS)

    def test_scope_only_on_pull_request_without_full_ci(self):
        scope = self.job("api-workerd-scope")
        self.assertIn("github.event_name == 'pull_request' && !(contains(github.event.pull_request.labels.*.name, 'full-ci') && (github.event.pull_request.base.ref != 'feat-cmux-next' || (github.event.action == 'labeled' && github.event.label.name == 'full-ci') || (vars.CI_FULL_CI_ONE_SHOT || '1') == '0'))", scope)
        self.assertIn("lookup-only: true", scope)
        self.assertIn("key: api-workerd-green-${{ steps.key.outputs.key }}", scope)

    def test_shards_skip_only_on_a_hit(self):
        shards = self.job("api-workerd")
        self.assertIn("needs.api-workerd-scope.outputs.hit != 'true'", shards)

    def test_test_job_accepts_skip_only_on_a_hit(self):
        test = self.job("test")
        self.assertIn("needs: [api-workerd, workerd-changes, api-workerd-scope]", test)
        # A skip passes on the path gate's miss or on a green-marker hit, nothing else.
        self.assertIn(
            "!(needs.api-workerd.result == 'skipped' && (needs.workerd-changes.outputs.run == 'false' || (needs.api-workerd-scope.result == 'success' && needs.api-workerd-scope.outputs.hit == 'true')))",
            test,
        )

    def test_shards_keep_the_path_gate(self):
        shards = self.job("api-workerd")
        self.assertIn("needs: [workerd-changes, api-workerd-scope]", shards)
        self.assertIn("needs.workerd-changes.outputs.run != 'false'", shards)

    def test_marker_saved_only_by_our_own_pull_request_after_all_shards_pass(self):
        test = self.job("test")
        self.assertIn("key: api-workerd-green-${{ needs.api-workerd-scope.outputs.key }}", test)
        save = test[test.index("Save the API Worker green marker") :]
        cond = save[: save.index("continue-on-error")]
        for needle in (
            "success()",
            "github.event_name == 'pull_request'",
            "github.event.pull_request.head.repo.full_name == github.repository",
            "needs.api-workerd.result == 'success'",
            "needs.api-workerd-scope.outputs.hit != 'true'",
        ):
            self.assertIn(needle, cond)


if __name__ == "__main__":
    unittest.main()
