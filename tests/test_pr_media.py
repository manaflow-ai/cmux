#!/usr/bin/env python3

import base64
import contextlib
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
import urllib.parse
from unittest import mock
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("pr_media", ROOT / "scripts/pr-media.py")
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)

# The real privacy check reads this machine's names and may compile the OCR
# tool; tests that do not exercise it get a no-op, and PrivacyTests a stubbed one.
REAL_CHECK_PRIVACY = getattr(MODULE, "check_privacy", None)
MODULE.check_privacy = lambda items, repo, **options: None

PNG = b"\x89PNG\r\n\x1a\n" + b"0" * 32
MP4 = b"\x00\x00\x00\x18ftypisom" + b"0" * 32
GIF = b"GIF89a" + b"0" * 32

def written(directory, name, data=b"media"):
    path = Path(directory) / name
    path.write_bytes(data)
    return path


def git(cwd, *args, input=None):
    return subprocess.run(["git", "-C", str(cwd), *args], check=True, capture_output=True, text=True,
                          input=input).stdout


class Origin:
    """A bare repository standing in for GitHub: a pr-media branch, `refs/pull/N/head` for open pull requests,
    and partial-clone support (a `file://` URL goes through the same transport as GitHub's). Every test that
    reads or writes the branch gets one, with its own cache dir and with the host's git config shut out."""

    def __init__(self, case, existing=(), pulls=(7, 8, 3, 5, 15277), branch="pr-media"):
        temporary = tempfile.TemporaryDirectory(prefix="pr-media-origin-")
        case.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        empty = self.root / "gitconfig"
        empty.write_text("")
        patcher = mock.patch.dict(os.environ, {
            "GIT_CONFIG_GLOBAL": str(empty), "GIT_CONFIG_NOSYSTEM": "1",
            "PR_MEDIA_REMOTE_URL": f"file://{self.root / 'origin.git'}",
            "PR_MEDIA_CACHE_DIR": str(self.root / "cache")})
        patcher.start()
        case.addCleanup(patcher.stop)
        for name in ("GH_TOKEN", "GITHUB_TOKEN"):
            if name in os.environ:
                token = mock.patch.dict(os.environ)
                token.start()
                case.addCleanup(token.stop)
                del os.environ[name]
        MODULE._BRANCHES.clear()
        case.addCleanup(MODULE._BRANCHES.clear)
        MODULE._GIT_FAILED.clear()
        case.addCleanup(MODULE._GIT_FAILED.clear)
        self.bare = self.root / "origin.git"
        # GitHub's GraphQL API over the same repository, for the fallback when git can't reach it.
        self.api = FakeApi(self.bare, branch)
        api = mock.patch.object(MODULE, "API_RUNNER", self.api)
        api.start()
        case.addCleanup(api.stop)
        subprocess.run(["git", "init", "-q", "--bare", str(self.bare)], check=True)
        git(self.bare, "config", "uploadpack.allowFilter", "true")
        git(self.bare, "config", "uploadpack.allowAnySHA1InWant", "true")
        self.writer = self.root / "writer"
        subprocess.run(["git", "init", "-q", "-b", branch, str(self.writer)], check=True)
        for key, value in (("user.email", "t@example.com"), ("user.name", "t")):
            git(self.writer, "config", key, value)
        git(self.writer, "remote", "add", "origin", str(self.bare))
        self.branch = branch
        self.write({"README.md": b"media only\n", **{path: b"old " + path.encode() for path in existing}})
        tip = git(self.writer, "rev-parse", "HEAD").strip()
        for number in pulls:
            git(self.bare, "update-ref", f"refs/pull/{number}/head", tip)

    def write(self, files):
        """Another uploader's commit, pushed to the origin."""
        for path, data in files.items():
            (self.writer / path).parent.mkdir(parents=True, exist_ok=True)
            (self.writer / path).write_bytes(data)
            git(self.writer, "add", path)
        git(self.writer, "commit", "-q", "-m", "write " + ", ".join(files))
        git(self.writer, "push", "-q", "origin", f"HEAD:refs/heads/{self.branch}")

    def files(self):
        """Path -> bytes on the origin's branch now."""
        listed = git(self.bare, "ls-tree", "-r", "-z", self.branch).split("\0")
        found = {}
        for line in filter(None, listed):
            meta, _, path = line.partition("\t")
            found[path] = subprocess.run(["git", "-C", str(self.bare), "cat-file", "blob", meta.split()[2]],
                                         check=True, capture_output=True).stdout
        return found

    def blob(self, path):
        return git(self.bare, "rev-parse", f"{self.branch}:{path}").strip()

    def commits(self):
        return int(git(self.bare, "rev-list", "--count", self.branch))

    def hook(self, script):
        """A pre-receive hook on the origin (a refusal, or a branch that keeps moving)."""
        hook = self.bare / "hooks" / "pre-receive"
        hook.write_text("#!/bin/sh\n" + script)
        hook.chmod(0o755)


class FakeApi:
    """Stands in for `gh api graphql` over the Origin's bare repository: the ref and object reads and
    createCommitOnBranch that ApiBranch makes when git can't reach the remote. Anything else, a REST call
    included, fails the test. `fails` makes every call fail as a host with no gh login would."""

    def __init__(self, bare, branch):
        self.bare, self.branch = Path(bare), branch
        self.calls = []
        self.fails = False

    def __call__(self, argv, input=None, **kwargs):
        if argv != ["gh", "api", "graphql", "--input", "-"]:
            raise AssertionError(f"only `gh api graphql --input -` may run, ran {argv}")
        assert kwargs["env"]["GLAEDA_GH_CACHE_TTL"] == "0"
        request = json.loads(input)
        self.calls.append(request)
        if self.fails:
            return SimpleNamespace(returncode=1, stdout="", stderr="gh: To get started with GitHub CLI, run: gh auth login")
        query, variables = request["query"], request["variables"]
        if "createCommitOnBranch" in query:
            data, errors = self.commit(variables["input"])
        elif "pullRequest(" in query:
            found = self.rev(f"refs/pull/{variables['number']}/head")
            data = {"repository": {"pullRequest": {"number": variables["number"]} if found else None}}
            errors = [] if found else [{"type": "NOT_FOUND", "message": "Could not resolve to a PullRequest"}]
        elif "ref(qualifiedName" in query:
            tip = self.rev(variables["ref"])
            data, errors = {"repository": {"ref": {"target": {"oid": tip}} if tip else None}}, []
        elif "object(expression" in query:
            oid = self.rev(variables["expression"])
            kind = self.git("cat-file", "-t", oid).stdout.strip() if oid else ""
            data = {"repository": {"object": {"__typename": kind.capitalize(), "oid": oid} if oid else None}}
            errors = []
        else:
            raise AssertionError(f"unexpected query {query}")
        answer = {"data": data, **({"errors": errors} if errors else {})}
        return SimpleNamespace(returncode=1 if errors else 0, stdout=json.dumps(answer), stderr="")

    def git(self, *args, input=None, env=None):
        return subprocess.run(["git", "-C", str(self.bare), *args], capture_output=True, input=input,
                              text=not isinstance(input, bytes), env={**os.environ, **(env or {})})

    def rev(self, name):
        done = self.git("rev-parse", "--verify", "--quiet", name)
        return done.stdout.strip() if done.returncode == 0 else None

    def commit(self, given):
        ref = f"refs/heads/{given['branch']['branchName']}"
        tip = self.rev(ref)
        if tip != given["expectedHeadOid"]:
            return None, [{"message": f'Expected branch to point to "{given["expectedHeadOid"]}" but it did not. '
                                      "Pull and try again."}]
        with tempfile.TemporaryDirectory() as scratch:
            index = {"GIT_INDEX_FILE": str(Path(scratch) / "index")}
            assert self.git("read-tree", tip, env=index).returncode == 0
            for added in given["fileChanges"]["additions"]:
                blob = subprocess.run(["git", "-C", str(self.bare), "hash-object", "-w", "--stdin"],
                                      input=base64.b64decode(added["contents"]), capture_output=True,
                                      check=True).stdout.decode().strip()
                assert self.git("update-index", "--add", "--cacheinfo", f"100644,{blob},{added['path']}",
                                env=index).returncode == 0
            tree = self.git("write-tree", env=index).stdout.strip()
        commit = self.git("-c", "user.name=api", "-c", "user.email=api@example.com", "commit-tree", tree,
                          "-p", tip, "-m", given["message"]["headline"]).stdout.strip()
        assert self.git("update-ref", ref, commit, tip).returncode == 0
        return {"createCommitOnBranch": {"commit": {"oid": commit}}}, []


class FakeGh:
    """Stands in for `gh` as main()'s runner, which only `--comment` uses (the branch is read and written with
    git, or through FakeApi when git can't reach it). Any other gh call fails the test."""

    def __init__(self, comment_fails=False):
        self.comment_fails = comment_fails
        self.calls = []
        self.comments = []

    def __call__(self, argv, **kwargs):
        self.calls.append(argv)
        if argv[:3] == ["gh", "pr", "comment"]:
            if self.comment_fails:
                return self.reply(1, "", "HTTP 403: Resource not accessible")
            self.comments.append(kwargs.get("input", ""))
            return self.reply(0, "")
        if argv[0] == "ffprobe":
            # convert() reads the clip's rate for the gif; an unreadable rate starts at the default.
            return self.reply(0, "")
        raise AssertionError(f"only `gh pr comment` may run, ran {argv}")

    def reply(self, code, out, err=""):
        return SimpleNamespace(returncode=code, stdout=out, stderr=err)


class NameTests(unittest.TestCase):
    def test_a_name_keeps_its_shape_and_loses_what_a_url_cannot_carry(self):
        self.assertEqual(MODULE.sanitize("sidebar drag.gif"), "sidebar-drag.gif")
        self.assertEqual(MODULE.sanitize("01-Record@2x.MP4"), "01-Record-2x.mp4")
        self.assertEqual(MODULE.sanitize("a  b   c.png"), "a-b-c.png")
        self.assertEqual(MODULE.sanitize("keeps_underscores.gif"), "keeps_underscores.gif")

    def test_a_name_never_carries_a_separator_into_the_remote_path(self):
        # Two lines of defence: the stem drops any directory, and the character
        # filter drops what a URL or a shell would read as structure.
        for raw in ("../../etc/passwd.png", "a/b.gif", "..\\windows.png", "a:b.png", "-x-.gif"):
            name = MODULE.sanitize(raw)
            for forbidden in ("/", "\\", ":", ".."):
                self.assertNotIn(forbidden, name, raw)
            self.assertFalse(name.startswith("."), raw)

    def test_a_name_with_nothing_usable_is_rejected(self):
        with self.assertRaises(MODULE.MediaError):
            MODULE.sanitize("---.gif")

    def test_a_caption_drops_a_step_number_and_reads_as_words(self):
        self.assertEqual(MODULE.label_for("02-sidebar-drag.gif"), "sidebar drag")
        self.assertEqual(MODULE.label_for("settings_dark.png"), "settings dark")
        # A leading number that is part of the name, not a step index, stays.
        self.assertEqual(MODULE.label_for("15277.gif"), "15277")


class ContentTests(unittest.TestCase):
    def test_a_png_renamed_to_mp4_is_refused_before_ffmpeg_sees_it(self):
        with tempfile.TemporaryDirectory() as scratch:
            fake = written(scratch, "clip.mp4", PNG)
            with self.assertRaises(MODULE.MediaError) as raised:
                MODULE.require_matching_content(fake)
            self.assertIn("clip.mp4", str(raised.exception))
            self.assertIn("png", str(raised.exception).lower())

    def test_real_media_passes_and_an_unrecognized_header_is_left_alone(self):
        with tempfile.TemporaryDirectory() as scratch:
            for name, data in (("a.png", PNG), ("b.mp4", MP4), ("c.gif", GIF),
                               ("d.mov", MP4), ("e.png", b"who knows")):
                MODULE.require_matching_content(written(scratch, name, data))


class PlanTests(unittest.TestCase):
    def test_an_mp4_plans_a_gif_beside_it(self):
        with tempfile.TemporaryDirectory() as scratch:
            clip = written(scratch, "sidebar-drag.mp4")
            uploads = MODULE.plan([clip], None, gif=True)
            self.assertEqual([(u.name, u.kind) for u in uploads],
                             [("sidebar-drag.gif", "gif"), ("sidebar-drag.mp4", "video")])
            # The gif is made from the mp4, not uploaded from a path of its own.
            self.assertEqual(uploads[0].local, clip)
            self.assertEqual(uploads[0].source_name, "sidebar-drag.mp4")
            self.assertIsNone(uploads[1].source_name)

    def test_no_gif_uploads_the_mp4_alone(self):
        with tempfile.TemporaryDirectory() as scratch:
            clip = written(scratch, "clip.mp4")
            uploads = MODULE.plan([clip], None, gif=False)
            self.assertEqual([(u.name, u.kind) for u in uploads], [("clip.mp4", "video")])

    def test_a_gif_from_cmux_record_is_uploaded_as_it_is(self):
        with tempfile.TemporaryDirectory() as scratch:
            uploads = MODULE.plan([written(scratch, "already.gif")], None, gif=True)
            self.assertEqual([(u.name, u.kind, u.source_name) for u in uploads],
                             [("already.gif", "gif", None)])

    def test_two_files_that_would_share_a_name_are_refused(self):
        with tempfile.TemporaryDirectory() as scratch:
            (Path(scratch) / "a").mkdir()
            (Path(scratch) / "b").mkdir()
            one = written(Path(scratch) / "a", "clip.gif")
            two = written(Path(scratch) / "b", "clip.gif")
            with self.assertRaises(MODULE.MediaError) as raised:
                MODULE.plan([one, two], None, gif=True)
            self.assertIn("clip.gif", str(raised.exception))

    def test_an_mp4_that_would_overwrite_an_uploaded_gif_is_refused(self):
        with tempfile.TemporaryDirectory() as scratch:
            gif = written(scratch, "clip.gif")
            mp4 = written(scratch, "clip.mp4")
            with self.assertRaises(MODULE.MediaError):
                MODULE.plan([gif, mp4], None, gif=True)

    def test_one_label_for_several_files_is_refused_rather_than_dropped(self):
        with tempfile.TemporaryDirectory() as scratch:
            first = written(scratch, "a.png")
            second = written(scratch, "b.png")
            with self.assertRaises(MODULE.MediaError) as raised:
                MODULE.plan([first, second], "one caption", gif=True)
            self.assertIn("--label", str(raised.exception))

    def test_a_directory_expands_in_order_and_skips_what_is_not_media(self):
        with tempfile.TemporaryDirectory() as scratch:
            written(scratch, "02-second.png")
            written(scratch, "01-first.png")
            written(scratch, "steps.md")
            self.assertEqual([path.name for path in MODULE.collect([scratch])],
                             ["01-first.png", "02-second.png"])

    def test_an_unsupported_file_says_what_is_supported(self):
        with tempfile.TemporaryDirectory() as scratch:
            notes = written(scratch, "steps.md")
            with self.assertRaises(MODULE.MediaError) as raised:
                MODULE.collect([str(notes)])
            self.assertIn(".gif", str(raised.exception))


class MarkdownTests(unittest.TestCase):
    def test_a_gif_embeds_and_its_mp4_is_only_linked(self):
        with tempfile.TemporaryDirectory() as scratch:
            clip = written(scratch, "sidebar-drag.mp4")
            body = MODULE.markdown(MODULE.plan([clip], None, gif=True), 15277)
            self.assertIn(
                "![sidebar drag](https://raw.githubusercontent.com/manaflow-ai/cmux/pr-media/15277/sidebar-drag.gif)",
                body,
            )
            self.assertIn(
                "Full quality: [sidebar-drag.mp4]"
                "(https://raw.githubusercontent.com/manaflow-ai/cmux/pr-media/15277/sidebar-drag.mp4)",
                body,
            )
            # GitHub does not render an mp4 from a raw URL, so it is never embedded.
            self.assertNotIn("![sidebar drag](https://raw.githubusercontent.com/manaflow-ai/cmux"
                             "/pr-media/15277/sidebar-drag.mp4)", body)

    def test_an_mp4_kept_without_a_gif_is_still_linked(self):
        with tempfile.TemporaryDirectory() as scratch:
            clip = written(scratch, "clip.mov")
            body = MODULE.markdown(MODULE.plan([clip], None, gif=False), 9)
            self.assertIn("[clip (clip.mov)](https://raw.githubusercontent.com/manaflow-ai/cmux/pr-media/9/clip.mov)",
                          body)

    def test_a_label_names_a_single_file(self):
        with tempfile.TemporaryDirectory() as scratch:
            shot = written(scratch, "01-x.png")
            body = MODULE.markdown(MODULE.plan([shot], "before: one tab", gif=True), 3)
            self.assertIn("![before: one tab](", body)

    def test_a_space_in_a_name_never_reaches_the_url(self):
        # sanitize already removes it; the URL builder is the second line.
        self.assertEqual(MODULE.raw_url("o/r", "pr-media", "1/a b.gif"),
                         "https://raw.githubusercontent.com/o/r/pr-media/1/a%20b.gif")


class GifCommandTests(unittest.TestCase):
    def test_the_conversion_never_upscales_a_narrow_clip(self):
        argv = MODULE.gif_argv(Path("in.mp4"), Path("out.gif"), 10, 900)
        chain = argv[argv.index("-filter_complex") + 1]
        self.assertIn("min(900\\,iw)", chain)
        self.assertIn("fps=10", chain)

    def test_the_conversion_loops_and_builds_its_own_palette(self):
        argv = MODULE.gif_argv(Path("in.mp4"), Path("out.gif"), 8, 600)
        self.assertEqual(argv[argv.index("-loop") + 1], "0")
        chain = argv[argv.index("-filter_complex") + 1]
        self.assertIn("palettegen", chain)
        self.assertIn("paletteuse", chain)
        self.assertEqual(argv[-1], "out.gif")


class GifRateTests(unittest.TestCase):
    """Leo, 2026-10-31, on 4 and then 10-15 fps previews: "WHY ... IS IT NOT 30/60/120"."""

    def test_the_default_is_smooth(self):
        self.assertGreaterEqual(MODULE.DEFAULT_GIF_FPS, 30)
        self.assertEqual(MODULE.gif_attempts((900, 720, 558))[0], (30, 900))

    def test_a_60_fps_clip_starts_at_the_fastest_rate_a_gif_plays(self):
        # Delays are hundredths of a second and browsers play 1/100 s as 1/10 s: 50 fps is the real ceiling.
        self.assertEqual(MODULE.GIF_MAX_FPS, 50)
        self.assertEqual(MODULE.gif_attempts((900,), source_rate=60.0)[0], (50, 900))
        self.assertEqual(MODULE.gif_attempts((900,), fps=120)[0], (50, 900))

    def test_it_gets_narrower_before_it_gets_choppier(self):
        attempts = MODULE.gif_attempts((900, 720, 558), source_rate=60.0)
        self.assertEqual(attempts[:4], [(50, 900), (30, 900), (30, 720), (30, 558)])
        self.assertEqual(attempts[4:], [(24, 558), (20, 558), (15, 558), (12, 558), (10, 558)])

    def test_a_slow_clip_never_gets_repeated_frames(self):
        self.assertEqual(MODULE.gif_attempts((900,), source_rate=2.0), [(2, 900)])
        self.assertTrue(all(rate <= 24 for rate, _ in MODULE.gif_attempts((900,), source_rate=23.976)))

    def test_a_width_or_rate_under_one_is_refused_up_front(self):
        for flags in (["--gif-width", "0"], ["--gif-width", "-5"], ["--gif-fps", "0"]):
            with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
                MODULE.parse_args(["--pr", "1", "clip.mp4", *flags])
        self.assertIsNone(MODULE.parse_args(["--pr", "1", "clip.mp4"]).gif_fps)

    def test_widths_step_down_from_the_requested_one(self):
        self.assertEqual(MODULE.gif_widths(900), (900, 720, 558))

    def test_the_source_rate_is_read_from_ffprobe(self):
        def runner(stdout):
            return lambda argv, **kwargs: SimpleNamespace(returncode=0, stdout=stdout, stderr="")

        with mock.patch.object(MODULE.shutil, "which", return_value="/usr/bin/ffprobe"):
            read = lambda out: MODULE.source_fps(Path("c.mp4"), runner(out))
            self.assertEqual(read('{"streams":[{"r_frame_rate":"60/1","avg_frame_rate":"30/1"}]}'), 60.0)
            self.assertEqual(read('{"streams":[{"r_frame_rate":"90000/1","avg_frame_rate":"48/1"}]}'), 48.0)
            # A variable-rate capture's average undercounts it; it never caps the gif below the default.
            self.assertEqual(read('{"streams":[{"r_frame_rate":"90000/1","avg_frame_rate":"7/1"}]}'),
                             float(MODULE.DEFAULT_GIF_FPS))
            self.assertIsNone(read(""))
            self.assertIsNone(read('{"streams":[]}'))
        with mock.patch.object(MODULE.shutil, "which", return_value=None):
            self.assertIsNone(MODULE.source_fps(Path("c.mp4")))


class ConvertTests(unittest.TestCase):
    """`convert` itself, with ffmpeg faked: it decides whether a gif is usable."""

    def upload(self, source):
        return MODULE.Upload(local=source, name="clip.gif", kind="gif", label="clip",
                             source_name="clip.mp4")

    @contextlib.contextmanager
    def ffmpeg(self, behaviour):
        with mock.patch.object(MODULE.shutil, "which", return_value="/usr/bin/ffmpeg"):
            yield behaviour

    def test_a_conversion_that_writes_a_gif_returns_it(self):
        with tempfile.TemporaryDirectory() as scratch:
            source = written(scratch, "clip.mp4", MP4)
            into = Path(scratch) / "out"
            into.mkdir()

            def runner(argv, **kwargs):
                Path(argv[-1]).write_bytes(GIF)
                return SimpleNamespace(returncode=0, stdout="", stderr="")

            with self.ffmpeg(runner):
                made = MODULE.convert(self.upload(source), into, 10, 900, runner=runner)
            self.assertEqual(made, into / "clip.gif")
            self.assertEqual(made.read_bytes(), GIF)

    def test_ffmpeg_runs_without_the_publish_steps_secrets(self):
        with tempfile.TemporaryDirectory() as scratch:
            source = written(scratch, "clip.mp4", MP4)
            seen = {}

            def runner(argv, **kwargs):
                seen.update(kwargs["env"])
                Path(argv[-1]).write_bytes(GIF)
                return SimpleNamespace(returncode=0, stdout="", stderr="")

            secrets = {"PR_MEDIA_PRIVATE_TERMS": "secret-host", "GH_TOKEN": "t", "PATH": "/usr/bin"}
            with self.ffmpeg(runner), mock.patch.dict(MODULE.os.environ, secrets):
                MODULE.convert(self.upload(source), Path(scratch), 10, 900, runner=runner)
            self.assertEqual(seen.get("PATH"), "/usr/bin")
            self.assertFalse({"PR_MEDIA_PRIVATE_TERMS", "GH_TOKEN"} & set(seen))
            self.assertLessEqual(set(seen), set(MODULE.TOOL_ENV_KEYS))

    def test_a_failed_conversion_says_what_ffmpeg_said(self):
        with tempfile.TemporaryDirectory() as scratch:
            source = written(scratch, "clip.mp4", MP4)

            def runner(argv, **kwargs):
                return SimpleNamespace(returncode=1, stdout="", stderr="moov atom not found")

            with self.ffmpeg(runner), self.assertRaises(MODULE.MediaError) as raised:
                MODULE.convert(self.upload(source), Path(scratch), 10, 900, runner=runner)
            self.assertIn("moov atom not found", str(raised.exception))

    def test_a_conversion_that_claims_success_but_writes_nothing_is_caught(self):
        with tempfile.TemporaryDirectory() as scratch:
            source = written(scratch, "clip.mp4", MP4)

            def runner(argv, **kwargs):
                return SimpleNamespace(returncode=0, stdout="", stderr="")

            with self.ffmpeg(runner), self.assertRaises(MODULE.MediaError) as raised:
                MODULE.convert(self.upload(source), Path(scratch), 10, 900, runner=runner)
            self.assertIn("no gif", str(raised.exception))

    def test_a_gif_over_the_limit_is_made_again_smaller_instead_of_refused(self):
        with tempfile.TemporaryDirectory() as scratch:
            source = written(scratch, "clip.mp4", MP4)
            into = Path(scratch) / "out"
            into.mkdir()
            calls = []

            def runner(argv, **kwargs):
                if argv[0] == "ffprobe":
                    return SimpleNamespace(returncode=0, stdout='{"streams":[{"r_frame_rate":"60/1"}]}', stderr="")
                calls.append(argv[argv.index("-filter_complex") + 1].split(",")[0])
                Path(argv[-1]).write_bytes(GIF + (b"0" * 4096 if len(calls) < 3 else b""))
                return SimpleNamespace(returncode=0, stdout="", stderr="")

            with self.ffmpeg(runner):
                made = MODULE.convert(self.upload(source), into, None, 900, runner=runner, limit=1024)
            self.assertEqual(calls, ["fps=50", "fps=30", "fps=30"])
            self.assertEqual(made.read_bytes(), GIF)

    def test_a_missing_ffmpeg_names_the_flag_that_skips_it(self):
        with tempfile.TemporaryDirectory() as scratch:
            source = written(scratch, "clip.mp4", MP4)
            with mock.patch.object(MODULE.shutil, "which", return_value=None):
                with self.assertRaises(MODULE.MediaError) as raised:
                    MODULE.convert(self.upload(source), Path(scratch), 10, 900)
            self.assertIn("--no-gif", str(raised.exception))


class SizeTests(unittest.TestCase):
    def test_an_inline_image_stops_at_the_size_github_will_still_render(self):
        # Camo, which proxies an image in a PR body, refuses past 5 MiB and the
        # reader gets a broken image, so the upload has to stop before it does.
        with tempfile.TemporaryDirectory() as scratch:
            big = written(scratch, "big.gif", b"0" * (MODULE.INLINE_MAX_BYTES + 1))
            with self.assertRaises(MODULE.MediaError) as raised:
                MODULE.check_size(big, "gif")
            self.assertIn("--gif-fps", str(raised.exception))
            self.assertIn("render", str(raised.exception))
        self.assertEqual(MODULE.INLINE_MAX_BYTES, 5 * 1024 * 1024)

    def test_an_mp4_is_only_linked_so_it_gets_the_larger_limit(self):
        with tempfile.TemporaryDirectory() as scratch:
            clip = written(scratch, "clip.mp4", b"0" * (MODULE.INLINE_MAX_BYTES + 1))
            self.assertEqual(MODULE.check_size(clip, "video"), [])
            over = written(scratch, "huge.mp4", b"0" * (MODULE.FILE_MAX_BYTES + 1))
            with self.assertRaises(MODULE.MediaError):
                MODULE.check_size(over, "video")

    def test_a_large_but_allowed_clip_warns_instead(self):
        with tempfile.TemporaryDirectory() as scratch:
            large = written(scratch, "large.gif", b"0" * (MODULE.INLINE_WARN_BYTES + 1))
            warnings = MODULE.check_size(large, "gif")
            self.assertEqual(len(warnings), 1)
            self.assertIn("slow", warnings[0])

    def test_a_small_clip_says_nothing(self):
        with tempfile.TemporaryDirectory() as scratch:
            self.assertEqual(MODULE.check_size(written(scratch, "small.gif"), "gif"), [])


class ReadTests(unittest.TestCase):
    """The branch, the pull request and what is already uploaded are read with git, never the REST API: the
    host's gh guard refuses `contents/` reads and REST reads with no GraphQL equivalent."""

    def test_a_missing_branch_is_the_one_case_that_says_create_it(self):
        Origin(self, branch="other")
        with self.assertRaises(MODULE.MediaError) as raised:
            MODULE.require_branch("o/r", "pr-media")
        self.assertIn("create it", str(raised.exception))

    def test_an_unreachable_remote_with_no_api_either_says_both_and_never_says_create_it(self):
        origin = Origin(self)
        os.environ["PR_MEDIA_REMOTE_URL"] = f"file://{origin.root / 'gone.git'}"
        origin.api.fails = True
        with self.assertRaises(MODULE.MediaError) as raised:
            MODULE.require_branch("o/r", "pr-media")
        self.assertIn("ls-remote", str(raised.exception))
        self.assertIn("gh auth login", str(raised.exception))
        # The one thing it must never say: that the shared branch is missing.
        self.assertNotIn("create it", str(raised.exception))

    def test_when_git_cannot_reach_the_remote_the_reads_go_through_graphql(self):
        origin = Origin(self, existing=["12/shot.png"])
        os.environ["PR_MEDIA_REMOTE_URL"] = f"file://{origin.root / 'gone.git'}"
        MODULE.require_branch("o/r", "pr-media")
        MODULE.require_pull_request(7, "o/r")
        with self.assertRaises(MODULE.MediaError) as raised:
            MODULE.require_pull_request(999999, "o/r")
        self.assertIn("999999", str(raised.exception))
        self.assertEqual(MODULE.existing_sha("o/r", "pr-media", "12/shot.png"), origin.blob("12/shot.png"))
        self.assertIsNone(MODULE.existing_sha("o/r", "pr-media", "12"))
        self.assertIsNone(MODULE.existing_sha("o/r", "pr-media", "12/other.png"))
        # Every read is GraphQL; none asks for a file's content.
        self.assertTrue(origin.api.calls)
        self.assertFalse([call for call in origin.api.calls if "text" in call["query"] or "contents" in call["query"]])

    def test_git_is_tried_once_per_run_then_the_api_answers_at_once(self):
        origin = Origin(self)
        os.environ["PR_MEDIA_REMOTE_URL"] = f"file://{origin.root / 'gone.git'}"
        tried = []
        real = MODULE.MediaBranch.ls_remote

        def ls_remote(store, ref):
            tried.append(ref)
            return real(store, ref)

        with mock.patch.object(MODULE.MediaBranch, "ls_remote", ls_remote):
            MODULE.require_branch("o/r", "pr-media")
            MODULE.require_pull_request(7, "o/r")
        self.assertEqual(tried, ["refs/heads/pr-media"])

    def test_the_api_is_never_asked_while_git_works(self):
        origin = Origin(self, existing=["12/shot.png"])
        MODULE.require_branch("o/r", "pr-media")
        MODULE.require_pull_request(7, "o/r")
        MODULE.existing_sha("o/r", "pr-media", "12/shot.png")
        self.assertEqual(origin.api.calls, [])

    def test_an_existing_branch_and_pull_request_are_accepted(self):
        Origin(self)
        MODULE.require_branch("o/r", "pr-media")
        MODULE.require_pull_request(7, "o/r")

    def test_a_pull_request_that_does_not_exist_is_named(self):
        Origin(self)
        with self.assertRaises(MODULE.MediaError) as raised:
            MODULE.require_pull_request(999999, "o/r")
        self.assertIn("999999", str(raised.exception))
        self.assertIn("o/r", str(raised.exception))

    def test_a_file_on_the_branch_gives_the_blob_sha_github_reports(self):
        origin = Origin(self, existing=["12/shot.png"])
        self.assertEqual(MODULE.existing_sha("o/r", "pr-media", "12/shot.png"), origin.blob("12/shot.png"))

    def test_a_missing_path_or_a_folder_is_absent(self):
        Origin(self, existing=["12/shot.png"])
        self.assertIsNone(MODULE.existing_sha("o/r", "pr-media", "12/other.png"))
        self.assertIsNone(MODULE.existing_sha("o/r", "pr-media", "12"))
        self.assertIsNone(MODULE.existing_sha("o/r", "pr-media", "99/shot.png"))

    def test_the_cache_clone_is_bare_shallow_blobless_and_reused(self):
        origin = Origin(self, existing=["12/shot.png"])
        MODULE.existing_sha("o/r", "pr-media", "12/shot.png")
        clone = origin.root / "cache" / "o_r.git"
        self.assertEqual(git(clone, "rev-parse", "--is-bare-repository").strip(), "true")
        self.assertEqual(git(clone, "rev-parse", "--is-shallow-repository").strip(), "true")
        self.assertEqual(git(clone, "config", "remote.origin.partialclonefilter").strip(), "blob:none")
        # The branch's media never comes down: its blob is not in the clone.
        missing = subprocess.run(["git", "-C", str(clone), "cat-file", "-e", origin.blob("12/shot.png")],
                                 env={**os.environ, "GIT_NO_LAZY_FETCH": "1"}, capture_output=True)
        self.assertNotEqual(missing.returncode, 0)
        # A later run on the host reuses the clone and sees what landed since.
        origin.write({"12/late.png": b"late"})
        MODULE._BRANCHES.clear()
        self.assertEqual(MODULE.existing_sha("o/r", "pr-media", "12/late.png"), origin.blob("12/late.png"))

    def test_a_path_that_climbs_out_is_refused(self):
        Origin(self)
        for path in ("../x.png", "a//b.png", "/abs.png", ""):
            with self.subTest(path=path), self.assertRaises(MODULE.MediaError):
                MODULE.existing_sha("o/r", "pr-media", path)


class UploadTests(unittest.TestCase):
    def test_a_new_file_lands_and_an_existing_one_is_replaced_in_one_commit_each(self):
        origin = Origin(self, existing=["15277/shot.png"])
        with tempfile.TemporaryDirectory() as scratch:
            shot = written(scratch, "shot.png", PNG)
            before = origin.commits()
            MODULE.put_file("o/r", "pr-media", "15277/shot.png", shot, "msg", checked=True)
            MODULE.put_file("o/r", "pr-media", "15277/new.png", shot, "msg", checked=True)
        files = origin.files()
        self.assertEqual(files["15277/shot.png"], PNG)
        self.assertEqual(files["15277/new.png"], PNG)
        self.assertEqual(files["README.md"], b"media only\n")  # nothing else on the branch is touched
        self.assertEqual(origin.commits(), before + 2)

    def test_a_batch_lands_as_one_commit_and_deep_paths_get_their_folders(self):
        origin = Origin(self, existing=["9/abc/next-tour/keep.png"])
        with tempfile.TemporaryDirectory() as scratch:
            first, second = written(scratch, "a.png", PNG), written(scratch, "b.gif", GIF)
            before = origin.commits()
            MODULE.put_files("o/r", "pr-media", {"9/abc/next-tour/a.png": first, "10/b.gif": second}, "batch",
                             checked=True)
        files = origin.files()
        self.assertEqual((files["9/abc/next-tour/a.png"], files["10/b.gif"]), (PNG, GIF))
        self.assertEqual(files["9/abc/next-tour/keep.png"], b"old 9/abc/next-tour/keep.png")
        self.assertEqual(origin.commits(), before + 1)

    def test_a_write_that_lost_a_race_is_built_again_on_the_new_tip(self):
        # Two sessions uploading to the branch at once: the rejected push is the branch moving under us,
        # not a reason to lose the clip, nor to drop the other session's.
        origin = Origin(self)
        real_fetch = MODULE.MediaBranch.fetch
        raced = []

        def fetch(store):
            tip = real_fetch(store)
            if not raced:
                raced.append(tip)
                origin.write({"7/theirs.png": b"theirs"})
            return tip

        with tempfile.TemporaryDirectory() as scratch, mock.patch.object(MODULE.MediaBranch, "fetch", fetch), \
                mock.patch.object(MODULE.time, "sleep") as slept:
            MODULE.put_file("o/r", "pr-media", "7/mine.png", written(scratch, "mine.png", PNG), "m", checked=True)
        files = origin.files()
        self.assertEqual((files["7/mine.png"], files["7/theirs.png"]), (PNG, b"theirs"))
        self.assertGreaterEqual(slept.call_count, 1)  # at least the one lost race

    def test_a_path_taken_after_the_check_is_never_replaced_without_force(self):
        # Review of #28265: a run that saw 7/shot.png free, then lost the path to another uploader before its
        # push, must not silently replace that upload. The check holds on the tip the commit is built on.
        origin = Origin(self)
        with tempfile.TemporaryDirectory() as scratch:
            shot = written(scratch, "shot.png", PNG)
            real_put = MODULE.MediaBranch.put

            def put(store, files, message, expect=None):
                origin.write({"7/shot.png": b"theirs"})  # lands after main() checked, before the commit
                return real_put(store, files, message, expect=expect)

            with mock.patch.object(MODULE.MediaBranch, "put", put), \
                    contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()) as err:
                code = MODULE.main(["--pr", "7", str(shot)], runner=FakeGh())
        self.assertEqual(code, 1)
        self.assertIn("7/shot.png changed on pr-media", err.getvalue())
        self.assertEqual(origin.files()["7/shot.png"], b"theirs")

    def test_a_path_taken_during_a_lost_race_is_caught_on_the_rebuilt_tip(self):
        origin = Origin(self)
        real_fetch = MODULE.MediaBranch.fetch
        fetches = []

        def fetch(store):
            tip = real_fetch(store)
            fetches.append(tip)
            if len(fetches) == 1:
                origin.write({"7/shot.png": b"theirs"})  # the first push now loses, and the path is taken
            return tip

        with tempfile.TemporaryDirectory() as scratch, mock.patch.object(MODULE.MediaBranch, "fetch", fetch), \
                mock.patch.object(MODULE.time, "sleep"), self.assertRaises(MODULE.MediaError) as raised:
            MODULE.put_files("o/r", "pr-media", {"7/shot.png": written(scratch, "shot.png", PNG)}, "m",
                             checked=True, expect={"7/shot.png": None})
        self.assertIn("changed on pr-media", str(raised.exception))
        self.assertEqual(len(fetches), 2)
        self.assertEqual(origin.files()["7/shot.png"], b"theirs")

    def test_force_replaces_whatever_is_there_when_the_commit_is_built(self):
        origin = Origin(self, existing=["7/shot.png"])
        with tempfile.TemporaryDirectory() as scratch:
            shot = written(scratch, "shot.png", PNG)
            real_put = MODULE.MediaBranch.put

            def put(store, files, message, expect=None):
                self.assertIsNone(expect)
                origin.write({"7/shot.png": b"newer theirs"})
                return real_put(store, files, message, expect=expect)

            with mock.patch.object(MODULE.MediaBranch, "put", put), contextlib.redirect_stdout(io.StringIO()):
                code = MODULE.main(["--pr", "7", "--force", str(shot)], runner=FakeGh())
        self.assertEqual(code, 0)
        self.assertEqual(origin.files()["7/shot.png"], PNG)

    def test_only_the_cli_refuses_an_existing_path_and_put_file_replaces_it_as_on_base(self):
        # The no-replace rule is main()'s (without --force); put_file, which publish.py and reel.py call,
        # replaces the file, as the contents-API writer did by sending the existing sha with its PUT.
        origin = Origin(self, existing=["7/shot.png"])
        with tempfile.TemporaryDirectory() as scratch:
            shot = written(scratch, "shot.png", PNG)
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()) as err:
                code = MODULE.main(["--pr", "7", str(shot)], runner=FakeGh())
            self.assertEqual(code, 1)
            self.assertIn("--force", err.getvalue())
            self.assertEqual(origin.files()["7/shot.png"], b"old 7/shot.png")
            MODULE.put_file("o/r", "pr-media", "7/shot.png", shot, "m", checked=True)
        self.assertEqual(origin.files()["7/shot.png"], PNG)

    def test_a_refused_push_fails_with_what_the_remote_said_and_is_not_retried(self):
        origin = Origin(self)
        origin.hook("echo 'protected branch: no pushes here' >&2\nexit 1\n")
        with tempfile.TemporaryDirectory() as scratch, mock.patch.object(MODULE, "retry_pause") as slept, \
                self.assertRaises(MODULE.MediaError) as raised:
            MODULE.put_file("o/r", "pr-media", "1/shot.png", written(scratch, "shot.png", PNG), "m", checked=True)
        self.assertIn("protected branch", str(raised.exception))
        slept.assert_not_called()
        # The remote answered and refused: the API would be refused the same way, so it is not asked.
        self.assertEqual(origin.api.calls, [])
        self.assertNotIn("1/shot.png", origin.files())

    def test_a_branch_that_stays_busy_still_fails_after_a_bounded_number_of_pushes(self):
        origin = Origin(self)
        count = origin.root / "pushes"
        origin.hook(f"echo x >> '{count}'\necho 'non-fast-forward' >&2\nexit 1\n")
        with tempfile.TemporaryDirectory() as scratch, mock.patch.object(MODULE, "retry_pause"), \
                self.assertRaises(MODULE.MediaError):
            MODULE.put_file("o/r", "pr-media", "1/shot.png", written(scratch, "shot.png", PNG), "m", checked=True)
        self.assertEqual(len(count.read_text().split()), MODULE.PUSH_ATTEMPTS)
        # A race lost every time is not a transport failure: the API does not get a go at it.
        self.assertEqual(origin.api.calls, [])

    def test_a_folder_is_never_overwritten_by_a_file(self):
        origin = Origin(self, existing=["1/shot.png"])
        with tempfile.TemporaryDirectory() as scratch, self.assertRaises(MODULE.MediaError):
            MODULE.put_file("o/r", "pr-media", "1", written(scratch, "shot.png", PNG), "m", checked=True)
        self.assertIn("1/shot.png", origin.files())

    def test_in_ci_the_token_from_the_environment_authenticates_the_push(self):
        with mock.patch.dict(os.environ, {"GH_TOKEN": "t0ken"}):
            args = MODULE.credential_args()
        self.assertEqual(args[0::2], ["-c", "-c"])
        self.assertEqual(args[1], "credential.https://github.com.helper=")
        self.assertTrue(args[3].startswith("credential.https://github.com.helper=!"))
        self.assertNotIn("t0ken", " ".join(args))  # read from the environment by the helper, never on a command line
        with mock.patch.dict(os.environ, {}, clear=True):
            self.assertEqual(MODULE.credential_args(), [])

    def test_the_token_wins_over_a_helper_the_host_already_has(self):
        # Review of #28265: the token helper was appended after the host's own, and git stops at the first
        # helper that answers, so a cached account (one without push access, say) was used instead of GH_TOKEN.
        cached = '!f() { test "$1" = get || exit 0; echo username=cached; echo password=CACHED; }; f'
        env = {"PATH": os.environ.get("PATH", "/usr/bin"), "GIT_CONFIG_NOSYSTEM": "1",
               "GIT_CONFIG_GLOBAL": os.devnull, "GIT_TERMINAL_PROMPT": "0", "GIT_CONFIG_COUNT": "1",
               "GIT_CONFIG_KEY_0": "credential.helper", "GIT_CONFIG_VALUE_0": cached, "GH_TOKEN": "t0ken"}
        with mock.patch.dict(os.environ, env, clear=True):
            args = MODULE.credential_args()
            filled = subprocess.run(["git", *args, "credential", "fill"], input="url=https://github.com/o/r.git\n\n",
                                    capture_output=True, text=True, check=True).stdout
        self.assertIn("username=x-access-token\n", filled)
        self.assertIn("password=t0ken\n", filled)
        self.assertNotIn("CACHED", filled)

    def test_a_credential_in_a_remote_url_never_reaches_git_or_an_error(self):
        # Review of #28265: an origin like https://user:PAT@github.com/... was passed to ls-remote and
        # printed in its error. The userinfo is dropped before git runs, and any URL in an error is redacted.
        self.assertEqual(MODULE.without_userinfo("https://user:DUMMY_PAT@github.com/o/r.git"),
                         "https://github.com/o/r.git")
        self.assertEqual(MODULE.without_userinfo("https://x-access-token@github.com/o/r"), "https://github.com/o/r")
        self.assertEqual(MODULE.without_userinfo("git@github.com:o/r.git"), "git@github.com:o/r.git")
        self.assertNotIn("DUMMY_PAT", MODULE.redact("fatal: unable to access 'https://u:DUMMY_PAT@github.com/o/r/'"))
        Origin(self)
        os.environ["PR_MEDIA_REMOTE_URL"] = "https://u:DUMMY_PAT@127.0.0.1:9/o/r.git"
        store = MODULE.MediaBranch("o/r", "pr-media")
        self.assertNotIn("DUMMY_PAT", store.url)
        seen = []
        real_run = subprocess.run

        def run(argv, *args, **kwargs):
            seen.append(" ".join(map(str, argv)))
            return real_run(argv, *args, **kwargs)

        with mock.patch.object(MODULE.subprocess, "run", side_effect=run), \
                self.assertRaises(MODULE.MediaError) as raised:
            store.ls_remote("refs/heads/pr-media")
        self.assertNotIn("DUMMY_PAT", str(raised.exception))
        self.assertFalse([call for call in seen if "DUMMY_PAT" in call])

    def test_a_credential_only_in_the_origin_url_still_authenticates_and_is_in_no_arguments(self):
        # Review of #28265: dropping the URL's credential broke a host whose only credential was in that URL;
        # rewriting the URL to carry it put it in git-remote-https's arguments. Git gets it from a credential
        # helper that reads this child's environment, scoped to the clean URL.
        Origin(self)
        os.environ["PR_MEDIA_REMOTE_URL"] = "https://u:DUMMY%40PAT@github.com/o/r.git"
        store = MODULE.MediaBranch("o/r", "pr-media")
        self.assertEqual(store.url, "https://github.com/o/r.git")
        env = store.env()
        self.assertNotIn("DUMMY", " ".join(value for key, value in env.items() if key.startswith("GIT_CONFIG")))
        # A real request names the host only (no credential.useHttpPath); one with the path must match too.
        for asked in ("url=https://github.com\n\n", "url=https://github.com/o/r.git\n\n"):
            filled = subprocess.run(["git", "credential", "fill"], input=asked, capture_output=True, text=True,
                                    env=env, check=True).stdout
            self.assertIn("username=u\n", filled, asked)
            self.assertIn("password=DUMMY@PAT\n", filled, asked)
        # Any other host gets nothing from it.
        other = subprocess.run(["git", "credential", "fill"], input="url=https://example.com/x\n\n",
                               capture_output=True, text=True, env=env)
        self.assertNotIn("DUMMY", other.stdout)
        # The trace of a real fetch shows the secret in no process's arguments.
        traced = subprocess.run(["git", "ls-remote", "https://127.0.0.1:9/o/r.git"], capture_output=True, text=True,
                                env={**MODULE.MediaBranch("o/r", "pr-media",
                                                          url="https://u:DUMMY_PAT@127.0.0.1:9/o/r.git").env(),
                                     "GIT_TRACE": "1"}, timeout=60)
        self.assertNotIn("DUMMY_PAT", traced.stderr)
        store.dir.parent.mkdir(parents=True, exist_ok=True)
        store.ensure_clone()
        self.assertNotIn("DUMMY", (store.dir / "config").read_text())
        token_only = MODULE.url_credential_env({}, "https://TOK@github.com/o/r.git", "https://github.com/o/r.git")
        self.assertEqual((token_only["PR_MEDIA_URL_USERNAME"], token_only["PR_MEDIA_URL_PASSWORD"]),
                         ("x-access-token", "TOK"))

    def test_a_name_with_a_carriage_return_survives_an_unrelated_upload_byte_for_byte(self):
        # Review of #28265: text-mode ls-tree turned "a\rb" into "a\nb", so with both on the branch an
        # unrelated upload rewrote the tree with one of them gone.
        origin = Origin(self)
        for name in ("9/a\rb.png", "9/a\nb.png"):
            (origin.writer / name).parent.mkdir(parents=True, exist_ok=True)
            (origin.writer / name).write_bytes(name.encode())
            git(origin.writer, "add", "--", name)
        git(origin.writer, "commit", "-q", "-m", "odd names")
        git(origin.writer, "push", "-q", "origin", "HEAD:refs/heads/pr-media")

        def names():
            listed = subprocess.run(["git", "-C", str(origin.bare), "ls-tree", "-z", "--name-only", "pr-media:9"],
                                    check=True, capture_output=True).stdout
            return sorted(filter(None, listed.split(b"\0")))

        before = names()
        self.assertEqual(len(before), 2)
        with tempfile.TemporaryDirectory() as scratch:
            MODULE.put_file("o/r", "pr-media", "9/new.png", written(scratch, "new.png", PNG), "m", checked=True)
        self.assertEqual(names(), sorted([*before, b"new.png"]))

    def test_the_remote_is_a_local_clones_origin_when_there_is_one(self):
        for url in ("git@github.com:o/r.git", "https://github.com/O/R", "https://x-access-token@github.com/o/r.git",
                    "ssh://git@github.com/o/r.git"):
            self.assertTrue(MODULE.origin_is(url, "o/r"), url)
        for url in ("git@github.com:o/r2.git", "https://notgithub.com/o/r", "/srv/mirrors/github.com/o/r",
                    "https://gitlab.com/o/r"):
            self.assertFalse(MODULE.origin_is(url, "o/r"), url)
        with tempfile.TemporaryDirectory() as home, mock.patch.dict(os.environ, {"HOME": home}), \
                mock.patch.object(MODULE.Path, "cwd", return_value=Path(home)):
            os.environ.pop("PR_MEDIA_REMOTE_URL", None)
            self.assertEqual(MODULE.remote_url("o/r"), "https://github.com/o/r.git")
            clone = Path(home) / "Projects" / "cmux"
            subprocess.run(["git", "init", "-q", str(clone)], check=True)
            git(clone, "remote", "add", "origin", "git@github.com:o/r.git")
            self.assertEqual(MODULE.remote_url("o/r"), "git@github.com:o/r.git")


class ApiFallbackUploadTests(unittest.TestCase):
    """When git can't reach or authenticate to the remote, the batch still lands as one commit through
    GraphQL's createCommitOnBranch, with the same no-replace rule."""

    def unreachable(self, **options):
        origin = Origin(self, **options)
        os.environ["PR_MEDIA_REMOTE_URL"] = f"file://{origin.root / 'gone.git'}"
        return origin

    def test_a_batch_lands_as_one_commit_through_the_api(self):
        origin = self.unreachable()
        before = origin.commits()
        with tempfile.TemporaryDirectory() as scratch:
            first, second = written(scratch, "a.png", PNG), written(scratch, "b.gif", GIF)
            with contextlib.redirect_stdout(io.StringIO()) as out:
                code = MODULE.main(["--pr", "7", str(first), str(second)], runner=FakeGh())
        self.assertEqual(code, 0, out.getvalue())
        self.assertEqual(origin.commits(), before + 1)
        self.assertEqual((origin.files()["7/a.png"], origin.files()["7/b.gif"]), (PNG, GIF))
        self.assertIn("![", out.getvalue())

    def test_an_existing_file_needs_force_through_the_api_too(self):
        origin = self.unreachable(existing=["7/shot.png"])
        with tempfile.TemporaryDirectory() as scratch:
            shot = written(scratch, "shot.png", PNG)
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()) as err:
                code = MODULE.main(["--pr", "7", str(shot)], runner=FakeGh())
            self.assertEqual(code, 1)
            self.assertIn("--force", err.getvalue())
            self.assertEqual(origin.files()["7/shot.png"], b"old 7/shot.png")
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(MODULE.main(["--pr", "7", "--force", str(shot)], runner=FakeGh()), 0)
        self.assertEqual(origin.files()["7/shot.png"], PNG)

    def test_a_path_taken_after_the_check_is_never_replaced_through_the_api(self):
        origin = self.unreachable()
        with tempfile.TemporaryDirectory() as scratch:
            shot = written(scratch, "shot.png", PNG)
            real = MODULE.ApiBranch.put

            def put(store, files, message, expect=None):
                origin.write({"7/shot.png": b"theirs"})
                return real(store, files, message, expect=expect)

            with mock.patch.object(MODULE.ApiBranch, "put", put), \
                    contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()) as err:
                code = MODULE.main(["--pr", "7", str(shot)], runner=FakeGh())
        self.assertEqual(code, 1)
        self.assertIn("another upload got there first", err.getvalue())
        self.assertEqual(origin.files()["7/shot.png"], b"theirs")

    def test_a_lost_race_is_built_again_on_the_new_tip(self):
        origin = self.unreachable()
        api = MODULE.ApiBranch("o/r", "pr-media")
        real_tip = api.tip
        raced = []

        def tip():
            seen = real_tip()
            if not raced:
                raced.append(seen)
                origin.write({"9/other.png": b"theirs"})
            return seen

        api.tip = tip
        with tempfile.TemporaryDirectory() as scratch, mock.patch.object(MODULE, "retry_pause") as slept:
            api.put({"9/shot.png": written(scratch, "shot.png", PNG)}, "m", expect={"9/shot.png": None})
        self.assertEqual(slept.call_count, 1)
        self.assertEqual(origin.files()["9/other.png"], b"theirs")
        self.assertEqual(origin.files()["9/shot.png"], PNG)

    def test_a_folder_is_never_overwritten_through_the_api(self):
        origin = self.unreachable(existing=["1/shot.png"])
        with tempfile.TemporaryDirectory() as scratch, self.assertRaises(MODULE.MediaError) as raised:
            MODULE.put_file("o/r", "pr-media", "1", written(scratch, "shot.png", PNG), "m", checked=True)
        self.assertIn("folder", str(raised.exception))
        self.assertIn("1/shot.png", origin.files())

    def test_library_callers_still_get_the_privacy_check_on_the_api_path(self):
        self.unreachable()
        with tempfile.TemporaryDirectory() as scratch, \
                mock.patch.object(MODULE, "check_privacy", side_effect=MODULE.PrivacyError("refused")), \
                self.assertRaises(MODULE.PrivacyError):
            MODULE.put_file("o/r", "pr-media", "1/shot.png", written(scratch, "shot.png", PNG), "m")


class MainTests(unittest.TestCase):
    def run_main(self, argv, runner=None):
        with contextlib.redirect_stdout(io.StringIO()) as out, \
             contextlib.redirect_stderr(io.StringIO()) as err:
            code = MODULE.main(argv, runner=runner)
        return code, out.getvalue(), err.getvalue()

    def test_a_dry_run_prints_the_plan_and_the_markdown_without_touching_github(self):
        with tempfile.TemporaryDirectory() as scratch:
            clip = written(scratch, "sidebar-drag.mp4", MP4)

            def forbidden(argv, **kwargs):
                raise AssertionError(f"a dry run must not run anything, ran {argv}")

            with mock.patch.object(MODULE, "media_branch", side_effect=AssertionError("a dry run reads no branch")):
                code, out, _ = self.run_main(["--pr", "15277", "--dry-run", str(clip)], runner=forbidden)
            self.assertEqual(code, 0)
            self.assertIn("plan   gif  15277/sidebar-drag.gif", out)
            self.assertIn("plan video  15277/sidebar-drag.mp4", out)
            self.assertIn("![sidebar drag](", out)

    def test_a_dry_run_still_measures_the_files_it_was_given(self):
        with tempfile.TemporaryDirectory() as scratch:
            big = written(scratch, "big.gif", b"0" * (MODULE.INLINE_MAX_BYTES + 1))
            code, _, err = self.run_main(["--pr", "1", "--dry-run", str(big)])
            self.assertEqual(code, 1)
            self.assertIn("MB", err)

    def test_a_bad_pr_number_is_rejected_before_any_work(self):
        with tempfile.TemporaryDirectory() as scratch:
            clip = written(scratch, "clip.gif")
            code, _, err = self.run_main(["--pr", "0", str(clip)])
            self.assertEqual(code, 2)
            self.assertIn("pull request number", err)

    def test_the_default_branch_is_not_a_media_branch(self):
        with tempfile.TemporaryDirectory() as scratch:
            clip = written(scratch, "clip.gif", GIF)
            with mock.patch.object(MODULE, "media_branch", side_effect=AssertionError("must not reach the branch")):
                code, _, err = self.run_main(["--pr", "1", "--branch", "main", str(clip)], runner=FakeGh())
            self.assertEqual(code, 1)
            self.assertIn("main", err)

    def test_a_missing_file_fails_with_one_line(self):
        code, _, err = self.run_main(["--pr", "1", "/nonexistent/clip.gif"])
        self.assertEqual(code, 1)
        self.assertIn("not a file", err)
        self.assertNotIn("Traceback", err)

    def test_a_file_that_cannot_be_read_fails_with_one_line_too(self):
        Origin(self)
        with tempfile.TemporaryDirectory() as scratch:
            shot = written(scratch, "shot.png", PNG)
            shot.chmod(0o000)
            try:
                try:
                    shot.read_bytes()
                except OSError:
                    pass
                else:
                    self.skipTest("this user ignores file modes, so there is nothing to refuse")
                code, _, err = self.run_main(["--pr", "1", str(shot)], runner=FakeGh())
                self.assertEqual(code, 1)
                self.assertNotIn("Traceback", err)
                self.assertIn("shot.png", err)
            finally:
                shot.chmod(0o600)

    def test_an_upload_run_puts_every_file_in_one_commit_and_prints_the_markdown(self):
        origin = Origin(self)
        with tempfile.TemporaryDirectory() as scratch:
            first = written(scratch, "01-before.png", PNG)
            second = written(scratch, "02-after.png", PNG)
            gh = FakeGh()
            before = origin.commits()
            code, out, _ = self.run_main(["--pr", "15277", str(first), str(second)], runner=gh)
            self.assertEqual(code, 0)
            self.assertEqual(sorted(path for path in origin.files() if path.startswith("15277/")),
                             ["15277/01-before.png", "15277/02-after.png"])
            self.assertEqual(origin.commits(), before + 1)
            self.assertEqual(gh.calls, [])  # no gh call at all, REST or otherwise
            self.assertIn("![before](", out)
            self.assertIn("![after](", out)

    def test_an_mp4_is_converted_once_and_both_files_land(self):
        origin = Origin(self)
        with tempfile.TemporaryDirectory() as scratch:
            clip = written(scratch, "drag.mp4", MP4)
            conversions = []

            def runner(argv, **kwargs):
                if argv[0] == "ffmpeg":
                    conversions.append(argv)
                    Path(argv[-1]).write_bytes(GIF)
                    return SimpleNamespace(returncode=0, stdout="", stderr="")
                return FakeGh()(argv, **kwargs)

            with mock.patch.object(MODULE.shutil, "which", return_value="/usr/bin/ffmpeg"):
                code, out, _ = self.run_main(["--pr", "8", str(clip)], runner=runner)
            self.assertEqual(code, 0, out)
            self.assertEqual(len(conversions), 1)
            files = origin.files()
            self.assertEqual((files["8/drag.gif"], files["8/drag.mp4"]), (GIF, MP4))

    def test_an_upload_over_an_existing_clip_needs_force_and_says_what_it_replaces(self):
        origin = Origin(self, existing=["7/shot.png"])
        with tempfile.TemporaryDirectory() as scratch:
            shot = written(scratch, "shot.png", PNG)
            old = origin.blob("7/shot.png")
            code, _, err = self.run_main(["--pr", "7", str(shot)], runner=FakeGh())
            self.assertEqual(code, 1)
            self.assertIn("7/shot.png", err)
            self.assertIn("--force", err)
            self.assertNotEqual(origin.files()["7/shot.png"], PNG)

            MODULE._BRANCHES.clear()
            code, out, _ = self.run_main(["--pr", "7", "--force", str(shot)], runner=FakeGh())
            self.assertEqual(code, 0)
            self.assertIn("replacing 7/shot.png", out)
            self.assertIn(old, out)
            self.assertEqual(origin.files()["7/shot.png"], PNG)

    def test_nothing_is_uploaded_when_one_of_the_files_is_too_big(self):
        origin = Origin(self)
        with tempfile.TemporaryDirectory() as scratch:
            small = written(scratch, "01-small.png", PNG)
            big = written(scratch, "02-big.png", b"0" * (MODULE.INLINE_MAX_BYTES + 1))
            before = origin.commits()
            code, _, err = self.run_main(["--pr", "3", str(small), str(big)], runner=FakeGh())
            self.assertEqual(code, 1)
            self.assertIn("02-big.png", err)
            self.assertEqual(origin.commits(), before)

    def test_a_pull_request_that_does_not_exist_stops_before_the_first_write(self):
        origin = Origin(self)
        with tempfile.TemporaryDirectory() as scratch:
            shot = written(scratch, "shot.png", PNG)
            before = origin.commits()
            code, _, err = self.run_main(["--pr", "424242", str(shot)], runner=FakeGh())
            self.assertEqual(code, 1)
            self.assertIn("424242", err)
            self.assertEqual(origin.commits(), before)

    def test_a_refused_push_lands_nothing_and_prints_no_markdown(self):
        origin = Origin(self)
        origin.hook("echo 'could not write' >&2\nexit 1\n")
        with tempfile.TemporaryDirectory() as scratch:
            first = written(scratch, "01-before.png", PNG)
            second = written(scratch, "02-after.png", PNG)
            code, out, err = self.run_main(["--pr", "5", str(first), str(second)], runner=FakeGh())
            self.assertEqual(code, 1)
            self.assertIn("could not write", err)
            self.assertNotIn("![", out)
            self.assertFalse([path for path in origin.files() if path.startswith("5/")])

    def test_the_markdown_is_printed_even_when_the_comment_is_refused(self):
        Origin(self)
        with tempfile.TemporaryDirectory() as scratch:
            shot = written(scratch, "shot.png", PNG)
            code, out, err = self.run_main(["--pr", "7", "--comment", str(shot)], runner=FakeGh(comment_fails=True))
            self.assertEqual(code, 1)
            self.assertIn("![shot](", out)
            self.assertIn("403", err)

    def test_comment_is_only_posted_when_it_is_asked_for(self):
        Origin(self)
        with tempfile.TemporaryDirectory() as scratch:
            shot = written(scratch, "shot.png", PNG)
            for argv, expected in ([], 0), (["--comment"], 1):
                gh = FakeGh()
                code, _, _ = self.run_main(["--pr", "7", "--force", *argv, str(shot)], runner=gh)
                self.assertEqual(code, 0)
                self.assertEqual(len(gh.comments), expected, argv)
                if expected:
                    self.assertIn("![shot](", gh.comments[0])


class PrivacyTests(unittest.TestCase):
    """pr-media.py runs the shared check (scripts/ci/pr_media_privacy.py) with a
    fake OCR (a file holding LEAK reads as a fleet prompt) and a fake author lookup."""

    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="pr-media-privacy-test-")
        self.addCleanup(temporary.cleanup)
        self.scratch = temporary.name
        # A CI step inside .github/actions/pr-media-publish (PR_MEDIA_PUBLISH_GATE).
        self.env = {"HOME": self.scratch, "GITHUB_ACTIONS": "true", "PR_MEDIA_PRIVATE_TERMS": '["glow-box"]',
                    "PR_MEDIA_AGENT_AUTHORS": "bot-a", "PR_MEDIA_PUBLISH_GATE": "1"}
        self.authors = {7: "bot-a", 8: "teammate"}
        self.ocr_calls = []
        self.lookups = []

        def ocr(local):
            self.ocr_calls.append(local.name)
            data = local.read_bytes()
            # TERM: a frame showing the private-terms list's "glow-box".
            return ["cmux@cmux7s-Mac-mini ~ %"] if b"LEAK" in data else ["ssh glow-box"] if b"TERM" in data else ["ok"]

        def lookup(numbers):
            self.lookups.append(numbers)
            if self.authors is None:
                raise RuntimeError("GraphQL unavailable")
            return self.authors

        def check(items, repo, **options):
            REAL_CHECK_PRIVACY(items, repo, **{"env": self.env, "ocr": ocr, "lookup": lookup, **options})

        original = MODULE.check_privacy
        MODULE.check_privacy = check
        self.addCleanup(setattr, MODULE, "check_privacy", original)
        self.origin = Origin(self)

    def landed(self):
        return sorted(path for path in self.origin.files() if path != "README.md")

    def run_main(self, argv, runner=None):
        with contextlib.redirect_stdout(io.StringIO()) as out, \
             contextlib.redirect_stderr(io.StringIO()) as err:
            code = MODULE.main(argv, runner=runner)
        return code, out.getvalue(), err.getvalue()

    def test_an_agents_capture_with_a_private_name_is_refused_before_any_upload(self):
        clean = written(self.scratch, "01-clean.png", PNG)
        leak = written(self.scratch, "02-leak.png", PNG + b"LEAK")
        gh = FakeGh()
        code, out, err = self.run_main(["--pr", "7", str(clean), str(leak)], runner=gh)
        self.assertEqual(code, 1)
        self.assertEqual(self.landed(), [])
        self.assertIn("7/02-leak.png", err)
        self.assertIn("refused", err)
        self.assertNotIn("cmux7s", out + err)

    def test_a_clean_capture_is_uploaded_and_checked_once(self):
        clean = written(self.scratch, "shot.png", PNG)
        gh = FakeGh()
        code, _, _ = self.run_main(["--pr", "7", str(clean)], runner=gh)
        self.assertEqual(code, 0)
        self.assertEqual(self.landed(), ["7/shot.png"])
        self.assertEqual(self.ocr_calls, ["shot.png"])

    def test_a_teammates_capture_with_a_private_name_is_refused_and_names_only_its_category(self):
        # Leo, 2026-10-22: "1 ok": a teammate's PR is refused like an agent's, and nothing is uploaded.
        clean = written(self.scratch, "01-clean.png", PNG)
        frame = written(self.scratch, "02-frame.png", PNG + b"TERM")
        gh = FakeGh()
        code, out, err = self.run_main(["--pr", "8", str(clean), str(frame)], runner=gh)
        self.assertEqual(code, 1)
        self.assertEqual(self.landed(), [])
        self.assertIn("8/02-frame.png shows a personal machine or account name; refused", err)
        self.assertIn("then recapture", err)
        self.assertNotIn("glow", (out + err).replace(self.scratch, ""))
        self.assertEqual(self.lookups, [])  # whoever's PR it is, no author decides

    def test_a_refusal_names_each_category_never_the_text(self):
        leak = written(self.scratch, "shot.png", PNG + b"LEAK")
        gh = FakeGh()
        code, out, err = self.run_main(["--pr", "8", str(leak)], runner=gh)
        self.assertEqual(code, 1)
        self.assertEqual(self.landed(), [])
        self.assertIn("fleet Mac mini name", err)
        self.assertIn("fleet shell prompt", err)
        self.assertNotIn("cmux7s", out + err)

    def test_the_gif_made_from_an_mp4_is_what_gets_checked(self):
        clip = written(self.scratch, "drag.mp4", MP4)
        gh = FakeGh()

        def runner(argv, **kwargs):
            if argv[0] == "ffmpeg":
                Path(argv[-1]).write_bytes(GIF + b"LEAK")
                return SimpleNamespace(returncode=0, stdout="", stderr="")
            return gh(argv, **kwargs)

        with mock.patch.object(MODULE.shutil, "which", return_value="/usr/bin/ffmpeg"):
            code, _, err = self.run_main(["--pr", "7", str(clip)], runner=runner)
        self.assertEqual(code, 1)
        self.assertIn("7/drag.gif", err)
        self.assertEqual(self.landed(), [])

    def test_a_dry_run_checks_the_files_it_was_given(self):
        leak = written(self.scratch, "shot.png", PNG + b"LEAK")

        def forbidden(argv, **kwargs):
            raise AssertionError(f"a dry run must not run anything, ran {argv}")

        code, out, err = self.run_main(["--pr", "7", "--dry-run", str(leak)], runner=forbidden)
        self.assertEqual(code, 1)
        self.assertIn("privacy check", out)
        self.assertIn("7/shot.png", err)

    def test_a_dry_run_looks_no_pull_request_author_up(self):
        leak = written(self.scratch, "shot.png", PNG + b"LEAK")
        code, out, err = self.run_main(["--pr", "8", "--dry-run", str(leak)])
        self.assertEqual(self.lookups, [])
        self.assertEqual(code, 1)
        self.assertIn("8/shot.png", err)

    def test_off_ci_a_hit_is_refused_too(self):
        self.env = {"HOME": self.scratch, "PR_MEDIA_PRIVATE_TERMS": '["glow-box"]'}
        frame = written(self.scratch, "shot.png", PNG + b"TERM")
        gh = FakeGh()
        code, _, err = self.run_main(["--pr", "8", str(frame)], runner=gh)
        self.assertEqual(code, 1)
        self.assertEqual(self.landed(), [])
        self.assertIn("personal machine or account name", err)

    def test_a_refusal_is_a_privacy_error_so_callers_never_retry_it(self):
        leak = written(self.scratch, "shot.png", PNG + b"LEAK")
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(MODULE.PrivacyError):
            MODULE.check_privacy([("7/shot.png", leak)], "o/r")
        self.assertTrue(issubclass(MODULE.PrivacyError, MODULE.MediaError))

    def test_put_file_checks_for_library_callers_unless_already_checked(self):
        leak = written(self.scratch, "shot.png", PNG + b"LEAK")
        gh = FakeGh()
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(MODULE.MediaError):
            MODULE.put_file("o/r", "pr-media", "nightly-next/reel/shot.png", leak, "msg", runner=gh)
        self.assertEqual(self.landed(), [])
        MODULE.put_file("o/r", "pr-media", "nightly-next/reel/shot.png", leak, "msg", runner=gh, checked=True)
        self.assertEqual(self.landed(), ["nightly-next/reel/shot.png"])

    def test_a_refusal_is_never_retried_like_a_busy_branch(self):
        # put_file retries a lost race and a GitHub 5xx; a refusal gets the same
        # answer every time, so it must stop before the first write.
        leak = written(self.scratch, "shot.png", PNG + b"LEAK")
        with contextlib.redirect_stderr(io.StringIO()), mock.patch("time.sleep") as slept, \
                mock.patch.object(MODULE, "media_branch", side_effect=AssertionError("refused before the branch")), \
                self.assertRaises(MODULE.PrivacyError):
            MODULE.put_file("o/r", "pr-media", "7/shot.png", leak, "msg")
        slept.assert_not_called()

    def test_a_checkout_without_the_privacy_check_refuses_to_upload(self):
        shot = written(self.scratch, "shot.png", PNG)
        with mock.patch.object(MODULE, "PRIVACY_MODULE", Path(self.scratch) / "absent.py"), \
                mock.patch.object(MODULE, "_privacy", None), self.assertRaises(MODULE.MediaError) as raised:
            REAL_CHECK_PRIVACY([("7/shot.png", shot)], "o/r")
        self.assertIn("absent.py", str(raised.exception))


class HelpTests(unittest.TestCase):
    def test_the_script_runs_and_documents_itself(self):
        done = subprocess.run([sys.executable, str(ROOT / "scripts/pr-media.py"), "--help"],
                              capture_output=True, text=True)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("--pr", done.stdout)
        self.assertIn("pr-media", done.stdout)


if __name__ == "__main__":
    unittest.main()
