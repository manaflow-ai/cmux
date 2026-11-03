"""The cold benchmark fixture must contain the bytes and newest turn it reports."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("cold_local", Path(__file__).with_name("cold_local.py"))
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


class FixtureTests(unittest.TestCase):
    def test_rotated_fixture_has_exact_counts_and_newest_message(self):
        with tempfile.TemporaryDirectory() as scratch:
            home = Path(scratch) / "home"
            result = fixture.write_fixture(home, 3, message_bytes=128, segment_bytes=400)
            session = result["sessions"][0]
            directory = home / "sessions" / session["id"]
            segments = sorted((directory / "events").glob("*.ndjson"))
            data = b"".join(path.read_bytes() for path in segments)
            records = [json.loads(line) for line in data.splitlines()]
            self.assertGreater(len(segments), 1)
            self.assertEqual(len(segments), session["segments"])
            self.assertEqual(len(data), session["bytes"])
            self.assertEqual(len(records), session["records"])
            self.assertEqual([r["seq"] for r in records], list(range(1, 14)))
            self.assertIn(session["lastMarker"], records[-2]["msg"]["params"]["update"]["content"]["text"])
            self.assertEqual(records[-1]["msg"]["status"], "completed")
            self.assertEqual(json.loads((directory / "session.json").read_text())["lastSeq"], 13)


if __name__ == "__main__":
    unittest.main()
