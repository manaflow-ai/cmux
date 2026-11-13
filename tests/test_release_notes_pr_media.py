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
# tests/git_fixture_env.py, loaded by path: `python3 -I` puts no script folder on sys.path.
import importlib.util as _git_fixture_importlib  # noqa: E402
from os import path as _git_fixture_path  # noqa: E402
_git_fixture_spec = _git_fixture_importlib.spec_from_file_location(
    "git_fixture_env", _git_fixture_path.join(_git_fixture_path.dirname(_git_fixture_path.abspath(__file__)), "git_fixture_env.py"))
git_fixture_env = _git_fixture_importlib.module_from_spec(_git_fixture_spec)
_git_fixture_spec.loader.exec_module(git_fixture_env)

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


class HighlightRepo(unittest.TestCase):
    """A repo whose one commit (#123) adds an Improved highlight, and its notes built from a fixture."""

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



class PullRequestMediaTests(HighlightRepo):
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


class GalleryPictureTests(HighlightRepo):
    """A highlight's `gallery:` and `before:` states, rendered by media/whats-new-gallery.py on merge, are
    its picture and its before; they win over the pull request body's picture."""
    AFTER = "agent-pane.composer/streaming"
    BEFORE = "agent-pane.composer/streaming-old"

    def set_highlight(self, lines):
        path = os.path.join(self.repo, "release-notes/next/highlights/group-colors.md")
        with open(path, "w") as f:
            f.write("title: Group labels keep their band color\ncategory: improved\n" + lines
                    + "\nA label keeps its band's color.\n")
        git(self.repo, "add", ".")
        git(self.repo, "commit", "-q", "--amend", "-m", "sidebar: group labels keep their color (#123)")
        self.head = git(self.repo, "rev-parse", "HEAD")

    def url(self, role, state):
        return release_notes.gallery_url("group-colors", role, state)

    def test_the_state_and_its_before_are_the_media_with_roles_picture_first(self):
        self.set_highlight(f"gallery: {self.AFTER}\nbefore: {self.BEFORE}\n")
        before_png = PNG + b"before"
        after, before = self.url("after", self.AFTER), self.url("before", self.BEFORE)
        highlight = self.build(f"![a]({MEDIA})", {after: PNG, before: before_png, MEDIA: PNG})
        self.assertEqual(highlight["media"], [
            {"url": after, "sha256": hashlib.sha256(PNG).hexdigest(), "kind": "image",
             "alt": "Group labels keep their band color", "role": "after"},
            {"url": before, "sha256": hashlib.sha256(before_png).hexdigest(), "kind": "image",
             "alt": "Before: Group labels keep their band color", "role": "before"},
        ])
        self.assertTrue(after.startswith(release_notes.CLIP_PREFIX + "group-colors/gallery-"))
        self.assertTrue(release_notes.public_pr_media_url(after))

    def test_a_state_alone_is_one_picture_without_a_role(self):
        self.set_highlight(f"gallery: {self.AFTER}\nbefore: {self.BEFORE}\n")
        highlight = self.build("", {self.url("after", self.AFTER): PNG})
        self.assertEqual([m.get("role") for m in highlight["media"]], [None])

    def test_an_unpublished_state_falls_back_to_the_pull_request_picture(self):
        self.set_highlight(f"gallery: {self.AFTER}\n")
        self.assertEqual(self.build(f"![a]({MEDIA})", {MEDIA: PNG})["media"][0]["url"], MEDIA)

    def test_with_no_line_an_improvement_takes_the_picked_state_and_the_one_before_it(self):
        auto = lambda role: release_notes.gallery_auto_url("group-colors", role)
        before_png = PNG + b"before"
        highlight = self.build(f"![a]({MEDIA})", {auto("after"): PNG, auto("before"): before_png, MEDIA: PNG})
        self.assertEqual([(m["url"], m["role"]) for m in highlight["media"]],
                         [(auto("after"), "after"), (auto("before"), "before")])
        self.assertTrue(release_notes.public_pr_media_url(auto("after")))

    def test_a_named_state_without_a_before_takes_the_one_at_the_commit_before(self):
        self.set_highlight(f"gallery: {self.AFTER}\n")
        auto_before = release_notes.gallery_auto_url("group-colors", "before")
        highlight = self.build("", {self.url("after", self.AFTER): PNG, auto_before: PNG + b"before"})
        self.assertEqual([(m["url"], m["role"]) for m in highlight["media"]],
                         [(self.url("after", self.AFTER), "after"), (auto_before, "before")])

    def test_only_an_improvement_gets_a_before_it_did_not_name(self):
        urls = release_notes.gallery_urls
        auto = lambda role: release_notes.gallery_auto_url("h", role)
        self.assertEqual(urls({}, "h", "new"), {"after": auto("after")})
        self.assertEqual(urls({}, "h", "improved"), {"after": auto("after"), "before": auto("before")})
        self.assertEqual(urls({}, "h", "fixed"), {})
        self.assertEqual(urls({"gallery": self.AFTER, "before": self.BEFORE}, "h", "improved"),
                         {"after": release_notes.gallery_url("h", "after", self.AFTER),
                          "before": release_notes.gallery_url("h", "before", self.BEFORE)})

    def test_states_parse_strictly(self):
        states = release_notes.gallery_states
        self.assertEqual(states({"gallery": self.AFTER, "before": self.BEFORE}),
                         {"after": self.AFTER, "before": self.BEFORE})
        self.assertEqual(states({"before": self.BEFORE}), {})
        self.assertEqual(states({"gallery": "../x/y"}), {})
        self.assertEqual(states({"gallery": "no-variant"}), {})
        self.assertNotEqual(self.url("after", self.AFTER), self.url("after", self.BEFORE))


WEBP = b"RIFF\x00\x00\x00\x00WEBPVP8 " + b"\x00" * 32


class RecordedClipTests(HighlightRepo):
    """A clip the nightly tour recorded from the highlight's spec (whats-new-clips.py publish-auto), and for an
    improvement its before on the previous nightly's app, win over the gallery pictures, role by role."""

    def clip(self, role):
        return release_notes.clip_auto_url("group-colors", role)

    def gallery(self, role):
        return release_notes.gallery_auto_url("group-colors", role)

    def test_a_recorded_clip_and_its_before_are_the_media(self):
        highlight = self.build("", {self.clip("after"): WEBP, self.clip("before"): WEBP + b"b",
                                    self.gallery("after"): PNG, self.gallery("before"): PNG})
        self.assertEqual([(m["url"], m["role"], m["kind"]) for m in highlight["media"]],
                         [(self.clip("after"), "after", "image"), (self.clip("before"), "before", "image")])
        self.assertTrue(release_notes.public_pr_media_url(self.clip("after")))

    def test_a_role_with_no_clip_takes_the_gallery_picture(self):
        highlight = self.build("", {self.clip("after"): WEBP, self.gallery("before"): PNG})
        self.assertEqual([(m["url"], m["role"]) for m in highlight["media"]],
                         [(self.clip("after"), "after"), (self.gallery("before"), "before")])

    def test_only_new_and_improved_highlights_without_a_clip_line_look_for_one(self):
        urls = release_notes.clip_auto_urls
        auto = lambda role: release_notes.clip_auto_url("h", role)
        self.assertEqual(urls({}, "h", "new"), {"after": auto("after")})
        self.assertEqual(urls({}, "h", "improved"), {"after": auto("after"), "before": auto("before")})
        self.assertEqual(urls({}, "h", "fixed"), {})
        self.assertEqual(urls({"clip": "x"}, "h", "new"), {})


class LatePictureTests(HighlightRepo):
    """A highlight whose pictures were published after its nightly cut rides along with the next build that
    finds them, once (release-notes.py late_pictures)."""

    def setUp(self):
        super().setUp()
        self.shipped = self.head
        git(self.repo, "commit", "-q", "--allow-empty", "-m", "later work (#124)")
        self.head = git(self.repo, "rev-parse", "HEAD")
        auto = lambda role: release_notes.gallery_auto_url("group-colors", role)
        self.pictures = {auto("after"): PNG, auto("before"): PNG + b"before"}

    def notes(self, shipped_media, pictures=True, feed=True):
        """This span's highlights, with the feed's one earlier build showing group-colors with `shipped_media`."""
        feed_base = release_notes.NOTES_FEED
        published = {"highlights": [{"id": "group-colors", "category": "improved", "media": shipped_media}]}
        files = dict(self.pictures) if pictures else {}
        if feed:
            files[feed_base + "index.json"] = json.dumps({"builds": [{"build": "1"}]}).encode()
            files[feed_base + "1.json"] = json.dumps(published).encode()
        fixture = os.path.join(self.repo, "fixture.json")
        stored = {}
        for url, data in files.items():
            path = os.path.join(self.repo, hashlib.sha256(url.encode()).hexdigest())
            with open(path, "wb") as f:
                f.write(data)
            stored[url] = path
        with open(fixture, "w") as f:
            json.dump({"bodies": {}, "files": stored}, f)
        out = os.path.join(self.repo, "out")
        subprocess.run([sys.executable, SCRIPT, "build", "--build", "2", "--short", "1.0.0-nightly.2", "--date",
                        "2026-10-21", "--head", self.head, "--since", self.shipped, "--out", out, "--pr-media"],
                       cwd=self.repo, capture_output=True, text=True, check=True,
                       env={**os.environ, "CMUX_RELEASE_NOTES_PR_FIXTURE": fixture})
        with open(os.path.join(out, "2.json")) as f:
            return json.load(f)["highlights"]

    def test_a_highlight_that_shipped_without_its_pictures_rides_along_with_them(self):
        highlights = self.notes([])
        self.assertEqual([h["id"] for h in highlights], ["group-colors"])
        self.assertEqual([m["role"] for m in highlights[0]["media"]], ["after", "before"])

    def test_an_improvement_that_shipped_without_its_before_rides_along(self):
        shipped = [{"url": release_notes.gallery_auto_url("group-colors", "after"), "sha256": "0" * 64}]
        self.assertEqual([h["id"] for h in self.notes(shipped)], ["group-colors"])

    def test_an_improvement_with_no_before_rides_along_with_its_after_once(self):
        # Its gallery state is new in its commit, so nothing renders at the commit before it.
        del self.pictures[release_notes.gallery_auto_url("group-colors", "before")]
        highlights = self.notes([])
        self.assertEqual([h["id"] for h in highlights], ["group-colors"])
        self.assertEqual([m.get("role") for m in highlights[0]["media"]], [None])
        shipped = [{"url": release_notes.gallery_auto_url("group-colors", "after"), "sha256": "0" * 64}]
        self.assertEqual(self.notes(shipped), [])

    def test_once_it_shipped_with_its_pictures_it_rides_no_more(self):
        roles = [{"url": f"https://x/{r}.png", "role": r} for r in ("after", "before")]
        self.assertEqual(self.notes(roles), [])

    def test_a_recorded_clip_published_after_the_cut_rides_along_too(self):
        clip = lambda role: release_notes.clip_auto_url("group-colors", role)
        self.pictures = {clip("after"): WEBP, clip("before"): WEBP + b"b"}
        highlights = self.notes([])
        self.assertEqual([m["url"] for m in highlights[0]["media"]], [clip("after"), clip("before")])

    def add_spec(self):
        os.makedirs(os.path.join(self.repo, "release-notes/next/clips"), exist_ok=True)
        with open(os.path.join(self.repo, "release-notes/next/clips/group-colors.json"), "w") as f:
            f.write("{}\n")
        git(self.repo, "add", ".")
        git(self.repo, "commit", "-q", "-m", "its clip spec (#125)")
        self.head = git(self.repo, "rev-parse", "HEAD")

    def test_a_clip_recorded_after_it_shipped_with_its_stills_replaces_them_once(self):
        clip = lambda role: release_notes.clip_auto_url("group-colors", role)
        gallery = lambda role: release_notes.gallery_auto_url("group-colors", role)
        stills = [{"url": gallery(r), "sha256": "0" * 64, "role": r} for r in ("after", "before")]
        self.add_spec()
        self.pictures[clip("after")] = WEBP
        highlights = self.notes(stills)
        self.assertEqual([h["id"] for h in highlights], ["group-colors"])
        self.assertEqual([m["url"] for m in highlights[0]["media"]], [clip("after"), gallery("before")])
        # Once the notes showed it, the same clip re-announces nothing; its before clip, when published, does.
        shown = [{"url": clip("after"), "sha256": "0" * 64, "role": "after"}, stills[1]]
        self.assertEqual(self.notes(shown), [])
        self.pictures[clip("before")] = WEBP + b"b"
        self.assertEqual([m["url"] for m in self.notes(shown)[0]["media"]], [clip("after"), clip("before")])

    def test_stills_with_no_clip_published_or_no_spec_ride_no_more(self):
        clip = lambda role: release_notes.clip_auto_url("group-colors", role)
        stills = [{"url": release_notes.gallery_auto_url("group-colors", r), "sha256": "0" * 64, "role": r}
                  for r in ("after", "before")]
        self.pictures[clip("after")] = WEBP
        self.assertEqual(self.notes(stills), [])  # no spec: a clip at that name is not this highlight's
        self.add_spec()
        del self.pictures[clip("after")]
        self.assertEqual(self.notes(stills), [])

    def test_no_pictures_yet_or_no_feed_means_no_ride_along(self):
        self.assertEqual(self.notes([], pictures=False), [])
        self.assertEqual(self.notes([], feed=False), [])


class GalleryRenderPlanTests(unittest.TestCase):
    """media/whats-new-gallery.py: each planned state renders as the dark default theme's case of its entry."""

    def setUp(self):
        spec = importlib.util.spec_from_file_location(
            "whats_new_gallery", os.path.join(os.path.dirname(SCRIPT), "media", "whats-new-gallery.py"))
        self.tool = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.tool)

    def picture(self, width, height, marks, filtered=False):
        """An RGB PNG of a dark stage with light squares at (x, y, size); `filtered` encodes every row
        with a different PNG filter, as Chromium's encoder may."""
        import struct, zlib
        rows = [bytearray(b"\x20\x20\x20" * width) for _ in range(height)]
        for x0, y0, size in marks:
            for y in range(y0, y0 + size):
                rows[y][x0 * 3:(x0 + size) * 3] = b"\xe0\xe0\xe0" * size
        if not filtered:
            return self.tool.png_write(width, height, 3, rows)
        raw, prior = b"", bytearray(width * 3)
        for y, row in enumerate(rows):
            kind, out = y % 5, bytearray()
            for i, value in enumerate(row):
                left = row[i - 3] if i >= 3 else 0
                up, corner = prior[i], prior[i - 3] if i >= 3 else 0
                guess = left + up - corner
                pa, pb, pc = abs(guess - left), abs(guess - up), abs(guess - corner)
                paeth = left if pa <= pb and pa <= pc else up if pb <= pc else corner
                out.append((value - [0, left, up, (left + up) >> 1, paeth][kind]) & 255)
            raw += bytes([kind]) + bytes(out)
            prior = row
        chunk = lambda k, b: struct.pack(">I", len(b)) + k + b + struct.pack(">I", zlib.crc32(k + b))
        return (self.tool.PNG + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))

    def test_png_read_undoes_every_row_filter(self):
        width, height, channels, rows = self.tool.png_read(self.picture(40, 30, [(5, 6, 4)], filtered=True))
        self.assertEqual((width, height, channels), (40, 30, 3))
        self.assertEqual(self.tool.content_box(width, height, channels, rows), (5, 6, 9, 10))

    def test_a_pair_is_cropped_to_one_box_with_a_margin(self):
        with tempfile.TemporaryDirectory() as tmp:
            after, before = os.path.join(tmp, "after.png"), os.path.join(tmp, "before.png")
            with open(after, "wb") as f:
                f.write(self.picture(200, 120, [(40, 50, 10)]))
            with open(before, "wb") as f:
                f.write(self.picture(200, 120, [(60, 40, 10)]))
            from pathlib import Path
            out = self.tool.crop_pictures([Path(after), Path(before)], Path(tmp) / "cropped")
            sizes = [self.tool.png_read(p.read_bytes())[:2] for p in out]
        # Union (40, 40)-(70, 60), plus 32 each side: (8, 8)-(102, 92).
        self.assertEqual(sizes, [(94, 84), (94, 84)])

    def test_an_empty_or_odd_picture_is_kept_as_it_is(self):
        with tempfile.TemporaryDirectory() as tmp:
            from pathlib import Path
            blank = Path(tmp) / "blank.png"
            blank.write_bytes(self.picture(50, 50, []))
            self.assertEqual(self.tool.crop_pictures([blank], Path(tmp) / "c"), [blank])
            webp = Path(tmp) / "x.webp"
            webp.write_bytes(b"RIFF\0\0\0\0WEBPVP8 ")
            self.assertEqual(self.tool.crop_pictures([webp], Path(tmp) / "c"), [webp])

    def test_manifest_keeps_one_dark_case_per_state_and_names_the_missing(self):
        case = lambda entry, variant, scheme: {"id": f"{entry}--{variant}--{scheme}", "path_or_url": "frame.html",
                                               "params": {"entry": entry, "variant": variant, "colorScheme": scheme}}
        cases = [case("a.b", "new", "light"), case("a.b", "new", "dark"), case("a.bc", "new", "dark"),
                 case("a.b", "old", "dark")]
        rows = [{"id": "h", "role": "after", "state": "a.b/new", "entry": "a.b", "variant": "new"},
                {"id": "h", "role": "before", "state": "a.b/gone", "entry": "a.b", "variant": "gone"}]
        out, missing = self.tool.manifest(rows, cases)
        self.assertEqual(out, [{**cases[1], "id": "h--after"}])
        self.assertEqual(missing, ["h: no gallery state a.b/gone"])

    def case(self, entry, variant, source="src/a.gallery.tsx", scheme="dark"):
        return {"id": f"{entry}--{variant}--{scheme}", "path_or_url": "frame.html",
                "params": {"entry": entry, "variant": variant, "colorScheme": scheme, "source": source}}

    def test_infer_takes_the_variant_the_commit_added(self):
        cases = [self.case("a.b", "old"), self.case("a.b", "new"), self.case("a.b", "later")]
        files = {"c^": 'variants: {\n  old: {},\n}\n', "c": 'variants: {\n  old: {},\n  "new": {},\n}\n'}
        row = {"id": "h", "role": "after", "sources": ["src/a.gallery.tsx"], "commit": "c"}
        text_at = lambda rev, path: files.get(rev)
        self.assertEqual(self.tool.infer(row, cases, text_at, lambda c, p: set()), "a.b/new")

    def test_infer_takes_the_added_variant_its_note_calls_selected(self):
        # A new file's first variant was its closed row, which showed nothing of the cards it added (2026-11-09).
        cases = [self.case("a.b", "closed"), self.case("a.b", "cards")]
        files = {"c": 'variants: {\n  closed: {},\n  cards: {},\n}\n'}
        row = {"id": "h", "role": "after", "sources": ["src/a.gallery.tsx"], "commit": "c"}
        # The notes come from the entries (notes.ts), so a note anywhere in a variant counts, and a nested prop's never.
        notes = {"a.b": {"closed": "Closed, one row.", "cards": "Selected: opened."}}
        self.assertEqual(self.tool.infer(row, cases, lambda rev, path: files.get(rev), lambda c, p: set(), notes),
                         "a.b/cards")
        self.assertEqual(self.tool.infer(row, cases, lambda rev, path: files.get(rev), lambda c, p: set()), "a.b/closed")

    def test_infer_takes_the_variant_whose_lines_the_commit_changed_most(self):
        cases = [self.case("a.b", v) for v in ("first", "picked", "picked-solid")]
        text = "variants: {\n  first: {\n    x: 1,\n  },\n  picked: {\n    x: 2,\n    y: 3,\n  },\n  \"picked-solid\": {},\n}\n"
        row = {"id": "h", "role": "after", "sources": ["src/a.gallery.tsx"], "commit": "c"}
        self.assertEqual(self.tool.infer(row, cases, lambda rev, path: text, lambda c, p: {3, 6, 7}), "a.b/picked")
        # Nothing changed in a variant: the first one, never one named for the old look.
        cases = [self.case("a.b", "picked-solid"), self.case("a.b", "first")]
        self.assertEqual(self.tool.infer(row, cases, lambda rev, path: text, lambda c, p: set()), "a.b/first")

    def test_resolve_names_a_highlight_with_no_gallery_entry(self):
        row = {"id": "h", "role": "after", "sources": ["src/none.gallery.ts"], "commit": "c"}
        rows, missing = self.tool.resolve([row], [self.case("a.b", "x")], lambda rev, path: "")
        self.assertEqual((rows, missing), ([], ["h: no gallery state in src/none.gallery.ts"]))

    def test_a_before_at_the_parent_is_the_same_state_there_never_another(self):
        rows = [{"id": "h", "role": "before", "state": "a.b/new", "entry": "a.b", "variant": "new", "parent": "p"},
                {"id": "g", "role": "before", "state": "a.c/x", "entry": "a.c", "variant": "x", "parent": "p"},
                {"id": "h", "role": "after", "state": "a.b/new", "entry": "a.b", "variant": "new"}]
        at_parent = [self.case("a.b", "first"), self.case("a.b", "new")]
        out, missing = self.tool.manifest(rows, at_parent, "p")
        self.assertEqual(out, [{**at_parent[1], "id": "h--before"}])
        self.assertEqual(missing, ["g: no gallery state a.c/x at p"])
        # A state new in the highlight's commit has no before there: never the entry's first variant,
        # which showed an unrelated picture (notes-sections took popover-pr-links, 2026-11-09).
        out, missing = self.tool.manifest(rows[:1], [self.case("a.b", "first")], "p")
        self.assertEqual((out, missing), ([], ["h: no gallery state a.b/new at p"]))
        # Without --parent, the befores rendered there are left out.
        self.assertEqual([c["id"] for c in self.tool.manifest(rows, at_parent)[0]], ["h--after"])

    NOTES = {"a.b": {"notes-sections": "Picked and shipped", "notes-sections-light": "Light",
                     "notes-flat": "Before: one flat list", "card-button": "Before (the old card)"}}
    GALLERY = ('variants: {\n  "notes-sections": {},\n  "notes-sections-light": {},\n  "notes-flat": {},\n'
               '  "card-button": {},\n  "card-solid": {},\n}\n')

    def test_a_before_is_the_old_look_its_entry_marks_rendered_beside_the_after(self):
        cases = [self.case("a.b", v) for v in ("notes-sections", "notes-sections-light", "notes-flat", "card-button", "card-solid")]
        # The note-marked variant sharing the longest name prefix wins over other marked ones.
        self.assertEqual(self.tool.marked_before("a.b/notes-sections", cases, self.NOTES), "a.b/notes-flat")
        self.assertEqual(self.tool.marked_before("a.b/card", cases, self.NOTES), "a.b/card-button")
        # A name in OLD_LOOK's words counts when no note says Before.
        self.assertEqual(self.tool.marked_before("a.b/card", [self.case("a.b", v) for v in ("card", "card-solid")],
                                                 {}), "a.b/card-solid")
        self.assertIsNone(self.tool.marked_before("a.b/x", [self.case("a.b", "x"), self.case("a.b", "y")], {}))
        # Another surface's old look is not this one's, and "Before/after" is a name, not a mark.
        self.assertIsNone(self.tool.marked_before("a.b/popover-compact", cases, self.NOTES))
        other = {"a.b": {"compare-side": "Before/after variant B"}}
        self.assertIsNone(self.tool.marked_before("a.b/compare-slider",
                                                  [self.case("a.b", "compare-slider"), self.case("a.b", "compare-side")], other))
        rows = [{"id": "h", "role": "after", "sources": ["src/a.gallery.tsx"], "commit": "c"},
                {"id": "h", "role": "before", "sources": ["src/a.gallery.tsx"], "commit": "c", "parent": "p"}]
        files = {"c^": "variants: {\n}\n", "c": self.GALLERY}
        out, missing = self.tool.resolve(rows, cases, lambda rev, path: files.get(rev), self.NOTES)
        self.assertEqual(missing, [])
        self.assertEqual([(r["role"], r["state"], r.get("parent")) for r in out],
                         [("after", "a.b/notes-sections", None), ("before", "a.b/notes-flat", None)])
        # Rendered now, beside the after: both in the manifest without --parent.
        self.assertEqual([c["id"] for c in self.tool.manifest(out, cases)[0]], ["h--after", "h--before"])

    def test_an_entry_that_marks_no_old_look_renders_the_before_at_the_parent(self):
        cases = [self.case("a.b", "x"), self.case("a.b", "y")]
        rows = [{"id": "h", "role": "before", "state": "a.b/x", "parent": "p"}]
        files = {("p", "webviews/src/a.gallery.tsx"): "x: {}\n"}
        out, missing = self.tool.resolve(rows, cases, lambda rev, path: files.get((rev, path)), {})
        self.assertEqual((out[0]["state"], out[0]["parent"], missing), ("a.b/x", "p", []))

    def test_a_before_whose_state_its_commit_added_is_named_not_rendered_at_the_parent(self):
        # agent-file-result-cards added its gallery file: at the parent there was nothing to render (2026-11-09).
        cases = [self.case("a.b", "x"), self.case("a.b", "y")]
        rows = [{"id": "h", "role": "before", "state": "a.b/x", "parent": "p" * 40}]
        for at_parent in (None, "y: {}\n"):
            with self.subTest(at_parent=at_parent):
                out, missing = self.tool.resolve(rows, cases, lambda rev, path: at_parent, {})
                self.assertEqual(out, [])
                self.assertEqual(len(missing), 1)
                self.assertIn("h before: a.b/x is new in its commit, not in src/a.gallery.tsx at pppppppppppp", missing[0])
                self.assertIn('"Before:"', missing[0])

    def test_parents_come_newest_highlight_first(self):
        import json
        from pathlib import Path
        rows = [{"id": "a", "parent": "old", "born": 1}, {"id": "b", "parent": "new", "born": 3},
                {"id": "c", "parent": "mid", "born": 2}, {"id": "d", "born": 4}]
        with tempfile.TemporaryDirectory() as tmp:
            plan = Path(tmp) / "plan.json"
            plan.write_text(json.dumps(rows))
            import contextlib, io
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                self.tool.main(["parents", "--plan", str(plan), "--limit", "2"])
        self.assertEqual(out.getvalue().split(), ["new", "mid"])

    def test_a_published_picture_is_never_uploaded_again(self):
        from pathlib import Path
        with tempfile.TemporaryDirectory() as tmp:
            results = Path(tmp)
            rows = [{"id": "h", "role": "after", "state": "a.b/x", "url": "u/after", "path": "p/after"},
                    {"id": "h", "role": "before", "state": "a.b/y", "url": "u/before", "path": "p/before"}]
            (results / "h--after-chromium.png").write_bytes(self.picture(40, 30, [(5, 6, 4)]))
            (results / "h--before-chromium.png").write_bytes(self.picture(40, 30, [(9, 9, 4)]))
            uploaded = []
            fake = type("M", (), {"privacy_module": lambda self: type("P", (), {"ocr_binary": lambda self: "ocr"})(),
                                  "check_privacy": lambda self, files, repo: None,
                                  "MediaConflict": LookupError,
                                  "put_files": lambda self, repo, branch, files, message, checked, expect: (
                                      self.raced(files) if raced else uploaded.extend(
                                          p for p in files if expect == {p: None}))})()
            fake.raced = lambda files: (_ for _ in ()).throw(raced("got there first"))
            raced = False
            original = self.tool._load
            self.tool._load = lambda name, path: fake
            try:
                # Signed notes pin the after's bytes: its late before goes up alone.
                self.tool.publish(rows, results, exists=lambda url: url == "u/after")
                self.assertEqual(uploaded, ["p/before"])
                uploaded.clear()
                self.tool.publish(rows, results, exists=lambda url: True)
                self.assertEqual(uploaded, [])
                # Another run put the before there after `exists` read it: kept, named, nothing replaced.
                raced = LookupError
                problems = self.tool.publish(rows, results, exists=lambda url: url == "u/after")
                self.assertEqual(uploaded, [])
                self.assertIn("h before: kept the copy already there (got there first)", problems)
                # Any other failure (no branch, auth, retries spent) is not a race: it stops the run.
                raced = RuntimeError
                with self.assertRaises(RuntimeError):
                    self.tool.publish(rows, results, exists=lambda url: url == "u/after")
            finally:
                self.tool._load = original


if __name__ == "__main__":
    unittest.main()
