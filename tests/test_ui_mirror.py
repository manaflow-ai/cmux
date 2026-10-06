import importlib.util
import json
import pathlib
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("cmux_ui_mirror", ROOT / "scripts/ci/ui-mirror.py")
assert SPEC and SPEC.loader
MIRROR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MIRROR)


class UIMirrorTests(unittest.TestCase):
    def make_artifact(self, root: pathlib.Path) -> pathlib.Path:
        test = root / "DogfoodScenarioUITests" / "testRunScenario"
        (test / "frames").mkdir(parents=True)
        (test / "attachments").mkdir()
        (test / "steps.md").write_text(
            "# DogfoodScenarioUITests/testRunScenario: Passed\n\n"
            "1. Click Preview  (frames/0001-click-preview.jpg)\n"
            "2. Final  (frames/0002-final.jpg)  <- failed here\n"
            "Failure: expected preview\n",
            encoding="utf-8",
        )
        for name in ("0001-click-preview.jpg", "0002-final.jpg"):
            (test / "frames" / name).write_bytes(b"jpg")
        (test / "attachments" / "01-reply.json").write_text(
            '{"ok":true}\n', encoding="utf-8"
        )
        (test / "attachments" / "02-clip.mp4").write_bytes(b"video")
        return test

    def test_collects_steps_failures_and_attachments(self) -> None:
        with tempfile.TemporaryDirectory(prefix="cmux-ui-mirror-") as directory:
            root = pathlib.Path(directory)
            self.make_artifact(root)
            tests = MIRROR.collect(root)

            self.assertEqual(len(tests), 1)
            self.assertEqual(len(tests[0]["steps"]), 2)
            self.assertTrue(tests[0]["steps"][1]["failed"])
            self.assertEqual(tests[0]["attachments"][0]["name"], "01-reply.json")
            self.assertEqual(tests[0]["attachments"][1]["name"], "02-clip.mp4")

    def test_manifest_and_html_are_written_without_script_breakout(self) -> None:
        with tempfile.TemporaryDirectory(prefix="cmux-ui-mirror-") as directory:
            root = pathlib.Path(directory)
            test = self.make_artifact(root)
            steps = test / "steps.md"
            steps.write_text(
                steps.read_text(encoding="utf-8").replace(
                    "Click Preview", "Click </script><script>alert(1)"
                ),
                encoding="utf-8",
            )
            output = MIRROR.write_mirror(root, MIRROR.collect(root))

            self.assertEqual(output, root / "index.html")
            manifest = json.loads((root / "mirror.json").read_text(encoding="utf-8"))
            self.assertEqual(manifest["version"], 1)
            html = output.read_text(encoding="utf-8")
            self.assertNotIn("</script><script>alert(1)", html)
            self.assertIn("document.createElement('video')", html)
            self.assertIn("cmux UI mirror", html)


if __name__ == "__main__":
    unittest.main()
