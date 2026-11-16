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

import importlib.util
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
        AcpmuxPaneMethods+Params.swift, the protocol types) each hand-resolved these."""
        attributes = generated_merge.merge_attributes(ROOT, [
            "cmux-tui/crates/acpmux/docs/acpmux-schema.json",
            "cmux-tui/crates/acpmux/spec/acpmux-protocol.json",
            "cmux-tui/crates/cmux-agent-pane-policy/policy.json",
            "Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/AcpmuxPaneMethods+Params.swift",
            "webviews/src/agent-session/acpmux/protocol/generated/methods.ts",
            "webviews/src/agent-session/acpmux/protocol/generated/types.ts",
        ])
        self.assertEqual(attributes["cmux-tui/crates/acpmux/docs/acpmux-schema.json"], "cmux-insertions-v1")
        self.assertEqual(attributes["cmux-tui/crates/acpmux/spec/acpmux-protocol.json"], "cmux-insertions-v1")
        self.assertEqual(attributes["cmux-tui/crates/cmux-agent-pane-policy/policy.json"], "cmux-insertions-v1")
        self.assertEqual(attributes["Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/AcpmuxPaneMethods+Params.swift"],
                         "cmux-insertions-v1")
        for path in ("webviews/src/agent-session/acpmux/protocol/generated/methods.ts",
                     "webviews/src/agent-session/acpmux/protocol/generated/types.ts"):
            self.assertEqual(attributes[path], "cmux-generated-v1", path)
        catalog = generated_merge.Catalog(ROOT)
        commands, _ = generated_merge.plan(
            generated_merge.families_of(catalog, ["webviews/src/agent-session/acpmux/protocol/generated/types.ts"]))
        self.assertIn(("bun", "webviews/scripts/acpmux-protocol-codegen.ts"), commands)

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
                       "docs/settings.json merge=cmux-generated-v1\n")
        self.assertEqual(self.audit(self.routed()), [])

    def test_a_generated_file_that_merges_by_line_fails(self):
        self.base_tree("docs/settings.json merge=cmux-generated-v1\n")
        problems = self.audit(self.routed())
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("src/widgets.generated.ts", problems[0])
        self.assertIn("must merge with merge=cmux-generated-v1", problems[0])

    def test_a_new_generator_with_no_family_fails(self):
        self.manifest({"id": "widgets", "generator": "scripts/gen-widgets.py", "outputs": ["src/widgets.generated.ts"],
                       "status": "committed"},
                      {"id": "gadgets", "generator": "scripts/gen-gadgets.py", "outputs": ["src/gadgets.json"],
                       "status": "committed"})
        self.base_tree("src/*.generated.ts merge=cmux-generated-v1\ndocs/settings.json merge=cmux-generated-v1\n")
        self.write("src/gadgets.json")
        problems = self.audit(self.routed())
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("src/gadgets.json", problems[0])
        self.assertIn("REGENERATE has no entry", problems[0])

    def test_a_hand_written_file_kept_by_the_generated_driver_fails(self):
        self.base_tree("src/** merge=cmux-generated-v1\ndocs/settings.json merge=cmux-generated-v1\n")
        problems = self.audit(self.routed())
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("src/hand.ts", problems[0])
        self.assertIn("keeps one side", problems[0])

    def test_a_line_family_kept_by_the_generated_driver_fails(self):
        """A file no merge host rebuilds must never keep one side: the other side's change would be lost."""
        self.base_tree("src/*.generated.ts merge=cmux-generated-v1\nvendor/** merge=cmux-generated-v1\n"
                       "docs/settings.json merge=cmux-generated-v1\n")
        problems = self.audit(self.routed())
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("vendor/notices.md", problems[0])

    def test_an_entry_for_a_family_that_is_gone_fails(self):
        self.base_tree("src/*.generated.ts merge=cmux-generated-v1\ndocs/settings.json merge=cmux-generated-v1\n")
        problems = self.audit({**self.routed(), "retired": generated_merge.here(("python3", "x.py"))})
        self.assertEqual(problems, ["REGENERATE['retired']: no generated file has this family any more; remove the entry"])


class MergeRegeneratesTests(unittest.TestCase):
    """A merge whose only conflict is a generated file finishes, and regenerate rebuilds it from the merged inputs."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="generated-merge-run-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.repo = self.tmp / "repo"
        self.env = git_env(self.tmp)
        (self.tmp / "gitconfig").write_text("[merge \"cmux-generated-v1\"]\n\tdriver = true\n")
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


if __name__ == "__main__":
    unittest.main()
