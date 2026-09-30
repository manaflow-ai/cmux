import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


class UITestLocalArtifactTests(unittest.TestCase):
    def test_wrapper_renders_a_local_ui_frames_directory(self) -> None:
        with tempfile.TemporaryDirectory(prefix="cmux-ui-test-") as directory:
            root = pathlib.Path(directory)
            artifact = root / "ui-frames" / "DogfoodScenarioUITests" / "testTour"
            (artifact / "frames").mkdir(parents=True)
            (artifact / "frames" / "0001-start.jpg").write_bytes(b"jpg")
            (artifact / "steps.md").write_text(
                "# DogfoodScenarioUITests/testTour: Passed\n\n"
                "1. Start  (frames/0001-start.jpg)\n",
                encoding="utf-8",
            )
            output = root / "mirror"

            result = subprocess.run(
                [str(ROOT / "scripts/ui-test"), str(root / "ui-frames"), "--out", str(output)],
                cwd=ROOT,
                capture_output=True,
                text=True,
                timeout=30,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue((output / "index.html").is_file())
            self.assertTrue((output / "mirror.json").is_file())


if __name__ == "__main__":
    unittest.main()
