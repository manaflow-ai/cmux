"""scripts/ci/naming_autofix.py: the dotted experiment id of #48230 (`agent-pane.high-contrast-look`, which
validateExperiments refused until #49118) is renamed with its references, and valid ids are never touched."""
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "ci" / "naming_autofix.py"
EXPERIMENT_TS = "webviews/src/experiments/experiment.ts"
FORMAT_TS = "webviews/src/gallery/format.ts"

EXPERIMENT = '''import { defineExperiment } from "../../experiments/experiment";

export const highContrastLook = defineExperiment({
  id: "{id}",
  title: "High contrast chat",
  arms: { off: { label: "Off", description: "a" }, high: { label: "On", description: "b" } },
  defaultArm: "off",
});
'''
VALID_EXPERIMENT = '''export const steer = defineExperiment({
  id: "steer-queue",
  arms: {},
  defaultArm: "off",
});
'''
TEST_REF = '''test("arm", () => {
  localStorage.setItem("cmux.experiments", JSON.stringify({ "agent-pane.high-contrast-look": "high" }));
  expect(experimentById('agent-pane.high-contrast-look')).toBeDefined();
  const partial = "agent-pane.high-contrast-look-extra";
});
'''
GALLERY = '''export default agentPaneEntry({
  id: "{gallery}",
  title: "High contrast chat",
});
'''


def git(repo, *args):
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env.update(GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t", GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@t",
               GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
    return subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, text=True, env=env).stdout


class Fixture:
    def __init__(self, experiment_id, gallery_id="agent-pane.high-contrast", with_test_ref=True):
        self.temporary = tempfile.TemporaryDirectory()
        self.path = Path(self.temporary.name)
        for rel in (EXPERIMENT_TS, FORMAT_TS):  # the real rules: the regexes come from them
            (self.path / rel).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / rel, self.path / rel)
        git(self.path, "init", "-q", "-b", "main")
        self.write("webviews/src/acpmux/steer.experiment.ts", VALID_EXPERIMENT)
        git(self.path, "add", "-A")
        git(self.path, "commit", "-q", "-m", "base")
        git(self.path, "checkout", "-q", "-b", "pr")
        self.write("webviews/src/acpmux/highContrastLook.experiment.ts", EXPERIMENT.replace("{id}", experiment_id))
        self.write("webviews/src/acpmux/highContrastLook.gallery.ts", GALLERY.replace("{gallery}", gallery_id))
        if with_test_ref:
            self.write("webviews/test/high-contrast.test.ts", TEST_REF)
        git(self.path, "add", "-A")
        git(self.path, "commit", "-q", "-m", "pr")

    def write(self, rel, text):
        (self.path / rel).parent.mkdir(parents=True, exist_ok=True)
        (self.path / rel).write_text(text)

    def read(self, rel):
        return (self.path / rel).read_text()

    def run(self, *args):
        return subprocess.run([sys.executable, "-I", str(SCRIPT), "--repo", str(self.path), *args],
                              capture_output=True, text=True)

    def close(self):
        self.temporary.cleanup()


class NamingAutofixTests(unittest.TestCase):
    def fixture(self, *args, **kwargs):
        fixture = Fixture(*args, **kwargs)
        self.addCleanup(fixture.close)
        return fixture

    def test_check_names_the_dotted_experiment_id(self):
        f = self.fixture("agent-pane.high-contrast-look")
        done = f.run("--check")
        self.assertEqual(done.returncode, 1, done.stdout + done.stderr)
        self.assertIn("webviews/src/acpmux/highContrastLook.experiment.ts:4 agent-pane.high-contrast-look -> "
                      "agent-pane-high-contrast-look (experiment-id)", done.stdout)
        self.assertEqual(done.stdout.count("\n"), 1, done.stdout)  # the valid ids are not reported

    def test_fix_renames_the_id_and_its_exact_references(self):
        f = self.fixture("agent-pane.high-contrast-look")
        done = f.run("--fix", "--base", "main")
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertIn('id: "agent-pane-high-contrast-look"', f.read("webviews/src/acpmux/highContrastLook.experiment.ts"))
        test = f.read("webviews/test/high-contrast.test.ts")
        self.assertIn('{ "agent-pane-high-contrast-look": "high" }', test)
        self.assertIn("experimentById('agent-pane-high-contrast-look')", test)
        self.assertIn('"agent-pane.high-contrast-look-extra"', test)  # not an exact reference
        self.assertEqual(f.run("--check").returncode, 0)

    def test_fix_leaves_valid_ids_alone(self):
        f = self.fixture("high-contrast-look")
        before = {rel: f.read(rel) for rel in git(f.path, "ls-files").split()}
        self.assertEqual(f.run("--check").returncode, 0)
        done = f.run("--fix")
        self.assertEqual((done.returncode, done.stdout), (0, ""))
        self.assertEqual(before, {rel: f.read(rel) for rel in before})

    def test_a_gallery_id_equal_to_the_old_id_is_not_renamed(self):
        # #48230 itself: the gallery entry beside the experiment is the valid `agent-pane.high-contrast-look`.
        f = self.fixture("agent-pane.high-contrast-look", gallery_id="agent-pane.high-contrast-look", with_test_ref=False)
        done = f.run("--fix")
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertIn('id: "agent-pane-high-contrast-look"', f.read("webviews/src/acpmux/highContrastLook.experiment.ts"))
        self.assertIn('id: "agent-pane.high-contrast-look"', f.read("webviews/src/acpmux/highContrastLook.gallery.ts"))

    def test_gallery_entry_id_in_camel_case_is_renamed(self):
        f = self.fixture("high-contrast-look", gallery_id="agentPane.highContrast")
        done = f.run("--fix")
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertIn('id: "agent-pane.high-contrast"', f.read("webviews/src/acpmux/highContrastLook.gallery.ts"))

    def test_no_unambiguous_rename_is_left(self):
        # Undotted gallery id: the area cannot be guessed. A taken canonical form cannot be used either.
        f = self.fixture("Steer_Queue", gallery_id="high-contrast")
        done = f.run("--fix")
        self.assertEqual(done.returncode, 1)
        self.assertIn("left: webviews/src/acpmux/highContrastLook.gallery.ts:2 high-contrast", done.stdout)
        self.assertIn("steer-queue is already a experiment-id", done.stdout)
        self.assertEqual(git(f.path, "status", "--porcelain"), "")

    def test_base_limits_to_changed_files_and_only_keeps_a_rename_whole(self):
        f = self.fixture("agent-pane.high-contrast-look")
        git(f.path, "checkout", "-q", "-b", "later")
        self.assertEqual(f.run("--check", "--base", "HEAD").returncode, 0)  # nothing changed since HEAD
        done = f.run("--fix", "--only", "webviews/src/")
        self.assertEqual(done.returncode, 1)
        self.assertIn("webviews/test/high-contrast.test.ts (outside webviews/src/)", done.stdout)
        self.assertEqual(git(f.path, "status", "--porcelain"), "")

    def test_base_autofix_naming_repair(self):
        # The bot path: cmux-next-pr-autofix.yml's repair runs base-autofix.sh --naming-base BASE_SHA, and the push
        # job commits the patch to a same-repo branch; the base bot runs --naming.
        f = self.fixture("agent-pane.high-contrast-look")
        for rel in ("scripts/cmux-next/base-autofix.sh", "scripts/cmux-next/base-autofix-frozen.txt",
                    "scripts/ci/naming_autofix.py"):
            (f.path / rel).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / rel, f.path / rel)
        done = subprocess.run(["bash", str(f.path / "scripts/cmux-next/base-autofix.sh"), "--naming-base", "main",
                               "--no-fmt", str(f.path)], capture_output=True, text=True)
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertIn("fixed: webviews/src/acpmux/highContrastLook.experiment.ts:4 agent-pane.high-contrast-look -> "
                      "agent-pane-high-contrast-look", done.stdout)
        self.assertIn('"agent-pane-high-contrast-look": "high"', f.read("webviews/test/high-contrast.test.ts"))

    def test_areas_turn_naming_on_for_webviews_sources(self):
        areas = ROOT / "scripts/cmux-next/autofix-areas.sh"
        on = subprocess.run(["bash", str(areas)], input="webviews/src/a/b.experiment.ts\n", capture_output=True, text=True)
        off = subprocess.run(["bash", str(areas)], input="docs/x.md\n", capture_output=True, text=True)
        self.assertIn("naming=true", on.stdout)
        self.assertIn("naming=false", off.stdout)

    def test_repository_runs_clean_and_fast(self):
        done = subprocess.run([sys.executable, "-I", str(SCRIPT), "--repo", str(ROOT), "--check"],
                              capture_output=True, text=True, timeout=10)
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)


if __name__ == "__main__":
    unittest.main()
