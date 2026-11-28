#!/usr/bin/env python3
"""RFD 0166 step 2: the smaller acpmux update files beside a tree's binaries.

`acpmux machine self-update` (cmux-tui/crates/acpmux/src/cli/host_self_update.rs) reads, before the raw
`tree/<key>/cmux-tui-acpmux-<target>`:
  - `cmux-tui-acpmux-<target>.from-<sha256 of the installed binary>.zst`: `zstd -19 --long=31
    --patch-from=<old> <new>`, old being the build the channel (channels/<channel>.json) names for that
    target before this tree is published, which is what the machines run (A1: about 11% of the binary);
  - `cmux-tui-acpmux-<target>.zst`: `zstd -19 --long=31` of the binary (about 36%).
Both are checked by the client against the channel's sha256, so a bad file costs a request, never an
update. This never fails the publish: every problem is a ::warning and that file is skipped.

With --uploader the files go to cmux-tui/tree/<key>/ write-once (their names are content-addressed, so a
second publication of the tree writes the same objects or finds them there); without it they are only
written into --out-dir. --channel-dir reads <channel>.json and tree/<key>/<name> from a folder (tests).
"""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import urllib.request

FILES = "https://files.cmux.com/cmux-tui"
# The CDN answers urllib's default User-Agent with 403 (acpmux_update_replay.py).
USER_AGENT = "cmux-cas-update-files"
CACHE = "public, max-age=31536000, immutable"
ZSTD = ["zstd", "-q", "-f", "-19", "--long=31", "-T0"]
NAME_PREFIX = "cmux-tui-acpmux-"


def warn(text: str) -> None:
    print(f"::warning title=acpmux update files::{text}", flush=True)


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def read(source: str, rel: str, dest: Path | None = None) -> bytes | None:
    """`rel` under the CDN, or under the --channel-dir folder; into `dest` when given."""
    if not source.startswith("https://"):
        path = Path(source) / rel
        if not path.is_file():
            raise FileNotFoundError(path)
        if dest is None:
            return path.read_bytes()
        shutil.copyfile(path, dest)
        return None
    req = urllib.request.Request(f"{source}/{rel}", headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=300) as r:
        if dest is None:
            return r.read()
        with open(dest, "wb") as f:
            shutil.copyfileobj(r, f, 1 << 20)
    return None


def olds(source: str, channels: list[str], key: str, name: str) -> dict[str, str]:
    """The old builds to patch from, by sha256: their tree keys. Each channel's build of `name`, unless it
    is this tree's."""
    found: dict[str, str] = {}
    for channel in channels:
        try:
            feed = json.loads(read(source, f"channels/{channel}.json"))
            old_key, old_sha = feed["key"], feed["binaries"][name]
        except KeyError:
            continue  # no build of this target in that channel (or another schema)
        except Exception as e:  # noqa: BLE001
            warn(f"channel {channel}: {e}")
            continue
        if old_key != key:
            found.setdefault(old_sha, old_key)
    return found


def make(assets: Path, out: Path, work: Path, source: str, channels: list[str], key: str,
         name: str) -> list[Path]:
    new = assets / name
    new_sha = sha256(new)
    made: list[Path] = []
    # The files are write-once beside tree/<key>/<name>: make them only from the bytes that object is
    # (a run that kept another run's publication of the tree may hold other bytes here).
    try:
        published = read(source, f"tree/{key}/{name}.sha256").decode().split()[0]
    except Exception as e:  # noqa: BLE001
        warn(f"tree/{key}/{name}.sha256: {e}; no update files for it")
        return made
    if published != new_sha:
        warn(f"tree/{key}/{name} is {published}, not this run's {new_sha}; no update files for it")
        return made
    zst = out / f"{name}.zst"
    try:
        subprocess.run([*ZSTD, str(new), "-o", str(zst)], check=True)
        made.append(zst)
    except Exception as e:  # noqa: BLE001
        warn(f"{name}.zst: {e}")
    for old_sha, old_key in olds(source, channels, key, name).items():
        if old_sha == new_sha:
            continue
        old = work / f"{name}.{old_sha}"
        patch = out / f"{name}.from-{old_sha}.zst"
        try:
            read(source, f"tree/{old_key}/{name}", old)
            if sha256(old) != old_sha:
                warn(f"tree/{old_key}/{name} is not the channel's {old_sha}; no patch from it")
                continue
            subprocess.run([*ZSTD, f"--patch-from={old}", str(new), "-o", str(patch)], check=True)
            # A patch no smaller than the whole .zst is never worth the request.
            if zst in made and patch.stat().st_size >= zst.stat().st_size:
                patch.unlink()
                continue
            made.append(patch)
        except Exception as e:  # noqa: BLE001
            warn(f"{patch.name}: {e}")
        finally:
            old.unlink(missing_ok=True)
    return made


def upload(args: argparse.Namespace, key: str, path: Path) -> bool:
    command = [sys.executable, str(args.uploader), "--write-once", "--file", str(path),
               "--endpoint-url", args.endpoint_url, "--bucket", args.bucket,
               "--key", f"cmux-tui/tree/{key}/{path.name}", "--cache-control", CACHE]
    result = subprocess.run(command, text=True, capture_output=True)
    if result.returncode:
        warn(f"uploading {path.name} to tree/{key}: {(result.stderr or result.stdout).strip()[-400:]}")
        return False
    return True


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--assets-dir", type=Path, required=True, help="the tree's binaries")
    p.add_argument("--key", action="append", required=True, help="tree key(s) the binaries are published as")
    p.add_argument("--channel", action="append", default=[], help="channel(s) whose build to patch from")
    p.add_argument("--channel-dir", help="read channels/ and tree/ from this folder, not the CDN")
    p.add_argument("--out-dir", type=Path, help="keep the files here (default: a temporary folder)")
    p.add_argument("--uploader", type=Path)
    p.add_argument("--endpoint-url")
    p.add_argument("--bucket", default="cmux-binaries")
    args = p.parse_args(argv)
    try:
        return run(args)
    except Exception as e:  # noqa: BLE001
        warn(f"stopped: {e}")
        return 0


def run(args: argparse.Namespace) -> int:
    if shutil.which("zstd") is None:
        warn("no zstd on this runner; the tree has only its raw acpmux binaries")
        return 0
    names = sorted(f.name for f in args.assets_dir.glob(f"{NAME_PREFIX}*")
                   if f.is_file() and "." not in f.name)
    if not names:
        print("no acpmux binaries in", args.assets_dir)
        return 0
    source = args.channel_dir or FILES
    channels = args.channel or ["feat-cmux-next"]
    with tempfile.TemporaryDirectory(prefix="acpmux-update-files-") as t:
        out = args.out_dir or Path(t) / "out"
        work = Path(t) / "work"
        out.mkdir(parents=True, exist_ok=True)
        work.mkdir()
        summary = []
        for key in dict.fromkeys(args.key):
            with ThreadPoolExecutor(max_workers=len(names)) as pool:
                made = [f for fs in pool.map(lambda n: make(args.assets_dir, out, work, source, channels, key, n),
                                             names) for f in fs]
            for f in made:
                sent = upload(args, key, f) if args.uploader else None
                summary.append({"key": key, "file": f.name, "bytes": f.stat().st_size,
                                "raw": (args.assets_dir / f.name.split(".")[0]).stat().st_size, "uploaded": sent})
        print(json.dumps({"files": summary}, indent=2))
        if os.environ.get("GITHUB_STEP_SUMMARY"):
            with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as s:
                s.write("### acpmux update files (RFD 0166)\n\n| key | file | MB | of raw |\n|---|---|---|---|\n")
                for r in summary:
                    s.write(f"| {r['key'][:12]} | {r['file']} | {r['bytes'] / 1e6:.1f} | "
                            f"{100 * r['bytes'] / r['raw']:.1f}% |\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
