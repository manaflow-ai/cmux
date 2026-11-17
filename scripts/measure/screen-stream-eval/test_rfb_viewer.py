"""rfb-viewer.py against a fake Apple Screen Sharing server: login, ZRLE decode, marker latency,
window rows and the nonce readiness check. Runs anywhere (no Mac):
  python3 -m unittest scripts/measure/screen-stream-eval/test_rfb_viewer.py
"""
import importlib.util
import json
import os
import socket
import struct
import subprocess
import tempfile
import threading
import time
import unittest
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("rfb_viewer", HERE / "rfb-viewer.py")
rfb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rfb)

CELL, W, H = 16, 680, 200
NONCE = "00112233445566778899aabbccddeeff"


class FakeServer(threading.Thread):
    """RFB 3.889, security type 30 only, a ZRLE framebuffer whose top rows are the marker:
    the counter row (bumped by each key or click, and by every update while `tick`), then the
    nonce rows when `nonce` is set."""

    def __init__(self, nonce=None, tick=False, reject=False, split=False, cell=None, top=0):
        super().__init__(daemon=True)
        self.listener = socket.socket()
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen(1)
        self.port = self.listener.getsockname()[1]
        self.nonce, self.tick, self.reject = nonce, tick, reject
        # split: each update arrives in two pieces 0.3 s apart, longer than the viewer's 80-200 ms
        # pause between inputs, so the drain (1 ms deadline) reads only the first piece.
        self.split, self.cell, self.top = split, cell or CELL, top
        self.counter = 5
        self.z = zlib.compressobj()
        self.login = None

    def frame(self):
        px = bytearray(b"\xc0\xc0\xc0" * (W * H))
        # A white strip above the marker, as a light menu bar.
        px[:self.top * W * 3] = b"\xff" * (self.top * W * 3)
        words = [self.counter] + (rfb.nonce_words(self.nonce) if self.nonce else [])
        c, top = self.cell, self.top
        for row, word in enumerate(words):
            for col in range(20):
                on = (word >> col) & 1 if col < 16 else (1, 0, 1, 0)[col - 16]
                for y in range(top + row * c, top + (row + 1) * c):
                    for x in range(col * c, (col + 1) * c):
                        px[(y * W + x) * 3:(y * W + x) * 3 + 3] = b"\xff\xff\xff" if on else b"\x00\x00\x00"
        return px

    def update(self, conn):
        px = self.frame()
        tiles = bytearray()
        for ty in range(0, H, 64):
            for tx in range(0, W, 64):
                tiles.append(0)
                for y in range(ty, min(H, ty + 64)):
                    for x in range(tx, min(W, tx + 64)):
                        r, g, b = px[(y * W + x) * 3:(y * W + x) * 3 + 3]
                        tiles += bytes((b, g, r))
        data = self.z.compress(bytes(tiles)) + self.z.flush(zlib.Z_SYNC_FLUSH)
        message = (struct.pack("!BxH", 0, 1) + struct.pack("!HHHHi", 0, 0, W, H, 16)
                   + struct.pack("!I", len(data)) + data)
        if self.split:
            conn.sendall(message[:6])
            time.sleep(0.3)
            message = message[6:]
        conn.sendall(message)

    def run(self):
        conn, _ = self.listener.accept()
        f = conn.makefile("rb")
        conn.sendall(b"RFB 003.889\n")
        f.read(12)
        conn.sendall(bytes([1, 30]))
        assert f.read(1) == b"\x1e"
        prime = (2 ** 127 - 1).to_bytes(16, "big")
        conn.sendall(struct.pack("!HH", 2, 16) + prime + pow(2, 12345, 2 ** 127 - 1).to_bytes(16, "big"))
        self.login = f.read(128 + 16)
        if self.reject:
            conn.sendall(struct.pack("!I", 1) + struct.pack("!I", 4) + b"nope")
            conn.close()
            return
        conn.sendall(struct.pack("!I", 0))
        f.read(1)
        conn.sendall(struct.pack("!HH", W, H) + bytes(16) + struct.pack("!I", 4) + b"fake")
        try:
            while True:
                kind = f.read(1)
                if not kind:
                    return
                kind = kind[0]
                if kind == 0:
                    f.read(19)
                elif kind == 2:
                    n = struct.unpack("!xH", f.read(3))[0]
                    f.read(4 * n)
                elif kind == 3:
                    f.read(9)
                    if self.tick:
                        self.counter += 1
                    time.sleep(0.01)
                    self.update(conn)
                elif kind == 4:
                    down = f.read(7)[0]
                    if down:
                        self.counter += 1
                elif kind == 5:
                    mask = f.read(5)[0]
                    if mask:
                        self.counter += 1
        except (OSError, ValueError):
            return


class RFBViewerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.login = self.dir / "login"
        self.login.write_text("cmux\nsecret\n")
        os.chmod(self.login, 0o600)

    def tearDown(self):
        self.tmp.cleanup()

    def run_viewer(self, server, *args):
        server.start()
        return rfb.main([args[0], "--host", "127.0.0.1", "--port", str(server.port), "--login-file", str(self.login),
                         "--timeout", "10", *args[1:]])

    def test_aes_fips197_vector(self):
        key = bytes(range(16))
        plain = bytes.fromhex("00112233445566778899aabbccddeeff")
        self.assertEqual(rfb.aes128_ecb_encrypt(key, plain).hex(), "69c4e0d86a7b0430d8cdb78070b4c55a")

    def test_login_file_must_be_private(self):
        os.chmod(self.login, 0o644)
        with self.assertRaisesRegex(rfb.RFBError, "chmod 600"):
            rfb.read_login(str(self.login))

    def test_one_line_login_is_this_accounts_password(self):
        import pwd
        self.login.write_text("secret\n")
        self.assertEqual(rfb.read_login(str(self.login)), (pwd.getpwuid(os.getuid()).pw_name, "secret"))

    def fake_security(self, attrs_rc=0, account="leo", password="saved-secret"):
        calls = []

        def run(argv, **kwargs):
            calls.append(argv)
            if argv[-1] == "-w":
                return subprocess.CompletedProcess(argv, 0, password + "\n", "")
            return subprocess.CompletedProcess(argv, attrs_rc, f'    "acct"<blob>="{account}"\n', "")
        return run, calls

    def test_keychain_login_is_screen_sharings_saved_login(self):
        run, calls = self.fake_security()
        self.assertEqual(rfb.keychain_login("10.0.0.5", run), ("leo", "saved-secret"))
        self.assertEqual(calls[0], ["security", "find-internet-password", "-r", "rfb ", "-s", "10.0.0.5"])
        self.assertTrue(all("saved-secret" not in " ".join(c) for c in calls))

    def test_keychain_login_missing_or_empty_is_none(self):
        self.assertIsNone(rfb.keychain_login("10.0.0.5", self.fake_security(attrs_rc=44)[0]))
        self.assertIsNone(rfb.keychain_login("10.0.0.5", self.fake_security(password="")[0]))
        self.assertIsNone(rfb.keychain_login("10.0.0.5", self.fake_security(account="")[0]))

    def test_no_default_file_falls_back_to_keychain(self):
        import pwd
        if os.path.exists(os.path.join(pwd.getpwuid(os.getuid()).pw_dir, ".config/screen-stream-eval/login")):
            self.skipTest("this account has a default login file")
        run, _ = self.fake_security()
        self.assertEqual(rfb.read_login(None, "10.0.0.5", run), ("leo", "saved-secret"))
        with self.assertRaisesRegex(rfb.RFBError, "Remember this password"):
            rfb.read_login(None, "10.0.0.5", self.fake_security(attrs_rc=44)[0])

    def test_explicit_missing_file_never_reads_keychain(self):
        run, calls = self.fake_security()
        with self.assertRaises(rfb.RFBError):
            rfb.read_login(str(self.dir / "absent"), "10.0.0.5", run)
        self.assertEqual(calls, [])

    def test_rejected_login_fails(self):
        self.assertEqual(self.run_viewer(FakeServer(reject=True), "probe"), 1)

    def test_key_latency_reads_marker(self):
        out = self.dir / "lat.json"
        self.assertEqual(self.run_viewer(FakeServer(), "latency", "--input", "key", "--samples", "5", "--out", str(out)), 0)
        result = json.loads(out.read_text())
        self.assertEqual(result["g2g_ms"]["n"], 5)
        self.assertEqual(result["lost"], 0)
        self.assertEqual(result["geometry"]["cell"], CELL)

    def test_message_split_across_drain_deadline_keeps_stream_in_sync(self):
        # An update whose bytes straddle the 1 ms drain deadline used to lose its first byte and
        # desync the stream ("unexpected server message 180" on a real Mac).
        out = self.dir / "lat.json"
        self.assertEqual(self.run_viewer(FakeServer(split=True), "latency", "--input", "key", "--samples", "5",
                                         "--out", str(out)), 0)
        self.assertEqual(json.loads(out.read_text())["lost"], 0)

    def test_locate_finds_full_size_cells_below_a_light_strip(self):
        # A 32 px marker under a white menu bar once read as 16 px cells half a row too low.
        out = self.dir / "lat.json"
        self.assertEqual(self.run_viewer(FakeServer(cell=32, top=30), "latency", "--input", "key", "--samples", "3",
                                         "--out", str(out)), 0)
        geometry = json.loads(out.read_text())["geometry"]
        self.assertEqual((geometry["marker_y"], geometry["cell"]), (30, 32.0))

    def test_pointer_latency_uses_marker_log_geometry(self):
        log = self.dir / "marker.log"
        # Stream pixels twice the framebuffer's: the log's numbers halve.
        log.write_text(f"marker-origin 0,0 click-at 704,32\nmarker: stream width {W * 2} px, cell 16 pt, display (0,0)\n")
        out = self.dir / "lat.json"
        self.assertEqual(self.run_viewer(FakeServer(), "latency", "--input", "pointer", "--samples", "3",
                                         "--marker-log", str(log), "--out", str(out)), 0)
        result = json.loads(out.read_text())
        self.assertEqual(result["geometry"]["at"], [352, 16])
        self.assertEqual(result["g2g_ms"]["n"], 3)

    def test_window_with_nonce_counts_bytes_and_frames(self):
        out, frame, go = self.dir / "win.json", self.dir / "frame.png", self.dir / "go"
        rc = self.run_viewer(FakeServer(nonce=NONCE, tick=True), "window", "--seconds", "2.2", "--frame", str(frame),
                             "--go", str(go), "--out", str(out), "--nonce", NONCE)
        self.assertEqual(rc, 0)
        self.assertTrue(go.exists())
        self.assertEqual(frame.read_bytes()[:8], b"\x89PNG\r\n\x1a\n")
        result = json.loads(out.read_text())
        self.assertGreaterEqual(len(result["series"]), 2)
        self.assertTrue(all(r["bytes"] > 0 and r["frames"] > 0 for r in result["series"]))
        self.assertTrue(result["extra"]["readiness"]["nonce_observed"])

    def test_window_refuses_another_nonce(self):
        out, frame, go = self.dir / "win.json", self.dir / "frame.png", self.dir / "go"
        rc = self.run_viewer(FakeServer(nonce="ff" * 16, tick=True), "window", "--seconds", "1", "--frame", str(frame),
                             "--go", str(go), "--out", str(out), "--nonce", NONCE)
        self.assertEqual(rc, 1)
        self.assertFalse(go.exists())


if __name__ == "__main__":
    unittest.main()
