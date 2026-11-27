#!/usr/bin/env python3
"""Behavior tests of scripts/cmux-next/pack-markdown-libraries.py (CMUX-570).

The app build packs Mermaid, Ondine and Vega into `<name>.xz`; the app unpacks them on first use
(CmuxNextPages PackedResource.swift, whose WebKit test draws from them). Here: every library comes
back byte for byte, a second run (an incremental build) changes nothing, the cache is reused, and
the cut stays worth what the PR measured.
"""

from __future__ import annotations

import lzma
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
TOOL = ROOT / "scripts/cmux-next/pack-markdown-libraries.py"
LIBRARIES = ROOT / "Resources/markdown-viewer"
NAMES = ("mermaid.min.js", "ondine.min.js", "vega.min.js", "vega-lite.min.js", "vega-embed.min.js")


def run(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, "-I", str(TOOL), *args], capture_output=True, text=True, check=False)


def copy_libraries(d: Path) -> Path:
    folder = d / "markdown-viewer"
    folder.mkdir()
    for name in (*NAMES, "marked.min.js", "shell.html"):
        shutil.copy(LIBRARIES / name, folder / name)
    return folder


def test_every_library_unpacks_to_itself(d: Path) -> None:
    folder = copy_libraries(d)
    r = run(str(folder), "--cache", str(d / "cache"))
    assert r.returncode == 0, r.stderr
    raw_total = packed_total = 0
    for name in NAMES:
        assert not (folder / name).exists(), f"{name} still raw"
        packed = (folder / (name + ".xz")).read_bytes()
        original = (LIBRARIES / name).read_bytes()
        assert lzma.decompress(packed) == original, name
        raw_total += len(original)
        packed_total += len(packed)
    # What a first page loads stays as it was.
    assert (folder / "marked.min.js").read_bytes() == (LIBRARIES / "marked.min.js").read_bytes()
    assert (folder / "shell.html").exists()
    # The PR's measured cut was 4.76 MB; under 3 MB means the libraries or the packing changed.
    assert raw_total - packed_total > 3_000_000, (raw_total, packed_total)


def test_a_second_run_changes_nothing_and_the_cache_is_reused(d: Path) -> None:
    folder = copy_libraries(d)
    cache = d / "cache"
    assert run(str(folder), "--cache", str(cache)).returncode == 0
    first = {p.name: p.read_bytes() for p in folder.iterdir()}
    r = run(str(folder), "--cache", str(cache))
    assert r.returncode == 0 and "packed" not in r.stdout, r.stdout
    assert {p.name: p.read_bytes() for p in folder.iterdir()} == first
    # Xcode copies the folder again on an incremental build: the raw files come back beside the .xz.
    for name in NAMES:
        shutil.copy(LIBRARIES / name, folder / name)
    # A cache entry is never trusted: one that does not unpack to its source is rebuilt.
    kept = sorted(cache.iterdir())
    assert len(kept) == len(NAMES), kept
    marker = lzma.compress(b"cached")
    for p in kept:
        p.write_bytes(marker)
    assert run(str(folder), "--cache", str(cache)).returncode == 0
    for name in NAMES:
        assert not (folder / name).exists()
        assert lzma.decompress((folder / (name + ".xz")).read_bytes()) == (LIBRARIES / name).read_bytes(), name
        assert (folder / (name + ".xz.sha256")).is_file(), name


def test_a_missing_folder_is_not_an_error(d: Path) -> None:
    r = run(str(d / "none"))
    assert r.returncode == 0 and "nothing to pack" in r.stdout, r.stdout


def main() -> int:
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    failed = 0
    for t in tests:
        with tempfile.TemporaryDirectory() as d:
            try:
                t(Path(d))
                print(f"ok {t.__name__}")
            except AssertionError as e:
                failed += 1
                print(f"FAIL {t.__name__}: {e}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
