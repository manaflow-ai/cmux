"""The PR capture check: native UI changes show a real capture in the description.

Native UI is what scripts/cmux-next/media/path_map.py maps to a Mac tour. The check never blocks a land
(Leo, 2026-10-31: "WE DONT NEED FUCKIGN SCREENSHOTS JUST LET ME TRY THE SHIT OUT"): it always exits 0, and
what it flags is a `::warning title=...` annotation. run_check returns 1 for a flagged body, 0 otherwise.
"""
import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/pr_capture_check.py"
spec = importlib.util.spec_from_file_location("pr_capture_check", SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

SHA = "a" * 40
SWIFT = "Packages/macOS/CmuxNext/Sources/CmuxNextApp/Sidebar/WorkspaceHoverCard.swift"
CAPTURE = (f"<!-- cmux-capture sha={SHA} state=tour:hover-card job=j1 -->\n"
           "| Light | Dark |\n| --- | --- |\n"
           "| ![light](https://raw.githubusercontent.com/manaflow-ai/cmux/pr-media/42/cap-aaaaaaaa-tour-hover-card-light.png) "
           "| ![dark](https://raw.githubusercontent.com/manaflow-ai/cmux/pr-media/42/cap-aaaaaaaa-tour-hover-card-dark.png) |\n")
FLAGGED = "::warning title="
REVIEW = ("Viewed after image: yes\n"
          "Visual verdict: This looks right next to ChatGPT and Claude.\n")


class CaptureCheckTests(unittest.TestCase):
    def run_check(self, body, paths, labels="", head=SHA):
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / "body.md").write_text(body)
            (Path(tmp) / "paths.txt").write_text("\n".join(paths) + "\n")
            done = subprocess.run([sys.executable, str(SCRIPT), "--body-file", f"{tmp}/body.md", "--paths-file",
                                   f"{tmp}/paths.txt", "--labels", labels, "--head-sha", head, "--pr", "42"],
                                  capture_output=True, text=True)
        self.assertEqual(done.returncode, 0, done.stdout)  # never a red check: the landing tools count it as the PR's own
        return (1 if FLAGGED in done.stdout else 0), done.stdout

    def test_native_ui_paths_need_a_capture(self):
        self.assertEqual(module.ui_tours([SWIFT]), ["hover-card"])
        self.assertEqual(module.ui_tours(["Packages/macOS/CmuxNext/Sources/CmuxNextApp/Other.swift"]), ["core"])
        self.assertEqual(module.ui_tours(["Packages/macOS/CmuxNext/Sources/CmuxNextApp/HitTest.swift"]), ["core"])
        for paths in (["docs/x.md"], ["Packages/macOS/CmuxNext/Tests/CmuxNextAppTests/FooTests.swift"],
                      ["webviews/src/pages/settings/theme.test.tsx"],
                      ["webviews/src/gallery/sidebar.gallery.tsx"], ["scripts/ci/x.py"], []):
            with self.subTest(paths=paths):
                self.assertEqual(module.ui_tours(paths), [])

    def test_missing_capture_warns_with_the_command_to_run(self):
        code, out = self.run_check("## Summary\nMoved the hover card.\n", [SWIFT])
        self.assertEqual(code, 1)
        self.assertIn("::warning title=No real capture::", out)
        self.assertNotIn("::error", out)
        self.assertIn("does not block the land", out)
        self.assertIn(f"cmux-ci capture {SHA} --state tour:hover-card --pr 42", out)
        self.assertIn(SWIFT, out)

    def test_capture_marker_with_media_passes(self):
        self.assertEqual(self.run_check(CAPTURE + REVIEW, [SWIFT])[0], 0)
        code, out = self.run_check(CAPTURE + REVIEW, [SWIFT], head="b" * 40)  # captured an earlier commit
        self.assertEqual(code, 0)
        self.assertIn("::warning::", out)

    def test_capture_requires_after_image_review_proof(self):
        code, out = self.run_check(CAPTURE, [SWIFT])
        self.assertEqual(code, 1)
        self.assertIn("Viewed after image: yes", out)
        self.assertIn("Visual verdict: <one sentence: would Leo accept this next to ChatGPT/Claude?>", out)
        self.assertEqual(self.run_check(CAPTURE + "Viewed after image: yes\n", [SWIFT])[0], 1)
        self.assertEqual(self.run_check(CAPTURE + "Viewed after image: yes\n"
                                        "Visual verdict: <one sentence: would Leo accept this next to ChatGPT/Claude?>\n",
                                        [SWIFT])[0], 1)
        self.assertEqual(self.run_check(CAPTURE + "Viewed after image: yes\n"
                                        "Visual verdict: <one sentence: would Leo accept this next to ChatGPT/Claude?>.\n",
                                        [SWIFT])[0], 1)
        self.assertEqual(self.run_check(CAPTURE + "Viewed after image: yes\n"
                                        "Visual verdict: <one sentence: would Leo accept this next to ChatGPT/Claude? >.\n",
                                        [SWIFT])[0], 1)
        self.assertEqual(self.run_check(CAPTURE + "Viewed after image: yes\n"
                                        "Visual verdict: < one sentence : would Leo accept this next to ChatGPT/Claude? >.\n",
                                        [SWIFT])[0], 1)
        self.assertEqual(self.run_check(CAPTURE + "Viewed after image: yes\nVisual verdict: Looks good.\n", [SWIFT])[0], 0)
        self.assertEqual(self.run_check(CAPTURE + "Viewed after image: yes\n"
                                        "Visual verdict: Looks polished. Ship it.\n", [SWIFT])[0], 1)
        self.assertEqual(self.run_check(CAPTURE + "Viewed after image: yes\n"
                                        "Visual verdict: The 1.5 px inset looks good.\n", [SWIFT])[0], 0)
        self.assertEqual(self.run_check(CAPTURE + "Viewed after image: yes\n"
                                        "Visual verdict: The URL https://x.y/z looks good.\n", [SWIFT])[0], 0)
        self.assertEqual(self.run_check(CAPTURE + "Viewed after image: yes\n"
                                        "Visual verdict: Looks good. ship it.\n", [SWIFT])[0], 1)
        self.assertEqual(self.run_check(CAPTURE + "Viewed after image: yes\n"
                                        "Visual verdict: Looks good?! Ship it.\n", [SWIFT])[0], 1)
        self.assertEqual(self.run_check(CAPTURE + "Viewed after image: yes\n"
                                        "Visual verdict: Looks good. 123px is aligned.\n", [SWIFT])[0], 1)
        self.assertEqual(self.run_check(CAPTURE + "Viewed after image: yes\n"
                                        "Visual verdict: Looks good... really nice.\n", [SWIFT])[0], 0)
        self.assertEqual(self.run_check(CAPTURE + REVIEW, [SWIFT])[0], 0)

    def test_review_proof_is_not_accepted_from_comments_or_code(self):
        body = CAPTURE + "<!--\n" + REVIEW + "-->\n"
        self.assertEqual(self.run_check(body, [SWIFT])[0], 1)
        body = CAPTURE + "```\n" + REVIEW + "```\n"
        self.assertEqual(self.run_check(body, [SWIFT])[0], 1)
        body = CAPTURE + "    Viewed after image: yes\n    Visual verdict: Looks good.\n"
        self.assertEqual(self.run_check(body, [SWIFT])[0], 1)
        body = CAPTURE + "<!--\n" + REVIEW + "    -->\n"
        self.assertEqual(self.run_check(body, [SWIFT])[0], 1)
        body = CAPTURE + "> ```\n> " + REVIEW.replace("\n", "\n> ") + "> ```\n"
        self.assertEqual(self.run_check(body, [SWIFT])[0], 1)
        body = CAPTURE + "<!--\n" + REVIEW
        self.assertEqual(self.run_check(body, [SWIFT])[0], 1)
        body = CAPTURE + "> > ```\n> > " + REVIEW.replace("\n", "\n> > ") + "> > ```\n"
        self.assertEqual(self.run_check(body, [SWIFT])[0], 1)
        body = CAPTURE + ">     Viewed after image: yes\n>     Visual verdict: Looks good.\n"
        self.assertEqual(self.run_check(body, [SWIFT])[0], 1)
        body = CAPTURE + "````\n```\n" + REVIEW + "```\n````\n"
        self.assertEqual(self.run_check(body, [SWIFT])[0], 1)
        body = CAPTURE + "```\n> ```\n" + REVIEW + "```\n"
        self.assertEqual(self.run_check(body, [SWIFT])[0], 1)
        body = CAPTURE + "```\n<!--\n```\n" + REVIEW
        self.assertEqual(self.run_check(body, [SWIFT])[0], 0)
        body = CAPTURE + "    <!--\n\n" + REVIEW
        self.assertEqual(self.run_check(body, [SWIFT])[0], 0)
        body = CAPTURE + "<pre>\n" + REVIEW + "</pre>\n"
        self.assertEqual(self.run_check(body, [SWIFT])[0], 1)

    def test_marker_alone_or_in_a_code_block_is_not_a_capture(self):
        marker_only = f"<!-- cmux-capture sha={SHA} state=x -->\n"
        self.assertEqual(module.evidence(marker_only, set()), ("", None))
        self.assertEqual(module.evidence("```\n" + CAPTURE + "```\n", set()), ("", None))
        mock = "![after](https://raw.githubusercontent.com/manaflow-ai/cmux/pr-media/42/mock.png)\n"
        self.assertEqual(module.evidence(mock, set()), ("", None))
        self.assertEqual(module.evidence("```\n" + CAPTURE, set()), ("", None))  # unclosed fence

    def test_capture_must_be_this_pull_requests_media_right_after_the_marker(self):
        self.assertEqual(module.evidence(CAPTURE, set(), "42"), ("capture", SHA))
        self.assertEqual(module.evidence(CAPTURE, set(), "43"), ("", None))  # copied from another PR
        far = CAPTURE.replace("| Light", "x" * 2500 + "\n| Light")
        # Too far from the marker to be its capture: still this PR's own stills, with no sha (pr-media stills)
        self.assertEqual(module.evidence(far, set(), "42"), ("pr-media stills", None))
        hidden = CAPTURE.replace("| ![light]", "<!-- ![light]").replace("-light.png) ", "-light.png) -->")
        hidden = hidden.replace("| ![dark](", "`").replace("-dark.png) |", "-dark.png`")
        self.assertEqual(module.evidence(hidden, set(), "42"), ("", None))

    def test_this_pull_requests_own_pr_media_stills_pass_with_review_proof(self):
        # #27786: four of its own pr-media stills and the review lines, but no cmux-capture marker
        stills = ("Before: ![before](https://raw.githubusercontent.com/manaflow-ai/cmux/pr-media/{pr}/before-light.png)\n"
                  "After: ![after](https://raw.githubusercontent.com/manaflow-ai/cmux/pr-media/{pr}/after-light.png)\n")
        own = stills.format(pr=42)
        self.assertEqual(module.evidence(own, set(), "42"), ("pr-media stills", None))
        code, out = self.run_check("## Proof\n\n" + REVIEW + "\n" + own, [SWIFT])
        self.assertEqual(code, 0)
        self.assertIn("shown by: pr-media stills", out)
        self.assertIn("::warning::The pr-media stills carry no capture marker", out)
        # Another PR's folder is not this change's
        self.assertEqual(module.evidence(stills.format(pr=43), set(), "42"), ("", None))
        self.assertEqual(self.run_check(REVIEW + stills.format(pr=43), [SWIFT])[0], 1)
        # The stills still need the after-image review lines
        code, out = self.run_check(own, [SWIFT])
        self.assertEqual(code, 1)
        self.assertIn("Viewed after image: yes", out)
        # Stills in a code fence, an HTML comment or inline code are not shown
        self.assertEqual(self.run_check(REVIEW + "```\n" + own + "```\n", [SWIFT])[0], 1)
        self.assertEqual(self.run_check(REVIEW + "<!--\n" + own + "-->\n", [SWIFT])[0], 1)
        self.assertEqual(self.run_check(REVIEW + "`https://raw.githubusercontent.com/manaflow-ai/cmux/pr-media/42/a.png`\n",
                                        [SWIFT])[0], 1)
        # With no PR number the folder can't be told apart from another PR's
        self.assertEqual(module.evidence(own, set(), "N"), ("", None))

    def test_tour_label_or_a_reason_passes(self):
        self.assertEqual(self.run_check(REVIEW, [SWIFT], labels="risk:normal,media-tour")[0], 0)
        self.assertEqual(self.run_check("", [SWIFT], labels="risk:normal,media-tour")[0], 1)
        for body in ("No capture: renames a private type, nothing on screen changes",
                     "- **No capture:** layout constants only, verified identical",
                     "no capture - internal refactor of the view model",
                     "> No capture: copy only, the strings are unchanged on screen"):
            with self.subTest(body=body):
                self.assertEqual(self.run_check(body, [SWIFT])[0], 0)
        for body in ("No capture:", "No capture: ok", "No capture-tooling exists here yet",
                     "## Proof\n\nNo capture:\n\n## Checklist\n- [x] tests", "<!-- No capture: hidden in a comment -->", "We have no capture tooling"):
            with self.subTest(body=body):
                self.assertEqual(self.run_check(body, [SWIFT])[0], 1)

    def test_non_ui_change_passes_without_anything(self):
        code, out = self.run_check("", ["docs/x.md", "Packages/macOS/CmuxNext/Tests/A/ATests.swift"])
        self.assertEqual(code, 0)
        self.assertIn("No native UI change", out)


if __name__ == "__main__":
    unittest.main()
