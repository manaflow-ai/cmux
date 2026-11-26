"""Without presented-* geometry, apple.sh's viewer finds the marker itself (marker-locate on a display
capture) and passes it to cmux-rd observe; explicit geometry still wins; no marker refuses with why.

No Mac: Screen Sharing, screencapture, marker-locate and cmux-rd are stubs (test_apple_bytes.apple_fixture).
"""
import json
from pathlib import Path
import tempfile
import unittest

from test_apple_bytes import apple_fixture, stub, window_view


class AppleAutoGeometryTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.root = Path(self.dir.name)
        self.env, self.tools, self.bin = apple_fixture(self.root)
        # The observer stub records its arguments, then answers as the fixture's does.
        real = (self.bin / "cmux-rd").read_text().split("\n", 1)[1]
        stub(self.bin, "cmux-rd", f'printf "%s\\n" "$*" >>"{self.root}/observe.args"\n' + real)
        for key in ("EVAL_PRESENTED_OBSERVER_BIN", "EVAL_PRESENTED_MARKER_ORIGIN", "EVAL_PRESENTED_CELL_SIZE"):
            self.env.pop(key)
        self.env["EVAL_APPLE_LOCATE_TRIES"] = "2"

    def observe_args(self) -> str:
        return (self.root / "observe.args").read_text()

    def test_located_marker_is_the_observed_geometry(self):
        # The first capture has no marker (the remote frame has not arrived), the second has.
        stub(self.bin, "screen-eval-marker-locate",
             f'n=$(cat "{self.root}/locates" 2>/dev/null || echo 0); echo $((n + 1)) >"{self.root}/locates"\n'
             '(( n >= 1 )) || { echo "screen-eval-marker-locate: no marker visible on the display" >&2; exit 1; }\n'
             'echo "origin 312,96 cell 14 at 600,103"\n')
        run = window_view(self.root, self.env, 1)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertTrue((self.root / "go").exists())
        self.assertIn("--marker-origin 312,96 --cell-size 14", self.observe_args())
        readiness = json.loads((self.root / "window.raw.readiness.json").read_text())
        self.assertEqual(readiness["marker_geometry"], {"origin": "312,96", "cell_size": 14, "source": "marker-locate"})

    def test_presented_geometry_wins(self):
        stub(self.bin, "screen-eval-marker-locate", 'echo "origin 1,1 cell 4 at 2,2"\n')
        self.env.update(EVAL_PRESENTED_MARKER_ORIGIN="10,10", EVAL_PRESENTED_CELL_SIZE="8")
        run = window_view(self.root, self.env, 1)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn("--marker-origin 10,10 --cell-size 8", self.observe_args())
        readiness = json.loads((self.root / "window.raw.readiness.json").read_text())
        self.assertEqual(readiness["marker_geometry"]["source"], "presented")

    def test_no_marker_refuses_with_the_reason_and_no_go(self):
        stub(self.bin, "screen-eval-marker-locate",
             'echo "screen-eval-marker-locate: no marker visible on the display" >&2; exit 1\n')
        run = window_view(self.root, self.env, 1)
        self.assertNotEqual(run.returncode, 0)
        self.assertFalse((self.root / "go").exists())
        self.assertIn("marker-locate found no marker in 2 tries (screen-eval-marker-locate: no marker visible", run.stderr)
        self.assertFalse((self.root / "observe.args").exists())

    def test_missing_locate_tool_refuses(self):
        run = window_view(self.root, self.env, 1)
        self.assertNotEqual(run.returncode, 0)
        self.assertIn("no screen-eval-marker-locate in EVAL_BIN", run.stderr)


if __name__ == "__main__":
    unittest.main()
