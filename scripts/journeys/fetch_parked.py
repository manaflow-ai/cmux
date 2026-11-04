#!/usr/bin/env python3
"""Fetches the movies a run.py lease PARKED on its mini, in a whole-host lease of its own.

    fetch_parked.py OUT

run.py (park_movies) moves each typing journey's video/ folder out of the lease root to
$HOME/.cache/cmux-journeys/fetch/<run id>/ on the mini and names it in OUT/parked.json, because about 620 MB of movies
do not fit in the lease time left after a journey. This script takes `capture-host acquire --exclusive` (the whole
mini: nothing else runs there meanwhile) on that host, tars the parked items' judged files (the movies, their meta and frame
times, the trace and events files; not the .mov.scan dumps) to OUT, removes the parked folder only after every item
came whole, and releases the lease. So nothing touches the mini outside a lease (R-HARNESS rule,
2026-11-04). The caller takes the lease's turn on the mini through the mini scheduler (a GO), and sets
CAPTURE_HOST_HOSTS / CAPTURE_HOST_POOL / CMUX_AGENT_ID as for run.py.

Writes OUT/fetched.json {at, host, path, items, bytes, ok, error?}. Exit 0: every item fetched and the folder removed;
1: the lease was taken but the fetch failed (the folder is kept); 75: no lease or nothing to fetch.
"""
import argparse
import io
import json
import re
import subprocess
import sys
import tarfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.argv, _argv = sys.argv[:1], sys.argv  # run.py reads its own argv at import
import run  # noqa: E402

sys.argv = _argv

LEASE_SECONDS = 540     # capture-host's hard maximum is 600 s from acquire
# The parked files fetched: what typing/ledger.py's video judge reads (the movie, its meta and its frame times) and the
# small trace and events files. Not the .mov.scan scanline dumps (nothing in the typing pipeline reads them).
JUDGED_SUFFIXES = (".mov", ".meta.json", ".mov.frames.json", ".trace.json", ".events.json")
RELEASE_MARGIN = 45     # s kept for the rm and the release
PATH_RE = re.compile(r"/[A-Za-z0-9_./-]*/\.cache/cmux-journeys/fetch/[A-Za-z0-9_-]+")
ITEM_RE = re.compile(r"[a-z0-9][a-z0-9-]*/video")


def whole_tar(data):
    """The member names of tar stream DATA, only when it came whole: every regular member's data reads to its full
    size and the end-of-archive blocks follow the last member. A cut stream raises tarfile.TarError."""
    end, names = 0, []
    with tarfile.open(fileobj=io.BytesIO(data)) as tar:
        for member in tar.getmembers():
            names.append(member.name)
            if member.isreg():
                got = tar.extractfile(member)
                if got is None or len(got.read()) != member.size:
                    raise tarfile.TarError(f"{member.name}: its data was cut")
            end = max(end, member.offset_data + (member.size + 511) // 512 * 512)
    if not names or len(data) < end + 1024:
        raise tarfile.TarError("no end-of-archive blocks: the stream was cut")
    return names


def fetch(out, ch=None, now=time.monotonic):
    out = Path(out)
    rec = {"at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "ok": False}
    try:
        parked = json.loads((out / "parked.json").read_text())
    except (OSError, ValueError) as error:
        rec["error"] = f"no parked.json: {error}"
        (out / "fetched.json").write_text(json.dumps(rec))
        return 75
    host, path, items = parked.get("host"), parked.get("path"), parked.get("items") or []
    rec.update(host=host, path=path, items=items)
    # Only what park_movies writes: an absolute folder under .cache/cmux-journeys/fetch, items <journey>/video.
    if not (isinstance(host, str) and re.fullmatch(r"[A-Za-z0-9_-]+", host) and isinstance(path, str)
            and PATH_RE.fullmatch(path) and items and all(isinstance(i, str) and ITEM_RE.fullmatch(i) for i in items)):
        rec["error"] = f"parked.json names no plain host, folder and items: {json.dumps(parked)[:300]}"
        (out / "fetched.json").write_text(json.dumps(rec))
        return 75
    ch = ch or run.capture_host()
    try:
        words = run.acquire_lease(ch, True, out / "fetch-acquire.log", whole_host=True)
    except (RuntimeError, subprocess.TimeoutExpired) as error:
        rec["error"] = f"no lease: {str(error)[-300:]}"
        (out / "fetched.json").write_text(json.dumps(rec))
        return 75
    if not words:
        rec["error"] = "capture-host acquire printed no lease"
        (out / "fetched.json").write_text(json.dumps(rec))
        return 75
    lease, deadline = words[-1], now() + LEASE_SECONDS
    left = lambda cap: max(10.0, min(cap, deadline - now() - RELEASE_MARGIN))
    run.log(f"fetch lease {lease}")
    code = 1
    try:
        info = dict(kv.split("=", 1) for kv in run.run([ch, "slot-info", lease]).stdout.decode().split() if "=" in kv)
        if info.get("host") != host:
            raise RuntimeError(f"the lease is on {info.get('host')}, the movies are parked on {host}")
        rec["lease"] = lease
        # Only the files the video judge reads (typing/ledger.py: <part>.mov, .meta.json, .mov.frames.json), then the
        # small ones. The raw scanline dumps (.mov.scan, about 430 MB of the 620 MB) are read by nothing in the typing
        # pipeline; they stay on the mini (s1ab-s17a-1-off: the whole folder did not come in 495 s from cmux21).
        globs = " ".join(f"{i}/*{suffix}" for i in items for suffix in JUDGED_SUFFIXES)
        tarred = run.remote(host, f"cd {run.q(path)} && setopt null_glob 2>/dev/null || shopt -s nullglob; "
                                  f"set -- {globs}; [ $# -gt 0 ] && tar c \"$@\"", timeout=left(LEASE_SECONDS), check=False)
        if tarred.returncode != 0:
            raise RuntimeError(f"tar exited {tarred.returncode}: {tarred.stderr.decode(errors='replace').strip()[-300:]}")
        data = tarred.stdout or b""
        names = whole_tar(data)
        got = sorted({n.split("/video", 1)[0] + "/video" for n in names if "/video/" in n})
        if got != sorted(items):
            raise RuntimeError(f"the tar holds {got}, not {sorted(items)}")
        movies = [n for n in names if n.endswith(".mov")]
        if not movies:
            raise RuntimeError(f"the tar holds no movie: {names[:6]}")
        run.take_videos(data, out, {i.split("/", 1)[0] for i in items})
        rec["bytes"], rec["files"] = len(data), names
        run.remote(host, f"rm -rf {run.q(path)}", timeout=left(60), check=False)
        rec["ok"], code = True, 0
        run.log(f"parked movies: {len(data)} bytes ({len(movies)} movies and their judge files) fetched in lease {lease}; "
                f"{path} removed on {host} (the .mov.scan dumps with it)")
    except (RuntimeError, subprocess.TimeoutExpired, OSError, EOFError, tarfile.TarError, KeyError, ValueError) as error:
        rec["error"] = str(error)[-400:]
        run.log(f"parked movies not fetched (kept on {host} at {path}): {rec['error']}")
    finally:
        released = subprocess.run([ch, "release", lease], capture_output=True, timeout=120)
        rec["released"] = released.returncode == 0
        run.log(f"released {lease}" if released.returncode == 0 else
                f"release of {lease} exited {released.returncode} (it expires within 10 minutes)")
        (out / "fetched.json").write_text(json.dumps(rec))
    return code


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("out", help="the run's OUT folder (it holds parked.json)")
    return fetch(ap.parse_args().out)


if __name__ == "__main__":
    sys.exit(main())
