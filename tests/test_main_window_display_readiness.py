"""Real AppKit ratchet for completion subscription before/after initial display.

Requires an isolated macOS GUI session. Opens only this short-lived accessory
probe's nearly transparent windows; no cmux app, notifications, defaults or socket.
"""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class MainWindowDisplayReadinessTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='cmux-window-readiness-')
        window = (ROOT / 'Sources/App/CmuxMainWindow.swift').read_text()
        start = window.index('    private var initialDisplayCompletion')
        lifecycle = window[start:window.index('    private var isSoftHiddenForVisibilityController', start)]
        template = (ROOT / 'tests/fixtures/main_window_display_readiness.swift').read_text()
        source = Path(cls.temp.name) / 'main.swift'
        source.write_text(template.replace('// WINDOW LIFECYCLE', lifecycle))
        cls.binary = Path(cls.temp.name) / 'window-readiness'
        run = subprocess.run(['swiftc', '-swift-version', '6', '-parse-as-library',
                              str(source), '-o', str(cls.binary)], text=True, capture_output=True)
        if run.returncode:
            raise RuntimeError(run.stdout + run.stderr)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def run_case(self, mode):
        run = subprocess.run([str(self.binary), mode], text=True, capture_output=True,
                             env={**os.environ, 'SWIFT_BACKTRACE':'disable'}, timeout=15)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        print(run.stdout.strip())

    def test_registration_after_completed_display_without_redraw(self): self.run_case('late-display')
    def test_registration_after_completed_display_if_needed_without_redraw(self): self.run_case('late-if-needed')
    def test_registration_after_automatic_initial_paint_without_redraw(self): self.run_case('late-automatic')
    def test_registration_before_first_display(self): self.run_case('before')
    def test_hidden_window_keeps_gate_closed(self): self.run_case('hidden')


if __name__ == '__main__':
    unittest.main()
