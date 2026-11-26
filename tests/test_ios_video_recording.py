#!/usr/bin/env python3
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class IOSVideoRecordingTests(unittest.TestCase):
    def stop_recording(self, wait_status, content):
        workflow = (ROOT / '.github/workflows/test-ios.yml').read_text()
        start = workflow.index('          stop_video() {')
        end = workflow.index('          record_test_seconds() {', start)
        function = textwrap.dedent(workflow[start:end])
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'recording.mp4'
            if content is not None:
                path.write_bytes(content)
            return subprocess.run(
                ['bash', '-c', function + '''
video_pid=123
video_path="$1"
kill() { return 0; }
wait_status="$2"
wait() { return "$wait_status"; }
stop_video
''', 'test', str(path), str(wait_status)],
                capture_output=True, text=True,
            )

    def test_success_requires_finalized_output(self):
        self.assertEqual(self.stop_recording(0, b'finalized video').returncode, 0)

    def test_missing_output_fails(self):
        self.assertNotEqual(self.stop_recording(0, None).returncode, 0)

    def test_empty_output_fails(self):
        self.assertNotEqual(self.stop_recording(0, b'').returncode, 0)

    def test_recorder_failure_is_not_hidden_by_output(self):
        self.assertNotEqual(self.stop_recording(1, b'partial video').returncode, 0)


if __name__ == '__main__':
    unittest.main()
