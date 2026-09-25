#!/usr/bin/env python3
"""Behavior probes for the actual isolated helper; run only on a scheduled Mac."""
import json
import os
from pathlib import Path
import shutil
import select
import struct
import subprocess
import tempfile
import time
import unittest
import uuid

HELPER = os.environ.get("CMUX_PASTE_HELPER", "")
PROVIDER = os.environ.get("CMUX_PASTE_PROVIDER", "")
CLIENT = os.environ.get("CMUX_PASTE_CLIENT", "")


@unittest.skipUnless(HELPER and PROVIDER, "requires built helper and isolated provider")
class PlainPasteFixture(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="cmux-paste-test-"))
        self.children = []
        self.workdirs = []

    def tearDown(self):
        for child in self.children:
            if child.poll() is None:
                child.kill()
            child.wait(timeout=5)
            if child.stdin:
                child.stdin.close()
            if child.stdout:
                child.stdout.close()
        for path in self.workdirs + [self.root]:
            shutil.rmtree(path, ignore_errors=True)

    def board(self, text="hello\n日本語 🦀 e\u0301\r\n", extra=None, behavior=None):
        identity = str(uuid.uuid4())
        config = dict(name="cmux-paste-test-" + identity, text=text or "",
                      representations={**({"public.utf8-plain-text": text} if text is not None else {}), **(extra or {})},
                      ready=str(self.root / (identity + "-ready.json")),
                      requested=str(self.root / (identity + "-requested")))
        if behavior:
            config["behavior"] = behavior
            config["representations"].pop("public.utf8-plain-text", None)
        config_path = self.root / "config.json"
        config_path.write_text(json.dumps(config))
        child = subprocess.Popen([PROVIDER, str(config_path)])
        self.children.append(child)
        self.until(lambda: Path(config["ready"]).exists())
        config["generation"] = json.loads(Path(config["ready"]).read_text())["generation"]
        return config

    def until(self, predicate, seconds=5):
        deadline = time.monotonic() + seconds
        while not predicate() and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertTrue(predicate(), "fixture condition did not occur")

    def directory(self, board, stale=False):
        path = Path(tempfile.gettempdir()) / ("cmux-paste-preparation-" + str(uuid.uuid4()))
        path.mkdir(mode=0o700)
        self.workdirs.append(path)
        request = dict(pasteboard=dict(pasteboardName=board["name"],
                                      changeCount=-1 if stale else board["generation"]),
                       mode={"paste": {}}, destination={"terminal": {}})
        (path / "request.json").write_text(json.dumps(request))
        return path

    def launch(self, path):
        child = subprocess.Popen([HELPER, "--cmux-plain-text-paste-worker",
                                  "--cmux-paste-preparation-working-directory", str(path)],
                                 stdin=subprocess.PIPE)
        self.children.append(child)
        return child

    def result(self, path, expected=0):
        child = self.launch(path)
        self.assertEqual(child.wait(timeout=12), expected)
        if expected == 0:
            return json.loads((path / "response.json").read_text())


class PlainTextPasteWorkerTests(PlainPasteFixture):
    def test_unicode_multiline_and_repeat(self):
        board = self.board()
        for directory_index in range(2):
            path = self.directory(board)
            for repetition in range(2):
                start = time.perf_counter()
                result = self.result(path)
                ms = (time.perf_counter() - start) * 1000
                self.assertEqual(result["textPayload"]["filename"], "text-payload.txt")
                self.assertEqual(result["textPayload"]["destination"], {"terminal": {}})
                self.assertEqual(result["ownedTemporaryImageNames"], [])
                self.assertEqual((path / "text-payload.txt").read_bytes(), board["text"].encode())
                print(json.dumps(dict(helper_startup_ms=ms, directory=directory_index,
                                      repetition=repetition, size=Path(HELPER).stat().st_size)), flush=True)

    def test_plain_text_with_rich_flavors_uses_fast_path(self):
        for flavor in ["public.html", "public.rtf"]:
            for text in ["hello\n日本語 🦀 e\u0301\r\n", "Question?", "文本\n" * 100_000]:
                with self.subTest(flavor=flavor, bytes=len(text.encode())):
                    board = self.board(text=text, extra={flavor: "unused rich text"})
                    path = self.directory(board)
                    result = self.result(path)
                    self.assertEqual(result["textPayload"]["destination"], {"terminal": {}})
                    self.assertEqual((path / "text-payload.txt").read_bytes(), text.encode())

    def test_rich_only_and_empty_plain_text_delegate(self):
        for flavor in ["public.html", "public.rtf", "com.apple.flat-rtfd"]:
            for text in [None, ""]:
                with self.subTest(flavor=flavor, text=text):
                    board = self.board(text=text, extra={flavor: "rich fallback"})
                    self.result(self.directory(board), expected=73)

    def test_lossy_plain_text_with_rich_flavors_delegates(self):
        for flavor in ["public.html", "public.rtf"]:
            for text in ["??", "text\ufffd", "日本語??"]:
                with self.subTest(flavor=flavor, text=text):
                    board = self.board(text=text, extra={flavor: "rich fallback"})
                    self.result(self.directory(board), expected=73)

    def test_loss_markers_without_rich_text_remain_literal(self):
        text = "??\ufffd"
        board = self.board(text=text)
        path = self.directory(board)
        self.result(path)
        self.assertEqual((path / "text-payload.txt").read_bytes(), text.encode())

    def test_rich_images_and_auxiliary_urls_delegate_without_provider_read(self):
        for flavor in ["public.png",
                       "public.tiff", "public.jpeg", "public.file-url", "public.url",
                       "NSFilenamesPboardType", "com.apple.pasteboard.promised-file-url"]:
            with self.subTest(flavor=flavor):
                board = self.board(extra={flavor: "auxiliary"}, behavior="stall")
                self.result(self.directory(board), expected=73)
                self.assertFalse(Path(board["requested"]).exists())
                Path(board["ready"]).unlink()

    def test_stale_generation_never_requests_provider(self):
        board = self.board(behavior="stall")
        result = self.result(self.directory(board, stale=True))
        self.assertIn("reject", result["result"]["terminal"]["_0"])
        self.assertFalse(Path(board["requested"]).exists())

    def test_provider_changes_generation(self):
        board = self.board(behavior="replace")
        result = self.result(self.directory(board))
        self.assertIn("reject", result["result"]["terminal"]["_0"])
        self.assertTrue(Path(board["requested"]).exists())

    def test_missing_provider_data_rejects(self):
        board = self.board(behavior="missing")
        result = self.result(self.directory(board))
        self.assertIn("reject", result["result"]["terminal"]["_0"])

    def test_parent_disappearance_terminates_stalled_read(self):
        board = self.board(behavior="stall")
        path = self.directory(board)
        child = self.launch(path)
        self.until(lambda: Path(board["requested"]).exists())
        child.stdin.close()
        self.assertEqual(child.wait(timeout=3), 125)
        self.assertFalse(path.exists())

    def test_hard_deadline_terminates_stalled_read(self):
        board = self.board(behavior="stall")
        child = self.launch(self.directory(board))
        self.until(lambda: Path(board["requested"]).exists())
        self.assertEqual(child.wait(timeout=12), 124)

    def test_sigkill_reaps_stalled_helper(self):
        board = self.board(behavior="stall")
        child = self.launch(self.directory(board))
        self.until(lambda: Path(board["requested"]).exists())
        child.kill()
        self.assertEqual(child.wait(timeout=3), -9)


class PlainTextPasteServerTests(PlainPasteFixture):
    def server(self):
        child = subprocess.Popen([HELPER, "--cmux-plain-text-paste-server"],
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        self.children.append(child)
        self.assertEqual(self.read_exact(child, 1), b"R")
        return child

    def read_exact(self, child, count):
        result = bytearray()
        while len(result) < count:
            self.assertTrue(select.select([child.stdout], [], [], 12)[0], "missing server response")
            chunk = os.read(child.stdout.fileno(), count - len(result))
            self.assertTrue(chunk, "server exited during response")
            result.extend(chunk)
        return bytes(result)

    def send(self, child, board, stale=False):
        request = dict(pasteboard=dict(pasteboardName=board["name"],
                                      changeCount=-1 if stale else board["generation"]),
                       mode={"paste": {}}, destination={"terminal": {}})
        child.stdin.write((json.dumps(request) + "\n").encode())
        child.stdin.flush()

    def receive(self, child):
        status, count = struct.unpack("!BI", self.read_exact(child, 5))
        self.assertLessEqual(count, 16 * 1024 * 1024)
        return status, self.read_exact(child, count)

    def test_reuses_reader_for_exact_unicode_and_rich_text(self):
        child = self.server()
        for extra in [None, {"public.html": "unused"}, {"public.rtf": "unused"}]:
            board = self.board(extra=extra)
            for repetition in range(3):
                self.send(child, board)
                self.assertEqual(self.receive(child), (0, board["text"].encode()))
                self.assertIsNone(child.poll())

    def test_ineligible_payload_preserves_server_for_next_request(self):
        child = self.server()
        for flavor in ["public.png", "public.file-url", "public.url"]:
            board = self.board(extra={flavor: "auxiliary"}, behavior="stall")
            self.send(child, board)
            self.assertEqual(self.receive(child), (73, b""))
            self.assertFalse(Path(board["requested"]).exists())
        lossy = self.board(text="??", extra={"public.html": "faithful text"})
        self.send(child, lossy)
        self.assertEqual(self.receive(child), (73, b""))
        board = self.board()
        self.send(child, board)
        self.assertEqual(self.receive(child), (0, board["text"].encode()))

    def test_stale_and_replaced_generations_do_not_insert_replacement(self):
        child = self.server()
        stale = self.board(behavior="stall")
        self.send(child, stale, stale=True)
        self.assertEqual(self.receive(child), (0, b""))
        self.assertFalse(Path(stale["requested"]).exists())
        replaced = self.board(behavior="replace")
        self.send(child, replaced)
        self.assertEqual(self.receive(child), (0, b""))
        self.assertTrue(Path(replaced["requested"]).exists())

    def test_idle_server_exits_when_owner_closes(self):
        child = self.server()
        child.stdin.close()
        self.assertEqual(child.wait(timeout=3), 125)

    def test_invalid_request_terminates_server(self):
        child = self.server()
        child.stdin.write(b"[]\n")
        child.stdin.flush()
        self.assertEqual(child.wait(timeout=3), 65)

    def test_stalled_provider_has_independent_deadline(self):
        child = self.server()
        board = self.board(behavior="stall")
        self.send(child, board)
        self.until(lambda: Path(board["requested"]).exists())
        self.assertEqual(child.wait(timeout=12), 124)

    def test_parent_exit_terminates_reader_inside_provider(self):
        board = self.board(behavior="stall")
        launcher = self.root / "parent.py"
        launcher.write_text("""import os, subprocess, sys
reader = subprocess.Popen([sys.argv[1], '--cmux-plain-text-paste-server'],
                          stdin=subprocess.PIPE, stdout=subprocess.PIPE)
assert reader.stdout.read(1) == b'R'
print(reader.pid, flush=True)
reader.stdin.write(sys.stdin.buffer.readline())
reader.stdin.flush()
sys.stdin.buffer.readline()
os._exit(0)
""")
        parent = subprocess.Popen([os.sys.executable, str(launcher), HELPER],
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        self.children.append(parent)
        self.assertTrue(select.select([parent.stdout], [], [], 5)[0])
        reader_pid = int(parent.stdout.readline())
        try:
            self.send(parent, board)
            self.until(lambda: Path(board["requested"]).exists())
            parent.stdin.close()
            self.assertEqual(parent.wait(timeout=3), 0)

            def reader_exited():
                try:
                    os.kill(reader_pid, 0)
                    return False
                except ProcessLookupError:
                    return True

            self.until(reader_exited, seconds=3)
        finally:
            try:
                os.kill(reader_pid, 9)
            except ProcessLookupError:
                pass


@unittest.skipUnless(CLIENT and HELPER and PROVIDER, "requires built Swift client probe")
class PlainTextPasteClientTests(unittest.TestCase):
    def probe(self, name):
        result = subprocess.run([CLIENT, name, HELPER, PROVIDER],
                                text=True, capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("PASS: " + name, result.stdout)

    def test_clipboard_restoration_through_production_swift_client(self):
        self.probe("restore")

    def test_cancellation_reaps_before_reader_replacement(self):
        self.probe("cancel")

    def test_oversized_reply_is_rejected_and_reaped(self):
        self.probe("malformed")


if __name__ == "__main__":
    unittest.main(verbosity=2)
