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
from pathlib import Path
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("pr_media", ROOT / "scripts/pr-media.py")
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


def written(directory, name, data=b"media"):
    path = Path(directory) / name
    path.write_bytes(data)
    return path


class FakeGh:
    """Stands in for `gh api`, recording the calls and the decoded bodies."""

    def __init__(self, existing=(), fail=()):
        self.existing = set(existing)
        self.fail = set(fail)
        self.calls = []
        self.puts = {}

    def __call__(self, argv, **kwargs):
        self.calls.append(argv)
        joined = " ".join(argv)
        if "/branches/" in joined:
            name = argv[-1].rsplit("/", 1)[-1]
            return self.reply(0, json.dumps({"name": name})) if name != "missing" else self.reply(1, "", "404")
        if "--method" in argv and "PUT" in argv:
            path = argv[argv.index("--method") + 2]
            body = json.loads(kwargs["input"])
            if path.rsplit("/contents/", 1)[-1] in self.fail:
                return self.reply(1, "", "422 could not write")
            self.puts[path.rsplit("/contents/", 1)[-1]] = body
            return self.reply(0, json.dumps({"content": {"path": path}}))
        # A contents read: the sha of an existing file, or a 404.
        path = argv[-1].split("/contents/", 1)[-1].split("?")[0]
        if path in self.existing:
            return self.reply(0, json.dumps({"sha": "abc123"}))
        return self.reply(1, "", "404 Not Found")

    def reply(self, code, out, err=""):
        return SimpleNamespace(returncode=code, stdout=out, stderr=err)


class NameTests(unittest.TestCase):
    def test_a_name_keeps_its_shape_and_loses_what_a_url_cannot_carry(self):
        self.assertEqual(MODULE.sanitize("sidebar drag.gif"), "sidebar-drag.gif")
        self.assertEqual(MODULE.sanitize("01-Record@2x.MP4"), "01-Record-2x.mp4")
        self.assertEqual(MODULE.sanitize("a  b   c.png"), "a-b-c.png")
        self.assertEqual(MODULE.sanitize("keeps_underscores.gif"), "keeps_underscores.gif")

    def test_a_name_with_nothing_usable_is_rejected(self):
        with self.assertRaises(MODULE.MediaError):
            MODULE.sanitize("---.gif")

    def test_a_caption_drops_a_step_number_and_reads_as_words(self):
        self.assertEqual(MODULE.label_for("02-sidebar-drag.gif"), "sidebar drag")
        self.assertEqual(MODULE.label_for("settings_dark.png"), "settings dark")
        # A leading number that is part of the name, not a step index, stays.
        self.assertEqual(MODULE.label_for("15277.gif"), "15277")


class PlanTests(unittest.TestCase):
    def test_an_mp4_plans_a_gif_beside_it(self):
        with tempfile.TemporaryDirectory() as scratch:
            clip = written(scratch, "sidebar-drag.mp4")
            uploads = MODULE.plan([clip], 15277, None, gif=True)
            self.assertEqual([(u.name, u.kind) for u in uploads],
                             [("sidebar-drag.gif", "gif"), ("sidebar-drag.mp4", "video")])
            # The gif is made from the mp4, not uploaded from a path of its own.
            self.assertEqual(uploads[0].local, clip)
            self.assertEqual(uploads[0].source_name, "sidebar-drag.mp4")
            self.assertIsNone(uploads[1].source_name)

    def test_no_gif_uploads_the_mp4_alone(self):
        with tempfile.TemporaryDirectory() as scratch:
            clip = written(scratch, "clip.mp4")
            uploads = MODULE.plan([clip], 1, None, gif=False)
            self.assertEqual([(u.name, u.kind) for u in uploads], [("clip.mp4", "video")])

    def test_a_gif_from_cmux_record_is_uploaded_as_it_is(self):
        with tempfile.TemporaryDirectory() as scratch:
            uploads = MODULE.plan([written(scratch, "already.gif")], 1, None, gif=True)
            self.assertEqual([(u.name, u.kind, u.source_name) for u in uploads],
                             [("already.gif", "gif", None)])

    def test_two_files_that_would_share_a_name_are_refused(self):
        with tempfile.TemporaryDirectory() as scratch:
            (Path(scratch) / "a").mkdir()
            (Path(scratch) / "b").mkdir()
            one = written(Path(scratch) / "a", "clip.gif")
            two = written(Path(scratch) / "b", "clip.gif")
            with self.assertRaises(MODULE.MediaError) as raised:
                MODULE.plan([one, two], 1, None, gif=True)
            self.assertIn("clip.gif", str(raised.exception))

    def test_an_mp4_that_would_overwrite_an_uploaded_gif_is_refused(self):
        with tempfile.TemporaryDirectory() as scratch:
            gif = written(scratch, "clip.gif")
            mp4 = written(scratch, "clip.mp4")
            with self.assertRaises(MODULE.MediaError):
                MODULE.plan([gif, mp4], 1, None, gif=True)

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
            body = MODULE.markdown(MODULE.plan([clip], 15277, None, gif=True), 15277)
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
            body = MODULE.markdown(MODULE.plan([clip], 9, None, gif=False), 9)
            self.assertIn("[clip (clip.mov)](https://raw.githubusercontent.com/manaflow-ai/cmux/pr-media/9/clip.mov)",
                          body)

    def test_a_label_names_a_single_file(self):
        with tempfile.TemporaryDirectory() as scratch:
            shot = written(scratch, "01-x.png")
            body = MODULE.markdown(MODULE.plan([shot], 3, "before: one tab", gif=True), 3)
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


class SizeTests(unittest.TestCase):
    def test_a_clip_past_the_limit_is_refused_with_advice(self):
        with tempfile.TemporaryDirectory() as scratch:
            big = written(scratch, "big.gif", b"0" * (MODULE.MAX_BYTES + 1))
            with self.assertRaises(MODULE.MediaError) as raised:
                MODULE.check_size(big)
            self.assertIn("--gif-fps", str(raised.exception))

    def test_a_large_but_allowed_clip_warns_instead(self):
        with tempfile.TemporaryDirectory() as scratch:
            large = written(scratch, "large.gif", b"0" * (MODULE.WARN_BYTES + 1))
            warnings = MODULE.check_size(large)
            self.assertEqual(len(warnings), 1)
            self.assertIn("slow to load", warnings[0])

    def test_a_small_clip_says_nothing(self):
        with tempfile.TemporaryDirectory() as scratch:
            self.assertEqual(MODULE.check_size(written(scratch, "small.gif")), [])


class UploadTests(unittest.TestCase):
    def test_a_new_file_is_created_and_an_existing_one_carries_its_sha(self):
        with tempfile.TemporaryDirectory() as scratch:
            shot = written(scratch, "shot.png", b"pixels")
            gh = FakeGh(existing={"15277/shot.png"})
            MODULE.put_file("o/r", "pr-media", "15277/shot.png", shot, "msg", runner=gh)
            body = gh.puts["15277/shot.png"]
            self.assertEqual(body["sha"], "abc123")
            self.assertEqual(base64.b64decode(body["content"]), b"pixels")
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

    def test_a_missing_media_branch_is_named_rather_than_created(self):
        gh = FakeGh()
        with self.assertRaises(MODULE.MediaError) as raised:
            MODULE.require_branch("o/r", "missing", runner=gh)
        self.assertIn("missing", str(raised.exception))
        self.assertFalse([argv for argv in gh.calls if "PUT" in argv])


class MainTests(unittest.TestCase):
    def run_main(self, argv, runner=None):
        with contextlib.redirect_stdout(io.StringIO()) as out, \
             contextlib.redirect_stderr(io.StringIO()) as err:
            code = MODULE.main(argv, runner=runner)
        return code, out.getvalue(), err.getvalue()

    def test_a_dry_run_prints_the_plan_and_the_markdown_without_touching_github(self):
        with tempfile.TemporaryDirectory() as scratch:
            clip = written(scratch, "sidebar-drag.mp4")

            def forbidden(argv, **kwargs):
                raise AssertionError(f"a dry run must not run anything, ran {argv}")

            code, out, _ = self.run_main(["--pr", "15277", "--dry-run", str(clip)], runner=forbidden)
            self.assertEqual(code, 0)
            self.assertIn("plan   gif  15277/sidebar-drag.gif", out)
            self.assertIn("plan video  15277/sidebar-drag.mp4", out)
            self.assertIn("![sidebar drag](", out)

    def test_a_bad_pr_number_is_rejected_before_any_work(self):
        with tempfile.TemporaryDirectory() as scratch:
            clip = written(scratch, "clip.gif")
            code, _, err = self.run_main(["--pr", "0", str(clip)])
            self.assertEqual(code, 2)
            self.assertIn("pull request number", err)

    def test_a_missing_file_fails_with_one_line(self):
        code, _, err = self.run_main(["--pr", "1", "/nonexistent/clip.gif"])
        self.assertEqual(code, 1)
        self.assertIn("not a file", err)
        self.assertNotIn("Traceback", err)

    def test_an_upload_run_puts_every_file_and_prints_the_markdown(self):
        with tempfile.TemporaryDirectory() as scratch:
            first = written(scratch, "01-before.png")
            second = written(scratch, "02-after.png")
            gh = FakeGh()
            code, out, _ = self.run_main(["--pr", "15277", str(first), str(second)], runner=gh)
            self.assertEqual(code, 0)
            self.assertEqual(sorted(gh.puts), ["15277/01-before.png", "15277/02-after.png"])
            self.assertIn("![before](", out)
            self.assertIn("![after](", out)

    def test_comment_is_only_posted_when_it_is_asked_for(self):
        with tempfile.TemporaryDirectory() as scratch:
            shot = written(scratch, "shot.png")
            for argv, expected in ([], 0), (["--comment"], 1):
                gh = FakeGh()
                comments = []

                def runner(command, **kwargs):
                    if command[:2] == ["gh", "pr"]:
                        comments.append(kwargs.get("input", ""))
                        return gh.reply(0, "")
                    return gh(command, **kwargs)

                code, _, _ = self.run_main(["--pr", "7", *argv, str(shot)], runner=runner)
                self.assertEqual(code, 0)
                self.assertEqual(len(comments), expected, argv)
                if expected:
                    self.assertIn("![shot](", comments[0])


class HelpTests(unittest.TestCase):
    def test_the_script_runs_and_documents_itself(self):
        done = subprocess.run([sys.executable, str(ROOT / "scripts/pr-media.py"), "--help"],
                              capture_output=True, text=True)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("--pr", done.stdout)
        self.assertIn("pr-media", done.stdout)


if __name__ == "__main__":
    unittest.main()
