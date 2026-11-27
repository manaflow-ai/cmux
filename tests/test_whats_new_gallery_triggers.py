#!/usr/bin/env python3
"""whats-new-gallery.yml runs on nightly-next pushes too, so a highlight an earlier run failed to
render gets another try on the next promote (run 45963430187 failed and nothing retried it)."""
import os, re, unittest

WORKFLOW = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".github", "workflows", "whats-new-gallery.yml")


class GalleryTriggerTests(unittest.TestCase):
    def test_push_runs_on_feat_cmux_next_and_nightly_next(self):
        text = open(WORKFLOW).read()
        on = text.split("\non:\n", 1)[1].split("\npermissions:", 1)[0]
        branches = re.search(r"^  push:\n(?:    #.*\n)*    branches: \[([^\]]*)\]", on, re.M)
        self.assertIsNotNone(branches, on)
        names = {b.strip() for b in branches.group(1).split(",")}
        self.assertTrue({"feat-cmux-next", "nightly-next"} <= names, names)

    def test_publish_environment_admits_every_push_branch(self):
        # publish runs in pr-media, which admits only main, feat-cmux-next and nightly-next.
        text = open(WORKFLOW).read()
        self.assertIn("environment: pr-media", text)
        self.assertIn("(main, feat-cmux-next, nightly-next)", text)

    def test_one_broken_gallery_file_costs_only_its_own_pictures(self):
        # 2026-11-27: one duplicate `const` in ClaudeConnectRow.gallery.tsx failed 10 runs (05:14Z to 08:18Z), so four
        # Improved highlights shipped in nightly 4598742452601 with no picture. Every step that loads the gallery
        # files skips one that fails to load (entries.ts loadEntrySources), and each build compiles only the entries
        # it renders (CMUX_GALLERY_ENTRIES), never the whole gallery.
        render = open(WORKFLOW).read().split("- name: Render the gallery states", 1)[1].split("\n      - name:", 1)[0]
        loads = re.findall(r"bun scripts/gallery/(?:manifest|notes)\.ts[^\n]*", render)
        self.assertEqual(len(loads), 3, loads)
        for line in loads:
            self.assertIn("--skip-broken", line)
        builds = re.findall(r"(?:^|\n)([^\n]*\n)?([^\n]*bun run gallery:build[^\n]*)", render)
        self.assertEqual(len(builds), 2, builds)
        for before, line in builds:
            self.assertIn("CMUX_GALLERY_ENTRIES=", (before or "") + line)


if __name__ == "__main__":
    unittest.main()
