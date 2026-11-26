"""hot-apply.py keeps its HTTP fetch and its git fetch apart.

2026-11-26 12:17Z, #58371 added `def fetch(repo, *args) -> bool` (a bounded `git fetch`) below the HTTP
`def fetch(url, timeout)`. Python keeps only the later one, so fetch_kept() read a tree's completion.json through
`git fetch`, got False, and every fleet hot-verify plan from 12:36Z died in lists_binary's
`json.loads(False)` (TypeError: the JSON object must be str, bytes or bytearray, not bool): 14 of 33 Mac looks
failed that way by 13:10Z. Each name is defined once, and fetch_kept reads the URL it is given.
"""
import importlib.util
import io
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
ENGINE = ROOT / "scripts" / "cmux-next" / "hot-apply.py"


def load():
    spec = importlib.util.spec_from_file_location("hot_apply_fetch_names", ENGINE)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class HotApplyFetchNames(unittest.TestCase):
    def test_no_name_is_defined_twice(self):
        checker = ROOT / "scripts" / "cmux-next" / "check-test-redefinitions.py"
        done = subprocess.run([sys.executable, str(checker), str(ENGINE)], capture_output=True, text=True)
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)

    def test_fetch_kept_reads_the_url_it_is_given(self):
        engine = load()
        body = b'{"key": "k", "binaries": {"cmux-tui-x": "abc"}}'
        state = tempfile.mkdtemp()
        with mock.patch.dict(os.environ, {"CMUX_HOT_APPLY_STATE_DIR": state}), \
                mock.patch.object(engine.urllib.request, "urlopen", return_value=io.BytesIO(body)) as opened, \
                mock.patch.object(engine.subprocess, "run", side_effect=AssertionError("no git for a URL")):
            got = engine.fetch_kept("https://files.cmux.com/cmux-tui/tree/k/completion.json",
                                    engine.lists_binary("cmux-tui-x"))
        self.assertEqual(got, body)
        self.assertEqual(opened.call_count, 1)


if __name__ == "__main__":
    unittest.main()
