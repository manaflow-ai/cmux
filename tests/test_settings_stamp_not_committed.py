#!/usr/bin/env python3
"""The settings export stamp is derived, never committed (Leo 2026-10-21: "just generate and
don't commit"). It was one `sha256  path` line per CmuxNextSettings source, so every pull request
that touched a settings source changed it, it conflicted on nearly every base move, and the
red it caused needed a 30-minute Mac export to clear (#22674). `defaults_guard.py source-stamp
--ref REF` derives it for any commit; the committed schema is checked against a fresh export
(SettingsSchemaExportTests) instead.
"""

from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
STAMP = "schemas/settings-export/settings-schema.sources.sha256"


def git(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(["git", "-C", str(ROOT), *args], capture_output=True, text=True, check=False)


class SettingsStampIsNotCommitted(unittest.TestCase):
    def test_the_stamp_is_not_tracked(self):
        self.assertEqual(git("ls-files", "--", STAMP).stdout, "")

    def test_the_stamp_is_ignored(self):
        self.assertEqual(git("check-ignore", "-q", "--no-index", STAMP).returncode, 0)

    def test_no_script_workflow_or_test_reads_a_committed_stamp(self):
        # ci-target-graph.json is generated (base autofix rewrites it from the test sources).
        found = git("grep", "-l", "-F", STAMP, "--", ".github", "scripts", "tests", "Packages", ".gitattributes",
                    ":!Packages/macOS/CmuxNext/ci-target-graph.json",
                    ":!tests/test_settings_stamp_not_committed.py").stdout.split()
        self.assertEqual(found, [])

    def test_no_gate_asks_whether_a_committed_stamp_is_fresh(self):
        found = git("grep", "-l", "-e", "check-stamp", "--", ".github", "scripts",
                    ":!scripts/ci/cmux-tui-rust-check.sh").stdout.split()
        self.assertEqual(found, [])


class OneListOfTheExports(unittest.TestCase):
    """scripts/cmux-next/settings-exports.txt is the one list of what the settings export writes.
    The exporter exports those files and the checker restores them, and a file in one and not the
    other is how a base-version export reached a repair artifact (review of #23915), so neither may
    hard-code its own list."""

    LIST = "scripts/cmux-next/settings-exports.txt"

    def paths(self) -> list[str]:
        return [line.split("#", 1)[0].strip()
                for line in (ROOT / self.LIST).read_text(encoding="utf-8").splitlines()
                if line.split("#", 1)[0].strip()]

    def test_the_list_names_the_exports(self):
        self.assertEqual(self.paths(), [
            "docs/mdm/com.manaflow.cmux.json", "docs/mdm/com.manaflow.cmux.plist",
            "docs/mdm/com.manaflow.cmux.intune.plist", "docs/mdm/cmux-example.mobileconfig",
            "docs/mdm/managed-preferences.md", "schemas/settings/settings-schema.json"])

    def test_every_listed_export_is_committed(self):
        for path in self.paths():
            self.assertNotEqual(git("ls-files", "--", path).stdout, "", path)

    def test_the_exporter_and_the_checker_both_read_the_list(self):
        for script in ("scripts/cmux-next/regenerate-settings-exports.sh",
                       "scripts/cmux-next/check-settings-exports.sh"):
            body = (ROOT / script).read_text(encoding="utf-8")
            # The exporter names it as its default (CMUX_SETTINGS_EXPORTS_LIST overrides it for the
            # base export), so the file name, not the whole path, is what both have in common.
            self.assertIn("settings-exports.txt", body, script)
            # No second, hard-coded copy of the export paths. Comments may name one as prose.
            code = [line for line in body.splitlines() if not line.lstrip().startswith("#")]
            for path in self.paths():
                for line in code:
                    self.assertNotIn(path, line, f"{script} hard-codes {path} instead of reading the list")

    READERS = (
        "scripts/cmux-next/regenerate-settings-exports.sh",   # exports them
        "scripts/cmux-next/check-settings-exports.sh",        # compares and restores them
        "scripts/cmux-next/base-autofix-push.sh",             # lands them whole
        "scripts/cmux-next/base-autofix-settings-landed.sh",  # judges whether the tip's are current
        "scripts/cmux-next/base-autofix-land.sh",             # matches them on the tip
        "scripts/cmux-next/tests/pr-autofix.test.sh",         # its fixture is exactly them
        "scripts/ci/run-swift-testing-suites.sh",             # puts them in the fleet's artifact
        "scripts/cmux-next/generated_outputs.py",             # maps them to the inputs that own them
        "scripts/ci/next_batch.py",                           # knows only a mini can rebuild them
        "scripts/cmux-next/pr-autofix-apply.sh",              # lets a repair push them
        "scripts/cmux-next/swift-exports-key.py",             # keys the export cache on them
        "scripts/ci/generated_files_guard.py",                # hands it to generated_outputs.py
    )

    # A test's own fixture may name the exports it drives: a short copy there weakens that test,
    # it does not write a wrong artifact. Only the scripts CI runs have to read the list.
    FIXTURES = (
        "scripts/cmux-next/tests/base-autofix-push.test.sh",
        "scripts/cmux-next/tests/base-autofix-settings-landed.test.sh",
        "scripts/cmux-next/tests/generated-ownership.test.sh",
    )

    # The checks below read only the code, so a path in a comment is prose, not a copy.
    @staticmethod
    def code_of(script: str) -> str:
        return "\n".join(line for line in (ROOT / script).read_text(encoding="utf-8").splitlines()
                         if not line.lstrip().startswith("#"))

    def test_no_script_keeps_its_own_copy_of_the_list(self):
        """Seven scripts need this list, and each one reads it. A hand-kept enumeration is a place it
        can drift: the base export rewrites EVERY export, so a script whose copy is short leaves one
        holding base bytes. A classifier that matches a path or two by glob
        (`docs/mdm/*`) is not an enumeration; naming most of the list is."""
        for script in self.READERS:
            body = (ROOT / script).read_text(encoding="utf-8")
            self.assertIn("settings-exports.txt", body, f"{script} does not read the list")
            named = [path for path in self.paths() if path in self.code_of(script)]
            self.assertLess(len(named), 3, f"{script} enumerates the list ({named}) instead of reading it")

    def test_no_script_anywhere_enumerates_the_exports(self):
        """The check above only looks at the scripts that read the list, so it cannot see a copy in
        a script that does not. scripts/ci/run-swift-testing-suites.sh was exactly that: it put all
        six exports in the fleet's artifact from its own list, so an export added to the real list
        would have been missing there and nothing would have said so (review of #23915). Every
        script that names most of the exports has to be a reader."""
        scripts = git("ls-files", "--", "scripts/*.sh", "scripts/*.py").stdout.split()
        for script in scripts:
            if script in self.READERS or script in self.FIXTURES:
                continue
            named = [path for path in self.paths() if path in self.code_of(script)]
            self.assertLess(len(named), 3,
                            f"{script} keeps its own copy of the exports ({named}); it must read "
                            "scripts/cmux-next/settings-exports.txt and join READERS")

    def test_every_script_that_reads_the_list_is_named_here(self):
        """A new reader has to join READERS, so the check above covers it. The workflows and the
        router only name the path (a trigger, a route), so they are not readers."""
        found = set(git("grep", "-l", "-F", "settings-exports.txt", "--", "scripts", ".github",
                        ":!scripts/cmux-next/settings-exports.txt", ":!scripts/ci/cmux_next_route.py",
                        ":!.github").stdout.split())
        self.assertEqual(found, set(self.READERS))

    def test_the_checker_is_executable_and_routed_to_the_generated_files_job(self):
        self.assertEqual(git("ls-files", "-s", "--", "scripts/cmux-next/check-settings-exports.sh")
                         .stdout.split()[0], "100755")
        import ast
        route = ast.parse((ROOT / "scripts/ci/cmux_next_route.py").read_text(encoding="utf-8"))
        inputs = next(node.value for node in route.body
                      if isinstance(node, ast.Assign)
                      and any(getattr(t, "id", "") == "GENERATED_INPUTS" for t in node.targets))
        listed = {e.value for e in inputs.elts if isinstance(e, ast.Constant)}
        for path in ("scripts/cmux-next/check-settings-exports.sh", self.LIST):
            self.assertIn(path, listed, f"{path} changing must route to the generated-files job")


class ExportsAreComparedWithAFreshExport(unittest.TestCase):
    """The generated files job exports the settings fresh only when the event changed the settings
    sources (their derived stamps at HEAD^1 and HEAD differ), and fails when the committed copies
    differ. Any other event leaves exports the base left stale to the base autofix: a PR that only
    touched other Swift must not go red for the base's staleness (review of #23915)."""

    CHECK = "scripts/cmux-next/check-settings-exports.sh"

    def step(self) -> str:
        """The one script every `settings` step of cmux-next.yml runs: the generated-files job's and
        the daemon-test job's folded copy (CMUX_NEXT_FOLD_GENERATED). Two inline copies would drift,
        and did: the fold's was still asking `defaults_guard.py check-stamp` (review of #23915)."""
        workflow = yaml.safe_load((ROOT / ".github/workflows/cmux-next.yml").read_text(encoding="utf-8"))
        steps = [step for job in workflow["jobs"].values() for step in job.get("steps", [])
                 if step.get("id") == "settings"]
        self.assertGreaterEqual(len(steps), 1)
        self.assertEqual({step["run"].strip() for step in steps}, {self.CHECK})
        return (ROOT / self.CHECK).read_text(encoding="utf-8")

    def install_check(self, repo: Path) -> None:
        """The real script, at its real path in the fixture: it finds its export list beside
        itself, as it does in a checkout, so running its text through `bash -c` would not do."""
        target = repo / self.CHECK
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text((ROOT / self.CHECK).read_text(encoding="utf-8"))
        target.chmod(0o755)

    def run_check(self, repo: Path, env: dict) -> subprocess.CompletedProcess:
        return subprocess.run(["bash", self.CHECK], cwd=repo, env=env, capture_output=True, text=True)

    def test_the_check_runs_only_when_the_settings_sources_moved(self):
        script = self.step()
        self.assertIn('defaults_guard.py source-stamp --ref "$(git rev-parse HEAD^1)"', script)
        self.assertIn("defaults_guard.py source-stamp --ref HEAD", script)
        self.assertNotIn("generated_outputs.py caused", script)

    def test_the_check_exports_fresh_and_compares(self):
        script = self.step()
        self.assertIn("scripts/cmux-next/regenerate-settings-exports.sh", script)
        self.assertIn("s/^regenerated: //p", script)

    def test_an_unchanged_source_stamp_exports_nothing(self):
        """Run the step's own gate in a repository where HEAD changed only non-settings Swift."""
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            run = lambda *args: subprocess.run(args, cwd=repo, capture_output=True, text=True, check=True)
            run("git", "init", "-q", "-b", "main")
            run("git", "config", "user.email", "t@t")
            run("git", "config", "user.name", "t")
            (repo / "scripts/ci").mkdir(parents=True)
            (repo / "scripts/ci/defaults_guard.py").write_text(
                (ROOT / "scripts/ci/defaults_guard.py").read_text(encoding="utf-8"))
            settings = repo / "Packages/macOS/CmuxNext/Sources/CmuxNextSettings"
            settings.mkdir(parents=True)
            (settings / "A.swift").write_text("// a\n")
            tests_dir = repo / "Packages/macOS/CmuxNext/Tests/CmuxNextSettingsTests"
            tests_dir.mkdir(parents=True)
            for name in ("ManagedPreferencesManifestTests.swift", "SettingsSchemaExportTests.swift"):
                (tests_dir / name).write_text("// t\n")
            other = repo / "Packages/macOS/CmuxNext/Sources/CmuxNextApp"
            other.mkdir(parents=True)
            (other / "B.swift").write_text("// b\n")
            run("git", "add", "-A")
            run("git", "commit", "-q", "-m", "base")
            (other / "B.swift").write_text("// b, edited\n")
            run("git", "commit", "-q", "-am", "other swift")
            fake = repo / "scripts/cmux-next"
            fake.mkdir(parents=True)
            (fake / "settings-exports.txt").write_text("schemas/settings/settings-schema.json\n")
            (fake / "regenerate-settings-exports.sh").write_text("#!/bin/sh\necho EXPORTED\n")
            (fake / "regenerate-settings-exports.sh").chmod(0o755)
            self.install_check(repo)
            env = {"RUNNER_TEMP": tmp, "PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"}
            result = self.run_check(repo, env)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertNotIn("EXPORTED", result.stdout)
            (settings / "A.swift").write_text("// a, edited\n")
            run("git", "commit", "-q", "-am", "settings swift")
            result = self.run_check(repo, env)
            self.assertIn("EXPORTED", result.stdout)
            # An event that changes an export with the sources unchanged (a merge that kept older exports
            # while taking the base's sources) is checked too: the stamp alone would let it through.
            schema = repo / "schemas/settings"
            schema.mkdir(parents=True)
            (schema / "settings-schema.json").write_text("{}\n")
            run("git", "add", "-A")
            run("git", "commit", "-q", "-m", "an older export")
            result = self.run_check(repo, env)
            self.assertIn("EXPORTED", result.stdout)

    def run_step_on_merge(self, base_edit, pr_edit, env_extra=None, keep=(), swift_exit=None,
                          build_products=False, legacy=False) -> subprocess.CompletedProcess:
        """The step on a merge commit: base_edit(repo) lands on the base without an export, then
        pr_edit(repo) is the pull request; the fake export writes both exports from A.swift's text.

        `swift_exit` puts a `swift` on PATH that exits with it, for the restore's plain rebuild of
        the package; `build_products` leaves built products in the package for it to keep or remove.
        `legacy` adds a third source and export, for a pull request that removes one.

        Returns the step's result with `.repo` set, and asserts the checkout is HEAD's apart from
        the paths in `keep` (the exports the event itself leaves stale)."""
        tmp = tempfile.mkdtemp()
        self.addCleanup(subprocess.run, ["rm", "-rf", tmp])
        repo = Path(tmp) / "repo"
        repo.mkdir()
        run = lambda *args: subprocess.run(args, cwd=repo, capture_output=True, text=True, check=True)
        run("git", "init", "-q", "-b", "main")
        run("git", "config", "user.email", "t@t")
        run("git", "config", "user.name", "t")
        (repo / "scripts/ci").mkdir(parents=True)
        (repo / "scripts/ci/defaults_guard.py").write_text(
            (ROOT / "scripts/ci/defaults_guard.py").read_text(encoding="utf-8"))
        settings = repo / "Packages/macOS/CmuxNext/Sources/CmuxNextSettings"
        settings.mkdir(parents=True)
        # Two sources and two exports, as the real list has: the schema follows A.swift and the
        # docs follow B.swift. So an event can leave ONE export stale while the other is current,
        # and the base export still rewrites BOTH -- which is how a base-version export reached a
        # repair artifact when only the initially-stale files were restored.
        (settings / "A.swift").write_text("v1\n")
        (settings / "B.swift").write_text("w1\n")
        tests_dir = repo / "Packages/macOS/CmuxNext/Tests/CmuxNextSettingsTests"
        tests_dir.mkdir(parents=True)
        for name in ("ManagedPreferencesManifestTests.swift", "SettingsSchemaExportTests.swift"):
            (tests_dir / name).write_text("// t\n")
        (repo / "schemas/settings").mkdir(parents=True)
        (repo / "schemas/settings/settings-schema.json").write_text("v1\n")
        (repo / "docs/mdm").mkdir(parents=True)
        (repo / "docs/mdm/managed-preferences.md").write_text("w1\n")
        fake = repo / "scripts/cmux-next"
        fake.mkdir(parents=True)
        listed = ["schemas/settings/settings-schema.json", "docs/mdm/managed-preferences.md"]
        if legacy:
            # A third source and the export it writes, so a pull request can REMOVE one. The base
            # export runs from HEAD^1's sources, which still have LEGACY.swift, so it writes the
            # removed export back into the checkout.
            (settings / "LEGACY.swift").write_text("l1\n")
            (repo / "docs/mdm/legacy.md").write_text("l1\n")
            listed.append("docs/mdm/legacy.md")
        (fake / "settings-exports.txt").write_text("".join(f"{path}\n" for path in listed))
        # `$1` is OUT, whose basename says which call this is; the restore's is settings-head-exports.
        # The legacy export is written only while its source is there, as the real export tests do.
        # Like the real exporter, it reads its list (CMUX_SETTINGS_EXPORTS_LIST overrides it) and
        # REFUSES a file the export wrote that the list does not name: without that refusal a test
        # of a removed export cannot see the real failure.
        (fake / "regenerate-settings-exports.sh").write_text(
            "#!/bin/sh\nset -e\nsrc=Packages/macOS/CmuxNext/Sources/CmuxNextSettings\n"
            'case "${CMUX_TEST_EXPORT_FAILS_ON_RESTORE:-}${1##*/}" in\n'
            '  1settings-head-exports) echo "the export blew up" >&2; exit 7 ;;\n'
            "esac\n"
            'list="${CMUX_SETTINGS_EXPORTS_LIST:-scripts/cmux-next/settings-exports.txt}"\n'
            'cp "$src/A.swift" schemas/settings/settings-schema.json\n'
            'cp "$src/B.swift" docs/mdm/managed-preferences.md\n'
            'written="schemas/settings/settings-schema.json docs/mdm/managed-preferences.md"\n'
            'if [ -f "$src/LEGACY.swift" ]; then\n'
            '  cp "$src/LEGACY.swift" docs/mdm/legacy.md\n'
            '  written="$written docs/mdm/legacy.md"\n'
            "fi\n"
            'for f in $written; do\n'
            '  if ! grep -qxF "$f" "$list"; then\n'
            '    echo "::error::the settings export wrote $f, which the list does not name" >&2\n'
            "    exit 1\n"
            "  fi\n"
            '  git diff --quiet -- "$f" || echo "regenerated: $f"\n'
            "done\n")
        (fake / "regenerate-settings-exports.sh").chmod(0o755)
        self.install_check(repo)
        path = "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"
        if swift_exit is not None:
            fake_bin = repo / "fake-bin"
            fake_bin.mkdir()
            (fake_bin / "swift").write_text(f"#!/bin/sh\necho 'fake swift' >&2\nexit {swift_exit}\n")
            (fake_bin / "swift").chmod(0o755)
            path = f"{fake_bin}:{path}"
        run("git", "add", "-A")
        run("git", "commit", "-q", "-m", "base")
        base_edit(repo)
        run("git", "commit", "-q", "-am", "base change", "--allow-empty")
        run("git", "checkout", "-q", "-b", "pr", "HEAD~1")
        pr_edit(repo)
        run("git", "commit", "-q", "-am", "pr change")
        run("git", "checkout", "-q", "main")
        run("git", "merge", "-q", "--no-ff", "--no-edit", "pr")
        if build_products:
            products = repo / "Packages/macOS/CmuxNext/.build/debug"
            products.mkdir(parents=True)
            (products / "CmuxNextSettingsTests.xctest").write_text("built from whichever sources\n")
        env = {"RUNNER_TEMP": tmp, "PATH": path, **(env_extra or {})}
        result = self.run_check(repo, env)
        left = [line for line in run("git", "status", "--porcelain", "--untracked-files=no").stdout.splitlines()
                if not any(line.endswith(path) for path in keep)]
        self.assertEqual(left, [], "the step leaves the checkout as HEAD has it, apart from the stale exports")
        result.repo = repo
        return result

    SCHEMA = "schemas/settings/settings-schema.json"
    DOCS = "docs/mdm/managed-preferences.md"

    @staticmethod
    def write(path: str, text: str):
        return lambda repo: (repo / path).write_text(text)

    def test_base_export_lag_is_a_warning_for_a_pr_that_touches_another_settings_source(self):
        result = self.run_step_on_merge(
            self.write("Packages/macOS/CmuxNext/Sources/CmuxNextSettings/A.swift", "v2\n"),
            self.write("Packages/macOS/CmuxNext/Tests/CmuxNextSettingsTests/SettingsSchemaExportTests.swift", "// t2\n"),
            keep=(self.SCHEMA, self.DOCS))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("::warning", result.stdout)

    def test_a_pr_settings_change_without_its_export_fails_over_base_lag(self):
        result = self.run_step_on_merge(
            lambda repo: None, self.write("Packages/macOS/CmuxNext/Sources/CmuxNextSettings/A.swift", "v3\n"),
            keep=(self.SCHEMA, self.DOCS))
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("settings-schema.json", result.stdout)

    def test_a_pr_that_edits_an_export_to_a_stale_value_fails(self):
        result = self.run_step_on_merge(
            self.write("Packages/macOS/CmuxNext/Sources/CmuxNextSettings/A.swift", "v2\n"),
            self.write("schemas/settings/settings-schema.json", "hand edit\n"),
            keep=(self.SCHEMA, self.DOCS))
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)


class TheCheckoutIsHeadsAfterwards(ExportsAreComparedWithAFreshExport):
    """The check exports a SECOND time from the base parent's settings sources, in place. Both
    callers keep using the checkout afterwards, so every export it overwrote must be HEAD's fresh
    export again, not the base's: the "Regenerate stale files" step collects `git diff` of the
    export paths, and the daemon-test job runs `swift test --skip-build` after this step. The first
    version restored only the files that were stale to begin with, while the base export rewrites
    all of them (review of #23915)."""

    def exports_after(self, result) -> dict:
        return {path: (result.repo / path).read_text() for path in (self.SCHEMA, self.DOCS)}

    # The PR edits B.swift (the docs' source) AND commits the matching docs export, so the docs are
    # current at HEAD while HEAD^1 still has B.swift w1. Base edits A.swift (the schema's source)
    # without exporting. At the merge only the SCHEMA is stale, and the base export -- which reads
    # HEAD^1's B.swift -- rewrites the current docs back to w1. The docs are the file a restore of
    # just the initially-stale list leaves holding base bytes.
    @staticmethod
    def pr_edits_the_docs_source():
        def edit(repo):
            (repo / "Packages/macOS/CmuxNext/Sources/CmuxNextSettings/B.swift").write_text("w2\n")
            (repo / "docs/mdm/managed-preferences.md").write_text("w2\n")
        return edit

    def test_an_export_this_event_did_not_leave_stale_is_not_left_at_the_base_version(self):
        result = self.run_step_on_merge(
            self.write("Packages/macOS/CmuxNext/Sources/CmuxNextSettings/A.swift", "v2\n"),
            self.pr_edits_the_docs_source(), keep=(self.SCHEMA,))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        after = self.exports_after(result)
        self.assertEqual(after[self.DOCS], "w2\n", "the docs export holds the base export's bytes")
        self.assertEqual(after[self.SCHEMA], "v2\n", "the schema is not HEAD's fresh export")

    def test_the_failing_path_also_leaves_heads_fresh_exports(self):
        """`steps.settings.outcome == 'failure'` is what makes the next step collect the files, so
        the error path is the one that must not leave base bytes behind. Here the PR's own schema
        source change is unexported, so the check fails AND the docs must survive."""
        def pr_edit(repo):
            self.pr_edits_the_docs_source()(repo)
            (repo / "Packages/macOS/CmuxNext/Sources/CmuxNextSettings/A.swift").write_text("v3\n")
        result = self.run_step_on_merge(lambda repo: None, pr_edit, keep=(self.SCHEMA,))
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        after = self.exports_after(result)
        self.assertEqual(after[self.SCHEMA], "v3\n", "the schema is not HEAD's fresh export")
        self.assertEqual(after[self.DOCS], "w2\n", "the docs export holds the base export's bytes")

    def test_an_export_that_cannot_be_redone_falls_back_to_the_committed_copies(self):
        """When the re-export from HEAD's sources fails there is nothing fresh to leave, so the
        committed exports go back: collecting nothing is right, collecting the base's is not."""
        result = self.run_step_on_merge(
            self.write("Packages/macOS/CmuxNext/Sources/CmuxNextSettings/A.swift", "v2\n"),
            self.pr_edits_the_docs_source(),
            env_extra={"CMUX_TEST_EXPORT_FAILS_ON_RESTORE": "1"})
        self.assertNotEqual(result.returncode, 0)
        after = self.exports_after(result)
        self.assertEqual(after[self.SCHEMA], "v1\n", "the schema is neither HEAD's export nor the committed copy")
        self.assertEqual(after[self.DOCS], "w2\n", "the docs are neither HEAD's export nor the committed copy")

    def test_an_export_this_event_removed_does_not_come_back(self):
        """The pull request drops an export (its source, its file and its line in the list) and the
        base changes another source without exporting. The base export runs from HEAD^1's sources,
        which still have the removed source, so it writes the removed export back. Nothing in HEAD's
        list covers it, so it would stay in the checkout for the "Regenerate stale files" step's
        `docs/mdm/*` glob to collect and push: the removal undone by the repair (review of #23915)."""
        def pr_edit(repo):
            (repo / "Packages/macOS/CmuxNext/Sources/CmuxNextSettings/LEGACY.swift").unlink()
            (repo / "docs/mdm/legacy.md").unlink()
            (repo / "scripts/cmux-next/settings-exports.txt").write_text(
                "schemas/settings/settings-schema.json\ndocs/mdm/managed-preferences.md\n")
        result = self.run_step_on_merge(
            self.write("Packages/macOS/CmuxNext/Sources/CmuxNextSettings/A.swift", "v2\n"),
            pr_edit, keep=(self.SCHEMA,), legacy=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((result.repo / "docs/mdm/legacy.md").exists(),
                         "the base export put the removed export back and it was left there")

    PRODUCTS = "Packages/macOS/CmuxNext/.build"

    def run_fallback_with_swift(self, swift_exit) -> subprocess.CompletedProcess:
        """The fallback path (the re-export from HEAD's sources failed) with built products on disk
        and a `swift` that exits with `swift_exit` for the plain rebuild."""
        result = self.run_step_on_merge(
            self.write("Packages/macOS/CmuxNext/Sources/CmuxNextSettings/A.swift", "v2\n"),
            self.pr_edits_the_docs_source(),
            env_extra={"CMUX_TEST_EXPORT_FAILS_ON_RESTORE": "1"},
            swift_exit=swift_exit, build_products=True)
        self.assertNotEqual(result.returncode, 0)
        return result

    def test_products_rebuilt_from_heads_sources_on_the_fallback_path_stay(self):
        """The committed exports went back and the sources are HEAD's again, so a plain build puts
        HEAD's built products back: what runs after this step is this commit's."""
        result = self.run_fallback_with_swift(0)
        self.assertTrue((result.repo / self.PRODUCTS).exists(),
                        "a rebuild from HEAD's sources succeeded, so its products must stay")
        self.assertIn("rebuilt from HEAD's sources", result.stderr)

    def test_products_that_cannot_be_rebuilt_are_removed(self):
        """Neither the re-export nor a plain build could put HEAD's products back, so what is built
        is the base export's. The daemon-test job runs `swift test --skip-build` after this step and
        the step is continue-on-error, so leaving the products there is how base settings binaries
        pass as this commit's: `--skip-build` with nothing built fails instead (review of #23915)."""
        result = self.run_fallback_with_swift(1)
        self.assertFalse((result.repo / self.PRODUCTS).exists(),
                         "the base export's built products are still there for a --skip-build suite")
        self.assertIn("removing its built products", result.stderr)


if __name__ == "__main__":
    unittest.main()
