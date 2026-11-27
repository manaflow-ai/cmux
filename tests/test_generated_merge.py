#!/usr/bin/env python3
"""No one resolves a conflict in a generated file: every file the generated-files check calls generated
merges through a driver its family needs, and the merge paths rebuild it.

Leo, 2026-11-16: "generated schema files those shouldve been handled automatically right why did you even
notice the conflict it shouldve just been done".

The detector is test_every_generated_file_is_routed_through_its_driver: scripts/cmux-next/generated_merge.py
audit over this tree. It fails when a file scripts/ci/generated_files_guard.py calls generated (a committed
generator's output, a generated_outputs.py export, a baseline file, a conventionally named file) has no
REGENERATE family, merges with another driver than its family names, or when a file kept by
cmux-generated-v1 is not generated at all.
"""
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/cmux-next/generated_merge.py"


def load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[name] = module  # dataclasses look their module up while the class is made
    spec.loader.exec_module(module)
    return module


generated_merge = load("generated_merge", SCRIPT)
# tests/git_fixture_env.py, by path (`python3 -I` puts no script folder on sys.path); loading it turns off git's
# auto maintenance for every fixture repository below.
git_fixture_env = load("git_fixture_env", ROOT / "tests/git_fixture_env.py")


def git_env(home: Path) -> dict[str, str]:
    env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=str(home / "gitconfig"), HOME=str(home),
               GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@example.com",
               GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@example.com")
    return git_fixture_env.without_auto_maintenance(env)


class TreeAuditTests(unittest.TestCase):
    """The detector, on this tree."""

    def test_every_generated_file_is_routed_through_its_driver(self):
        problems = generated_merge.audit(ROOT)
        self.assertEqual(problems, [], "\n".join(problems[:40]))

    def test_the_two_collisions_of_2026_11_16_merge_without_a_person(self):
        """cmux#44368 (acpmux-schema.json, the acpmux protocol codegen) and cmux#44453 (policy.json,
        AcpmuxPaneMethods+Params.swift, the protocol types) each hand-resolved these. The acpmux
        protocol's TypeScript types are build output now (not in git), so they cannot collide."""
        attributes = generated_merge.merge_attributes(ROOT, [
            "cmux-tui/crates/acpmux/docs/acpmux-schema.json",
            "cmux-tui/crates/acpmux/spec/acpmux-protocol.json",
            "cmux-tui/crates/cmux-agent-pane-policy/policy.json",
            "Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/AcpmuxPaneMethods+Params.swift",
        ])
        self.assertEqual(attributes["cmux-tui/crates/acpmux/docs/acpmux-schema.json"], "cmux-insertions-v1")
        self.assertEqual(attributes["cmux-tui/crates/acpmux/spec/acpmux-protocol.json"], "cmux-insertions-v1")
        self.assertEqual(attributes["cmux-tui/crates/cmux-agent-pane-policy/policy.json"], "cmux-insertions-v1")
        self.assertEqual(attributes["Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/AcpmuxPaneMethods+Params.swift"],
                         "cmux-insertions-v1")

    def test_every_here_command_names_a_tracked_script(self):
        tracked = set(generated_merge.tracked(ROOT))
        for family, entry in generated_merge.REGENERATE.items():
            ran = []
            for command in entry.commands:
                scripts = [word for word in command if word.endswith((".py", ".ts", ".sh", ".mjs"))]
                ran += scripts
                directory = command[4] if command[:2] == ("sh", "-c") else ""
                for script in scripts:
                    path = f"{directory}/{script}" if directory else script
                    self.assertIn(path, tracked, f"{family}: {path}")
            if entry.where == "here":
                self.assertTrue(ran, f"{family}: no command runs a generator")

    def test_the_catch_up_classifier_agrees_with_git_on_every_file(self):
        """The CI catch-up decides "only generated files conflict" from .gitattributes text, not git:
        a later `!merge` line (the Java hand-written files) must take a path back out there too."""
        catch_up = load("generated_catch_up", ROOT / "scripts/cmux-next/generated_catch_up.py")
        rules = catch_up.merge_rules((ROOT / ".gitattributes").read_text(encoding="utf-8"))
        files = generated_merge.tracked(ROOT)
        attributes = generated_merge.merge_attributes(ROOT, files)
        disagree = [path for path in files
                    if catch_up.is_generated(path, rules) != (attributes[path] == "cmux-generated-v1")]
        self.assertEqual(disagree, [])

    def test_the_java_hand_written_list_matches_its_manifest(self):
        """.gitattributes keeps every Java raw file but the hand-written ones; the manifest says which."""
        directory = "cmux-tui/bindings/java/src/com/cmux/raw"
        listed = {entry["path"] for entry in json.loads(
            (ROOT / directory / ".cmux-sdk-manifest.json").read_text(encoding="utf-8"))["files"]}
        files = [path for path in generated_merge.tracked(ROOT) if path.startswith(directory + "/")
                 and "/" not in path[len(directory) + 1:]]
        attributes = generated_merge.merge_attributes(ROOT, files)
        for path in files:
            name = path.rsplit("/", 1)[1]
            kept = attributes[path] == "cmux-generated-v1"
            self.assertEqual(kept, name in listed or name in generated_merge.SDK_SIDECARS, path)


class DaemonAbiBaselineMergeTests(unittest.TestCase):
    """The daemon ABI baseline preserves a real same-line disagreement for the base autofix."""

    PATH = "cmux-tui/spec/api-compat.surface.json"

    def test_divergent_surface_stays_unmerged_and_has_no_merge_rebuild(self):
        tmp = Path(tempfile.mkdtemp(prefix="generated-merge-daemon-"))
        self.addCleanup(shutil.rmtree, tmp, True)
        repo = tmp / "repo"
        repo.mkdir()
        env = git_env(tmp)
        shutil.copyfile(ROOT / ".gitattributes", repo / ".gitattributes")
        path = repo / self.PATH
        path.parent.mkdir(parents=True)

        def git(*args, check=True):
            return subprocess.run(["git", *args], cwd=repo, env=env, check=check,
                                  capture_output=True, text=True)

        def write(value):
            path.write_text('{"surface": %d}\n' % value)

        git("init", "-q", "-b", "main")
        write(0)
        git("add", "-A")
        git("commit", "-q", "-m", "base")
        git("checkout", "-q", "-b", "lane")
        write(1)
        git("commit", "-qam", "lane surface")
        git("checkout", "-q", "main")
        write(2)
        git("commit", "-qam", "base surface")
        git("checkout", "-q", "lane")

        merged = git("merge", "--no-edit", "main", check=False)
        self.assertNotEqual(merged.returncode, 0, merged.stdout + merged.stderr)
        self.assertEqual(git("diff", "--name-only", "--diff-filter=U").stdout.split(), [self.PATH])
        commands, notes = generated_merge.plan([self.PATH])
        self.assertEqual(commands, [])
        self.assertTrue(any("merged three-way by text" in note and "base autofix rebuilds it after landing" in note
                            for note in notes), notes)


class AuditFixtureTests(unittest.TestCase):
    """The detector catches each way a generated file can be left to a person."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="generated-merge-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.repo = self.tmp / "repo"
        self.env = git_env(self.tmp)
        (self.tmp / "gitconfig").write_text("")
        for relative in ("scripts/ci/generated_files_guard.py", "scripts/ci/ci_process_tree.py",
                         "scripts/cmux-next/generated_outputs.py", "scripts/cmux-next/generated_merge.py"):
            (self.repo / relative).parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / relative, self.repo / relative)
        (self.repo / "scripts/cmux-next/settings-exports.txt").write_text("docs/settings.json\n")
        (self.repo / "scripts/ci/generated-files-baseline.txt").write_text("vendor/notices.md\n")
        self.manifest({"id": "widgets", "generator": "scripts/gen-widgets.py", "outputs": ["src/widgets.generated.ts"],
                       "status": "committed"})
        self.subprocess("git", "init", "-q", "-b", "main")

    def manifest(self, *generators):
        (self.repo / "scripts/ci/generated-files.json").write_text(json.dumps({
            "conventions": ["**/*.generated.*"], "committed": [], "generators": list(generators)}))

    def subprocess(self, *args):
        return subprocess.run(args, cwd=self.repo, env=self.env, check=True, capture_output=True, text=True)

    def write(self, path: str, text: str = "x\n"):
        (self.repo / path).parent.mkdir(parents=True, exist_ok=True)
        (self.repo / path).write_text(text)
        self.subprocess("git", "add", "--", path)

    def audit(self, regenerate):
        saved = dict(generated_merge.REGENERATE)
        generated_merge.REGENERATE.clear()
        generated_merge.REGENERATE.update(regenerate)
        try:
            return generated_merge.audit(self.repo)
        finally:
            generated_merge.REGENERATE.clear()
            generated_merge.REGENERATE.update(saved)

    def routed(self) -> dict:
        return {
            "widgets": generated_merge.here(("python3", "scripts/gen-widgets.py")),
            "vendor/notices.md": generated_merge.line("a vendored file"),
            "docs/settings.json": generated_merge.autofix("a Mac export"),
        }

    def base_tree(self, attributes: str):
        self.write(".gitattributes", attributes)
        self.write("src/widgets.generated.ts")
        self.write("vendor/notices.md")
        self.write("docs/settings.json")
        self.write("src/hand.ts")

    def test_a_routed_tree_passes(self):
        self.base_tree("src/widgets.generated.ts merge=cmux-generated-v1\n"
                       "docs/settings.json merge=cmux-export-v1\n")
        self.assertEqual(self.audit(self.routed()), [])

    def test_a_generated_file_that_merges_by_line_fails(self):
        self.base_tree("docs/settings.json merge=cmux-export-v1\n")
        problems = self.audit(self.routed())
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("src/widgets.generated.ts", problems[0])
        self.assertIn("must merge with merge=cmux-generated-v1", problems[0])

    def test_a_new_generator_with_no_family_fails(self):
        self.manifest({"id": "widgets", "generator": "scripts/gen-widgets.py", "outputs": ["src/widgets.generated.ts"],
                       "status": "committed"},
                      {"id": "gadgets", "generator": "scripts/gen-gadgets.py", "outputs": ["src/gadgets.json"],
                       "status": "committed"})
        self.base_tree("src/*.generated.ts merge=cmux-generated-v1\ndocs/settings.json merge=cmux-export-v1\n")
        self.write("src/gadgets.json")
        problems = self.audit(self.routed())
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("src/gadgets.json", problems[0])
        self.assertIn("REGENERATE has no entry", problems[0])

    def test_a_hand_written_file_kept_by_the_generated_driver_fails(self):
        self.base_tree("src/** merge=cmux-generated-v1\ndocs/settings.json merge=cmux-export-v1\n")
        problems = self.audit(self.routed())
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("src/hand.ts", problems[0])
        self.assertIn("keeps one side", problems[0])

    def test_a_line_family_kept_by_the_generated_driver_fails(self):
        """A file no merge host rebuilds must never keep one side: the other side's change would be lost."""
        self.base_tree("src/*.generated.ts merge=cmux-generated-v1\nvendor/** merge=cmux-generated-v1\n"
                       "docs/settings.json merge=cmux-export-v1\n")
        problems = self.audit(self.routed())
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("vendor/notices.md", problems[0])

    def test_an_entry_for_a_family_that_is_gone_fails(self):
        self.base_tree("src/*.generated.ts merge=cmux-generated-v1\ndocs/settings.json merge=cmux-export-v1\n")
        problems = self.audit({**self.routed(), "retired": generated_merge.here(("python3", "x.py"))})
        self.assertEqual(problems, ["REGENERATE['retired']: no generated file has this family any more; remove the entry"])


class MergeRegeneratesTests(unittest.TestCase):
    """A merge whose only conflict is a generated file finishes, and regenerate rebuilds it from the merged inputs."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="generated-merge-run-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.repo = self.tmp / "repo"
        self.env = git_env(self.tmp)
        # The driver scripts/install-git-hooks.sh registers: a three-way merge, else this branch's copy.
        driver = f"{sys.executable} -I {ROOT / 'scripts/merge-insertions.py'} --generated %O %A %B %P %L"
        (self.tmp / "gitconfig").write_text(f"[merge \"cmux-generated-v1\"]\n\tdriver = {driver}\n")
        for relative in ("scripts/ci/generated_files_guard.py", "scripts/ci/ci_process_tree.py",
                         "scripts/cmux-next/generated_outputs.py", "scripts/cmux-next/generated_merge.py"):
            (self.repo / relative).parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / relative, self.repo / relative)
        (self.repo / "scripts/cmux-next/settings-exports.txt").write_text("docs/settings.json\n")
        (self.repo / "scripts/ci/generated-files-baseline.txt").write_text("")
        (self.repo / "scripts/ci/generated-files.json").write_text(json.dumps({
            "conventions": [], "committed": [], "generators": [
                {"id": "widgets", "generator": "gen.py", "outputs": ["out/widgets.json"], "status": "committed"}]}))
        # The generator: the sorted list of every name in inputs/.
        (self.repo / "gen.py").write_text(
            "import json, pathlib\n"
            "names = sorted(p.name for p in pathlib.Path('inputs').iterdir())\n"
            "pathlib.Path('out').mkdir(exist_ok=True)\n"
            "pathlib.Path('out/widgets.json').write_text(json.dumps(names, indent=1) + '\\n')\n")
        (self.repo / ".gitattributes").write_text("out/widgets.json merge=cmux-generated-v1\n")
        (self.repo / "inputs").mkdir()
        (self.repo / "inputs/a").write_text("a\n")
        self.git("init", "-q", "-b", "main")
        self.run_gen()
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "base")

    def git(self, *args, check=True):
        return subprocess.run(["git", *args], cwd=self.repo, env=self.env, check=check, capture_output=True, text=True)

    def run_gen(self):
        subprocess.run([sys.executable, "gen.py"], cwd=self.repo, check=True)

    def add_input(self, name: str):
        (self.repo / "inputs" / name).write_text(name + "\n")
        self.run_gen()
        self.git("add", "-A")
        self.git("commit", "-q", "-m", f"add {name}")

    def test_a_generated_only_conflict_merges_and_regenerates_with_no_person(self):
        self.git("checkout", "-q", "-b", "lane")
        self.add_input("lane")
        self.git("checkout", "-q", "main")
        self.add_input("base")
        self.git("checkout", "-q", "lane")
        merged = self.git("merge", "--no-edit", "main", check=False)
        self.assertEqual(merged.returncode, 0, merged.stdout + merged.stderr)  # no conflict
        # Both sides rewrote the `"a"` line (its comma): no three-way merge, so the lane's copy, said loudly.
        self.assertIn("out/widgets.json: both sides rebuilt this generated file", merged.stderr)
        self.assertEqual(json.loads((self.repo / "out/widgets.json").read_text()), ["a", "lane"])  # kept, stale
        saved = dict(generated_merge.REGENERATE)
        generated_merge.REGENERATE.clear()
        generated_merge.REGENERATE["widgets"] = generated_merge.here((sys.executable, "gen.py"))
        try:
            catalog = generated_merge.Catalog(self.repo)
            paths = generated_merge.merge_paths(self.repo)
            self.assertIn("out/widgets.json", paths)
            families = generated_merge.families_of(catalog, paths)
            self.assertEqual(families, ["widgets"])
            self.assertEqual(generated_merge.regenerate(self.repo, families, stage=True), 0)
        finally:
            generated_merge.REGENERATE.clear()
            generated_merge.REGENERATE.update(saved)
        self.assertEqual(json.loads((self.repo / "out/widgets.json").read_text()), ["a", "base", "lane"])
        self.assertEqual(self.git("diff", "--cached", "--name-only").stdout.split(), ["out/widgets.json"])


SETTINGS_SWIFT = "Packages/macOS/CmuxNext/Sources/CmuxNextSettings/Schema/SettingsSchema+Keys.generated.swift"
SETTINGS_EXPORTS = (
    "docs/mdm/com.manaflow.cmux.json",
    "docs/mdm/com.manaflow.cmux.plist",
    "docs/mdm/com.manaflow.cmux.intune.plist",
    "docs/mdm/cmux-example.mobileconfig",
    "docs/mdm/managed-preferences.md",
    "schemas/settings/settings-schema.json",
)
# Stands for the settings Swift generator (a `here` family regenerate reruns on any host).
SWIFT_GENERATOR = f"""import pathlib
keys = sorted(p.stem for p in pathlib.Path('settings-sources').glob('*.key'))
out = pathlib.Path({SETTINGS_SWIFT!r})
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text('let settingKeys = [\\n' + ''.join(f'    "{{k}}",\\n' for k in keys) + ']\\n')
"""
# Stands for regenerate-settings-exports.sh, which only a Mac runs: in this fixture each side's commit ran it,
# the merge never does.
MAC_EXPORTER = """import json, pathlib
keys = sorted(p.stem for p in pathlib.Path('settings-sources').glob('*.key'))
def write(path, text):
    pathlib.Path(path).parent.mkdir(parents=True, exist_ok=True)
    pathlib.Path(path).write_text(text)
props = {k: {'type': 'boolean'} for k in keys}
write('schemas/settings/settings-schema.json', json.dumps({'properties': props}, indent=2) + '\\n')
write('docs/mdm/com.manaflow.cmux.json', json.dumps({'keys': keys}, indent=2) + '\\n')
rows = ''.join(f'\\t<key>{k}</key>\\n\\t<true/>\\n' for k in keys)
plist = '<?xml version="1.0" encoding="UTF-8"?>\\n<plist version="1.0">\\n<dict>\\n' + rows + '</dict>\\n</plist>\\n'
write('docs/mdm/com.manaflow.cmux.plist', plist)
write('docs/mdm/cmux-example.mobileconfig', plist)
write('docs/mdm/com.manaflow.cmux.intune.plist', rows)
write('docs/mdm/managed-preferences.md', '# Managed preferences\\n\\n' + ''.join(f'- `{k}`\\n' for k in keys) + '\\nEnd.\\n')
"""


class SettingsKeysFromBothSidesTests(unittest.TestCase):
    """cmux#47525: base added settings keys (cornerFlush, finishSound, app.language, appearance.twoTone), the lane
    added its own, and the merge kept the lane's settings-schema.json, docs/mdm exports and settings Swift, so
    base's keys vanished with no conflict. The cmux-generated-v1 driver was `true` (always this branch's copy):
    nothing on Linux rebuilds the Mac-only exports, and the settings Swift is rebuilt only by post-merge, which
    never runs when a merge stops on a hand-written conflict and is finished with `git commit`.

    The detector: a merge of two sides that each add a different settings key keeps both keys in every output,
    after `regenerate --merge` and with no regenerate at all, and an old `driver = true` clone fails regenerate
    naming the file that lost base's rows."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="generated-merge-keys-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.repo = self.tmp / "repo"
        self.env = git_env(self.tmp)
        self.drivers(old=False)
        for relative in ("scripts/ci/generated_files_guard.py", "scripts/ci/ci_process_tree.py",
                         "scripts/cmux-next/generated_outputs.py", "scripts/cmux-next/generated_merge.py",
                         "scripts/cmux-next/settings-exports.txt", ".gitattributes"):
            (self.repo / relative).parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / relative, self.repo / relative)
        (self.repo / "scripts/ci/generated-files-baseline.txt").write_text("")
        (self.repo / "scripts/ci/generated-files.json").write_text(json.dumps({
            "conventions": ["**/*.generated.*"], "committed": [], "generators": [
                {"id": "settings-sources", "generator": "gen_swift.py", "outputs": [SETTINGS_SWIFT],
                 "status": "committed"}]}))
        (self.repo / "gen_swift.py").write_text(SWIFT_GENERATOR)
        (self.repo / "mac_export.py").write_text(MAC_EXPORTER)
        (self.repo / "notes.txt").write_text("base\n")
        self.git("init", "-q", "-b", "main")
        self.add_keys("aaa.first", "zzz.last")
        saved = dict(generated_merge.REGENERATE)
        self.addCleanup(lambda: (generated_merge.REGENERATE.clear(), generated_merge.REGENERATE.update(saved)))
        generated_merge.REGENERATE.clear()
        generated_merge.REGENERATE["settings-sources"] = generated_merge.here((sys.executable, "gen_swift.py"))
        generated_merge.REGENERATE["docs/mdm/com.manaflow.cmux.json"] = generated_merge.autofix("mac_export.py")

    def drivers(self, *, old: bool):
        """The drivers scripts/install-git-hooks.sh registers, or (OLD) the `true` every clone had before."""
        insertions = f"{sys.executable} -I {ROOT / 'scripts/merge-insertions.py'}"
        generated = "true" if old else f"{insertions} --generated %O %A %B %P %L"
        export = "true" if old else f"{insertions} %O %A %B %P %L"
        (self.tmp / "gitconfig").write_text(f"[merge \"cmux-generated-v1\"]\n\tdriver = {generated}\n"
                                            f"[merge \"cmux-export-v1\"]\n\tdriver = {export}\n")

    def git(self, *args, check=True):
        return subprocess.run(["git", *args], cwd=self.repo, env=self.env, check=check, capture_output=True, text=True)

    def add_keys(self, *keys: str, notes: str | None = None):
        (self.repo / "settings-sources").mkdir(exist_ok=True)
        for key in keys:
            (self.repo / "settings-sources" / f"{key}.key").write_text(key + "\n")
        if notes is not None:
            (self.repo / "notes.txt").write_text(notes)
        for script in ("gen_swift.py", "mac_export.py"):  # a Mac commit: every output rebuilt
            subprocess.run([sys.executable, script], cwd=self.repo, check=True)
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "add " + " ".join(keys))

    def branches(self, *, conflict: bool):
        self.git("checkout", "-q", "-b", "lane")
        self.add_keys("look.glyph", notes="lane\n" if conflict else None)
        self.git("checkout", "-q", "main")
        self.add_keys("appearance.twoTone", notes="main\n" if conflict else None)
        self.git("checkout", "-q", "lane")

    def regenerate(self) -> tuple[int, str]:
        err = io.StringIO()
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(err):
            code = generated_merge.main(["regenerate", "--repo", str(self.repo), "--merge", "--stage"])
        return code, err.getvalue()

    def assert_both_keys(self, where: str):
        for path in (SETTINGS_SWIFT, *SETTINGS_EXPORTS):
            text = (self.repo / path).read_text()
            for key in ("look.glyph", "appearance.twoTone", "aaa.first", "zzz.last"):
                self.assertIn(key, text, f"{where}: {path} lost {key}")
        json.loads((self.repo / "schemas/settings/settings-schema.json").read_text())
        json.loads((self.repo / "docs/mdm/com.manaflow.cmux.json").read_text())

    def test_a_clean_merge_and_regenerate_keep_both_keys(self):
        self.branches(conflict=False)
        merged = self.git("merge", "--no-edit", "main", check=False)
        self.assertEqual(merged.returncode, 0, merged.stdout + merged.stderr)
        self.assert_both_keys("after the merge")
        code, err = self.regenerate()
        self.assertEqual(code, 0, err)
        self.assert_both_keys("after regenerate --merge")
        self.assertEqual((self.repo / SETTINGS_SWIFT).read_text(),
                         'let settingKeys = [\n    "aaa.first",\n    "appearance.twoTone",\n    "look.glyph",\n'
                         '    "zzz.last",\n]\n')

    def test_a_merge_finished_by_hand_with_no_rebuild_keeps_both_keys(self):
        """post-merge never runs here: the merge stops on notes.txt and `git commit` finishes it."""
        self.branches(conflict=True)
        merged = self.git("merge", "--no-edit", "main", check=False)
        self.assertNotEqual(merged.returncode, 0)
        self.assertEqual(self.git("diff", "--name-only", "--diff-filter=U").stdout.split(), ["notes.txt"])
        (self.repo / "notes.txt").write_text("both\n")
        self.git("add", "notes.txt")
        self.git("commit", "-q", "--no-edit")
        self.assert_both_keys("committed with no regenerate")
        code, err = self.regenerate()
        self.assertEqual(code, 0, err)

    def test_an_old_keep_ours_clone_fails_regenerate_naming_the_file(self):
        self.drivers(old=True)
        self.branches(conflict=False)
        merged = self.git("merge", "--no-edit", "main", check=False)
        self.assertEqual(merged.returncode, 0, merged.stdout + merged.stderr)
        self.assertNotIn("appearance.twoTone", (self.repo / "schemas/settings/settings-schema.json").read_text())
        code, err = self.regenerate()
        self.assertEqual(code, 1)
        for path in SETTINGS_EXPORTS:
            self.assertIn(f"{path}: the merge dropped", err)
        self.assertIn("appearance.twoTone", err)
        self.assertNotIn(SETTINGS_SWIFT, err)  # regenerate rebuilt that one from the merged sources
        self.assertIn("appearance.twoTone", (self.repo / SETTINGS_SWIFT).read_text())


class InsertionsOnTheHandWrittenRegistriesTests(unittest.TestCase):
    """A registry both sides insert a method into, one entry per line, merges with cmux-insertions-v1. Two
    edits of one existing line (cmux#44453's field order on one policy.json line) still conflict: that is a
    real disagreement, and keeping either side would drop the other's change."""

    def test_two_appended_methods_merge(self):
        tmp = Path(tempfile.mkdtemp(prefix="generated-merge-ins-"))
        self.addCleanup(shutil.rmtree, tmp, True)
        repo = tmp / "repo"
        repo.mkdir()
        env = git_env(tmp)
        driver = f"{sys.executable} -I {ROOT / 'scripts/merge-insertions.py'} %O %A %B %P %L"
        (tmp / "gitconfig").write_text(f"[merge \"cmux-insertions-v1\"]\n\tdriver = {driver}\n")

        def git(*args, check=True):
            return subprocess.run(["git", *args], cwd=repo, env=env, check=check, capture_output=True, text=True)

        path = repo / "cmux-tui/crates/cmux-agent-pane-policy/policy.json"
        path.parent.mkdir(parents=True)
        shutil.copyfile(ROOT / ".gitattributes", repo / ".gitattributes")

        def write(methods):
            body = ",\n".join(f'    "{m}"' for m in methods)
            path.write_text('{\n  "requests": [\n' + body + '\n  ],\n  "x": 1\n}\n')

        git("init", "-q", "-b", "main")
        write(["a", "z"])
        git("add", "-A")
        git("commit", "-q", "-m", "base")
        git("checkout", "-q", "-b", "lane")
        write(["a", "lane", "z"])
        git("commit", "-qam", "lane")
        git("checkout", "-q", "main")
        write(["a", "base", "z"])
        git("commit", "-qam", "base method")
        git("checkout", "-q", "lane")
        merged = git("merge", "--no-edit", "main", check=False)
        self.assertEqual(merged.returncode, 0, merged.stdout + merged.stderr)
        self.assertEqual(json.loads(path.read_text())["requests"], ["a", "lane", "base", "z"])


class AMergeThatDoesNotParseIsMarkedTests(unittest.TestCase):
    """cmux#50003, 2026-11-25: feat-cmux-next held `cmux-deadline` twice in cmux-tui/crates/acpmux/Cargo.toml
    (cmux#55199 and cmux#54487 each added it, at two places, and the line merge of the two was clean). A lane
    that only added its own dependency merged that base and got the file as a conflict with no markers and no
    reason, and cargo could not load the workspace. The three files are that merge's blobs, trimmed."""

    BASE = (
        "[dependencies]\n"
        "cmux-agent-wire.workspace = true\n"
        "cmux-netwatch.workspace = true\n"
        "cmux-build-space.workspace = true\n"
        "cmux-stats-live.workspace = true\n"
        "serde.workspace = true\n"
    )
    LANE = BASE.replace(
        "cmux-build-space.workspace = true\n",
        "cmux-build-space.workspace = true\n"
        "# The team's hosted forum (`hub/forum_hosted.rs`): cmux-forum's post, reply and search.\n"
        'cmux-forum-hosted = { path = "../cmux-forum-hosted", features = ["http"] }\n',
    )
    TWICE = BASE.replace(
        "cmux-netwatch.workspace = true\n",
        "# Deadlines on silence since the last progress, not a wall clock (peer frame writes, mesh reads).\n"
        'cmux-deadline = { workspace = true, features = ["tokio"] }\n'
        "cmux-netwatch.workspace = true\n",
    ).replace(
        "serde.workspace = true\n",
        "# One deadline per wait (daemon/watchdog.rs: a hello waits until systemd's own limit).\n"
        "cmux-deadline.workspace = true\n"
        "serde.workspace = true\n",
    )
    ONCE = TWICE.replace(
        "# One deadline per wait (daemon/watchdog.rs: a hello waits until systemd's own limit).\n"
        "cmux-deadline.workspace = true\n", "")
    PATH = "cmux-tui/crates/acpmux/Cargo.toml"

    def drive(self, base, ours, theirs, path=PATH):
        tmp = Path(tempfile.mkdtemp(prefix="generated-merge-unparsed-"))
        self.addCleanup(shutil.rmtree, tmp, True)
        for name, text in (("base", base), ("ours", ours), ("theirs", theirs)):
            (tmp / name).write_text(text)
        run = subprocess.run(
            [sys.executable, "-I", str(ROOT / "scripts/merge-insertions.py"),
             str(tmp / "base"), str(tmp / "ours"), str(tmp / "theirs"), path, "7"],
            capture_output=True, text=True, cwd=tmp)
        return run, (tmp / "ours").read_text()

    @unittest.skipIf(sys.version_info < (3, 11), "the driver checks TOML with tomllib")
    def test_a_base_that_names_a_key_twice_is_a_marked_conflict_that_says_why(self):
        run, merged = self.drive(self.BASE, self.LANE, self.TWICE)
        self.assertEqual(run.returncode, 1, run.stderr)
        self.assertIn(
            "<<<<<<< ours\n=======\ncmux-deadline.workspace = true\n>>>>>>> theirs\n", merged)
        self.assertEqual(merged.count("<<<<<<<"), 1)
        self.assertIn("cmux-forum-hosted", merged)  # the rest is still the merge of both sides
        self.assertIn(self.PATH, run.stderr)
        self.assertIn("the copy being merged in already did not parse", run.stderr)
        self.assertNotIn("this branch's copy", run.stderr)

    @unittest.skipIf(sys.version_info < (3, 11), "the driver checks TOML with tomllib")
    def test_a_line_one_side_deleted_stays_deleted(self):
        # The lane branched while the base held the key twice; the base then dropped the second.
        lane = self.TWICE.replace("cmux-build-space.workspace = true\n",
                                  'cmux-build-space.workspace = true\ncmux-forum-hosted = { path = "x" }\n')
        run, merged = self.drive(self.TWICE, lane, self.ONCE)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(merged.count("cmux-deadline"), 1)
        self.assertIn("cmux-forum-hosted", merged)
        self.assertNotIn("<<<<<<<", merged)

    def test_a_key_each_side_added_at_its_own_place_is_marked_with_both_copies(self):
        base = '{\n  "a": 1,\n  "b": 2,\n  "c": 3,\n  "d": 4,\n  "e": 5,\n  "f": 6,\n  "g": 7\n}\n'
        ours = base.replace('  "a": 1,\n', '  "a": 1,\n  "new": 1,\n')
        theirs = base.replace('  "f": 6,\n', '  "f": 6,\n  "new": 2,\n')
        run, merged = self.drive(base, ours, theirs, "config/thing.json")
        self.assertEqual(run.returncode, 1, run.stderr)
        self.assertEqual(merged, f"<<<<<<< ours\n{ours}=======\n{theirs}>>>>>>> theirs\n")
        self.assertIn("config/thing.json: the merged file does not parse (duplicate key)", run.stderr)



class RustModListsMergeSortedTests(unittest.TestCase):
    """cmux#56459: acpmux `hub/mod.rs` keeps its `mod` list sorted by name. A branch made before the sort
    adds one `mod` among the old order; merged with the sorted base, every line around it moved, and the line
    merge stops although only the one line is new. The driver merges the three again with each list sorted."""

    BASE = ("//! hub\n\nmod zeta;\n// Alpha's note.\nmod alpha;\n#[cfg(test)]\nmod mid_tests;\nmod beta;\n"
            "pub use alpha::A;\n\nfn f() {}\nmod gamma;\n")
    SORTED = ("//! hub\n\n// Alpha's note.\nmod alpha;\nmod beta;\nmod gamma;\n#[cfg(test)]\nmod mid_tests;\n"
              "mod zeta;\npub use alpha::A;\n\nfn f() {}\n")
    PATH = "cmux-tui/crates/acpmux/src/hub/mod.rs"

    def drive(self, base, ours, theirs, path=PATH):
        tmp = Path(tempfile.mkdtemp(prefix="rust-mods-merge-"))
        self.addCleanup(shutil.rmtree, tmp, True)
        for name, text in (("base", base), ("ours", ours), ("theirs", theirs)):
            (tmp / name).write_text(text)
        run = subprocess.run(
            [sys.executable, "-I", str(ROOT / "scripts/merge-insertions.py"),
             str(tmp / "base"), str(tmp / "ours"), str(tmp / "theirs"), path, "7"],
            capture_output=True, text=True, cwd=tmp)
        return run, (tmp / "ours").read_text()

    def test_a_branch_from_before_the_sort_merges_its_new_mod_into_place(self):
        lane = self.BASE.replace("mod zeta;\n", "mod zeta;\n// Delta's note.\nmod delta;\n")
        run, merged = self.drive(self.BASE, lane, self.SORTED)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(merged, self.SORTED.replace("mod gamma;\n", "// Delta's note.\nmod delta;\nmod gamma;\n"
                                                     ).replace("mod beta;\n// Delta", "mod beta;\n// Delta"))
        self.assertLess(merged.index("mod beta;"), merged.index("mod delta;"))
        self.assertLess(merged.index("mod delta;"), merged.index("mod gamma;"))

    def test_the_sorted_base_merged_into_the_old_branch_the_other_way_round(self):
        lane = self.BASE.replace("mod beta;\n", "mod beta;\nmod epsilon;\n")
        run, merged = self.drive(self.BASE, self.SORTED, lane)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn("mod beta;\nmod epsilon;\nmod gamma;\n", merged)

    def test_a_real_conflict_stays_a_conflict(self):
        lane = self.BASE.replace("fn f() {}", "fn f() { 1 }")
        sorted_edit = self.SORTED.replace("fn f() {}", "fn f() { 2 }")
        run, merged = self.drive(self.BASE, lane, sorted_edit)
        self.assertEqual(run.returncode, 1)
        self.assertIn("<<<<<<<", merged)

    def test_a_file_with_macros_is_never_reordered(self):
        base = "macro_rules! m { () => {} }\n" + self.BASE
        lane = base.replace("mod zeta;\n", "mod zeta;\nmod delta;\n")
        theirs = "macro_rules! m { () => {} }\n" + self.SORTED
        run, merged = self.drive(base, lane, theirs)
        self.assertEqual(run.returncode, 1)
        self.assertIn("<<<<<<<", merged)

    def test_two_unsorted_sides_are_left_in_their_order(self):
        ours = self.BASE.replace("mod beta;\n", "mod beta;\nmod omega;\n")
        theirs = self.BASE.replace("mod beta;\n", "mod beta;\nmod kappa;\n")
        run, merged = self.drive(self.BASE, ours, theirs)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn("mod zeta;\n// Alpha's note.\nmod alpha;", merged)
        self.assertIn("mod beta;\nmod omega;\nmod kappa;\n", merged)


if __name__ == "__main__":
    unittest.main()
