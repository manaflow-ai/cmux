#!/usr/bin/env python3
"""File Mac reference PNGs in F1 stores, or recover them for B7/B10 on Linux."""

import argparse
import errno
import hashlib
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
GALLERY_SELECTOR = "[data-gallery-capture], #root"
CROPS = ("ref-topleft", "ref-sidebar", "ref-topbar")


def shotdiff(*args):
    return subprocess.check_output([os.environ.get("CMUX_SHOTDIFF", "cmux-shotdiff"), *args])


def store_path(root, runtime, revision, family, variant, recipe=None):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", runtime):
        raise ValueError("runtime must be a single capture profile name")
    key = json.loads(shotdiff("key", "--repo", ROOT, "--inputs", ROOT / ".github/golden-inputs.json",
                              "--rev", revision, "--family", family, "--variant", variant))
    path = Path(root) / family / runtime / variant / key["key"]
    if recipe is not None:
        canonical = json.dumps(recipe, sort_keys=True, separators=(",", ":")).encode()
        path /= hashlib.sha256(canonical).hexdigest()
    return path


def publish(store, images, rows=None):
    """Expose a complete store with one rename. Concurrent captures keep the first complete one."""
    store.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=store.parent) as tmp:
        staged = Path(tmp) / "store"
        for name, png in images:
            shotdiff("bless", "--store", staged, "--name", name, png)
        if rows is not None:
            (staged / "results.json").write_text(json.dumps(rows))
        try:
            staged.rename(store)
        except OSError as error:
            if error.errno not in (errno.EEXIST, errno.ENOTEMPTY) or not store.is_dir():
                raise
            return False
    return True


def gallery_store(root, runtime, revision, engine, cases, selector):
    return store_path(root, runtime, revision, "desktop-gallery", engine,
                      {"cases": cases, "selector": selector})


def gallery_images(cases, rows, engine):
    if not cases or [r["id"] for r in rows] != [c["id"] for c in cases]:
        raise ValueError("incomplete gallery reference")
    seen = set()
    for i, row in enumerate(rows):
        filename = row.get("screenshot", "")
        if (row.get("error") or row.get("ready") is not True or row.get("engine") != engine
                or Path(filename).name != filename or not filename.endswith(".png") or filename in seen):
            raise ValueError(f"invalid reference for {engine}/{row['id']}")
        seen.add(filename)
        yield f"case-{i}", filename


def file_gallery(store, cases, rows, engine, folder):
    images = [(name, folder / filename) for name, filename in gallery_images(cases, rows, engine)]
    return publish(store, images, rows)


def restore_gallery(store, cases, engine, folder):
    rows = json.loads((store / "results.json").read_text())
    for name, filename in gallery_images(cases, rows, engine):
        shotdiff("get", "--store", store, "--name", name, folder / filename)
    return rows


def validate_crop(name, png):
    with png.open("rb") as source:
        header = source.read(24)
    if len(header) != 24 or header[:8] != b"\x89PNG\r\n\x1a\n" or header[12:16] != b"IHDR":
        raise ValueError(f"{png}: expected a PNG")
    width, height = struct.unpack(">II", header[16:])
    valid = {"ref-topleft": (width, height) == (640, 400),
             "ref-sidebar": width == 380 and height >= 400,
             "ref-topbar": height == 40 and width >= 640}
    if not valid[name]:
        raise ValueError(f"{png}: unexpected 2x crop size {width} x {height}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=["file-chrome", "restore-chrome", "restore-gallery"])
    parser.add_argument("--root", required=True, type=Path, help="shared or unpacked Mac golden store")
    parser.add_argument("--runtime", required=True, help="reference Mac OS build and capture profile")
    parser.add_argument("--rev", required=True, help="Mac source tree used to build the reference app")
    parser.add_argument("--dir", required=True, type=Path, help="flat capture or restore directory")
    parser.add_argument("--manifest", type=Path, help="gallery capture manifest")
    parser.add_argument("--selector", default=GALLERY_SELECTOR, help="gallery capture selector")
    args = parser.parse_args()
    if args.operation == "file-chrome":
        store = store_path(args.root, args.runtime, args.rev, "desktop-chrome", "look-rest-2x")
        images = [(name, args.dir / f"{name}.png") for name in CROPS]
        for name, path in images:
            validate_crop(name, path)
        publish(store, images)
        print(store)
        return

    # A missing engine or corrupt object must not leave a partial reference for the parity tool.
    args.dir.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=args.dir.parent) as temp:
        out = Path(temp) / "render"
        out.mkdir()
        if args.operation == "restore-gallery":
            if not args.manifest:
                parser.error("restore-gallery requires --manifest")
            cases = json.loads(args.manifest.read_text())
            if isinstance(cases, dict):
                cases = cases["cases"]
            rows = []
            for engine in ("chromium", "webkit"):
                store = gallery_store(args.root, args.runtime, args.rev, engine, cases, args.selector)
                rows.extend(restore_gallery(store, cases, engine, out))
            (out / "results.json").write_text(json.dumps(rows))
        else:
            store = store_path(args.root, args.runtime, args.rev, "desktop-chrome", "look-rest-2x")
            for name in CROPS:
                shotdiff("get", "--store", store, "--name", name, out / f"{name}.png")
        out.rename(args.dir)


if __name__ == "__main__":
    main()
