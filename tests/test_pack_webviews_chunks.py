#!/usr/bin/env python3
"""scripts/cmux-next/pack-webviews-chunks.py stores the viewers' chunks as raw DEFLATE the page
handlers inflate (CEFShim cmux_page_packed.h, CmuxNextPages PagePackedFile.swift), only when that
saves disk blocks, and an incremental build's second run packs the fresh raw copies again."""

from __future__ import annotations

import importlib.util
import tempfile
import unittest
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "cmux-next" / "pack-webviews-chunks.py"


def load():
    spec = importlib.util.spec_from_file_location("pack_webviews_chunks", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


class PackWebviewsChunksTests(unittest.TestCase):
    def setUp(self) -> None:
        self.pack = load()
        self.tmp = tempfile.TemporaryDirectory()
        self.app = Path(self.tmp.name) / "webviews-app"
        self.chunks = self.app / "chunks"
        (self.chunks / "nested").mkdir(parents=True)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_packs_big_chunks_and_keeps_small_and_other_files_raw(self) -> None:
        big = b"".join(b"export const row%d = { id: %d };\n" % (i, i) for i in range(4000))
        (self.chunks / "view.mjs").write_bytes(big)
        (self.chunks / "nested" / "style.css").write_bytes(b".a{color:red}\n" * 2000)
        (self.chunks / "tiny.mjs").write_bytes(b"export const a = 1;\n")
        (self.chunks / "notes.txt").write_bytes(b"x" * 100_000)
        (self.app / "markdown-page.html").write_bytes(b"<html>" + b" " * 100_000)

        done = self.pack.pack_folder(self.app)

        self.assertEqual(sorted(item[0] for item in done), ["chunks/nested/style.css", "chunks/view.mjs"])
        self.assertFalse((self.chunks / "view.mjs").exists())
        self.assertEqual(zlib.decompress((self.chunks / "view.mjs.deflate").read_bytes(), -15), big)
        self.assertTrue((self.chunks / "nested" / "style.css.deflate").exists())
        # One block either way: kept raw. Not a served type, or outside chunks/: untouched.
        self.assertTrue((self.chunks / "tiny.mjs").exists())
        self.assertFalse((self.chunks / "tiny.mjs.deflate").exists())
        self.assertTrue((self.chunks / "notes.txt").exists())
        self.assertTrue((self.app / "markdown-page.html").exists())

    def test_second_run_packs_a_fresh_raw_copy_and_drops_a_stale_one(self) -> None:
        first = b"export const v = 1;\n" * 2000
        (self.chunks / "view.mjs").write_bytes(first)
        self.pack.pack_folder(self.app)
        self.assertEqual(self.pack.pack_folder(self.app), [])

        # An incremental build copies the raw chunk again: it is the newer one and is packed again.
        second = b"export const v = 2;\n" * 2000
        (self.chunks / "view.mjs").write_bytes(second)
        self.pack.pack_folder(self.app)
        self.assertEqual(zlib.decompress((self.chunks / "view.mjs.deflate").read_bytes(), -15), second)
        self.assertFalse((self.chunks / "view.mjs").exists())

        # A chunk that no longer saves a block is kept raw, without its old packed copy.
        (self.chunks / "view.mjs").write_bytes(b"export const v = 3;\n")
        self.pack.pack_folder(self.app)
        self.assertTrue((self.chunks / "view.mjs").exists())
        self.assertFalse((self.chunks / "view.mjs.deflate").exists())

    def test_symlinks_and_a_missing_folder_are_left_alone(self) -> None:
        target = Path(self.tmp.name) / "outside.mjs"
        target.write_bytes(b"export const v = 1;\n" * 2000)
        (self.chunks / "link.mjs").symlink_to(target)
        self.assertEqual(self.pack.pack_folder(self.app), [])
        self.assertTrue(target.exists())
        self.assertEqual(self.pack.main([str(Path(self.tmp.name) / "missing")]), 0)


if __name__ == "__main__":
    unittest.main()
