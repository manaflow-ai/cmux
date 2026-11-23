#!/usr/bin/env python3
"""The app's code-mode resources ship packed and still run (CMUX-570, app size).

Runs the Xcode "Bundle CLI resources" phase (scripts/cmux-next/bundle-cli-resources.sh) into a
temporary app, then checks that:

- the app holds Resources/code-mode.tar.xz and no Resources/code-mode folder, at most a fifth of
  the folder's size;
- bin/cmux-code-mode-unpack unpacks it into the cache once, byte for byte the sources, and a
  second run reuses that copy; a half-unpacked folder is replaced;
- with bun, the packaged MCP (bin/cmux-code-mode-mcp) starts from the unpacked copy and answers
  cmux_docs from the bundled catalog;
- with bun and bwrap, the packaged `cmux run` runner runs a script in its sandbox from the
  unpacked SDK.
"""

import json
import os
import shutil
import socket
import subprocess
import tempfile
import threading
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PHASE = ROOT / "scripts/cmux-next/bundle-cli-resources.sh"
SDK = ROOT / "cmux-tui/bindings/typescript"


def tree(folder: Path) -> dict[str, bytes]:
    return {p.relative_to(folder).as_posix(): p.read_bytes() for p in sorted(folder.rglob("*")) if p.is_file()}


class PackedCodeModeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="cmux-code-mode-packed-")
        cls.app = Path(cls.temp.name) / "cmux.app/Contents"
        cls.resources = cls.app / "Resources"
        work = Path(cls.temp.name) / "work"
        work.mkdir()
        env = {**os.environ, "TARGET_BUILD_DIR": str(cls.app), "UNLOCALIZED_RESOURCES_FOLDER_PATH": "Resources",
               "SRCROOT": str(ROOT), "TARGET_TEMP_DIR": str(work)}
        # An unpacked folder left by an older build of the same bundle is removed.
        (cls.resources / "code-mode/sdk").mkdir(parents=True)
        subprocess.run(["bash", str(PHASE)], env=env, check=True, capture_output=True)
        cls.archive = cls.resources / "code-mode.tar.xz"
        cls.unpack = cls.resources / "bin/cmux-code-mode-unpack"

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def setUp(self):
        self.cache = Path(tempfile.mkdtemp(prefix="cache-", dir=self.temp.name))
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith(("ACPMUX_", "CMUX_CLOUD_", "CMUX_CODE_MODE_", "CMUX_TUI_"))}
        self.env["CMUX_CODE_MODE_CACHE"] = str(self.cache)

    def unpacked(self) -> Path:
        out = subprocess.run([str(self.unpack), str(self.resources)], env=self.env, check=True,
                             capture_output=True, text=True).stdout.strip()
        return Path(out)

    def test_app_ships_the_archive_only(self):
        self.assertTrue(self.archive.is_file())
        self.assertFalse((self.resources / "code-mode").exists())
        folder = self.unpacked()
        raw = sum(len(b) for b in tree(folder).values())
        self.assertLess(self.archive.stat().st_size * 5, raw, "the archive should be at most a fifth")

    def test_unpacks_the_sources_once(self):
        folder = self.unpacked()
        self.assertEqual(folder.parent.parent, self.cache)
        self.assertEqual(tree(folder / "sdk/src"), tree(SDK / "src"))
        shipped = {k: v for k, v in tree(SDK / "code-mode").items() if not k.endswith(".test.mjs")}
        self.assertEqual(tree(folder / "sdk/code-mode"), shipped)
        self.assertEqual((folder / "mcp.mjs").read_bytes(), (SDK / "code-mode/mcp.mjs").read_bytes())
        catalog = json.loads((folder / "resource-operations-v2.json").read_text())
        self.assertEqual(catalog, json.loads((ROOT / "cmux-tui/spec/resource-operations-v2.json").read_text()))
        marker = folder / ".unpacked"
        os.utime(marker, (1, 1))
        self.assertEqual(self.unpacked(), folder)
        self.assertGreater(marker.stat().st_mtime, 1, "a run refreshes its copy's marker")
        self.assertEqual([p.name for p in self.cache.iterdir()], [folder.parent.name])

    def test_replaces_a_half_unpacked_copy(self):
        folder = self.unpacked()
        (folder / ".unpacked").unlink()
        (folder / "sdk/src/node.ts").unlink()
        again = self.unpacked()
        self.assertEqual(again, folder)
        self.assertEqual(tree(again / "sdk/src"), tree(SDK / "src"))
        self.assertEqual(sorted(p.name for p in self.cache.iterdir()), [folder.parent.name])

    def test_removes_copies_unused_for_30_days(self):
        stale = self.cache / "1-2/code-mode"
        stale.mkdir(parents=True)
        (stale / ".unpacked").touch()
        os.utime(stale / ".unpacked", (1, 1))
        fresh = self.cache / "3-4/code-mode"
        fresh.mkdir(parents=True)
        (fresh / ".unpacked").touch()
        folder = self.unpacked()
        self.assertEqual(sorted(p.name for p in self.cache.iterdir()), sorted([folder.parent.name, "3-4"]))

    @unittest.skipUnless(shutil.which("bun") or os.environ.get("GITHUB_ACTIONS") == "true", "bun is required")
    def test_packaged_mcp_answers_docs(self):
        messages = [
            {"jsonrpc": "2.0", "id": 1, "method": "initialize",
             "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "t", "version": "0"}}},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
             "params": {"name": "cmux_docs", "arguments": {"query": "workspace"}}},
        ]
        result = subprocess.run([str(self.resources / "bin/cmux-code-mode-mcp")], env=self.env, cwd=self.temp.name,
                                input="".join(json.dumps(m) + "\n" for m in messages), capture_output=True,
                                text=True, timeout=60)
        replies = {r.get("id"): r for r in map(json.loads, result.stdout.splitlines()) if r.get("id")}
        self.assertIn(2, replies, result.stderr)
        docs = json.loads(replies[2]["result"]["content"][0]["text"])
        self.assertTrue(docs["results"], docs)
        self.assertTrue(any("workspace" in r["selectors"] for r in docs["results"]), docs)
        self.assertEqual(len(list(self.cache.iterdir())), 1, "the MCP ran from the unpacked copy")

    @unittest.skipUnless((shutil.which("bun") and shutil.which("bwrap")) or os.environ.get("GITHUB_ACTIONS") == "true",
                         "bun and bwrap are required")
    def test_packaged_runner_runs_a_script(self):
        # A Unix socket path is at most about 100 bytes: a short folder of its own.
        directory = Path(tempfile.mkdtemp(prefix="cm-"))
        self.addCleanup(shutil.rmtree, directory, True)
        socket_path = directory / "target.sock"
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.addCleanup(server.close)
        server.bind(str(socket_path))
        server.listen()
        held = []
        stop = threading.Event()

        def accept():
            server.settimeout(0.2)
            while not stop.is_set():
                try:
                    held.append(server.accept()[0])
                except OSError:
                    continue
        thread = threading.Thread(target=accept, daemon=True)
        thread.start()
        self.addCleanup(lambda: (stop.set(), thread.join(), [c.close() for c in held]))
        script = directory / "hello.ts"
        script.write_text('console.log("packed code mode " + (6 * 7));\nprocess.exit(0);\n')
        env = {**self.env, "CMUX_TUI_SOCKET": str(socket_path), "TMPDIR": str(directory)}
        result = subprocess.run([str(self.resources / "bin/cmux-code-mode-run"), str(script)], env=env,
                                cwd=self.temp.name, capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("packed code mode 42", result.stdout)


if __name__ == "__main__":
    unittest.main()
