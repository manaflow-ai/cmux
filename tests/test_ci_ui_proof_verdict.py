#!/usr/bin/env python3
"""The `cmux/ui-proof` status (scripts/ci/ui_proof_verdict.py, pr_router.py ui_status, pr-router.yml's
ui-proof-status job, hot-verify.py look --record): a visual head lands only with a look at that head diffed against
NIGHTLY, and new visible UI only whole.

    python3 -I tests/test_ci_ui_proof_verdict.py
"""

from __future__ import annotations

import json
import contextlib
import io
import os
import struct
import sys
import tempfile
import unittest
import urllib.error
import zlib
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import proof_record  # noqa: E402
import ui_proof_verdict as u  # noqa: E402

HEAD = "a" * 40


def png(w: int, h: int, pixel=lambda x, y: (10, 20, 30), alpha: bool = False, filt: int = 0) -> bytes:
    """A PNG (color type 2 or 6, 8-bit) whose rows use filter FILT (0 none, 1 sub, 2 up), as screencapture's do."""
    ch = 4 if alpha else 3
    rows, prev = b"", bytes(w * ch)
    for y in range(h):
        line = bytearray()
        for x in range(w):
            line += bytes(pixel(x, y)) + (b"\xff" if alpha else b"")
        enc = bytearray(line)
        if filt == 1:
            for i in range(len(line) - 1, ch - 1, -1):
                enc[i] = (line[i] - line[i - ch]) & 255
        elif filt == 2:
            for i in range(len(line)):
                enc[i] = (line[i] - prev[i]) & 255
        rows += bytes([filt]) + bytes(enc)
        prev = bytes(line)

    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xffffffff)
    ihdr = struct.pack(">IIBBBBB", w, h, 8, 6 if alpha else 2, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b"")


def record(suite="gui-flows", verdict="pass", diffed=True, captures=4, head=HEAD) -> dict:
    return {"kind": proof_record.KIND, "version": 1, "suite": suite, "repo": "o/r", "pr": 7, "head_sha": head,
            "selection": {"flows": []}, "runs": [{"name": "look", "result": "pass" if verdict == "pass" else "fail"}],
            "captures": [{"name": f"after/{i}.png", "verdict": "same"} for i in range(captures)],
            "visual": {"screens": captures, "baselined": 2, "changed": 1, "video": True, "diffed": diffed},
            "verdict": verdict, "timing": {"push_to_proof_s": 240}, "tool": "t"}


class PathsTest(unittest.TestCase):
    def test_visual_paths(self) -> None:
        self.assertEqual(u.affects(["webviews/src/chat/Composer.tsx"]), "web")
        self.assertEqual(u.affects(["Packages/macOS/Sources/CmuxNext/Sidebar/Row.swift"]), "app")
        self.assertEqual(u.affects(["webviews/src/a.tsx", "Packages/Shared/X/Y.swift"]), "app")
        self.assertEqual(u.affects(["Assets.xcassets/Icon.imageset/Contents.json"]), "app")

    def test_tier_zero_is_not_visual(self) -> None:
        # Leo's tier 0: copy, docs, tests, logging-only scripts, CI; iOS is cmux/ios-fast's.
        for path in ("docs/a.md", "webviews/test/chat.test.ts", "webviews/src/chat/Composer.test.tsx",
                     "Packages/macOS/Tests/CmuxNextTests/RowTests.swift", "Packages/macOS/Sources/X/Localizable.xcstrings",
                     "scripts/ci/pr_router.py", ".github/workflows/pr-router.yml", "cmux-tui/crates/x/src/lib.rs",
                     "cmux-next-ios/App/Root.swift", "Packages/iOS/Kit/Sources/A.swift", "webviews/bench/a.bench.ts",
                     "release-notes/next/x.md", "Resources/Info.plist"):
            with self.subTest(path=path):
                self.assertEqual(u.affects([path]), "")

    def test_new_ui_is_a_new_view_or_component(self) -> None:
        views = {"Packages/macOS/Sources/A/TouchBar.swift": "struct CmuxTouchBar: View { var body: some View {} }",
                 "Packages/macOS/Sources/A/Planner.swift": "struct SidebarAutomaticPlanner { func plan() {} }"}
        got = u.new_ui(["webviews/src/chat/SummaryCard.tsx", "webviews/src/chat/SummaryCard.css",
                        "webviews/src/chat/fold.ts", "webviews/test/x.test.tsx", *views], read=views.__getitem__)
        self.assertEqual(got, ["webviews/src/chat/SummaryCard.tsx", "webviews/src/chat/SummaryCard.css",
                               "Packages/macOS/Sources/A/TouchBar.swift"])
        # Unread Swift counts: a gate that cannot read routes more, never less.
        self.assertEqual(u.new_ui(["Native/OptChat/New.swift"]), ["Native/OptChat/New.swift"])


class VerdictTest(unittest.TestCase):
    def v(self, need="app", body="", records=None, ui=(), off=False):
        return u.verdict(need, body, records or {}, list(ui), 7, off=off)

    def test_nothing_visual_passes_at_once(self) -> None:
        self.assertEqual(self.v(need="")[0], "success")

    def test_off_switch(self) -> None:
        self.assertEqual(self.v(off=True), ("success", "UI proof is off (vars.CI_UI_PROOF=0)"))

    def test_visual_head_waits_for_a_look_and_names_the_preview(self) -> None:
        state, desc = self.v()
        self.assertEqual(state, "pending")
        self.assertIn("cmux app try 7", desc)
        self.assertLessEqual(len(desc), 140)

    def test_a_look_at_head_diffed_against_nightly_passes(self) -> None:
        state, desc = self.v(records={"gui-flows": record()})
        self.assertEqual(state, "success")
        self.assertIn("vs NIGHTLY", desc)

    def test_a_look_with_nothing_diffed_still_waits(self) -> None:
        self.assertEqual(self.v(records={"gui-flows": record(diffed=False)})[0], "pending")

    def test_a_failed_look_fails(self) -> None:
        self.assertEqual(self.v(records={"gui-flows": record(verdict="fail")})[0], "failure")

    def test_a_web_gallery_does_not_prove_swift(self) -> None:
        self.assertEqual(self.v(records={"web-flows": record(suite="web-flows")})[0], "pending")
        self.assertEqual(self.v(need="web", records={"web-flows": record(suite="web-flows")})[0], "success")

    def test_new_visible_ui_ships_whole(self) -> None:
        # Leo, 11-27: "it can potentially just not ship until we get a proper handle and shell of it and/or build".
        recs = {"mac-flows": record(suite="mac-flows")}
        state, desc = self.v(records=recs, ui=["webviews/src/New.tsx"])
        self.assertEqual(state, "pending")
        self.assertIn("Visible-UI: complete", desc)
        self.assertEqual(self.v(body="x\nVisible-UI: complete\n", records=recs, ui=["a.tsx"])[0], "success")
        thin = {"mac-flows": record(suite="mac-flows", captures=2)}
        self.assertEqual(self.v(body="Visible-UI: complete", records=thin, ui=["a.tsx"])[0], "pending")
        self.assertEqual(self.v(body="Visible-UI: none (a helper file)", records=thin, ui=["a.tsx"])[0], "success")

    def test_declared_no_visual_change_passes_and_is_counted(self) -> None:
        state, desc = self.v(body="Visual: none (logging only)")
        self.assertEqual(state, "success")
        self.assertTrue(desc.startswith("Declared"))
        self.assertEqual(u.classify_merge({"state": "success", "description": desc})[0], "declared")

    def test_report_counts_every_bypass(self) -> None:
        self.assertEqual(u.classify_merge(None)[0], "bypass")
        self.assertEqual(u.classify_merge({"state": "pending", "description": "x"})[0], "bypass")
        self.assertEqual(u.classify_merge({"state": "success", "description": "UI proof is off (x)"})[0], "off")
        self.assertEqual(u.classify_merge({"state": "success", "description": "gui-flows at this head"})[0], "proved")


class PixelDiffTest(unittest.TestCase):
    def test_same_and_changed(self) -> None:
        a = png(20, 10)
        self.assertEqual(u.diff_ratio(a, png(20, 10, filt=1)), 0.0)
        b = png(20, 10, lambda x, y: (200, 0, 0) if x < 5 else (10, 20, 30), filt=2)
        self.assertEqual(u.diff_ratio(a, b), 0.25)
        self.assertEqual(u.diff_ratio(a, png(20, 10, alpha=True)), 0.0)
        self.assertEqual(u.diff_ratio(a, png(10, 10)), 1.0)
        self.assertIsNone(u.diff_ratio(b"not a png", a))

    def test_within_tolerance_is_same(self) -> None:
        self.assertEqual(u.diff_ratio(png(4, 4), png(4, 4, lambda x, y: (13, 22, 33))), 0.0)


class RecordTest(unittest.TestCase):
    def test_a_look_dir_becomes_a_valid_record_the_gate_reads(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            out = Path(d)
            for sub in ("before", "after", "steps"):
                (out / sub).mkdir()
            (out / "before" / "light.png").write_bytes(png(8, 8))
            (out / "after" / "light.png").write_bytes(png(8, 8, lambda x, y: (255, 255, 255)))
            (out / "before" / "dark.png").write_bytes(png(8, 8))
            (out / "after" / "dark.png").write_bytes(png(8, 8))
            (out / "steps" / "settings.png").write_bytes(png(8, 8))
            (out / "video.mp4").write_bytes(b"v")
            (out / "receipt.json").write_text(json.dumps({
                "plan": {"layers": ["web", "rust"], "base": "b" * 40}, "app": {"commit": "c" * 40},
                "steps": [{"name": "settings", "ok": True}], "errors": [], "phases": {"total": 41.0}}))
            rec = u.build_record(out, repo="o/r", pr=7, head=HEAD, pushed_at=1000.0, now=1240.0)
            self.assertEqual(proof_record.problems(rec), [])
            self.assertEqual(rec["suite"], "gui-flows")
            self.assertEqual(rec["visual"], {"screens": 3, "baselined": 2, "changed": 1, "video": True, "diffed": True})
            self.assertEqual(rec["timing"]["push_to_proof_s"], 240.0)
            self.assertEqual(rec["verdict"], "pass")
            comment = {"author_association": "MEMBER", "body": proof_record.render(rec, u.summary(rec)),
                       "created_at": "2026-11-27T03:00:00Z"}
            found = proof_record.find([comment], "gui-flows", HEAD)
            self.assertEqual(u.verdict("app", "", {"gui-flows": found}, [], 7)[0], "success")
            # A new push: the record is for an older head and no longer counts.
            self.assertIsNone(proof_record.find([comment], "gui-flows", "b" * 40))

    def test_a_failed_look_records_a_fail(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            out = Path(d)
            (out / "after").mkdir()
            (out / "after" / "light.png").write_bytes(png(2, 2))
            (out / "receipt.json").write_text(json.dumps({"plan": {"layers": ["web"]}, "errors": ["boom"]}))
            rec = u.build_record(out, repo="o/r", pr=7, head=HEAD)
            self.assertEqual((rec["suite"], rec["verdict"]), ("web-flows", "fail"))
            self.assertFalse(rec["visual"]["diffed"])


class SwiftDrawsTest(unittest.TestCase):
    """cmux#61522 marked two statics `nonisolated` in CmuxNextActions/ActionArgument.swift and needed a hand-added
    `Visual: none`. Leo: "shouldn't a build check fail beforehand fast like fast-fail is useful ci all stuff" and "i
    feel like there's more we can simplify/etc". A Swift file that imports nothing that draws is not visual."""
    P = "Packages/macOS/CmuxNext/Sources/CmuxNextActions/ActionArgument.swift"

    def affects(self, text, base=None):
        texts = [text] + ([base] if base is not None else [])
        return u.affects([self.P], read=lambda p: texts)

    def test_stdlib_only_imports_are_not_visual(self) -> None:
        self.assertEqual(self.affects("import Foundation\nimport os\npublic struct A { nonisolated static let x = 1 }"), "")
        self.assertEqual(self.affects("@preconcurrency import Foundation\nimport struct Darwin.Foo\n"), "")

    def test_a_drawing_or_local_import_is_visual(self) -> None:
        for mod in ("SwiftUI", "AppKit", "CoreGraphics", "QuartzCore", "WebKit", "CmuxNextDesign", "GhosttyKit"):
            with self.subTest(mod=mod):
                self.assertEqual(self.affects(f"import Foundation\nimport {mod}\n"), "app")

    def test_no_import_unread_or_a_dropped_ui_import_stays_visual(self) -> None:
        self.assertEqual(self.affects("struct A {}"), "app")

        def unread(path):
            raise OSError(path)
        self.assertEqual(u.affects([self.P], read=unread), "app")
        self.assertEqual(u.affects([self.P]), "app")
        self.assertEqual(self.affects("import Foundation\n", base="import SwiftUI\nstruct V: View {}"), "app")

    def test_only_swift_under_a_visual_root_is_read(self) -> None:
        def boom(path):
            raise AssertionError(path)
        self.assertEqual(u.affects(["webviews/src/a.tsx"], read=boom), "web")
        self.assertEqual(u.affects(["Assets.xcassets/I.imageset/Contents.json"], read=boom), "app")
        self.assertEqual(u.affects(["Packages/iOS/X.swift"], read=boom), "")

    def test_one_drawing_file_makes_the_head_visual(self) -> None:
        texts = {"A.swift": "import Foundation\n", "B.swift": "import AppKit\n"}
        root = "Packages/macOS/CmuxNext/Sources/M/"
        read = lambda p: [texts[p[len(root):]]]  # noqa: E731
        self.assertEqual(u.affects([root + "A.swift", root + "B.swift"], read=read), "app")
        self.assertEqual(u.affects([root + "A.swift"], read=read), "")

    def test_declared_none_still_passes_a_drawing_file(self) -> None:
        state, why = u.verdict("app", "Visual: none (logging only)", {}, [], 7)
        self.assertEqual(state, "success")
        self.assertIn("logging only", why)


class RevertedHistoryTest(unittest.TestCase):
    """Before -> after on the data the gate was added on (cmuxterm-hq docs/findings/ui-regressions.md): the 25
    desktop UI PRs reverted or fixed forward 2026-10-16..11-27. Before: none carried a look at its head, all merged.
    After: each is held `pending` until one is posted; those adding new visible UI also until it ships whole."""
    # PR: (a file it changed, a file it added that is new visible UI or None)
    HISTORY = {
        22822: ("Packages/macOS/Sources/CmuxNext/AgentPane/LinkRouter.swift", None),
        23969: ("Packages/macOS/Sources/CmuxNext/Tabs/OutboundTab.swift", None),
        26551: ("webviews/src/gallery/Gallery.tsx", None),
        26568: ("webviews/src/chat/Composer.tsx", None),
        26988: ("webviews/src/chat/Inspector.tsx", "webviews/src/chat/SubagentSummaryCard.tsx"),
        29974: ("webviews/src/artifacts/index.tsx", "webviews/src/artifacts/ArtifactsPage.tsx"),
        31365: ("Packages/macOS/Sources/CmuxNext/App.swift", "Packages/macOS/Sources/CmuxNext/CmuxTouchBar.swift"),
        37777: ("Packages/macOS/Sources/CmuxNext/Home/Home.swift",
                "Packages/macOS/Sources/CmuxNext/Home/HomeConversationPage.swift"),
        41446: ("webviews/src/transcript/Transcript.tsx", None),
        49506: ("Packages/macOS/Sources/CmuxNext/Sidebar/SidebarModel.swift", None),
        50499: ("Packages/Shared/CmuxTheme/Sources/Glass.swift", None),
        52997: ("Packages/macOS/Sources/CmuxNext/Sidebar/ChiefRow.swift", None),
    }

    def test_every_one_is_held_until_a_look(self) -> None:
        for pr, (changed, added) in self.HISTORY.items():
            with self.subTest(pr=pr):
                files = [changed] + ([added] if added else [])
                need = u.affects(files)
                self.assertNotEqual(need, "")
                state, _ = u.verdict(need, "", {}, u.new_ui([added] if added else []), pr)
                self.assertEqual(state, "pending")

    def test_new_visible_ui_is_held_past_the_look(self) -> None:
        recs = {"gui-flows": record(), "mac-flows": record(suite="mac-flows")}
        for pr, (changed, added) in self.HISTORY.items():
            if added:
                with self.subTest(pr=pr):
                    self.assertEqual(u.verdict(u.affects([changed, added]), "", recs, u.new_ui([added]), pr)[0],
                                     "pending")


class ReadFailureTest(unittest.TestCase):
    def test_both_gates_report_http_metadata_without_secrets(self) -> None:
        for code in (403, 429, 503):
            for module, argv, target in ((u, ["gate"], "gate_now"),
                                         (proof_record, ["gate", "--suite", "ios-flows"], "pr_comments")):
                with self.subTest(code=code, module=module.__name__):
                    error = urllib.error.HTTPError(
                        "https://user:secret@api.github.com/repos/manaflow-ai/cmux/issues/7/comments?token=secret",
                        code, "secret response reason", {"X-GitHub-Request-Id": "ABCD:1234", "Retry-After": "60",
                        "X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1795776600",
                        "Authorization": "Bearer secret"}, io.BytesIO(b"secret response body"))
                    stdout, stderr = io.StringIO(), io.StringIO()
                    with mock.patch.dict(os.environ, {"REPO": "manaflow-ai/cmux", "PR": "7", "SHA": HEAD,
                                                      "GH_TOKEN": "secret"}), \
                            mock.patch.object(module, target, side_effect=error), \
                            contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                        self.assertEqual(module.main(argv), 0)
                    self.assertTrue(stdout.getvalue().startswith("error\t"))
                    self.assertIn(f"HTTPError {code}", stdout.getvalue())
                    self.assertIn("see job log", stdout.getvalue())
                    details = json.loads(stderr.getvalue())
                    self.assertEqual(details["status"], code)
                    self.assertEqual(details["endpoint"], "/repos/manaflow-ai/cmux/issues/7/comments")
                    self.assertEqual(details["request_id"], "ABCD:1234")
                    self.assertEqual(details["retry_after"], "60")
                    self.assertEqual(details["rate_remaining"], "0")
                    self.assertEqual(details["rate_reset"], "1795776600")
                    self.assertNotIn("secret", stdout.getvalue() + stderr.getvalue())
                    self.assertEqual(error.fp.tell(), 0)

    def test_unknown_endpoint_and_unexpected_headers_are_omitted(self) -> None:
        error = urllib.error.HTTPError("https://example.com/secret?token=secret", 403, "secret",
                                       {"X-GitHub-Request-Id": "secret\nline", "Retry-After": "secret"}, None)
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            self.assertEqual(proof_record.read_error(error), "HTTPError 403")
        self.assertEqual(json.loads(stderr.getvalue()), {"error": "HTTPError", "status": 403})

    def test_non_http_failure_keeps_its_type_without_exception_text(self) -> None:
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            self.assertEqual(proof_record.read_error(TimeoutError("secret")), "TimeoutError")
            self.assertEqual(proof_record.read_error(urllib.error.HTTPError(
                "https://api.github.com/repos/manaflow-ai/cmux/pulls/7", 500, "secret", None, None)),
                "HTTPError 500")
        self.assertNotIn("secret", stderr.getvalue())


class RouterTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        import pr_router
        cls.status = staticmethod(pr_router.ui_status)

    def event(self, base="feat-cmux-next", draft=False) -> dict:
        repo = {"full_name": "manaflow-ai/cmux"}
        return {"pull_request": {"draft": draft, "base": {"ref": base, "repo": repo}, "head": {"repo": repo}}}

    def test_route_states(self) -> None:
        with mock.patch.dict(os.environ, {"CI_UI_PROOF": ""}):
            self.assertEqual(self.status(self.event(), ["docs/a.md"])[0], "success")
            self.assertEqual(self.status(self.event(), ["webviews/src/a.tsx"])[0], "pending")
            self.assertEqual(self.status(self.event(), None)[0], "pending")
            self.assertEqual(self.status(self.event(draft=True), ["webviews/src/a.tsx"]), ("", ""))
        with mock.patch.dict(os.environ, {"CI_UI_PROOF": "0"}):
            self.assertEqual(self.status(self.event(), ["webviews/src/a.tsx"])[0], "success")

    def test_workflow_posts_it_and_runs_the_gate_job(self) -> None:
        import yaml
        wf = yaml.safe_load((ROOT / ".github/workflows/pr-router.yml").read_text())
        route = wf["jobs"]["route"]
        self.assertIn("ui_status", route["outputs"])
        sparse = route["steps"][0]["with"]["sparse-checkout"]
        self.assertIn("scripts/ci/ui_proof_verdict.py", sparse)
        self.assertIn("scripts/ci/proof_record.py", sparse)
        self.assertTrue(any(s.get("name") == "Post the UI proof status" for s in route["steps"]))
        job = wf["jobs"]["ui-proof-status"]
        self.assertEqual(job["name"], u.GATE_JOB)
        self.assertIn("needs.route.outputs.ui_status == 'pending'", job["if"])
        self.assertIn("ui_proof_verdict.py gate", job["steps"][-1]["run"])


if __name__ == "__main__":
    unittest.main()
