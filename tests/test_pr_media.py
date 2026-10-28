#!/usr/bin/env python3

import base64
import contextlib
import importlib.util
import io
import json
import subprocess
import sys
import tempfile
import unittest
import urllib.parse
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
REAL_CHECK_PRIVACY = MODULE.check_privacy
MODULE.check_privacy = lambda items, repo, **options: None

PNG = b"\x89PNG\r\n\x1a\n" + b"0" * 32
MP4 = b"\x00\x00\x00\x18ftypisom" + b"0" * 32
GIF = b"GIF89a" + b"0" * 32

NOT_FOUND = "gh: Not Found (HTTP 404)"


def written(directory, name, data=b"media"):
    path = Path(directory) / name
    path.write_bytes(data)
    return path


class FakeGh:
    """Stands in for `gh`, recording the calls and the decoded bodies.

    It answers the four routes the script uses (a branch read, a pull request
    read, a contents read, a contents PUT) the way GitHub does, including the
    422 for a write over an existing file with no sha: a fake that accepts that
    write lets a real bug through.
    """

    def __init__(self, existing=(), fail=(), missing_branch=False, missing_pr=False,
                 read_error=None, conflict_once=(), comment_fails=False):
        self.existing = {path: "abc123" for path in existing}
        self.fail = set(fail)
        self.missing_branch = missing_branch
        self.missing_pr = missing_pr
        self.read_error = read_error
        self.conflict_once = set(conflict_once)
        self.comment_fails = comment_fails
        self.calls = []
        self.puts = {}
        self.comments = []

    def __call__(self, argv, **kwargs):
        self.calls.append(argv)
        if argv[:2] == ["gh", "pr"]:
            if self.comment_fails:
                return self.reply(1, "", "HTTP 403: Resource not accessible")
            self.comments.append(kwargs.get("input", ""))
            return self.reply(0, "")
        if "--method" in argv and "PUT" in argv:
            return self.put(argv, kwargs)
        if self.read_error:
            return self.reply(1, "", self.read_error)
        joined = " ".join(argv)
        if "/branches/" in joined:
            if self.missing_branch:
                return self.reply(1, "", NOT_FOUND)
            return self.reply(0, json.dumps({"name": argv[-1].rsplit("/", 1)[-1]}))
        if "/pulls/" in joined:
            if self.missing_pr:
                return self.reply(1, "", NOT_FOUND)
            return self.reply(0, json.dumps({"number": int(argv[-1].rsplit("/", 1)[-1])}))
        path = urllib.parse.unquote(argv[-1].split("/contents/", 1)[-1].split("?")[0])
        sha = self.existing.get(path)
        return self.reply(0, json.dumps({"sha": sha})) if sha else self.reply(1, "", NOT_FOUND)

    def put(self, argv, kwargs):
        target = urllib.parse.unquote(argv[argv.index("--method") + 2].split("/contents/", 1)[-1])
        body = json.loads(kwargs["input"])
        if target in self.fail:
            return self.reply(1, "", "422 could not write")
        if target in self.conflict_once:
            self.conflict_once.discard(target)
            return self.reply(1, "", "gh: Conflict (HTTP 409) is at 9f9f9f but expected abc123")
        if target in self.existing and "sha" not in body:
            return self.reply(1, "", '422 Unprocessable Entity: "sha" wasn\'t supplied')
        self.puts[target] = body
        self.existing[target] = "newsha"
        return self.reply(0, json.dumps({"content": {"path": target}}))

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
    """A failed `gh` read is a failure, not an absence."""

    def test_a_read_that_is_not_a_404_surfaces_what_gh_said(self):
        gh = FakeGh(read_error="gh: Bad credentials (HTTP 401)")
        with self.assertRaises(MODULE.MediaError) as raised:
            MODULE.require_branch("o/r", "pr-media", runner=gh)
        message = str(raised.exception)
        self.assertIn("HTTP 401", message)
        self.assertIn("gh auth status", message)
        # The one thing it must never say: that the shared branch is missing.
        self.assertNotIn("create it", message)

    def test_a_404_on_the_branch_is_the_one_case_that_says_create_it(self):
        gh = FakeGh(missing_branch=True)
        with self.assertRaises(MODULE.MediaError) as raised:
            MODULE.require_branch("o/r", "pr-media", runner=gh)
        self.assertIn("create it", str(raised.exception))
        self.assertFalse([argv for argv in gh.calls if "PUT" in argv])

    def test_an_existing_branch_is_accepted_and_read_with_a_quoted_name(self):
        gh = FakeGh()
        MODULE.require_branch("o/r", "pr media/2", runner=gh)
        self.assertIn("pr%20media%2F2", " ".join(gh.calls[0]))

    def test_a_sha_read_that_fails_for_another_reason_does_not_look_absent(self):
        gh = FakeGh(read_error="gh: Forbidden (HTTP 403)")
        with self.assertRaises(MODULE.MediaError) as raised:
            MODULE.existing_sha("o/r", "pr-media", "1/shot.png", runner=gh)
        self.assertIn("HTTP 403", str(raised.exception))

    def test_a_pull_request_that_does_not_exist_is_named(self):
        gh = FakeGh(missing_pr=True)
        with self.assertRaises(MODULE.MediaError) as raised:
            MODULE.require_pull_request(999999, "o/r", runner=gh)
        self.assertIn("999999", str(raised.exception))
        self.assertIn("o/r", str(raised.exception))


class UploadTests(unittest.TestCase):
    def test_a_new_file_is_created_and_an_existing_one_carries_its_sha(self):
        with tempfile.TemporaryDirectory() as scratch:
            shot = written(scratch, "shot.png", PNG)
            gh = FakeGh(existing={"15277/shot.png"})
            MODULE.put_file("o/r", "pr-media", "15277/shot.png", shot, "msg", runner=gh)
            body = gh.puts["15277/shot.png"]
            self.assertEqual(body["sha"], "abc123")
            self.assertEqual(base64.b64decode(body["content"]), PNG)
            self.assertEqual(body["branch"], "pr-media")

            fresh = FakeGh()
            MODULE.put_file("o/r", "pr-media", "15277/new.png", shot, "msg", runner=fresh)
            self.assertNotIn("sha", fresh.puts["15277/new.png"])

    def test_the_body_goes_in_on_stdin_rather_than_the_argument_list(self):
        with tempfile.TemporaryDirectory() as scratch:
            shot = written(scratch, "shot.png", b"x" * 4096)
            gh = FakeGh()
            MODULE.put_file("o/r", "pr-media", "1/shot.png", shot, "msg", runner=gh)
            put = [argv for argv in gh.calls if "PUT" in argv][0]
            self.assertIn("--input", put)
            self.assertEqual(put[put.index("--input") + 1], "-")
            self.assertFalse(any(len(argument) > 300 for argument in put))

    def test_a_refused_write_fails_the_run_with_what_github_said(self):
        with tempfile.TemporaryDirectory() as scratch:
            shot = written(scratch, "shot.png")
            gh = FakeGh(fail={"1/shot.png"})
            with self.assertRaises(MODULE.MediaError) as raised:
                MODULE.put_file("o/r", "pr-media", "1/shot.png", shot, "msg", runner=gh)
            self.assertIn("could not write", str(raised.exception))

    def test_a_write_that_lost_a_race_is_retried_with_the_sha_it_read_again(self):
        # Two sessions uploading to the branch at once: the 409 is the branch
        # moving under us, not a reason to lose the clip.
        with tempfile.TemporaryDirectory() as scratch:
            shot = written(scratch, "shot.png", PNG)
            gh = FakeGh(conflict_once={"1/shot.png"})
            MODULE.put_file("o/r", "pr-media", "1/shot.png", shot, "msg", runner=gh)
            self.assertEqual(len([argv for argv in gh.calls if "PUT" in argv]), 2)
            self.assertEqual(base64.b64decode(gh.puts["1/shot.png"]["content"]), PNG)

    def test_a_conflict_that_keeps_happening_still_fails_rather_than_looping(self):
        with tempfile.TemporaryDirectory() as scratch:
            shot = written(scratch, "shot.png", PNG)
            gh = FakeGh(fail={"1/shot.png"}, conflict_once={"1/shot.png"})
            with self.assertRaises(MODULE.MediaError):
                MODULE.put_file("o/r", "pr-media", "1/shot.png", shot, "msg", runner=gh)
            self.assertLessEqual(len([argv for argv in gh.calls if "PUT" in argv]), 3)


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

            def forbidden(argv, **kwargs):
                raise AssertionError(f"must not reach gh, ran {argv}")

            code, _, err = self.run_main(["--pr", "1", "--branch", "main", str(clip)],
                                         runner=forbidden)
            self.assertEqual(code, 1)
            self.assertIn("main", err)

    def test_a_missing_file_fails_with_one_line(self):
        code, _, err = self.run_main(["--pr", "1", "/nonexistent/clip.gif"])
        self.assertEqual(code, 1)
        self.assertIn("not a file", err)
        self.assertNotIn("Traceback", err)

    def test_a_file_that_cannot_be_read_fails_with_one_line_too(self):
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

    def test_an_upload_run_puts_every_file_and_prints_the_markdown(self):
        with tempfile.TemporaryDirectory() as scratch:
            first = written(scratch, "01-before.png", PNG)
            second = written(scratch, "02-after.png", PNG)
            gh = FakeGh()
            code, out, _ = self.run_main(["--pr", "15277", str(first), str(second)], runner=gh)
            self.assertEqual(code, 0)
            self.assertEqual(sorted(gh.puts), ["15277/01-before.png", "15277/02-after.png"])
            self.assertIn("![before](", out)
            self.assertIn("![after](", out)

    def test_an_mp4_is_converted_once_and_both_files_land(self):
        with tempfile.TemporaryDirectory() as scratch:
            clip = written(scratch, "drag.mp4", MP4)
            gh = FakeGh()
            conversions = []

            def runner(argv, **kwargs):
                if argv[0] == "ffmpeg":
                    conversions.append(argv)
                    Path(argv[-1]).write_bytes(GIF)
                    return gh.reply(0, "")
                return gh(argv, **kwargs)

            with mock.patch.object(MODULE.shutil, "which", return_value="/usr/bin/ffmpeg"):
                code, out, _ = self.run_main(["--pr", "8", str(clip)], runner=runner)
            self.assertEqual(code, 0, out)
            self.assertEqual(len(conversions), 1)
            self.assertEqual(sorted(gh.puts), ["8/drag.gif", "8/drag.mp4"])
            self.assertEqual(base64.b64decode(gh.puts["8/drag.gif"]["content"]), GIF)
            self.assertEqual(base64.b64decode(gh.puts["8/drag.mp4"]["content"]), MP4)

    def test_an_upload_over_an_existing_clip_needs_force_and_says_what_it_replaces(self):
        with tempfile.TemporaryDirectory() as scratch:
            shot = written(scratch, "shot.png", PNG)
            gh = FakeGh(existing={"7/shot.png"})
            code, _, err = self.run_main(["--pr", "7", str(shot)], runner=gh)
            self.assertEqual(code, 1)
            self.assertIn("7/shot.png", err)
            self.assertIn("--force", err)
            self.assertFalse(gh.puts)

            forced = FakeGh(existing={"7/shot.png"})
            code, out, _ = self.run_main(["--pr", "7", "--force", str(shot)], runner=forced)
            self.assertEqual(code, 0)
            self.assertIn("replacing 7/shot.png", out)
            self.assertIn("abc123", out)

    def test_nothing_is_uploaded_when_one_of_the_files_is_too_big(self):
        with tempfile.TemporaryDirectory() as scratch:
            small = written(scratch, "01-small.png", PNG)
            big = written(scratch, "02-big.png", b"0" * (MODULE.INLINE_MAX_BYTES + 1))
            gh = FakeGh()
            code, _, err = self.run_main(["--pr", "3", str(small), str(big)], runner=gh)
            self.assertEqual(code, 1)
            self.assertIn("02-big.png", err)
            self.assertFalse(gh.puts)

    def test_a_pull_request_that_does_not_exist_stops_before_the_first_write(self):
        with tempfile.TemporaryDirectory() as scratch:
            shot = written(scratch, "shot.png", PNG)
            gh = FakeGh(missing_pr=True)
            code, _, err = self.run_main(["--pr", "424242", str(shot)], runner=gh)
            self.assertEqual(code, 1)
            self.assertIn("424242", err)
            self.assertFalse(gh.puts)

    def test_a_failure_part_way_through_still_prints_what_landed(self):
        with tempfile.TemporaryDirectory() as scratch:
            first = written(scratch, "01-before.png", PNG)
            second = written(scratch, "02-after.png", PNG)
            gh = FakeGh(fail={"5/02-after.png"})
            code, out, err = self.run_main(["--pr", "5", str(first), str(second)], runner=gh)
            self.assertEqual(code, 1)
            self.assertIn("could not write", err)
            # The one clip that did land is still linkable, and it is named as
            # partial so nobody pastes half the evidence without knowing.
            self.assertIn("![before](", out)
            self.assertNotIn("![after](", out)
            self.assertIn("5/01-before.png", out)

    def test_the_markdown_is_printed_even_when_the_comment_is_refused(self):
        with tempfile.TemporaryDirectory() as scratch:
            shot = written(scratch, "shot.png", PNG)
            gh = FakeGh(comment_fails=True)
            code, out, err = self.run_main(["--pr", "7", "--comment", str(shot)], runner=gh)
            self.assertEqual(code, 1)
            self.assertIn("![shot](", out)
            self.assertIn("403", err)

    def test_comment_is_only_posted_when_it_is_asked_for(self):
        with tempfile.TemporaryDirectory() as scratch:
            shot = written(scratch, "shot.png", PNG)
            for argv, expected in ([], 0), (["--comment"], 1):
                gh = FakeGh()
                code, _, _ = self.run_main(["--pr", "7", *argv, str(shot)], runner=gh)
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
        self.assertFalse(gh.puts)
        self.assertIn("7/02-leak.png", err)
        self.assertIn("refused", err)
        self.assertNotIn("cmux7s", out + err)

    def test_a_clean_capture_is_uploaded_and_checked_once(self):
        clean = written(self.scratch, "shot.png", PNG)
        gh = FakeGh()
        code, _, _ = self.run_main(["--pr", "7", str(clean)], runner=gh)
        self.assertEqual(code, 0)
        self.assertEqual(sorted(gh.puts), ["7/shot.png"])
        self.assertEqual(self.ocr_calls, ["shot.png"])

    def test_a_teammates_capture_with_a_private_name_is_refused_and_names_only_its_category(self):
        # Leo, 2026-10-22: "1 ok": a teammate's PR is refused like an agent's, and nothing is uploaded.
        clean = written(self.scratch, "01-clean.png", PNG)
        frame = written(self.scratch, "02-frame.png", PNG + b"TERM")
        gh = FakeGh()
        code, out, err = self.run_main(["--pr", "8", str(clean), str(frame)], runner=gh)
        self.assertEqual(code, 1)
        self.assertFalse(gh.puts)
        self.assertIn("8/02-frame.png shows a personal machine or account name; refused", err)
        self.assertIn("then recapture", err)
        self.assertNotIn("glow", (out + err).replace(self.scratch, ""))
        self.assertEqual(self.lookups, [])  # whoever's PR it is, no author decides

    def test_a_refusal_names_each_category_never_the_text(self):
        leak = written(self.scratch, "shot.png", PNG + b"LEAK")
        gh = FakeGh()
        code, out, err = self.run_main(["--pr", "8", str(leak)], runner=gh)
        self.assertEqual(code, 1)
        self.assertFalse(gh.puts)
        self.assertIn("fleet Mac mini name", err)
        self.assertIn("fleet shell prompt", err)
        self.assertNotIn("cmux7s", out + err)

    def test_the_gif_made_from_an_mp4_is_what_gets_checked(self):
        clip = written(self.scratch, "drag.mp4", MP4)
        gh = FakeGh()

        def runner(argv, **kwargs):
            if argv[0] == "ffmpeg":
                Path(argv[-1]).write_bytes(GIF + b"LEAK")
                return gh.reply(0, "")
            return gh(argv, **kwargs)

        with mock.patch.object(MODULE.shutil, "which", return_value="/usr/bin/ffmpeg"):
            code, _, err = self.run_main(["--pr", "7", str(clip)], runner=runner)
        self.assertEqual(code, 1)
        self.assertIn("7/drag.gif", err)
        self.assertFalse(gh.puts)

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
        self.assertFalse(gh.puts)
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
        self.assertFalse(gh.puts)
        MODULE.put_file("o/r", "pr-media", "nightly-next/reel/shot.png", leak, "msg", runner=gh, checked=True)
        self.assertEqual(list(gh.puts), ["nightly-next/reel/shot.png"])

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
