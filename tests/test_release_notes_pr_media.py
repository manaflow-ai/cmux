#!/usr/bin/env python3
"""scripts/cmux-next/release-notes.py --pr-media: a highlight shows the first picture of the pull
request that added it (Leo 2026-10-21, What's New design pass item 2). The picture must be one the
repository published to its pr-media branch; its bytes are hashed into the signed notes, which the
app checks before it shows them (ReleaseMediaStore.highlightData)."""
import hashlib, json, os, subprocess, sys, tempfile, unittest
import importlib.util
import threading
import urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scripts", "cmux-next", "release-notes.py")
PNG = b"\x89PNG\r\n\x1a\n" + b"\x00" * 64
MP4 = b"\x00\x00\x00\x18ftypisom\x00\x00\x00\x00isommp42"
MEDIA = "https://raw.githubusercontent.com/manaflow-ai/cmux/pr-media/pr-123/after.png"
SPEC = importlib.util.spec_from_file_location("release_notes_pr_media", SCRIPT)
release_notes = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release_notes)


class MediaURLValidationTests(unittest.TestCase):
    def test_validator_rejects_normalization_bypasses_directly(self):
        prefix = "https://raw.githubusercontent.com/manaflow-ai/cmux/pr-media/"
        self.assertTrue(release_notes.public_pr_media_url(MEDIA))
        self.assertTrue(release_notes.public_pr_media_url(prefix + "123/screen%20shot.png"))
        for path in ["../main/file.png", "./file.png", "%2e%2e/main/file.png",
                     "%252e%252e/main/file.png", "%25252e%25252e/main/file.png",
                     "%5c..%5cmain/file.png", r"\..\main/file.png",
                     "%255c..%255cmain/file.png", "%2e%2e%2fmain/file.png"]:
            with self.subTest(path=path):
                self.assertFalse(release_notes.public_pr_media_url(prefix + path))

    def test_invalid_ports_are_false_without_an_exception_wrapper(self):
        for port in ["bad", "65536", "-1"]:
            with self.subTest(port=port):
                self.assertFalse(release_notes.public_pr_media_url(
                    f"https://raw.githubusercontent.com:{port}/manaflow-ai/cmux/pr-media/file.png"))

    def test_download_refuses_redirects_without_requesting_the_destination(self):
        requests = []

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                requests.append(self.path)
                if self.path == "/image":
                    self.send_response(200)
                    self.end_headers()
                    self.wfile.write(PNG)
                else:
                    self.send_response(int(self.path[1:]))
                    self.send_header("Location", "/image")
                    self.end_headers()

        # Only a disposable loopback server: no GitHub/network fixture dependency.
        with ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
            worker = threading.Thread(target=server.serve_forever, daemon=True)
            worker.start()
            try:
                base = f"http://127.0.0.1:{server.server_port}"
                self.assertEqual(release_notes.pr_download(base + "/image", None), PNG)
                requests.clear()
                for status in [301, 302, 303, 307, 308]:
                    with self.subTest(status=status), self.assertRaises(urllib.error.HTTPError) as error:
                        release_notes.pr_download(base + f"/{status}", None)
                    self.assertEqual(error.exception.code, status)
                self.assertEqual(requests, ["/301", "/302", "/303", "/307", "/308"])
            finally:
                server.shutdown()
                worker.join(timeout=5)


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

    def test_a_public_video_is_carried_as_optional_video_media(self):
        video = MEDIA[:-4] + ".mp4"
        highlight = self.build(f'<video src="{video}"></video>', {video: MP4})
        self.assertEqual(highlight["media"][0]["kind"], "video")

    def test_a_fixed_highlight_does_not_take_pr_media(self):
        path = os.path.join(self.repo, "release-notes/next/highlights/group-colors.md")
        with open(path, "w") as f:
            f.write("title: Group labels keep their band color\ncategory: fixed\n\nA label keeps its band's color.\n")
        git(self.repo, "add", ".")
        git(self.repo, "commit", "-q", "--amend", "-m", "sidebar: group labels keep their color (#123)")
        self.head = git(self.repo, "rev-parse", "HEAD")
        self.assertEqual(self.build(f"![a]({MEDIA})", {MEDIA: PNG})["media"], [])

    def test_a_picture_from_anywhere_else_or_not_a_picture_is_left_out(self):
        other = "https://raw.githubusercontent.com/someone/fork/pr-media/after.png"
        self.assertEqual(self.build(f"![a]({other})", {other: PNG})["media"], [])
        lookalike = "https://raw.githubusercontent.com.evil.example/manaflow-ai/cmux/pr-media/after.png"
        self.assertEqual(self.build(f"![a]({lookalike})", {lookalike: PNG})["media"], [])
        self.assertEqual(self.build(f"![a]({MEDIA})", {MEDIA: b"<html>not found</html>"})["media"], [])
        self.assertEqual(self.build(f"![a]({MEDIA})", {MEDIA: PNG + b"\x00" * (4 << 20)})["media"], [])
        # A download that fails leaves the highlight without a picture, never the build without notes.
        self.assertEqual(self.build(f"![a]({MEDIA})", {})["media"], [])

    def test_dot_segments_encoded_dot_segments_and_malformed_ports_are_left_out(self):
        dot = "https://raw.githubusercontent.com/manaflow-ai/cmux/pr-media/../main/file.png"
        encoded_dot = "https://raw.githubusercontent.com/manaflow-ai/cmux/pr-media/%2e%2e/main/file.png"
        malformed_port = "https://raw.githubusercontent.com:bad/manaflow-ai/cmux/pr-media/after.png"
        self.assertEqual(self.build(f"![a]({dot})", {dot: PNG})["media"], [])
        self.assertEqual(self.build(f"![a]({encoded_dot})", {encoded_dot: PNG})["media"], [])
        self.assertEqual(self.build(f"![a]({malformed_port})", {malformed_port: PNG})["media"], [])

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
