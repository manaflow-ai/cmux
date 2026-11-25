#!/usr/bin/env python3
"""scripts/ci/ios_gate_screen_diff.py: the App Review gate's screen diff against feat-cmux-next.

Tiny generated PNGs stand in for the reviewer path's stills, laid out the way
`xcresulttool export attachments` writes them (manifest.json plus UUID files).
Run: python3 tests/test_ios_gate_screen_diff.py
"""

from __future__ import annotations

import importlib.util
import json
import struct
import sys
import tempfile
import unittest
from unittest import mock
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "ci" / "ios_gate_screen_diff.py"
MENTION = "@azooz2003-bit"


def load():
    spec = importlib.util.spec_from_file_location("ios_gate_screen_diff", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def _chunk(kind: bytes, body: bytes) -> bytes:
    return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF)


def _paeth(a: int, b: int, c: int) -> int:
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    return a if pa <= pb and pa <= pc else (b if pb <= pc else c)


def png(pixels: list[list[tuple[int, int, int, int]]], filter_kind: int = 0) -> bytes:
    """An RGBA PNG whose every row uses one filter type (0-4)."""
    height, width = len(pixels), len(pixels[0])
    raw_rows = [bytes(v for px in row for v in px) for row in pixels]
    stream = bytearray()
    prev = bytes(width * 4)
    for raw in raw_rows:
        out = bytearray()
        for i, v in enumerate(raw):
            a = raw[i - 4] if i >= 4 else 0
            b = prev[i]
            c = prev[i - 4] if i >= 4 else 0
            pred = (0, a, b, (a + b) >> 1, _paeth(a, b, c))[filter_kind]
            out.append((v - pred) & 0xFF)
        stream += bytes([filter_kind]) + out
        prev = raw
    header = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + _chunk(b"IHDR", header) + _chunk(b"IDAT", zlib.compress(bytes(stream))) + _chunk(b"IEND", b"")


def screen(color=(20, 30, 40, 255), patch=None, size=20, filter_kind=0) -> bytes:
    pixels = [[color] * size for _ in range(size)]
    if patch:
        x0, y0, w, h, c = patch
        for y in range(y0, y0 + h):
            for x in range(x0, x0 + w):
                pixels[y][x] = c
    return png(pixels, filter_kind)


def write_family(root: Path, family: str, shots: dict[str, bytes]) -> None:
    """screens/<family>/ as xcresulttool exports it."""
    directory = root / "screens" / family
    directory.mkdir(parents=True)
    attachments = []
    for n, (name, data) in enumerate(shots.items()):
        uuid = f"{n:08X}-0000-4000-8000-{n:012X}"
        exported = f"{uuid}.png"
        (directory / exported).write_bytes(data)
        attachments.append({"exportedFileName": exported, "suggestedHumanReadableName": f"{name}_0_{uuid}.png",
                            "timestamp": 1000 + n, "isAssociatedWithFailure": False})
    # A string attachment the walk also keeps; never a screen.
    (directory / "AAAAAAAA-0000-4000-8000-AAAAAAAAAAAA.txt").write_text("gate-note")
    attachments.append({"exportedFileName": "AAAAAAAA-0000-4000-8000-AAAAAAAAAAAA.txt",
                        "suggestedHumanReadableName": "gate-note-x_0_AAAAAAAA-0000-4000-8000-AAAAAAAAAAAA.txt"})
    (directory / "manifest.json").write_text(json.dumps([{"testIdentifier": "AppReviewGateUITests/testWalk()",
                                                          "attachments": attachments}]))


class ScreenDiffTests(unittest.TestCase):
    def setUp(self) -> None:
        self.mod = load()
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.head = self.root / "in" / "review-gate-path-appstore-iphone"
        self.base = self.root / "base"

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def run_diff(self, body: str = "", event: str = "pull_request", baseline: bool = True,
                 families: tuple[str, ...] = ("iphone",)) -> tuple[int, str]:
        out = self.root / "section.md"
        args = ["--head-root", str(self.root / "in"), "--event", event, "--pr-body", body, "--out", str(out)]
        for family in families:
            args += ["--family", family]
        if baseline:
            args += ["--baseline-root", str(self.base)]
        code = self.mod.main(args)
        return code, out.read_text()

    def test_identical_screens_report_no_difference(self) -> None:
        shots = {"gate-iphone-home-01": screen(), "gate-iphone-settings": screen((200, 200, 200, 255))}
        write_family(self.head, "iphone", shots)
        write_family(self.base, "iphone", shots)
        code, text = self.run_diff()
        self.assertEqual(code, 0)
        self.assertIn("No screen differs from feat-cmux-next.", text)
        self.assertIn("2 screens unchanged", text)
        self.assertNotIn(MENTION, text)

    def test_antialiasing_noise_is_not_a_change(self) -> None:
        write_family(self.base, "iphone", {"gate-iphone-home-01": screen()})
        noisy = screen(patch=(0, 0, 20, 20, (25, 34, 44, 255)))  # every pixel moves by 4-5 levels
        write_family(self.head, "iphone", {"gate-iphone-home-01": noisy})
        _, text = self.run_diff()
        self.assertIn("No screen differs from feat-cmux-next.", text)

    def test_changed_and_justified(self) -> None:
        write_family(self.base, "iphone", {"gate-iphone-home-01": screen()})
        write_family(self.head, "iphone", {"gate-iphone-home-01": screen(patch=(2, 3, 5, 4, (255, 0, 0, 255)))})
        code, text = self.run_diff("Intro.\n\nVisual-change: gate-iphone-home-*: the new tab bar\n")
        self.assertEqual(code, 0)
        self.assertIn("| iphone | `gate-iphone-home-01` | changed | 5.00% | 5x4 at 2,3 | justified: the new tab bar |", text)
        self.assertIn("each with a Visual-change line", text)
        self.assertNotIn(MENTION, text)

    def test_changed_and_unjustified_ccs_the_ios_quality_bar(self) -> None:
        write_family(self.base, "iphone", {"gate-iphone-home-01": screen(), "gate-iphone-settings": screen()})
        write_family(self.head, "iphone", {"gate-iphone-home-01": screen(patch=(0, 0, 10, 10, (0, 0, 0, 255))),
                                           "gate-iphone-settings": screen()})
        code, text = self.run_diff("Visual-change: gate-iphone-settings: not this one\n")
        self.assertEqual(code, 0)
        self.assertIn(f"1 iOS screens differ from feat-cmux-next with no Visual-change line: "
                      f"is each wanted? cc {MENTION}", text)
        self.assertIn("| iphone | `gate-iphone-home-01` | changed | 25.00% | 10x10 at 0,0 | unjustified |", text)

    def test_a_push_run_reports_without_a_cc(self) -> None:
        write_family(self.base, "iphone", {"gate-iphone-home-01": screen()})
        write_family(self.head, "iphone", {"gate-iphone-home-01": screen(patch=(0, 0, 10, 10, (0, 0, 0, 255)))})
        code, text = self.run_diff(event="push")
        self.assertEqual(code, 0)
        self.assertIn("1 iOS screens differ from the previous feat-cmux-next push run.", text)
        self.assertIn("n/a (push run)", text)
        self.assertNotIn(MENTION, text)

    def test_new_screen(self) -> None:
        write_family(self.base, "iphone", {"gate-iphone-home-01": screen()})
        write_family(self.head, "iphone", {"gate-iphone-home-01": screen(), "gate-iphone-chief-01-open": screen()})
        _, text = self.run_diff()
        self.assertIn("| iphone | `gate-iphone-chief-01-open` | new |  |  | unjustified |", text)
        self.assertIn(f"cc {MENTION}", text)

    def test_removed_screen_justified_by_star(self) -> None:
        write_family(self.base, "iphone", {"gate-iphone-home-01": screen(), "gate-iphone-old": screen()})
        write_family(self.head, "iphone", {"gate-iphone-home-01": screen()})
        _, text = self.run_diff("Visual-change: *: the walk dropped a step\n")
        self.assertIn("| iphone | `gate-iphone-old` | removed |  |  | justified: the walk dropped a step |", text)
        self.assertNotIn(MENTION, text)

    def test_no_baseline_reports_and_exits_zero(self) -> None:
        write_family(self.head, "iphone", {"gate-iphone-home-01": screen()})
        code, text = self.run_diff(baseline=False)
        self.assertEqual(code, 0)
        self.assertIn("- iphone: no baseline,", text)
        self.assertIn("Nothing was compared (no baseline for any family).", text)
        self.assertNotIn("No screen differs from feat-cmux-next.", text)
        self.assertNotIn(MENTION, text)

    def test_a_family_with_no_baseline_qualifies_the_clean_line(self) -> None:
        write_family(self.base, "iphone", {"gate-iphone-home-01": screen()})
        write_family(self.head, "iphone", {"gate-iphone-home-01": screen()})
        write_family(self.head, "ipad", {"gate-ipad-home-01": screen()})
        code, text = self.run_diff(families=("iphone", "ipad"))
        self.assertEqual(code, 0)
        self.assertIn("- ipad: no baseline,", text)
        self.assertIn("No compared screen differs from feat-cmux-next (not compared: ipad).", text)
        self.assertNotIn("No screen differs from feat-cmux-next.", text)

    def test_a_name_with_dots_matches_across_runs(self) -> None:
        # xcresulttool puts `_0_<UUID>` before the last dot of `...DEAD-setup.teams.personal`.
        def export(root: Path, uuid: str) -> None:
            directory = root / "screens" / "iphone"
            directory.mkdir(parents=True)
            (directory / f"{uuid}.png").write_bytes(screen())
            human = f"gate-iphone-walk-onboarding-DEAD-setup.teams_0_{uuid}.personal"
            (directory / "manifest.json").write_text(json.dumps([{"attachments": [
                {"exportedFileName": f"{uuid}.png", "suggestedHumanReadableName": human, "timestamp": 1}]}]))
        export(self.head, "0DDA6791-43D3-4063-B3CE-10CE7EF19FD0")
        export(self.base, "10C08201-3B79-4659-97F5-9B3D7EBCB056")
        _, text = self.run_diff()
        self.assertIn("No screen differs from feat-cmux-next.", text)
        self.assertIn("1 screens unchanged", text)

    def test_a_visual_change_line_in_a_code_fence_justifies_nothing(self) -> None:
        write_family(self.base, "iphone", {"gate-iphone-home-01": screen()})
        write_family(self.head, "iphone", {"gate-iphone-home-01": screen(patch=(0, 0, 10, 10, (0, 0, 0, 255)))})
        _, text = self.run_diff("Use this format:\n\n```\nVisual-change: gate-iphone-home-*: an example\n```\n")
        self.assertIn("| iphone | `gate-iphone-home-01` | changed | 25.00% | 10x10 at 0,0 | unjustified |", text)
        self.assertIn(f"cc {MENTION}", text)

    def test_every_png_filter_decodes_the_same_pixels(self) -> None:
        pixels = [[((x * 37 + y * 11) & 0xFF, (x * y) & 0xFF, (200 - x * 3) & 0xFF, 255) for x in range(9)]
                  for y in range(7)]
        decoded = []
        for kind in range(5):
            image = self.mod.read_png(png(pixels, kind))
            decoded.append(self.mod._rows(image))
        expected = [bytes(v for px in row for v in px) for row in pixels]
        for kind, rows in enumerate(decoded):
            self.assertEqual(rows, expected, f"filter {kind}")
        # Different filters for the same pixels are the same screen.
        self.assertEqual(self.mod.diff_images(png(pixels, 1), png(pixels, 4)).ratio, 0.0)


class StillsArtifactTests(unittest.TestCase):
    """The baseline: the newest feat-cmux-next ios-gate-stills-* with screens, found by one listing per name."""

    BIG = 30 << 20

    def setUp(self) -> None:
        self.mod = load()
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    @staticmethod
    def artifact(aid, name, run=1, size=BIG, branch="feat-cmux-next", created="2026-11-23T10:00:00Z", fork=False):
        return {"id": aid, "name": name, "size_in_bytes": size, "expired": False, "created_at": created,
                "workflow_run": {"id": run, "head_branch": branch, "head_sha": "a" * 40,
                                 "repository_id": 7, "head_repository_id": 8 if fork else 7}}

    def fetch(self, by_name: dict[str, list[dict]], families=("iphone",), empty: set = frozenset(),
              fail: set = frozenset()) -> tuple[dict, list, list[str]]:
        import io
        import urllib.parse
        import zipfile
        downloaded: list = []
        listed: list[str] = []

        def api(url, token, deadline):
            name = urllib.parse.parse_qs(urllib.parse.urlparse(url).query)["name"][0]
            listed.append(name)
            return json.dumps({"artifacts": by_name.get(name, [])}).encode()

        def download(url, token, deadline, path):
            aid = url.split("/artifacts/")[1].split("/")[0]
            downloaded.append(aid)
            if aid in fail:
                raise TimeoutError("reading the answer: past the 180 s deadline")
            family = path.stem
            buffer = io.BytesIO()
            with zipfile.ZipFile(buffer, "w") as archive:
                archive.writestr(f"{family}.status.json", "{}")
                if aid not in empty:
                    archive.writestr(f"screens/{family}/a.png", b"x")
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(buffer.getvalue())
            return path

        self.mod._api, self.mod._download = api, download
        result = self.mod.fetch_baselines("o/r", "appstore", list(families), Path(self.tmp.name), "t", "0")
        return result, downloaded, listed

    def test_the_stills_artifact_is_read_with_one_listing(self) -> None:
        result, downloaded, listed = self.fetch({"ios-gate-stills-appstore-iphone": [self.artifact("s1", "ios-gate-stills-appstore-iphone", run=5)]})
        self.assertEqual(downloaded, ["s1"])
        self.assertEqual(listed, ["ios-gate-stills-appstore-iphone"])
        self.assertIsNotNone(result["iphone"].directory)
        self.assertEqual(result["iphone"].run_id, 5)
        self.assertEqual(result["iphone"].run_url, "https://github.com/o/r/actions/runs/5")

    def test_a_run_from_before_the_split_still_serves(self) -> None:
        result, downloaded, _ = self.fetch({"review-gate-path-appstore-iphone": [self.artifact("p1", "review-gate-path-appstore-iphone")]})
        self.assertEqual(downloaded, ["p1"])
        self.assertIsNotNone(result["iphone"].directory)

    def test_none_kept_names_the_stills_artifact(self) -> None:
        result, downloaded, _ = self.fetch({})
        self.assertEqual(downloaded, [])
        self.assertIn("ios-gate-stills-appstore-iphone", result["iphone"].problem)

    def test_a_status_only_artifact_is_skipped_without_a_download(self) -> None:
        # Run 45257341586, cancelled before its walk exported, kept a stills artifact with no screens.
        name = "ios-gate-stills-appstore-iphone"
        result, downloaded, _ = self.fetch({name: [
            self.artifact("tiny", name, run=9, size=400, created="2026-11-23T20:00:00Z"),
            self.artifact("old", name, run=3, created="2026-11-23T09:00:00Z")]})
        self.assertEqual(downloaded, ["old"])
        self.assertEqual(result["iphone"].run_id, 3)

    def test_pull_request_and_fork_runs_are_not_baselines(self) -> None:
        name = "ios-gate-stills-appstore-iphone"
        result, downloaded, _ = self.fetch({name: [
            self.artifact("pr", name, run=9, branch="lane/x", created="2026-11-23T20:00:00Z"),
            self.artifact("fork", name, run=8, fork=True, created="2026-11-23T19:00:00Z"),
            self.artifact("base", name, run=2, created="2026-11-23T09:00:00Z")]})
        self.assertEqual(downloaded, ["base"])

    def test_an_artifact_with_no_screens_falls_through_to_an_older_one(self) -> None:
        name = "ios-gate-stills-appstore-iphone"
        result, downloaded, _ = self.fetch({name: [
            self.artifact("new", name, run=9, created="2026-11-23T20:00:00Z"),
            self.artifact("old", name, run=3, created="2026-11-23T09:00:00Z")]}, empty={"new"})
        self.assertEqual(downloaded, ["new", "old"])
        self.assertIsNotNone(result["iphone"].directory)
        self.assertEqual((result["iphone"].run_id, result["iphone"].problem), (3, ""))

    def test_the_smaller_family_downloads_first_and_a_slow_one_says_its_size(self) -> None:
        result, downloaded, _ = self.fetch({
            "ios-gate-stills-appstore-ipad": [self.artifact("pad", "ios-gate-stills-appstore-ipad", size=411 << 20)],
            "ios-gate-stills-appstore-iphone": [self.artifact("phone", "ios-gate-stills-appstore-iphone", size=55 << 20)],
        }, families=("ipad", "iphone"), fail={"pad"})
        self.assertEqual(downloaded, ["phone", "pad"])
        self.assertIsNotNone(result["iphone"].directory)
        self.assertIsNone(result["ipad"].directory)
        self.assertIn("(431 MB)", result["ipad"].problem)


class ScaleChangeTests(unittest.TestCase):
    """The iPad's stills are halved before upload: a full-size baseline is another scale, not a change."""

    def setUp(self) -> None:
        self.mod = load()
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def run_diff(self, base_size: int) -> str:
        write_family(self.root / "in", "ipad", {"gate-ipad-home": screen(size=10), "gate-ipad-settings": screen(size=10)})
        write_family(self.root / "base", "ipad", {"gate-ipad-home": screen(size=base_size),
                                                  "gate-ipad-settings": screen(size=base_size)})
        out = self.root / "s.md"
        self.mod.main(["--head-root", str(self.root / "in"), "--baseline-root", str(self.root / "base"),
                       "--family", "ipad", "--event", "pull_request", "--pr-body", "", "--out", str(out)])
        return out.read_text()

    def test_a_baseline_at_another_scale_is_not_compared(self) -> None:
        text = self.run_diff(20)
        self.assertIn("stills are at another scale (20x20 -> 10x10)", text)
        self.assertNotIn("differ from feat-cmux-next with no Visual-change line", text)
        self.assertIn("Nothing was compared", text)

    def test_the_same_scale_still_compares(self) -> None:
        text = self.run_diff(10)
        self.assertIn("2 screens unchanged", text)


class ApiRetryTests(unittest.TestCase):
    """The first live runs lost the baseline to a bare 403 in 8 of 28 runs: say why, and try again."""

    def setUp(self) -> None:
        self.mod = load()
        self.sleeps: list[float] = []
        patch = mock.patch.object(self.mod.time, "sleep", self.sleeps.append)
        patch.start()
        self.addCleanup(patch.stop)

    def error(self, code: int, message: str = "", headers: dict | None = None):
        import io
        import urllib.error
        body = json.dumps({"message": message}).encode()
        return urllib.error.HTTPError("https://x", code, "Forbidden", headers or {}, io.BytesIO(body))

    def run_api(self, answers: list):
        calls = iter(answers)

        def request(req, deadline=None, max_bytes=None, raise_errors=False):
            answer = next(calls)
            if isinstance(answer, Exception):
                raise answer
            return 200, answer, {}

        class Clock:
            def left(self, what):
                return 10.0

        original = self.mod.deadline_http.request
        self.mod.deadline_http.request = request
        try:
            return self.mod._api("https://x", "t", Clock())
        finally:
            self.mod.deadline_http.request = original

    def test_a_rate_limit_is_retried_after_its_wait(self) -> None:
        body = self.run_api([self.error(403, "rate limit", {"retry-after": "7"}), b"{}"])
        self.assertEqual(body, b"{}")
        self.assertEqual(self.sleeps, [7.0])

    def test_the_reason_is_kept_when_retries_run_out(self) -> None:
        with self.assertRaises(RuntimeError) as caught:
            self.run_api([self.error(403, "Resource not accessible by integration") for _ in range(3)])
        self.assertIn("Resource not accessible by integration", str(caught.exception))
        self.assertEqual(len(self.sleeps), 2)

    def test_a_missing_page_is_not_retried(self) -> None:
        with self.assertRaises(RuntimeError):
            self.run_api([self.error(404, "Not Found")])
        self.assertEqual(self.sleeps, [])


if __name__ == "__main__":
    unittest.main()
