#!/usr/bin/env python3
"""CmuxMobileLinkFFI.xcframework is built once per set of inputs, not once per Mac job.

Every iOS review gate device leg built the same framework from scratch, about
3 minutes of a Mac each (run 43652999096: 3.4 min on iPhone, 2.9 on iPad),
while most app changes leave the Rust it is built from untouched. A job now
restores the framework built from the same inputs
(.github/scripts/ios_link_ffi_key.py) and builds only on a miss; a pull request
only reads the cache.

  python3 tests/test_ios_link_ffi_key.py
"""

from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / ".github/scripts"))
sys.path.insert(0, str(ROOT / "tests"))
import git_fixture_env  # noqa: E402  (fixture repositories: no auto maintenance, no inherited GIT_DIR)
import ios_link_ffi_key  # noqa: E402

BUILD = "build-xcframework.sh"
KEY_PREFIX = "ios-link-ffi-xcframework-"
# cmux-next-ios-kit.yml checks the build script itself (that it runs and leaves
# the generated Swift unchanged), so it always builds.
ALWAYS_BUILDS = {"cmux-next-ios-kit.yml"}
# The gate's legs read cmux NEXT's R2 bucket (cmux-next-fast-tier-seed.yml),
# under a namespace of their own: the key already names the Xcode build and
# the runner, and the Linux job that writes it is not the Mac that built it.
NEXT_PUBLIC_URL = "https://ci-cache-next.cmux.com"
NAMESPACE = "ios-link-ffi"
HANDOFF = "ios-link-ffi-framework"


def git(repo: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, text=True,
                          env=git_fixture_env.fixture_env()).stdout.strip()


def write(repo: Path, rel: str, text: str) -> None:
    path = repo / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def commit(repo: Path) -> str:
    git(repo, "add", "-A")
    git(repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "c", "--allow-empty")
    return git(repo, "rev-parse", "HEAD")


class KeyTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self.tmp.name)
        git_fixture_env.init_repo(self.repo)
        write(self.repo, "app/rust/Cargo.toml",
              '[workspace]\nmembers = ["ffi"]\n[patch.crates-io]\nnix = { path = "../../vendor/nix" }\n')
        write(self.repo, "app/rust/ffi/Cargo.toml",
              '[package]\nname = "ffi"\n[[bin]]\nname = "gen"\npath = "src/bin/gen.rs"\n'
              '[dependencies]\ncore = { path = "../../../core/crates/core" }\n')
        write(self.repo, "app/rust/ffi/src/lib.rs", "")
        write(self.repo, "core/Cargo.toml", '[workspace.package]\nedition = "2021"\n')
        write(self.repo, "core/crates/core/Cargo.toml",
              '[package]\nname = "core"\n[dependencies.wire]\npath = "../wire"\n')
        write(self.repo, "core/crates/core/src/lib.rs", "")
        write(self.repo, "core/crates/wire/Cargo.toml", '[package]\nname = "wire"\n')
        write(self.repo, "core/crates/wire/src/lib.rs", "")
        write(self.repo, "core/crates/unrelated/src/lib.rs", "")
        write(self.repo, "vendor/nix/Cargo.toml", '[package]\nname = "nix"\n')
        write(self.repo, "app/Sources/App.swift", "")
        self.base = commit(self.repo)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def key(self, rev: str, extra: list[str] | None = None) -> str:
        return ios_link_ffi_key.key(str(self.repo), rev, "app/rust", extra or [])[0]

    def changed(self, rel: str, text: str) -> str:
        write(self.repo, rel, text)
        return commit(self.repo)

    def test_the_same_inputs_give_the_same_key(self) -> None:
        self.assertEqual(self.key(self.base), self.key(commit(self.repo)))

    def test_a_crate_reached_through_another_crates_path_dependency_changes_the_key(self) -> None:
        self.assertNotEqual(self.key(self.base), self.key(self.changed("core/crates/wire/src/lib.rs", "fn f() {}")))

    def test_a_patched_crate_changes_the_key(self) -> None:
        self.assertNotEqual(self.key(self.base), self.key(self.changed("vendor/nix/src/lib.rs", "fn f() {}")))

    def test_the_workspace_manifest_above_a_path_crate_changes_the_key(self) -> None:
        self.assertNotEqual(self.key(self.base), self.key(self.changed("core/Cargo.toml", '[workspace.package]\nedition = "2024"\n')))

    def test_a_crate_inherited_from_the_workspace_by_path_changes_the_key(self) -> None:
        # `name.workspace = true` (and the inline-table form) resolves through the
        # workspace root's [workspace.dependencies], which may name a path.
        self.changed("core/Cargo.toml", '[workspace]\nmembers = ["crates/*"]\n[workspace.dependencies]\n'
                     'serde = "1"\nshared = { path = "crates/shared" }\n[workspace.dependencies.table]\npath = "crates/table"\n')
        self.changed("core/crates/shared/src/lib.rs", "")
        self.changed("core/crates/table/src/lib.rs", "")
        rev = self.changed("core/crates/wire/Cargo.toml",
                           '[package]\nname = "wire"\n[dependencies]\nshared.workspace = true\n'
                           'table = { workspace = true, features = ["x"] }\nserde.workspace = true\n')
        self.assertNotEqual(self.key(rev), self.key(self.changed("core/crates/shared/src/lib.rs", "fn f() {}")))
        rev = git(self.repo, "rev-parse", "HEAD")
        self.assertNotEqual(self.key(rev), self.key(self.changed("core/crates/table/src/lib.rs", "fn f() {}")))

    def test_a_toolchain_file_above_a_crate_changes_the_key(self) -> None:
        self.assertNotEqual(self.key(self.base), self.key(self.changed("rust-toolchain.toml", '[toolchain]\nchannel = "1.0"\n')))

    def test_app_code_and_unreached_crates_keep_the_key(self) -> None:
        self.changed("app/Sources/App.swift", "let x = 1")
        rev = self.changed("core/crates/unrelated/src/lib.rs", "fn f() {}")
        self.assertEqual(self.key(self.base), self.key(rev))

    def test_the_xcode_build_is_part_of_the_key(self) -> None:
        self.assertNotEqual(self.key(self.base, ["xcode=17A"]), self.key(self.base, ["xcode=17B"]))

    def test_a_path_outside_the_repository_is_refused(self) -> None:
        rev = self.changed("app/rust/ffi/Cargo.toml", '[dependencies]\nx = { path = "../../../../outside" }\n')
        with self.assertRaises(SystemExit):
            self.key(rev)

    def test_the_real_workspace_reaches_the_cmux_tui_crates_it_links(self) -> None:
        rev = git(ROOT, "rev-parse", "HEAD")
        _, lines = ios_link_ffi_key.key(str(ROOT), rev, "cmux-next-ios/rust", [])
        trees = {line.split()[1] for line in lines if line.startswith("tree ")}
        self.assertIn("cmux-next-ios/rust", trees)
        self.assertIn("cmux-tui/crates/cmux-transport", trees)
        self.assertIn("cmux-tui/vendor/smoltcp", trees)
        self.assertIn("file cmux-tui/Cargo.toml", "\n".join(lines))


def run_text(step: dict) -> str:
    return str(step.get("run", ""))


def is_ffi_key(step: dict) -> bool:
    return str(step.get("with", {}).get("key", "")).startswith(KEY_PREFIX)


def is_restore(step: dict) -> bool:
    uses = str(step.get("uses", ""))
    return is_ffi_key(step) and (uses.startswith("actions/cache/restore@") or uses.startswith("./.github/actions/cache-restore"))


def is_save(step: dict) -> bool:
    uses = str(step.get("uses", ""))
    return is_ffi_key(step) and (uses.startswith("actions/cache/save@") or uses.startswith("./.github/actions/cache-save"))


def gate() -> dict:
    return yaml.safe_load((ROOT / ".github/workflows/ios-review-gate.yml").read_text(encoding="utf-8"))


class WorkflowTests(unittest.TestCase):
    """Every job that builds the framework restores it first, builds only on a
    miss, and saves only outside pull requests."""

    def builders(self) -> list[tuple[str, str, list[dict]]]:
        found = []
        for path in sorted((ROOT / ".github/workflows").glob("*.yml")):
            doc = yaml.safe_load(path.read_text(encoding="utf-8"))
            for name, job in (doc.get("jobs") or {}).items():
                steps = job.get("steps") or []
                if any(BUILD in run_text(s) for s in steps):
                    found.append((path.name, name, steps))
        return found

    def test_every_builder_restores_by_the_input_key_and_builds_only_on_a_miss(self) -> None:
        for workflow, job, steps in self.builders():
            if workflow in ALWAYS_BUILDS:
                continue
            with self.subTest(workflow=workflow, job=job):
                build_at = next(i for i, s in enumerate(steps) if BUILD in run_text(s))
                key_steps = [i for i, s in enumerate(steps) if "ios_link_ffi_key.py" in run_text(s)]
                restores = [i for i, s in enumerate(steps) if is_restore(s)]
                self.assertTrue(key_steps and key_steps[0] < build_at, "the key is computed before the build")
                # A key that cannot be computed means a build, never a red job.
                self.assertIn("::warning::", run_text(steps[key_steps[0]]), "a failed key falls back to building")
                self.assertTrue(restores and restores[0] < build_at, "the framework is restored before the build")
                restore_id = steps[restores[0]].get("id")
                self.assertTrue(restore_id, "the restore step has an id the build reads")
                miss = f"steps.{restore_id}.outputs.cache-hit != 'true'"
                for step in steps[restores[0]:build_at + 1]:
                    if step.get("name") in ("Set up pinned Rust", "Cache cargo") or BUILD in run_text(step):
                        self.assertIn(miss, str(step.get("if", "")), f"'{step.get('name')}' runs only on a miss")

    def test_a_pull_request_never_saves_the_framework(self) -> None:
        for path in sorted((ROOT / ".github/workflows").glob("*.yml")):
            doc = yaml.safe_load(path.read_text(encoding="utf-8"))
            for job_name, job in (doc.get("jobs") or {}).items():
                for step in job.get("steps") or []:
                    if not is_save(step):
                        continue
                    with self.subTest(workflow=path.name, job=job_name):
                        condition = f"{job.get('if', '')} {step.get('if', '')}"
                        self.assertTrue("github.event_name != 'pull_request'" in condition
                                        or "github.event_name == 'push'" in condition, condition)
                        self.assertIs(step.get("continue-on-error"), True, "a lost save race never fails the job")

    # The Blacksmith Macs' GitHub cache store kept none of the gate's saves
    # for a later run (runs 43708277177, 43715850653, 43718931581 and
    # 43721191135 each saved key 01bde7d8, and the next push missed it), so
    # the legs read the repository's R2 store, which every runner reaches
    # without a credential.
    def test_the_review_gate_legs_read_the_framework_from_r2(self) -> None:
        steps = gate()["jobs"]["reviewer-path"]["steps"]
        restores = [s for s in steps if is_restore(s)]
        self.assertEqual(len(restores), 1)
        restore = restores[0]
        self.assertTrue(str(restore["uses"]).startswith("./.github/actions/cache-restore"))
        self.assertEqual(restore["with"].get("backend"), "r2")
        env = restore.get("env") or {}
        self.assertEqual(env.get("CI_CACHE_R2_PUBLIC_URL"), NEXT_PUBLIC_URL)
        self.assertEqual(env.get("CI_CACHE_R2_NAMESPACE"), NAMESPACE)
        # One directory per R2 entry: the framework and its generated Swift
        # are restored beside each other and moved into place on a hit.
        at = steps.index(restore)
        build_at = next(i for i, s in enumerate(steps) if BUILD in run_text(s))
        hit = f"steps.{restore['id']}.outputs.cache-hit == 'true'"
        placed = [s for s in steps[at + 1:build_at] if hit in str(s.get("if", ""))]
        self.assertTrue(placed and restore["with"]["path"].split("/")[-1] in run_text(placed[0])
                        and "CmuxMobileLinkFFI.swift" in run_text(placed[0]) and ".xcframework" in run_text(placed[0]),
                        "a hit moves the framework and its Swift into the app")
        self.assertFalse([s for s in steps if is_save(s)],
                         "the legs never hold the bucket's write credentials")

    def test_a_feat_cmux_next_run_seeds_r2_from_a_linux_job(self) -> None:
        jobs = gate()["jobs"]
        legs = jobs["reviewer-path"]["steps"]
        uploads = [s for s in legs if str(s.get("uses", "")).startswith("actions/upload-artifact@")
                   and str(s.get("with", {}).get("name", "")) == HANDOFF]
        self.assertEqual(len(uploads), 1, "a leg that built the framework hands it to the writer")
        self.assertIn("cache-hit != 'true'", str(uploads[0].get("if", "")))
        self.assertIs(uploads[0].get("continue-on-error"), True)
        writers = [(name, job) for name, job in jobs.items() if any(is_save(s) for s in job.get("steps") or [])]
        self.assertEqual(len(writers), 1)
        name, job = writers[0]
        self.assertIn("reviewer-path", job.get("needs", []))
        self.assertNotIn("macos", str(job.get("runs-on", "")), "the writer takes no Mac")
        self.assertEqual(job.get("environment"), "${{ github.ref == 'refs/heads/feat-cmux-next' && 'next-cache-writer' || '' }}")
        self.assertEqual((job.get("env") or {}).get("CI_CACHE_R2_BUCKET"), "cmux-ci-cache-next")
        self.assertIn("refs/heads/feat-cmux-next", str(job.get("if", "")))
        steps = job["steps"]
        downloads = [s for s in steps if str(s.get("uses", "")).startswith("actions/download-artifact@")]
        self.assertTrue(downloads and downloads[0].get("with", {}).get("name") == HANDOFF)
        save = next(s for s in steps if is_save(s))
        self.assertTrue(str(save["uses"]).startswith("./.github/actions/cache-save"))
        self.assertEqual(save["with"].get("backend"), "r2")
        self.assertEqual({**(job.get("env") or {}), **(save.get("env") or {})}.get("CI_CACHE_R2_NAMESPACE"), NAMESPACE)
        # r2-cache.sh save treats a missing public URL as "nothing saved", and exits 0.
        self.assertEqual({**(job.get("env") or {}), **(save.get("env") or {})}.get("CI_CACHE_R2_PUBLIC_URL"), NEXT_PUBLIC_URL)
        # Only a push seeds: a dispatch can name any source (inputs.ref, even a
        # fork's commit), and what it built would then be restored by every leg.
        self.assertIn("github.event_name == 'push'", str(job.get("if", "")))
        self.assertIn("github.event_name == 'push'", str(uploads[0].get("if", "")))
        # A seed that fails never turns the push run red.
        self.assertIs(job.get("continue-on-error"), True)
        # Only the save step reads the write credentials.
        for step in steps:
            if step is not save:
                self.assertNotIn("secrets.", str(step), f"'{step.get('name')}' reads no secret")


if __name__ == "__main__":
    unittest.main(verbosity=2)
