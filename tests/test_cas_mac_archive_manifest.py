#!/usr/bin/env python3
"""scripts/cas/mac_archive_manifest.py: chunk cuts are content-defined, reassembly is bit-exact,
and a small edit costs a few chunks, not the archive (RFD 0166 row 303)."""
from __future__ import annotations

import hashlib
import importlib.util
import random
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("mam", ROOT / "scripts/cas/mac_archive_manifest.py")
mam = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules["mam"] = mam
spec.loader.exec_module(mam)


def blob(seed: int, n: int) -> bytes:
    return random.Random(seed).randbytes(n)


class MacArchiveManifestTest(unittest.TestCase):
    def test_chunk_sizes_stay_in_bounds(self) -> None:
        data = blob(1, 3 * 1024 * 1024)
        cuts = mam.cut_points(data)
        self.assertEqual(cuts[-1], len(data))
        sizes = [b - a for a, b in zip([0] + cuts, cuts)]
        for s in sizes[:-1]:
            self.assertGreaterEqual(s, mam.MIN_SIZE)
            self.assertLessEqual(s, mam.MAX_SIZE)

    def test_assemble_is_bit_exact_and_rejects_corruption(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            t = Path(tmp)
            src = t / "a.dmg"
            src.write_bytes(blob(2, 2 * 1024 * 1024 + 123))
            store = t / "store"
            man = mam.build_manifest(src, store)
            out = t / "out.dmg"
            mam.assemble(man, store, out)
            self.assertEqual(hashlib.sha256(out.read_bytes()).hexdigest(), man["sha256"])
            self.assertEqual(out.read_bytes(), src.read_bytes())
            c = man["chunks"][1]["sha256"]
            (store / c[:2] / c).write_bytes(b"tampered")
            with self.assertRaises(SystemExit):
                mam.assemble(man, store, t / "bad.dmg")
            self.assertFalse((t / "bad.dmg").exists())

    def test_insertion_costs_few_chunks(self) -> None:
        base = blob(3, 4 * 1024 * 1024)
        edited = base[:1_000_000] + b"inserted bytes" + base[1_000_000:]
        with tempfile.TemporaryDirectory() as tmp:
            t = Path(tmp)
            (t / "old").write_bytes(base)
            (t / "new").write_bytes(edited)
            d = mam.delta(mam.build_manifest(t / "old"), mam.build_manifest(t / "new"))
        self.assertLessEqual(d["fetch_chunks"], 2)
        self.assertLess(d["fetch_bytes"], 2 * mam.MAX_SIZE)

    def test_tree_restore_is_exact_and_unchanged_files_cost_nothing(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            t = Path(tmp)
            app = t / "old" / "X.app" / "Contents"
            (app / "MacOS").mkdir(parents=True)
            (app / "MacOS" / "x").write_bytes(blob(4, 1024 * 1024))
            (app / "MacOS" / "x").chmod(0o755)
            (app / "Info.plist").write_bytes(b"<plist/>")
            (app / "Current").symlink_to("MacOS")
            store = t / "store"
            old = mam.build_tree_manifest(t / "old" / "X.app", store)
            out = t / "restored"
            mam.restore_tree(old, store, out)
            self.assertEqual(mam.build_tree_manifest(out)["sha256"], old["sha256"])
            self.assertEqual(oct((out / "Contents/MacOS/x").stat().st_mode & 0o777), "0o755")
            self.assertTrue((out / "Contents/Current").is_symlink())
            (app / "Info.plist").write_bytes(b"<plist>2</plist>")
            new = mam.build_tree_manifest(t / "old" / "X.app")
            d = mam.delta(old, new)
            self.assertEqual(d["fetch_chunks"], 1)
            self.assertIn("fetch_bytes_compressed", d)

    def test_parallel_writers_share_one_store(self) -> None:
        # Two builds of overlapping inputs into one store used to race on a
        # shared .tmp name (FileNotFoundError on rename).
        import concurrent.futures
        data = blob(5, 2 * 1024 * 1024)
        with tempfile.TemporaryDirectory() as d:
            store = Path(d) / "store"
            src = Path(d) / "a.bin"
            src.write_bytes(data)
            with concurrent.futures.ProcessPoolExecutor(8) as pool:
                outs = list(pool.map(mam.build_manifest, [src] * 8, [store] * 8))
            self.assertEqual(len({o["sha256"] for o in outs}), 1)
            self.assertEqual([p for p in store.rglob("*.tmp")], [])
            mam.assemble(outs[0], store, Path(d) / "re.bin")
            self.assertEqual((Path(d) / "re.bin").read_bytes(), data)


if __name__ == "__main__":
    unittest.main()
