#!/usr/bin/env python3
"""Every published cmux-tui manifest carries acpmux for the Linux musl targets.

cmux Cloud machines install acpmux beside the daemon from the cmux-tui manifest
(web/services/vms/drivers/cmuxTuiDaemon.ts, cloud-subagents-DESIGN.md B9), and
the devbox bake refuses a manifest without it (requireCmuxTuiAcpmux). The
commit-addressed manifest and the rolling latest/ manifest are therefore
verified to list acpmux, so a publish that drops it fails in CI instead of in
the next image bake.
"""
from __future__ import annotations

import importlib.util
import re
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/cmux-tui-artifacts.yml"
VERIFY_SCRIPT = ROOT / "cmux-tui/scripts/verify_published_manifest.py"
ACPMUX = ("cmux-tui-acpmux-x86_64-unknown-linux-musl", "cmux-tui-acpmux-aarch64-unknown-linux-musl")
MANIFEST_URL = re.compile(r'--manifest-url "https://files\.cmux\.com/cmux-tui/(\$GITHUB_SHA|latest)/manifest\.json[^"]*"')


def verify_calls() -> dict[str, str]:
    step = WORKFLOW.read_text(encoding="utf-8")
    step = step[step.index("- name: Verify published Unix manifests"):]
    step = step[: step.index("\n      - name:", 1) if "\n      - name:" in step[1:] else len(step)]
    calls: dict[str, str] = {}
    lines = step.splitlines()
    for i, line in enumerate(lines):
        match = MANIFEST_URL.search(line)
        if not match:
            continue
        body = [line]
        while body[-1].rstrip().endswith("\\") and i + len(body) < len(lines):
            body.append(lines[i + len(body)])
        calls[match.group(1)] = "\n".join(body)
    return calls


class LatestAcpmux(unittest.TestCase):
    def test_commit_and_latest_manifests_require_linux_acpmux(self) -> None:
        calls = verify_calls()
        self.assertEqual(set(calls), {"$GITHUB_SHA", "latest"}, "verify step lost a cmux-tui manifest check")
        for prefix, body in calls.items():
            for artifact in ACPMUX:
                with self.subTest(manifest=prefix, artifact=artifact):
                    self.assertIn(f"--require-artifact {artifact}", body)

    def test_a_manifest_without_acpmux_fails_the_check(self) -> None:
        spec = importlib.util.spec_from_file_location("verify_published_manifest", VERIFY_SCRIPT)
        assert spec is not None and spec.loader is not None
        verify = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(verify)
        commit = "2d6f4b2c598b85f15b493925f2273088c1b1a1d4"
        # The live latest/manifest.json shape on 2026-10-20: daemon and hook, no acpmux.
        latest = {"commit": commit, "binaries": {
            "cmux-tui-x86_64-unknown-linux-musl": "e" * 64,
            "cmux-tui-hook-x86_64-unknown-linux-musl": "4" * 64,
        }}
        with self.assertRaises(verify.ManifestError):
            verify._validate_manifest(latest, source="latest", expected_commit=commit, required_artifacts=ACPMUX)
        latest["binaries"].update({name: "a" * 64 for name in ACPMUX})
        verify._validate_manifest(latest, source="latest", expected_commit=commit, required_artifacts=ACPMUX)

    def test_the_pre_latest_check_runs_only_where_latest_is_published(self) -> None:
        # Off main the post-publish check covers the same immutable manifests,
        # so the pre-latest one only added 75 s to every feat-cmux-next publish.
        steps = {s.get("name"): s for s in yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]["publish"]["steps"]}
        before = steps["Verify immutable Unix manifests before latest publish"]
        self.assertEqual(before.get("if"), steps["Publish rolling latest artifacts"].get("if"))
        after = steps["Verify published Unix manifests"]
        self.assertNotIn("if", after)

        def calls(run: str) -> dict[str, set[str]]:
            found: dict[str, set[str]] = {}
            for call in run.replace("\\\n", " ").split("verify_published_manifest.py")[1:]:
                url = re.search(r'--manifest-url "([^"?]+)', call).group(1)
                found[url] = set(re.findall(r"--(?:require|forbid)-artifact \S+|--require-provenance|--machine-manifest", call))
            return found

        before_calls, after_calls = calls(before["run"]), calls(after["run"])
        self.assertTrue(before_calls)
        for url, checks in before_calls.items():
            with self.subTest(manifest=url):
                self.assertIn(url, after_calls)
                self.assertLessEqual(checks, after_calls[url])

if __name__ == "__main__":
    unittest.main()
