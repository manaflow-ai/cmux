#!/usr/bin/env python3
"""Keep the Linux SwiftPM build cache rolling instead of per-commit."""

from pathlib import Path
import os
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/swift-packages-linux.yml"
sys.path.insert(0, str(ROOT / "scripts/ci"))
from pr_test_lanes import Expression, load_yaml


class SwiftPackagesLinuxCacheTests(unittest.TestCase):
    def test_restore_and_save_use_one_rolling_key(self):
        text = WORKFLOW.read_text(encoding="utf-8")
        key_lines = [line.strip() for line in text.splitlines() if "key: swiftpm-linux-" in line]
        self.assertEqual(len(key_lines), 2)
        self.assertEqual(key_lines[0], key_lines[1])
        self.assertNotIn("${{ github.sha }}", key_lines[0])

    def test_week_and_manifest_prefixes_remain_in_the_key(self):
        text = WORKFLOW.read_text(encoding="utf-8")
        key = next(line for line in text.splitlines() if "key: swiftpm-linux-" in line)
        self.assertIn("${{ steps.key.outputs.week }}", key)
        self.assertIn("${{ steps.key.outputs.toolchain }}", key)
        self.assertIn("${{ matrix.group }}", key)
        self.assertIn("${{ steps.key.outputs.manifests }}", key)

    def test_key_snapshots_checkout_manifests_without_reading_git_metadata(self):
        steps = load_yaml(WORKFLOW)["jobs"]["packages"]["steps"]
        command = next(step["run"] for step in steps if step.get("id") == "key")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            package = root / "Packages/Test package"
            package.mkdir(parents=True)
            manifest, resolved = package / "Package.swift", package / "Package.resolved"
            manifest.write_text("manifest v1")
            resolved.write_text("resolved v1")
            tools = root / "bin"
            tools.mkdir()
            swift = tools / "swift"
            swift.write_text("#!/bin/sh\nprintf 'Swift version 6.2\\n'\n")
            swift.chmod(0o755)
            git = tools / "git"
            git.write_text("#!/bin/sh\nprintf 'fatal: detected dubious ownership\\n' >&2\nexit 128\n")
            git.chmod(0o755)
            output = root / "output"
            env = {**os.environ, "PATH": str(tools) + os.pathsep + os.environ["PATH"],
                   "GITHUB_OUTPUT": str(output)}

            def key():
                output.write_text("")
                subprocess.run(["bash", "-e", "-o", "pipefail", "-c", command],
                               cwd=root, env=env, check=True, capture_output=True)
                values = dict(line.split("=", 1) for line in output.read_text().splitlines())
                self.assertIn("manifests", values)
                return values["manifests"]

            before = key()
            generated = package / ".build/checkouts/Dependency/Package.swift"
            generated.parent.mkdir(parents=True)
            generated.write_text("generated manifest")
            self.assertEqual(key(), before)
            (package / "source.swift").write_text("unrelated source")
            self.assertEqual(key(), before)
            manifest.write_text("manifest v2")
            changed = key()
            self.assertNotEqual(changed, before)
            resolved.write_text("resolved v2")
            self.assertNotEqual(key(), changed)

    def test_only_successful_pushes_seed_the_immutable_cache(self):
        steps = load_yaml(WORKFLOW)["jobs"]["packages"]["steps"]
        condition = next(step["if"] for step in steps if step.get("name") == "Save .build")

        class WithJobStatus(Expression):
            def call(self, name, args):
                if name.lower() == "success":
                    return self.context["job_succeeded"]
                return super().call(name, args)

        for event, succeeded, expected in [("push", True, True), ("push", False, False),
                                           ("pull_request", True, False), ("workflow_dispatch", True, False)]:
            for hit in ["true", "false", ""]:
                with self.subTest(event=event, job_succeeded=succeeded, cache_hit=hit):
                    context = {"github.event_name": event, "job_succeeded": succeeded,
                               "steps.build_cache.outputs.cache-hit": hit}
                    self.assertIs(WithJobStatus(condition, context).evaluate(), expected and hit != "true")

    def test_comment_documents_immutable_seed_semantics(self):
        text = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("immutable seed", text)
        self.assertNotIn("restore the newest entry", text)


if __name__ == "__main__":
    unittest.main()
