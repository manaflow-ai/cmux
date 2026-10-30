#!/usr/bin/env python3
"""Pack and unpack the published cmux-next web bundle archive (cx-ycne).

The archive is a gzip tar of a `build-web-bundles.sh --out-root` tree (the
repository-relative output paths of web-bundle-key.py OUTPUTS). Packing is
deterministic for the same files: sorted names, mtime 0, uid/gid 0, mode 0644
or 0755, gzip without a name or time. Unpacking refuses absolute paths, `..`,
links and devices.

Usage:
  web-bundle-archive.py pack OUT_ROOT ARCHIVE     print the archive's sha256
  web-bundle-archive.py unpack ARCHIVE DEST
"""
import gzip
import hashlib
import io
import os
import sys
import tarfile


def pack(root, archive):
    names = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        for name in filenames:
            if name == ".DS_Store":
                continue
            full = os.path.join(dirpath, name)
            if os.path.islink(full) or not os.path.isfile(full):
                raise SystemExit(f"web-bundle-archive: {full} is not a regular file")
            names.append(os.path.relpath(full, root))
    if not names:
        raise SystemExit(f"web-bundle-archive: {root} holds no files")
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w", format=tarfile.PAX_FORMAT) as tar:
        for rel in sorted(names):
            full = os.path.join(root, rel)
            info = tarfile.TarInfo(rel.replace(os.sep, "/"))
            info.size = os.path.getsize(full)
            info.mtime = 0
            info.mode = 0o755 if os.access(full, os.X_OK) else 0o644
            info.uid = info.gid = 0
            info.uname = info.gname = ""
            with open(full, "rb") as f:
                tar.addfile(info, f)
    with open(archive, "wb") as out:
        with gzip.GzipFile(filename="", mode="wb", fileobj=out, mtime=0, compresslevel=9) as gz:
            gz.write(raw.getvalue())
    h = hashlib.sha256()
    with open(archive, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    print(h.hexdigest())


def unpack(archive, dest):
    os.makedirs(dest, exist_ok=True)
    real = os.path.realpath(dest)
    with tarfile.open(archive, mode="r:gz") as tar:
        members = tar.getmembers()
        for m in members:
            target = os.path.realpath(os.path.join(dest, m.name))
            if os.path.isabs(m.name) or ".." in m.name.split("/") or not (target == real or target.startswith(real + os.sep)):
                raise SystemExit(f"web-bundle-archive: refusing path {m.name!r}")
            if not (m.isfile() or m.isdir()):
                raise SystemExit(f"web-bundle-archive: refusing non-file member {m.name!r}")
        if hasattr(tarfile, "data_filter"):
            tar.extractall(dest, members=members, filter="data")
        else:
            tar.extractall(dest, members=members)


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "pack":
        pack(sys.argv[2], sys.argv[3])
    elif len(sys.argv) == 4 and sys.argv[1] == "unpack":
        unpack(sys.argv[2], sys.argv[3])
    else:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
