#!/usr/bin/env python3
"""scripts/cmux-next/release-notes.py --pr-media: a highlight shows the first picture of the pull
request that added it (Leo 2026-10-21, What's New design pass item 2). The picture must be one the
repository published to its pr-media branch; its bytes are hashed into the signed notes, which the
app checks before it shows them (ReleaseMediaStore.highlightData)."""
import hashlib, json, os, subprocess, sys, tempfile, unittest

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scripts", "cmux-next", "release-notes.py")
PNG = b"\x89PNG\r\n\x1a\n" + b"\x00" * 64
MEDIA = "https://raw.githubusercontent.com/manaflow-ai/cmux/pr-media/pr-123/after.png"


def git(cwd, *args):
    return subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True, check=True).stdout.strip()


class PullRequestMediaTests(unittest.TestCase):
    def setUp(self):
        self.repo = tempfile.mkdtemp()
        git(self.repo, "init", "-q")
        git(self.repo, "config", "user.email", "t@example.com")
        git(self.repo, "config", "user.name", "t")
        git(self.repo, "commit", "-q", "--allow-empty", "-m", "base")
        self.base = git(self.repo, "rev-parse", "HEAD")
        os.makedirs(os.path.join(self.repo, "release-notes/next/highlights"))
        with open(os.path.join(self.repo, "release-notes/next/highlights/group-colors.md"), "w") as f:
            f.write("title: Group labels keep their band color\ncategory: improved\n\nA label keeps its band's color.\n")
        git(self.repo, "add", ".")
        git(self.repo, "commit", "-q", "-m", "sidebar: group labels keep their color (#123)")
        self.head = git(self.repo, "rev-parse", "HEAD")

    def build(self, body, files=None, pr_media=True):
        """The notes, with the pull request bodies and downloads served from a fixture."""
        fixture = os.path.join(self.repo, "fixture.json")
        stored = {}
        for url, data in (files or {}).items():
            path = os.path.join(self.repo, hashlib.sha256(url.encode()).hexdigest())
            with open(path, "wb") as f:
                f.write(data)
            stored[url] = path
        with open(fixture, "w") as f:
            json.dump({"bodies": {"123": body}, "files": stored}, f)
        out = os.path.join(self.repo, "out")
        args = [sys.executable, SCRIPT, "build", "--build", "2", "--short", "1.0.0-nightly.2", "--date", "2026-10-21",
                "--head", self.head, "--since", self.base, "--out", out] + (["--pr-media"] if pr_media else [])
        env = {**os.environ, "CMUX_RELEASE_NOTES_PR_FIXTURE": fixture}
        subprocess.run(args, cwd=self.repo, capture_output=True, text=True, check=True, env=env)
        with open(os.path.join(out, "2.json")) as f:
            return json.load(f)["highlights"][0]

    def test_a_highlight_takes_the_first_pr_media_picture_of_its_pull_request(self):
        body = f"## Summary\n\nBefore:\n![before](https://example.com/before.png)\n\nAfter:\n![after]({MEDIA})\n"
        highlight = self.build(body, {MEDIA: PNG})
        self.assertEqual(highlight["media"], [{
            "url": MEDIA, "sha256": hashlib.sha256(PNG).hexdigest(), "kind": "image",
            "alt": "Group labels keep their band color",
        }])

    def test_an_html_img_tag_counts_too(self):
        highlight = self.build(f'<img width="600" alt="after" src="{MEDIA}">', {MEDIA: PNG})
        self.assertEqual(highlight["media"][0]["url"], MEDIA)

    def test_a_picture_from_anywhere_else_or_not_a_picture_is_left_out(self):
        other = "https://raw.githubusercontent.com/someone/fork/pr-media/after.png"
        self.assertEqual(self.build(f"![a]({other})", {other: PNG})["media"], [])
        self.assertEqual(self.build(f"![a]({MEDIA})", {MEDIA: b"<html>not found</html>"})["media"], [])
        self.assertEqual(self.build(f"![a]({MEDIA})", {MEDIA: PNG + b"\x00" * (4 << 20)})["media"], [])
        # A download that fails leaves the highlight without a picture, never the build without notes.
        self.assertEqual(self.build(f"![a]({MEDIA})", {})["media"], [])

    def test_a_download_that_raises_leaves_the_highlight_without_a_picture(self):
        # The fixture names a file that is not there, so reading it raises, as a timeout or a URL
        # urllib rejects would: the notes still build.
        fixture = os.path.join(self.repo, "fixture.json")
        with open(fixture, "w") as f:
            json.dump({"bodies": {"123": f"![a]({MEDIA})"}, "files": {MEDIA: os.path.join(self.repo, "missing")}}, f)
        out = os.path.join(self.repo, "out")
        subprocess.run([sys.executable, SCRIPT, "build", "--build", "2", "--short", "1.0.0-nightly.2", "--date",
                        "2026-10-21", "--head", self.head, "--since", self.base, "--out", out, "--pr-media"],
                       cwd=self.repo, capture_output=True, text=True, check=True,
                       env={**os.environ, "CMUX_RELEASE_NOTES_PR_FIXTURE": fixture})
        with open(os.path.join(out, "2.json")) as f:
            self.assertEqual(json.load(f)["highlights"][0]["media"], [])

    def test_without_the_flag_nothing_is_fetched(self):
        self.assertEqual(self.build(f"![a]({MEDIA})", {MEDIA: PNG}, pr_media=False)["media"], [])


if __name__ == "__main__":
    unittest.main()
