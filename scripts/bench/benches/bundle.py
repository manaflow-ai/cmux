"""bundle: an app bundle's size by component, cmux's and other apps' side by side.

Sources (one run may hold several; each app's rows carry labels app=<name>):
  --arg app=PATH           an .app on disk (stat only: never opens, launches or changes it). On a Mac
                           with --host local-readonly this reads an installed NIGHTLY in place.
  --compare-zip URL        another app's release zip, read from its central directory with HTTP range
                           requests (only the directory bytes are fetched, nothing is written). Repeatable
                           as --compare-zip URL1,URL2. --arg zip_name=NAME names it (default: the file name).
  --host fleet             cmux's DMG for --build (the newest NIGHTLY by default), mounted read-only on a fleet
                           Mac by scripts/measure/bundle-size.sh, which prints the same listing.

Rows: total_uncompressed (MB), download (MB, when known), file_count, and one `component` row per
direct child of Contents/<dir>/ (frameworks, helpers, resources, the main binary) of at least 1 MB.
"""
from __future__ import annotations

import collections
import json
import os
import struct
from pathlib import Path, PurePosixPath

from benchlib.bench import Bench, BenchError, Context
from benchlib.net import open_url

MIN_COMPONENT = 1_000_000


def _range(url: str, start: int, end: int) -> bytes:
    with open_url(url, headers={"Range": f"bytes={start}-{end}"}, timeout=60) as resp:
        if resp.status != 206:
            raise BenchError(f"{url}: the server ignores range requests (HTTP {resp.status})")
        return resp.read()


def zip_listing(url: str) -> tuple[list[tuple[str, int]], int]:
    """[(path, uncompressed bytes)] and the zip's own size, from the central directory alone."""
    with open_url(url, method="HEAD", timeout=60) as head:
        size = int(head.headers["Content-Length"])
        url = head.geturl()  # range reads go to the redirect's target
    tail_len = min(size, 4 * 1024 * 1024)
    tail = _range(url, size - tail_len, size - 1)
    base = size - len(tail)
    i = tail.rfind(b"PK\x05\x06")
    if i < 0:
        raise BenchError(f"{url}: no zip end-of-directory record in the last {tail_len} bytes")
    cd_size, cd_off = struct.unpack("<II", tail[i + 12:i + 20])
    if cd_off == 0xFFFFFFFF or cd_size == 0xFFFFFFFF:  # zip64
        j = tail.rfind(b"PK\x06\x07")
        z64 = struct.unpack("<Q", tail[j + 8:j + 16])[0]
        rec = tail[z64 - base:] if z64 >= base else _range(url, z64, z64 + 56)
        cd_size, cd_off = struct.unpack("<QQ", rec[40:56])
    cd = tail[cd_off - base:cd_off - base + cd_size] if cd_off >= base else _range(url, cd_off, cd_off + cd_size - 1)
    p, files = 0, []
    while p + 46 <= len(cd) and cd[p:p + 4] == b"PK\x01\x02":
        usz = struct.unpack("<I", cd[p + 24:p + 28])[0]
        n, e, c = struct.unpack("<HHH", cd[p + 28:p + 34])
        name = cd[p + 46:p + 46 + n].decode("utf-8", "replace")
        extra = cd[p + 46 + n:p + 46 + n + e]
        q = 0
        while q + 4 <= len(extra):
            hid, hl = struct.unpack("<HH", extra[q:q + 4])
            if hid == 1 and usz == 0xFFFFFFFF:
                usz = struct.unpack("<Q", extra[q + 4:q + 12])[0]
            q += 4 + hl
        if not name.endswith("/") and "__MACOSX/" not in name:
            files.append((name, usz))
        p += 46 + n + e + c
    return files, size


def tree_listing(app: Path) -> list[tuple[str, int]]:
    files = []
    for root, _dirs, names in os.walk(app):
        for name in names:
            path = Path(root) / name
            if path.is_symlink():
                continue
            files.append((f"{app.name}/{path.relative_to(app).as_posix()}", path.stat().st_size))
    return files


def components(files: list[tuple[str, int]]) -> dict[str, int]:
    """Bytes per Contents/<dir>/<child> (or Contents/<file>), with paths taken from the first *.app/."""
    agg: collections.Counter[str] = collections.Counter()
    for name, size in files:
        parts = PurePosixPath(name).parts
        try:
            at = next(i for i, part in enumerate(parts) if part.endswith(".app"))
        except StopIteration:
            agg[parts[0]] += size
            continue
        rel = parts[at + 1:]
        if len(rel) >= 3 and rel[0] == "Contents":
            agg["/".join(rel[:3])] += size
        else:
            agg["/".join(rel[:2]) or parts[at]] += size
    return dict(agg)


class Bundle(Bench):
    name = "bundle"
    summary = "App bundle size by component (frameworks, helpers, resources), vs other apps' release zips"
    units = "MB, count"
    owner = "size (CMUX-570)"
    hosts = ("anywhere", "local-readonly", "fleet")
    harness = "scripts/measure/bundle-size.sh"
    version = "1"
    thresholds = {"total_uncompressed": 3.0, "download": 3.0, "component": 5.0}
    floors = {"total_uncompressed": 0.5, "download": 0.5, "component": 0.5, "file_count": 0}
    nightly = True

    def _rows(self, ctx: Context, app: str, files: list[tuple[str, int]], download: int | None) -> None:
        labels = {"app": app}
        ctx.row("total_uncompressed", sum(s for _, s in files) / 1e6, "MB", labels=labels)
        ctx.row("file_count", len(files), "count", labels=labels)
        if download:
            ctx.row("download", download / 1e6, "MB", labels=labels)
        for comp, size in sorted(components(files).items(), key=lambda kv: -kv[1]):
            if size >= MIN_COMPONENT:
                ctx.row("component", size / 1e6, "MB", labels={**labels, "component": comp})

    def run(self, ctx: Context) -> None:
        did = False
        if ctx.arg("app"):
            app = Path(ctx.arg("app")).expanduser()
            if not app.is_dir():
                raise BenchError(f"--arg app={app}: not an app bundle directory")
            self._rows(ctx, ctx.arg("app_name") or "cmux", tree_listing(app), None)
            did = True
        elif ctx.host_role == "fleet":
            build = ctx.build
            dmg = build.get("url") or ctx.arg("dmg")
            if not dmg:
                raise BenchError("bundle --host fleet: no DMG URL for this build (pass --arg dmg=URL)")
            res = ctx.fleet_step(self.harness, [f"dmg={dmg}"], "artifacts/bundle-size.json",
                                 step_class="exclusive", labels=("measure",), timeout=1800)
            if res.artifact_path:
                self.ingest(ctx, res.artifact_path)
            did = True
        for url in filter(None, (ctx.arg("compare_zip") or "").split(",")):
            files, size = zip_listing(url)
            name = ctx.arg("zip_name") or PurePosixPath(url.split("?")[0]).name.removesuffix(".zip")
            self._rows(ctx, name, files, size)
            did = True
        if not did:
            raise BenchError("bundle: pass --arg app=PATH, --compare-zip URL, or --host fleet")

    def ingest(self, ctx: Context, path: Path) -> None:
        """bundle-size.sh's JSON ({app, download_bytes, files: [[path, bytes], ...]}) or a .app directory."""
        if path.is_dir():
            self._rows(ctx, ctx.arg("app_name") or "cmux", tree_listing(path), None)
            return
        data = json.loads(path.read_text())
        self._rows(ctx, data.get("app", "cmux"), [(f, int(s)) for f, s in data["files"]], data.get("download_bytes"))


BENCH = Bundle()
