#!/usr/bin/env python3
"""scripts/cmux-next/release-notes.py: a highlight's `clip:` line (whats-new-clips.py publish) becomes its
media, captioned by its clip spec, ahead of the pull request's picture; a clip added to a recent
highlight rides along with the next build so an update shows the item again with its clip."""
import json, os, subprocess, sys, tempfile, unittest

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scripts", "cmux-next", "release-notes.py")
SHA = "a" * 64
CLIP = "https://raw.githubusercontent.com/manaflow-ai/cmux/pr-media/whats-new/sidebar-archive/0123456789ab.webp"
HIGHLIGHT = "release-notes/next/highlights/sidebar-archive.md"
TEXT = ("title: Archive sidebar workspaces\ncategory: new\naction: workspace.toggleArchive | Archive\n{clip}\n\n"
        "Right-click a workspace and choose Archive.\n")


def git(cwd, *args, env=None):
    return subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True, check=True,
                          env={**os.environ, **(env or {})}).stdout.strip()


class ClipTests(unittest.TestCase):
    def setUp(self):
        self.repo = tempfile.mkdtemp()
        git(self.repo, "init", "-q")
        git(self.repo, "config", "user.email", "t@example.com")
        git(self.repo, "config", "user.name", "t")
        git(self.repo, "commit", "-q", "--allow-empty", "-m", "base")
        self.base = git(self.repo, "rev-parse", "HEAD")
        os.makedirs(os.path.join(self.repo, "release-notes/next/highlights"))
        os.makedirs(os.path.join(self.repo, "release-notes/next/clips"))

    def commit(self, clip_line, message, date=None, spec=None):
        with open(os.path.join(self.repo, HIGHLIGHT), "w") as f:
            f.write(TEXT.format(clip=clip_line))
        if spec is not None:
            with open(os.path.join(self.repo, "release-notes/next/clips/sidebar-archive.json"), "w") as f:
                json.dump(spec, f)
        git(self.repo, "add", ".")
        env = {"GIT_AUTHOR_DATE": date, "GIT_COMMITTER_DATE": date} if date else None
        git(self.repo, "commit", "-q", "-m", message, env=env)
        return git(self.repo, "rev-parse", "HEAD")

    def build(self, since, head, check=True):
        out = os.path.join(self.repo, "out")
        done = subprocess.run([sys.executable, SCRIPT, "build", "--build", "2", "--short", "1.0.0-nightly.2",
                               "--date", "2026-10-25", "--head", head, "--since", since, "--out", out],
                              cwd=self.repo, capture_output=True, text=True, check=check)
        if not check:
            return done
        with open(os.path.join(out, "2.json")) as f:
            return json.load(f)["highlights"]

    def test_a_clip_line_is_the_highlights_media_with_its_specs_caption(self):
        head = self.commit(f"clip: {CLIP} | {SHA}", "sidebar: archive (#1)",
                           spec={"caption": "Right-click a workspace and archive it."})
        [highlight] = self.build(self.base, head)
        self.assertEqual(highlight["media"], [{"url": CLIP, "sha256": SHA, "kind": "image",
                                               "alt": "Right-click a workspace and archive it."}])
        self.assertNotIn("clip", highlight)

    def test_without_a_spec_the_title_is_the_alt(self):
        head = self.commit(f"clip: {CLIP} | {SHA}", "sidebar: archive (#1)")
        self.assertEqual(self.build(self.base, head)[0]["media"][0]["alt"], "Archive sidebar workspaces")

    def test_a_clip_from_anywhere_else_is_left_out_and_the_notes_still_build(self):
        for line in (f"clip: https://example.com/a.webp | {SHA}", f"clip: {CLIP}", f"clip: {CLIP} | xyz", "clip:"):
            head = self.commit(line, "sidebar: archive (#1)")
            done = self.build(self.base, head, check=False)
            self.assertEqual(done.returncode, 0, line)
            self.assertIn("left out", done.stderr)
            with open(os.path.join(self.repo, "out", "2.json")) as f:
                self.assertEqual(json.load(f)["highlights"][0]["media"], [], line)

    def test_a_clip_added_to_a_recent_highlight_comes_with_the_next_build(self):
        first = self.commit("", "sidebar: archive (#1)")
        self.assertEqual(self.build(self.base, first)[0]["media"], [])
        second = self.commit(f"clip: {CLIP} | {SHA}", "release-notes: a clip for archive")
        [again] = self.build(first, second)
        self.assertEqual(again["id"], "sidebar-archive")
        self.assertEqual(again["media"][0]["url"], CLIP)
        # The What's New digest has it too, so the build passes the release gate.
        with open(os.path.join(self.repo, "out", "2.json")) as f:
            entries = json.load(f)["whatsNew"]["entries"]
        self.assertEqual([e["id"] for e in entries], ["sidebar-archive"])
        gate = subprocess.run([sys.executable, SCRIPT, "check", "--notes", os.path.join(self.repo, "out", "2.json")],
                              cwd=self.repo, capture_output=True, text=True)
        self.assertEqual(gate.returncode, 0, gate.stderr)
        # Nothing else changed in the highlight after that: the build after has no highlight.
        git(self.repo, "commit", "-q", "--allow-empty", "-m", "later")
        self.assertEqual(self.build(second, git(self.repo, "rev-parse", "HEAD")), [])
        # A new title over the same clip announces nothing again.
        path = os.path.join(self.repo, HIGHLIGHT)
        with open(path) as f:
            text = f.read()
        with open(path, "w") as f:
            f.write(text.replace("title: Archive sidebar workspaces", "title: Archive workspaces"))
        git(self.repo, "commit", "-qam", "release-notes: retitle archive")
        self.assertEqual(self.build(second, git(self.repo, "rev-parse", "HEAD")), [])

    def test_an_old_highlight_is_not_announced_again(self):
        first = self.commit("", "sidebar: archive (#1)", date="2026-09-01T12:00:00Z")
        second = self.commit(f"clip: {CLIP} | {SHA}", "release-notes: a clip for archive")
        self.assertEqual(self.build(first, second), [])


if __name__ == "__main__":
    unittest.main()
