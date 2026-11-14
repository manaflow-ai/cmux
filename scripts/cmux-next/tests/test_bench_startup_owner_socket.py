#!/usr/bin/env python3
"""bench-startup.py finds the app daemon's socket where cmux-tui puts it, for any tag (PERF-HOT TOOL, 2026-11-06).

The app starts its daemon with TMPDIR set to the user temp folder (DaemonLauncher.ensureEnvironment), and cmux-tui
listens on <TMPDIR>/cmux-tui-<uid>/<session>.sock only when that path fits sun_path (103 bytes); else on
/tmp/cmux-tui-<uid>/<session>.sock, then on a sha256 name (cmux-tui-core server/socket_path.rs). bench-startup
looked only in the user temp folder, for `cmux-app-<tag>.sock`. A chrome-parity-* fleet build (the Release bench
builds) has a long tag: on cmux22 (macOS 27.0) the user temp folder /var/folders/50/8_zbn3ns42j2l4kvmlhmf2nw0000gn/T/
made the path 105 bytes for chrome-parity-switch-stall-v4, its daemon's client.log said
"headless, control socket at /tmp/cmux-tui-501/cmux-app-chrome-parity-switch-stall-v4.sock", and every launch bench
of SWITCH STALL 3 (4 runs, 5 launches each) was NOT RUN: "no cmux-tui owner answered identify". A build whose names
are of its key (BuildIdentity: `cmux-app--<key hash>`) was not found either.
No app: a fake `getconf` names the user temp folder and the test binds the socket itself.
Run: python3 -I scripts/cmux-next/tests/test_bench_startup_owner_socket.py"""
import importlib.util, io, os, plistlib, shutil, socket, stat, sys, tempfile, unittest
from contextlib import redirect_stderr

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
spec = importlib.util.spec_from_file_location("bench_startup", os.path.join(HERE, "..", "bench-startup.py"))
bench_startup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bench_startup)
import build_names  # noqa: E402

CMUX22_TEMP = "/var/folders/50/8_zbn3ns42j2l4kvmlhmf2nw0000gn/T/"


def fake_bundle(root, name, bundle_id, tag):
    """A `cmux DEV <name>.app` with only the Info.plist bench-startup reads."""
    app = os.path.join(root, f"cmux DEV {name}.app")
    os.makedirs(os.path.join(app, "Contents/MacOS"))
    with open(os.path.join(app, "Contents/Info.plist"), "wb") as f:
        plistlib.dump({"CFBundleIdentifier": bundle_id, "CFBundleExecutable": "cmux DEV",
                       "LSEnvironment": {"CMUX_TAG": tag}}, f)
    return app


class SocketRule(unittest.TestCase):
    """session_socket_path is cmux-tui's default_socket_path_in_runtime_dir with the app's TMPDIR as the base."""

    def test_a_short_session_listens_in_the_user_temp_folder(self):
        self.assertEqual(bench_startup.session_socket_path("cmux-app-nxboot", CMUX22_TEMP, 501),
                         CMUX22_TEMP + "cmux-tui-501/cmux-app-nxboot.sock")

    def test_the_cmux22_chrome_parity_owner_listens_in_tmp(self):
        # Its daemon's client.log on cmux22, 2026-11-06 15:53Z.
        self.assertEqual(
            bench_startup.session_socket_path("cmux-app-chrome-parity-switch-stall-v4", CMUX22_TEMP, 501),
            "/tmp/cmux-tui-501/cmux-app-chrome-parity-switch-stall-v4.sock")

    def test_a_103_byte_path_fits_and_104_does_not(self):
        base = "/bbbbbb"  # longer than /tmp, so the one byte more still fits there
        fit = "s" * (103 - len(f"{base}/cmux-tui-501/.sock"))
        self.assertEqual(bench_startup.session_socket_path(fit, base, 501), f"{base}/cmux-tui-501/{fit}.sock")
        self.assertEqual(bench_startup.session_socket_path(fit + "s", base, 501), f"/tmp/cmux-tui-501/{fit}s.sock")

    def test_a_session_too_long_for_tmp_gets_its_sha256_name(self):
        import hashlib
        session = "cmux-app-" + "x" * 120
        digest = hashlib.sha256(session.encode()).hexdigest()
        self.assertEqual(bench_startup.session_socket_path(session, "/short", 501),
                         f"/short/cmux-tui-hashed-501/{digest}.sock")
        self.assertEqual(bench_startup.session_socket_path(session, "/" + "b" * 60, 501),
                         f"/tmp/cmux-tui-hashed-501/{digest}.sock")


class DaemonSocket(unittest.TestCase):
    """daemon_socket(tag) answers with the socket the tag's owner listens on, from the bundle's own names."""

    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="owner-socket-")
        self.bin = os.path.join(self.root, "bin")
        os.makedirs(self.bin)
        self.path = os.environ.get("PATH", "")
        os.environ["PATH"] = self.bin + os.pathsep + self.path
        self.listeners = []
        self.made = []

    def tearDown(self):
        os.environ["PATH"] = self.path
        for listener in self.listeners:
            listener.close()
        for path in self.made:
            try:
                os.unlink(path)
            except FileNotFoundError:
                pass
        bench_startup.APPS.clear()
        shutil.rmtree(self.root, ignore_errors=True)

    def user_temp(self, folder):
        """`getconf DARWIN_USER_TEMP_DIR` prints `folder` (with the trailing slash macOS gives)."""
        script = os.path.join(self.bin, "getconf")
        with open(script, "w") as f:
            f.write(f"#!/bin/sh\necho '{folder.rstrip('/')}/'\n")
        os.chmod(script, 0o755)

    def listen(self, path):
        os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(path)
        listener.listen(1)
        self.listeners.append(listener)
        self.made.append(path)
        return path

    def find(self, tag):
        with redirect_stderr(io.StringIO()):
            return bench_startup.daemon_socket(tag, timeout=1)

    def test_a_long_tag_owner_is_found_in_tmp(self):
        # A user temp folder as long as cmux22's: the preferred path does not fit, the owner listens in /tmp.
        self.user_temp(os.path.join(self.root, "T" * 60))
        tag = f"chrome-parity-owner-{os.getpid()}"
        app = fake_bundle(self.root, tag, "com.cmuxterm.app.debug." + tag.replace("-", "."), tag)
        bench_startup.APPS[tag] = app
        want = self.listen(f"/tmp/cmux-tui-{os.getuid()}/cmux-app-{tag}.sock")
        self.assertTrue(stat.S_ISSOCK(os.stat(want).st_mode))
        self.assertEqual(self.find(tag), want)

    def test_a_build_with_names_of_its_key_is_found(self):
        # A copy whose bundle id does not end in its tag (a capture slot's clone): `cmux-app--<key hash>`.
        temp = os.path.join(self.root, "T")
        self.user_temp(temp)
        tag = "keyed-owner"
        bundle_id = "com.cmuxterm.app.debug.keyed.owner.capslot1"
        app = fake_bundle(self.root, tag, bundle_id, tag)
        bench_startup.APPS[tag] = app
        session = build_names.names(bundle_id, tag, os.path.expanduser("~"))["session"]
        self.assertTrue(session.startswith("cmux-app--"), session)
        want = self.listen(os.path.join(temp, f"cmux-tui-{os.getuid()}", f"{session}.sock"))
        self.assertEqual(self.find(tag), want)

    def test_no_owner_names_the_path_it_waited_for(self):
        self.user_temp(os.path.join(self.root, "T"))
        tag = "absent-owner"
        bench_startup.APPS[tag] = fake_bundle(self.root, tag, "com.cmuxterm.app.debug.absent.owner", tag)
        with self.assertRaises(SystemExit) as raised:
            self.find(tag)
        self.assertIn(f"cmux-tui-{os.getuid()}/cmux-app-absent-owner.sock", str(raised.exception))


if __name__ == "__main__":
    unittest.main()
