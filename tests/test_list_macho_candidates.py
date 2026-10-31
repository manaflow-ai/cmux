#!/usr/bin/env python3
"""list-macho-candidates.py keeps every file `file` could call Mach-O.

The thin script and the prepare job's fat-binary check run `file` only on the
paths this filter keeps, so a Mach-O it dropped would ship unthinned. Run on
real bytes: the four Mach-O magics in both byte orders, the fat magics, and
files that start differently.
"""

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FILTER = ROOT / "scripts/list-macho-candidates.py"


class ListMachoCandidates(unittest.TestCase):
    def test_keeps_every_magic_and_drops_the_rest(self):
        keep = ["feedface", "cefaedfe", "feedfacf", "cffaedfe", "cafebabe", "bebafeca", "cafebabf", "bfbafeca"]
        with tempfile.TemporaryDirectory() as tmp:
            paths, wanted = [], set()
            for magic in keep:
                path = Path(tmp) / f"bin {magic}"
                path.write_bytes(bytes.fromhex(magic) + b"\0" * 64)
                paths.append(path)
                wanted.add(str(path))
            for name, data in (("script.sh", b"#!/bin/sh\n"), ("short", b"\xca"), ("empty", b""), ("plist", b"<?xml")):
                path = Path(tmp) / name
                path.write_bytes(data)
                paths.append(path)
            paths.append(Path(tmp) / "missing")
            out = subprocess.run([sys.executable, str(FILTER)], input=b"\0".join(str(p).encode() for p in paths) + b"\0",
                                 capture_output=True, check=True).stdout
            self.assertEqual({p.decode() for p in out.split(b"\0") if p}, wanted)


if __name__ == "__main__":
    unittest.main(verbosity=2)
