#!/usr/bin/env python3
"""Judge goldens: fixed films with known judge results; every judge change must reproduce them.

REWRITE R-HARNESS (handoff/rewrites/R-HARNESS/DESIGN.md, rule R8). Judge logic changed with no fixed films to
prove it: the HID clock fix changed 153 films' verdicts (STATUS 8023), the content-wait fix changed drop counts
(8176), and four review rounds each found one more drag-split fault (8212-8240). A golden film is a recording whose
files are frozen (read-only, sha256-pinned) with the judges' results on it. A judge change runs `run`: every result
must be reproduced, or the change says why in the same PR and blesses the new results with that reason.

    judge_goldens.py snapshot --source GALLERY            copy the films of a gallery into the store (read-only)
    judge_goldens.py bless --reason TEXT                  judge every film, record the results (needs committed judges)
    judge_goldens.py run [--judges DIR] [--only GLOB]     judge every film, compare with the recorded results

Common options: --store (default /work/goldens/judge-films), --manifest (default judge-goldens/ beside this file),
--jobs N (worker processes), --judges DIR (the folder that holds video_judge.py and video-cases/; default this
file's folder; an older checkout's folder judges with the older judges).

Store (outside the repo, on the VM disk): films/<folder>/<files> (copied once: reflink where the disk can, so no
extra space; then read-only), tables/<sha256>.json (every folder's files with size and sha256) and
expected/<sha256>.json (each full judge result); both are named by their own hash and checked against it when
read. Manifest (in the repo): films.json (the files table's hash, which pins every byte of every film; each film's
tier and judges), expected.json (the toolchain, how each judge is called, the bless history, and per film and judge
the result's sha256 and a short summary, one line per film, so a bless diff shows each changed film).

A film is every <name>.mov.frames.json or <name>.trace.json in a gallery folder (two levels deep at most). Judges:
  video_judge  video_judge.judge(base, movie=True)                 films with .mov.frames.json
  judge_trace  judge_trace.judge(trace, frames, scale, events)     films with .trace.json; scale = the scale the film
               was recorded at (meta.json start.scale, else display.json asked.scale, else 2)
  judge_keys   judge_keys.judge(base)                              films with .trace.json
  judge_scan   judge_scan.py (its own process: exit code and --json) films with .trace.json and .mov.scan
A judge that raises gives the result {"error": "<type>: <message>"}: a crash is a result, so a fix of it shows.

Results are compared as normalized JSON: the store path written as <root> (no key is dropped), floats rounded to
6 decimals, NaN and infinities named. Exit codes: run: 0 every result reproduced, 1 a difference,
2 NO VERDICT (a store file changed or is missing, a film of the manifest is not in the store, or the toolchain
(python, numpy, the ffmpeg binary) is not the blessed one); bless and snapshot: 0 done, 2 refused.

Run with the VM venv (numpy, imageio_ffmpeg): /work/tmp/bv-venv/bin/python -I scripts/journeys/judge_goldens.py run
Tests: scripts/journeys/test_judge_goldens.py.
"""
from __future__ import annotations

import argparse
import collections
import concurrent.futures
import datetime
import errno
import fcntl
import fnmatch
import hashlib
import importlib
import json
import math
import os
import platform
import re
import selectors
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
DEFAULT_STORE = Path("/work/goldens/judge-films")
DEFAULT_MANIFEST = HERE / "judge-goldens"
# Files a judge reads: the film's JSON, its exact scan lines and its movie. Derived media (.view.mp4, posters, PNG
# stills, logs) are not judged and not copied.
KEEP_SUFFIXES = (".json", ".scan", ".mov")
FOLDER_FILES = ("display", "diag-tiers")  # <name>.json: an input of every film of the folder, never a film's name
FILM_SUFFIXES = (".mov.frames.json", ".trace.json")
JUDGES = ("video_judge", "judge_trace", "judge_keys", "judge_scan")
JUDGE_FILES = ("video_judge.py", "video-cases/judge_trace.py", "video-cases/judge_keys.py", "video-cases/judge_scan.py")
# Modules the workers import (judge_scan has a command line only: it runs as its own process).
MODULES = ("video_judge", "judge_trace", "judge_keys")
CALLS = {
    "video_judge": "video_judge.judge(base, movie=True)",
    "judge_trace": "judge_trace.judge(judge_trace.load_trace(base.trace.json), frames, scale, events)",
    "judge_keys": "judge_keys.judge(base)",
    "judge_scan": "judge_scan.py base.mov.scan --trace base.trace.json --scale scale --json OUT (exit code and OUT)",
}
JUDGE_SCAN_TIMEOUT_S = 300  # as FILM_SECONDS (below): in a run the film's budget ends first; this ends a direct call
FLOAT_DECIMALS = 6
FICLONE = 0x40049409  # Linux ioctl: share the source's blocks (a reflink copy)


# ---------------------------------------------------------------------------------------------------------------
# Normalized results
# ---------------------------------------------------------------------------------------------------------------
def normalize(value, roots):
    """VALUE as plain JSON that does not depend on where the store is: ROOTS written as <root>, floats rounded to
    FLOAT_DECIMALS (-0.0 as 0.0), NaN and infinities as strings, numpy values as Python values. No key is dropped: a
    path a judge reports (video_judge's `base`) is the same <root> path on every machine."""
    if isinstance(value, dict):
        return {str(k): normalize(v, roots) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [normalize(v, roots) for v in value]
    if hasattr(value, "tolist") and not isinstance(value, (str, bytes)):
        return normalize(value.tolist(), roots)  # numpy arrays and scalars
    if isinstance(value, bool) or value is None or isinstance(value, int):
        return value
    if isinstance(value, float):
        if math.isnan(value):
            return "NaN"
        if math.isinf(value):
            return "Infinity" if value > 0 else "-Infinity"
        return round(value, FLOAT_DECIMALS) + 0.0
    if isinstance(value, str):
        for root in roots:
            if root:
                value = value.replace(root, "<root>")
        return value
    if isinstance(value, Path):
        return normalize(str(value), roots)
    if isinstance(value, (set, frozenset)):
        return sorted((normalize(v, roots) for v in value), key=canonical)
    raise TypeError(f"a judge result holds a {type(value).__name__}, which has no stable JSON form")


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False)


def digest(value):
    return hashlib.sha256(canonical(value).encode()).hexdigest()


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 22), b""):
            h.update(block)
    return h.hexdigest()


def summary(judge, result):
    """A short reading of RESULT for a reviewer (expected.json, and the difference lines of `run`); a result of a
    shape this reading does not know gives {"summary_error": ...} (the sha256 of the whole result decides anyway)."""
    try:
        return _summary(judge, result)
    except (AttributeError, TypeError, KeyError, ValueError) as error:
        return {"summary_error": f"{type(error).__name__}: {error}"[:200]}


def _summary(judge, result):
    if not isinstance(result, dict):
        return {"result": str(type(result).__name__)}
    if "error" in result and len(result) == 1:
        return {"error": result["error"]}
    if judge == "video_judge":
        findings = result.get("findings") or []
        by = collections.Counter(f.get("check") for f in findings if f.get("severity") == "defect")
        return {"frames": result.get("frames"), "dropped": result.get("dropped"), "windows": len(result.get("motion") or []),
                "defects": dict(sorted(by.items())), "notes": sum(1 for f in findings if f.get("severity") == "note"),
                "recorder": sum(1 for f in findings if f.get("severity") == "recorder"), "pacing": result.get("pacing")}
    if judge == "judge_trace":
        return {"counts": result.get("counts"), "defects": len(result.get("defects") or []),
                "parts": len(result.get("motions") or []), "split": bool(result.get("split"))}
    if judge == "judge_keys":
        verdicts = collections.Counter(str(i.get("verdict")) for i in result.get("items") or [])
        return {"presses": result.get("presses"), "verdicts": dict(sorted(verdicts.items())),
                "faults": len(result.get("faults") or []), "no_motion": len(result.get("no_motion") or [])}
    if judge == "judge_scan":
        report = result.get("report") or {}
        return {"exit": result.get("exit"), "counts": report.get("counts"), "frames": report.get("frames"),
                **({"said": result["said"]} if result.get("said") else {})}
    return {}


def summary_delta(old, new):
    """The keys of two summaries that differ, as 'key old -> new'."""
    keys = sorted(set(old or {}) | set(new or {}))
    return "; ".join(f"{k} {json.dumps((old or {}).get(k))} -> {json.dumps((new or {}).get(k))}" for k in keys
                     if (old or {}).get(k) != (new or {}).get(k))


def first_paths(old, new, path="", limit=4):
    """Up to LIMIT JSON paths where OLD and NEW differ, with both values cut short."""
    out = []
    if isinstance(old, dict) and isinstance(new, dict):
        for k in sorted(set(old) | set(new)):
            if len(out) >= limit:
                break
            if old.get(k) != new.get(k):
                out += first_paths(old.get(k), new.get(k), f"{path}.{k}", limit - len(out))
    elif isinstance(old, list) and isinstance(new, list) and len(old) == len(new):
        for i, (a, b) in enumerate(zip(old, new)):
            if len(out) >= limit:
                break
            if a != b:
                out += first_paths(a, b, f"{path}[{i}]", limit - len(out))
    else:
        cut = lambda v: (canonical(v)[:120] + "...") if len(canonical(v)) > 120 else canonical(v)
        out.append(f"{path or '.'}: {cut(old)} -> {cut(new)}")
    return out


# ---------------------------------------------------------------------------------------------------------------
# Manifest and store
# ---------------------------------------------------------------------------------------------------------------
def read_json(path, default=None):
    try:
        return json.loads(Path(path).read_text())
    except FileNotFoundError:
        return default


def write_json(path, value):
    """VALUE as sorted JSON; a top-level "films" map gets one line per film (a diff shows one line per changed film)
    and a top-level "history" list one line per bless."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = ["{"]
    keys = sorted(value)
    for i, key in enumerate(keys):
        end = "," if i < len(keys) - 1 else ""
        if key == "history" and isinstance(value[key], list) and value[key]:
            lines.append(f' {json.dumps(key)}: [')
            for j, entry in enumerate(value[key]):
                comma = "," if j < len(value[key]) - 1 else ""
                lines.append(f"  {json.dumps(entry, sort_keys=True)}{comma}")
            lines.append(f" ]{end}")
        elif key == "films" and isinstance(value[key], dict) and value[key]:
            films = sorted(value[key])
            lines.append(f' {json.dumps(key)}: {{')
            for j, film in enumerate(films):
                comma = "," if j < len(films) - 1 else ""
                lines.append(f'  {json.dumps(film)}: {json.dumps(value[key][film], sort_keys=True)}{comma}')
            lines.append(f" }}{end}")
        else:
            body = json.dumps(value[key], indent=1, sort_keys=True).replace("\n", "\n ")
            lines.append(f" {json.dumps(key)}: {body}{end}")
    lines.append("}")
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text("\n".join(lines) + "\n")
    os.replace(tmp, path)


def put_content(folder, value):
    """Writes VALUE as canonical JSON to FOLDER/<its sha256>.json, read-only (content-addressed: never rewritten).
    Returns the sha256. Each write has a part file of its own (pid and clock, as copy_folder): two writes of one result
    at once never share one, and the read-only part file a killed write leaves is never written again (a leftover dot
    file; no reader reads it)."""
    text = canonical(value)
    sha = hashlib.sha256(text.encode()).hexdigest()
    folder = Path(folder)
    folder.mkdir(parents=True, exist_ok=True)
    target = folder / f"{sha}.json"
    if target.exists():
        if hashlib.sha256(target.read_bytes()).hexdigest() != sha:
            raise ValueError(f"{target} does not hash to its name: the store changed (never kept as this result)")
        return sha
    tmp = folder / f".{sha}.{os.getpid()}.{threading.get_ident()}.{time.monotonic_ns()}.part"
    tmp.write_text(text)
    os.chmod(tmp, 0o444)
    os.replace(tmp, target)
    return sha


def get_content(folder, sha):
    """The JSON at FOLDER/<sha>.json, checked against its name (a changed file is refused)."""
    text = (Path(folder) / f"{sha}.json").read_text()
    if hashlib.sha256(text.encode()).hexdigest() != sha:
        raise ValueError(f"{folder}/{sha}.json does not hash to its name")
    return json.loads(text)


def load_expected(store, sha):
    return get_content(Path(store) / "expected", sha)


def files_table(store, films_doc):
    """{folder: {file: [size, sha256]}} of the store, by the root hash films.json pins."""
    sha = films_doc.get("files_table")
    return get_content(Path(store) / "tables", sha)["folders"] if sha else {}


def toolchain():
    """The versions a judge result can depend on besides the judges: python, numpy, and the ffmpeg binary the video
    judge decodes movies with (imageio_ffmpeg's)."""
    out = {"python": platform.python_version(), "numpy": None, "ffmpeg_sha256": None}
    try:
        import numpy
        out["numpy"] = numpy.__version__
    except ImportError:
        pass
    try:
        import imageio_ffmpeg
        out["ffmpeg_sha256"] = sha256_file(imageio_ffmpeg.get_ffmpeg_exe())
    except (ImportError, OSError, RuntimeError):
        pass
    return out


def film_judges(names):
    """The judges that apply to a film whose folder holds the file NAMES."""
    out = []
    if "mov.frames.json" in names:
        out.append("video_judge")
    if "trace.json" in names:
        out += ["judge_trace", "judge_keys"]
    if "trace.json" in names and "mov.scan" in names:
        out.append("judge_scan")
    return out


def find_films(source):
    """{folder (relative to SOURCE): sorted film names}: every folder up to two levels deep with a film file."""
    source = Path(source)
    found = collections.defaultdict(set)
    for pattern in ("*/*", "*/*/*"):
        for path in source.glob(pattern):
            name = path.name
            for suffix in FILM_SUFFIXES:
                if name.endswith(suffix) and path.is_file():
                    found[str(path.parent.relative_to(source))].add(name[: -len(suffix)])
    return {folder: sorted(names) for folder, names in sorted(found.items())}


def copy_reflink(src, dst):
    """Copies SRC to DST sharing its blocks where the file system can (FICLONE), else a plain copy."""
    with open(src, "rb") as fin, open(dst, "wb") as fout:
        try:
            fcntl.ioctl(fout.fileno(), FICLONE, fin.fileno())
            return
        except OSError as error:
            if error.errno not in (errno.EOPNOTSUPP, errno.EXDEV, errno.EINVAL, errno.ENOTTY, errno.EBADF):
                raise
        while True:
            block = fin.read(1 << 22)
            if not block:
                break
            fout.write(block)


def plan_folder(source, folder, recorded, names):
    """(the files to take {name: [size, sha256]}, the stored files to record, problems) of one gallery FOLDER, decided
    before anything is copied. RECORDED is what the store holds in the folder (every manifest's files: this manifest's
    table entry and the store's own files; {} for a new folder), NAMES the films found in it now. A stored file must be
    byte-identical (the store is immutable: a changed film needs a new folder name), and is recorded with no copy. In a
    stored folder a new file is taken only when it belongs to a new film (<new film>.*); a new file of a stored film or
    of the folder (display.json, diag-tiers.json: inputs of every film there) is refused, whatever manifest stored it,
    since it would change what a blessed film is (review 7 of #33930, finding B)."""
    src_dir = Path(source) / folder
    recorded_films = {n for n in names if any(f.startswith(n + ".") for f in recorded)}
    new_films = [n for n in names if n not in recorded_films]
    take, keep, problems = {}, {}, []
    for n in list(new_films):
        # A film's files are <film>.<suffix>: a name with a dot would make another film's inputs its own
        # (col-drag.events.json is col-drag's, not col-drag.events''), and a folder file's name is no film's.
        why = ("a film name with a dot (a film name is the part of its files' names before the first dot)" if "." in n
               else "a film named as a file of the folder (display.json and diag-tiers.json are inputs of every film "
                    "there)" if n in FOLDER_FILES else None)
        if why:
            problems.append(f"{folder}/{n}: {why}")
            new_films.remove(n)
    for path in sorted(src_dir.iterdir()):
        if not path.is_file() or not path.name.endswith(KEEP_SUFFIXES):
            continue
        entry = [path.stat().st_size, sha256_file(path)]
        if path.name in recorded:
            if list(recorded[path.name]) != entry:
                problems.append(f"{folder}/{path.name}: differs from the stored copy; the store is immutable (a changed "
                                "film needs a new folder name)")
            else:
                keep[path.name] = entry
            continue
        if recorded and not any(path.name.startswith(n + ".") for n in new_films):
            film = path.name.split(".", 1)[0]
            stored = sorted(f for f in recorded if f.startswith(film + "."))
            what = (f"a new input of the stored film {film} (stored as {', '.join(stored[:3])}"
                    f"{', ...' if len(stored) > 3 else ''})" if stored else "a new input of the folder's recorded films")
            problems.append(f"{folder}/{path.name}: {what}; the store is immutable (a changed film needs a new folder name)")
            continue
        take[path.name] = entry
    return take, keep, problems


def copy_folder(source, store, folder, take):
    """Copies the files TAKE of FOLDER into the store (reflink, verified, read-only), and leaves films/ and every
    folder under it read-only. Returns problems (a source that changed while it was copied: nothing of it is kept)."""
    films = Path(store) / "films"
    dst_dir = films / folder
    chain = [films] + [films / p for p in reversed(Path(folder).parents) if str(p) != "."] + [dst_dir]
    for d in chain:
        d.mkdir(exist_ok=True)
        os.chmod(d, 0o755)
    problems, done, linked = [], [], []
    try:
        for name, (size, sha) in sorted(take.items()):
            src, tmp = Path(source) / folder / name, dst_dir / f".{name}.{os.getpid()}.{time.monotonic_ns()}.part"
            copy_reflink(src, tmp)
            if sha256_file(tmp) != sha or sha256_file(src) != sha:
                os.remove(tmp)
                problems.append(f"{folder}/{name}: the source changed while it was copied; not taken")
                break
            os.chmod(tmp, 0o444)
            done.append((tmp, dst_dir / name))
        if problems:
            for tmp, _ in done:
                os.remove(tmp)
            return problems
        # A link never replaces a file: another snapshot that wrote the same name meanwhile keeps its file; the same
        # bytes are this folder's file too, other bytes refuse the folder (and remove what this call linked).
        try:
            for (tmp, dst), (name, (size, sha)) in zip(done, sorted(take.items())):
                try:
                    os.link(tmp, dst)
                    linked.append(dst)
                except FileExistsError:
                    if sha256_file(dst) != sha:
                        problems.append(f"{folder}/{name}: another snapshot stored other bytes under this name meanwhile; "
                                        "a stored file is never replaced")
        except BaseException:
            for dst in linked:  # a failure inside the loop keeps no file of this call: nothing of the folder is stored
                os.remove(dst)
            raise
        if problems:
            for dst in linked:
                os.remove(dst)
        return problems
    finally:
        for tmp, _ in done:
            if tmp.exists():
                os.remove(tmp)
        for d in reversed(chain):
            os.chmod(d, 0o555)


def store_pins(store):
    """{folder: {file name: [size, sha256]}} that the files tables in <store>/tables pin: every manifest's snapshot
    writes its table there when it completes, so a file of the store that no table pins is the leftover of a snapshot
    that did not complete (a SIGTERM or SIGKILL inside the link loop runs no clean-up). A table that does not hash to its
    name, or two tables that pin one file with other bytes, refuse (ValueError): the store changed by hand."""
    pins = collections.defaultdict(dict)
    tables = Path(store) / "tables"
    for path in sorted(tables.glob("*.json")) if tables.is_dir() else []:
        for folder, files in (get_content(tables, path.stem).get("folders") or {}).items():
            for name, entry in files.items():
                held = pins[folder].setdefault(name, list(entry))
                if held != list(entry):
                    raise ValueError(f"two files tables pin {folder}/{name} with other bytes ({held} and {list(entry)}): "
                                     "the store changed by hand")
    return pins


def stored_folder(store, folder, recorded, pins):
    """(held, problems): what the store holds in FOLDER, whatever manifest stored it: RECORDED (this manifest's table
    entry) and each other file of the store's folder that a table pins (PINS, store_pins), with the size and sha256 that
    the table pins (one store serves every manifest; the bytes on disk never decide what a new manifest records). A
    pinned file whose bytes on disk differ from its pin changed after it was stored: a problem, and the folder is
    refused. A file no table pins is no stored film's: its film is planned as new, and the copy's link takes the same
    bytes as this folder's file or refuses other bytes."""
    held, problems = dict(recorded or {}), []
    folder_dir = Path(store) / "films" / folder
    pinned = pins.get(folder, {})
    for path in sorted(folder_dir.iterdir()) if folder_dir.is_dir() else []:
        if path.is_file() and not path.name.startswith(".") and path.name not in held and path.name in pinned:
            held[path.name] = list(pinned[path.name])
            if [path.stat().st_size, sha256_file(path)] != held[path.name]:
                problems.append(f"{folder}/{path.name}: the stored file changed after a table pinned it; the store is "
                                "immutable (it was changed by hand)")
    return held, problems


STORE_LOCK = ".snapshot.lock"


def cmd_snapshot(opts):
    """snapshot, under the store's lock (one snapshot at a time: snapshots of two manifests share the store)."""
    store = Path(opts.store)
    store.mkdir(parents=True, exist_ok=True)
    with open(store / STORE_LOCK, "a") as lock:
        deadline = time.monotonic() + opts.lock_seconds
        while True:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    print(f"REFUSED: another snapshot holds the store's lock ({store / STORE_LOCK}) after "
                          f"{opts.lock_seconds:g} s", file=sys.stderr)
                    return 2
                time.sleep(0.2)
        try:
            return _cmd_snapshot(opts)
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)


def _cmd_snapshot(opts):
    store, manifest = Path(opts.store), Path(opts.manifest)
    (store / "films").mkdir(parents=True, exist_ok=True)
    (store / "expected").mkdir(parents=True, exist_ok=True)
    if not (store / "STORE.json").exists():
        write_json(store / "STORE.json", {"what": "R-HARNESS judge goldens (scripts/journeys/judge_goldens.py): read-only "
                                                  "film copies and content-addressed judge results; never edit",
                                          "created": utc_now()})
        os.chmod(store / "STORE.json", 0o444)
    films_doc = read_json(manifest / "films.json", {"v": 1, "films": {}})
    table = files_table(store, films_doc)
    films_doc["store"] = str(store)
    films_doc.setdefault("sources", [])
    if str(opts.source) not in films_doc["sources"]:
        films_doc["sources"].append(str(opts.source))
    found = find_films(opts.source)
    if opts.folder:
        found = {f: n for f, n in found.items() if any(fnmatch.fnmatch(f, g) for g in opts.folder)}
    # A folder a round still publishes into is not a finished film set: take it at the next snapshot.
    fresh = [f for f in found if newest_mtime(Path(opts.source) / f) > utc_seconds() - opts.settled_minutes * 60]
    for f in fresh:
        print(f"later: {f} changed in the last {opts.settled_minutes} min (a round may still publish into it)")
        found.pop(f)
    problems = []
    pins = store_pins(store)  # read once, under the store's lock: no other snapshot writes a table meanwhile
    held = {folder: stored_folder(store, folder, table.get(folder), pins) for folder in found}
    with concurrent.futures.ThreadPoolExecutor(max(1, opts.jobs)) as pool:
        plans = {folder: pool.submit(plan_folder, opts.source, folder, held[folder][0], names)
                 for folder, names in found.items() if not held[folder][1]}
        plans = {folder: job.result() for folder, job in plans.items()}
    plans.update({folder: ({}, {}, held[folder][1]) for folder in found if held[folder][1]})
    for folder, names in found.items():
        take, keep, issues = plans[folder]
        if not issues and take:
            issues = copy_folder(opts.source, store, folder, take)
        problems += issues
        if issues:
            continue  # nothing of a refused folder is kept or recorded
        # A folder may gain new films later (a new round published into it); a recorded file never changes and is never
        # dropped.
        merged = dict(table.get(folder) or {})
        merged.update(keep)
        merged.update(take)
        table[folder] = dict(sorted(merged.items()))
        for name in names:
            kinds = {fname[len(name) + 1:] for fname in merged if fname.startswith(name + ".")}
            judges = film_judges(kinds)
            if judges:
                films_doc["films"].setdefault(f"{folder}/{name}", {"tier": "baseline"})["judges"] = judges
    films_doc["files_table"] = put_content(store / "tables", {"folders": dict(sorted(table.items()))})
    write_json(manifest / "films.json", films_doc)
    for p in problems:
        print(f"REFUSED {p}", file=sys.stderr)
    print(f"snapshot: {len(films_doc['films'])} films in {len(table)} folders in {store} "
          f"(files table {films_doc['files_table'][:12]}); {len(problems)} refused")
    return 2 if problems else 0


# ---------------------------------------------------------------------------------------------------------------
# Judging: one process per film, in a sealed view, with a budget
# ---------------------------------------------------------------------------------------------------------------
# A film is judged in a process of its own (a judge's module state cannot carry from one film to the next, so a result
# does not depend on --jobs or the order), with only its folder's pinned files in view (reflink copies under
# <store>/.scratch: a judge that lists its folder or reads a file beside it sees exactly what the table pins, and cannot
# change the store), with fresh bytecode (-X pycache_prefix), and within a budget. Anything that keeps the run from
# saying what a judge gives on that film is a FAULT, which makes the run NO VERDICT: the film's budget passed, the
# process died or wrote no result, judge_scan timed out or was killed, MemoryError, an OSError of the machine (no file
# descriptors, no memory, no space, an I/O error), or a result that cannot be pinned (a value normalize does not know).
# A judge that raises any other exception gives that error as its result: it is the judge's, and a fix of it shows.
TRANSIENT_ERRNOS = {errno.EMFILE, errno.ENFILE, errno.ENOMEM, errno.EAGAIN, errno.ENOSPC, errno.EIO, errno.EINTR}
# The default budget of one film, all its judges together. Measured 2026-11-03 on cmux-orchestrator-1 (360 cores),
# --jobs 32: the slowest of the 834 gallery films took 50.8 s, judge_scan included. 300 s is about 6 times that, so
# only a hang or a real slow-down of a judge reaches it. Every run and bless prints its slowest film: when that comes
# near this budget, measure again and raise it (with --film-seconds for one run).
FILM_SECONDS = 300
SCRATCH = ".scratch"


class Fault(Exception):
    """The run cannot say what a judge gives (see above): NO VERDICT."""


_MODULES = {}
_JUDGES_DIR = []


def _load_judges(judges_dir):
    """Imports the judges of JUDGES_DIR in this process (a fresh one: nothing of the parent's imports)."""
    for k in ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS"):
        os.environ[k] = "1"
    judges_dir = str(Path(judges_dir).resolve())
    _JUDGES_DIR[:] = [judges_dir]
    sys.path[:0] = [judges_dir, os.path.join(judges_dir, "video-cases")]
    for name, rel in zip(JUDGES, JUDGE_FILES):
        if name not in MODULES:
            continue
        module = importlib.import_module(name)
        where = str(Path(module.__file__).resolve())
        if where != os.path.join(judges_dir, rel):
            raise Fault(f"{name} loaded from {where}, not from {judges_dir}")
        _MODULES[name] = module


def _python(*args, prefix=None):
    """This interpreter, isolated, with bytecode read and written only under PREFIX (default _PYCACHE[0]): a run gives
    its film processes a prefix of its own (judge_all), so no run reads bytecode another run or an older judge wrote
    (a same-size edit in the same second keeps a bytecode cache's key: review 2 of #33930, finding A)."""
    return [sys.executable, "-I", "-X", f"pycache_prefix={prefix or _PYCACHE[0]}", *args]


_PYCACHE = [tempfile.gettempdir()]
_RUN_ROOT = [None]  # a film process's run root (judge_all removes it): judge_scan's scratch goes there
# judge_scan runs as its own process, through this launcher: an error of the machine inside it (MemoryError, an
# OSError of TRANSIENT_ERRNOS) exits HOST_ERROR_EXIT, a Fault, as it is for the judges run in the film process.
HOST_ERROR_EXIT = 97
_SCAN_LAUNCHER = (
    "import runpy, sys\n"
    "TRANSIENT = set(%r)\n"
    "script = sys.argv[1]\n"
    "sys.argv = sys.argv[1:]\n"
    "try:\n"
    "    runpy.run_path(script, run_name='__main__')\n"
    "except MemoryError:\n"
    "    sys.stderr.write('host error: MemoryError\\n')\n"
    "    sys.exit(%d)\n"
    "except OSError as error:\n"
    "    if error.errno not in TRANSIENT:\n"
    "        raise\n"
    "    sys.stderr.write('host error: %%s\\n' %% error)\n"
    "    sys.exit(%d)\n"
)


def _judge_scan(base):
    """judge_scan.py as its own process (it has a command line only): its exit code and the report it wrote."""
    script = os.path.join(_JUDGES_DIR[0], "video-cases", "judge_scan.py")
    launcher = _SCAN_LAUNCHER % (sorted(TRANSIENT_ERRNOS), HOST_ERROR_EXIT, HOST_ERROR_EXIT)
    with tempfile.TemporaryDirectory(prefix="judge-scan-", dir=_RUN_ROOT[0]) as tmp:
        out = os.path.join(tmp, "report.json")
        try:
            done = subprocess.run(_python("-c", launcher, script, f"{base}.mov.scan", "--trace", f"{base}.trace.json",
                                          "--scale", str(_scale_of(base)), "--json", out),
                                  capture_output=True, text=True, timeout=JUDGE_SCAN_TIMEOUT_S, cwd=tmp)
        except subprocess.TimeoutExpired:
            raise Fault(f"judge_scan did not finish in {JUDGE_SCAN_TIMEOUT_S} s")
        if done.returncode < 0:
            raise Fault(f"judge_scan was ended by signal {-done.returncode}")
        said = [line for line in done.stderr.splitlines() if line.startswith("host error:")][-1:]
        if done.returncode == HOST_ERROR_EXIT and said:  # the launcher's own exit; 97 alone is the judge's
            raise Fault(f"judge_scan: {said[0]} (the machine, not the judge)")
        report = read_json(out)
    result = {"exit": done.returncode, "report": report}
    if report is None:
        tail = [line for line in (done.stdout + done.stderr).splitlines() if line.strip()][-1:]
        result["said"] = tail[0][:300] if tail else ""
    return result


def _scale_of(base):
    meta = read_json(f"{base}.meta.json", {}) or {}
    scale = (meta.get("start") or {}).get("scale")
    if not scale:
        display = read_json(Path(base).parent / "display.json", {}) or {}
        scale = (display.get("asked") or {}).get("scale")
    return scale or 2.0


def _call(judge, base):
    if judge == "video_judge":
        return _MODULES["video_judge"].judge(base, movie=True)
    if judge == "judge_trace":
        jt = _MODULES["judge_trace"]
        frames = read_json(f"{base}.mov.frames.json")
        if isinstance(frames, dict):
            frames = frames.get("frames") or []
        events = read_json(f"{base}.events.json")
        return jt.judge(jt.load_trace(f"{base}.trace.json"), frames, _scale_of(base), events)
    if judge == "judge_scan":
        return _judge_scan(base)
    return _MODULES["judge_keys"].judge(base)


def seal_view(store, table, film, root):
    """A folder under ROOT holding films/<the film's folder>/ with that folder's pinned files (reflink copies, so a
    judge can neither see an unpinned file nor change the store). Returns (the view, the film's base path in it)."""
    folder, name = film.rsplit("/", 1)
    view = Path(tempfile.mkdtemp(prefix="view-", dir=root))
    target = view / "films" / folder
    target.mkdir(parents=True)
    for file in table.get(folder) or {}:
        copy_reflink(Path(store) / "films" / folder / file, target / file)
    return view, str(target / name)


def judge_film(store, table, film, judges, root, started=lambda judge: None):
    """Every judge of FILM in a sealed view: {judge: {"sha256", "summary", "result"}}. Raises Fault (see above).
    STARTED(judge) is called as each judge starts (the film's process reports it, so a budget names the judge)."""
    view, base = seal_view(store, table, film, root)
    try:
        roots = [str(view / "films"), str(view)]
        out = {}
        for judge in judges:
            started(judge)
            try:
                result = _call(judge, base)
            except Fault:
                raise
            except MemoryError:
                raise Fault(f"{judge}: MemoryError")
            except OSError as error:
                if error.errno in TRANSIENT_ERRNOS:
                    raise Fault(f"{judge}: {type(error).__name__}: {error}")
                result = {"error": f"{type(error).__name__}: {error}"}
            except SystemExit as error:
                result = {"error": f"SystemExit: {error.code}"}
            except Exception as error:  # a judge that raises gives that as its result (a fix of it then shows)
                result = {"error": f"{type(error).__name__}: {error}"}
            try:
                result = normalize(result, roots)
            except TypeError as error:
                raise Fault(f"{judge}: a result that cannot be pinned: {error}")
            out[judge] = {"sha256": digest(result), "summary": summary(judge, result), "result": result}
        return out
    finally:
        shutil.rmtree(view, ignore_errors=True)


def _film_main(argv):
    """`judge_goldens.py _judge-film STORE TABLE_SHA JUDGES_DIR ROOT FILM JUDGE...`: one film. On stdout, one JSON
    line {"start": judge} as each judge starts, then one JSON object ({"results": ...} or {"fault": ...})."""
    store, table_sha, judges_dir, root, film, judges = argv[0], argv[1], argv[2], argv[3], argv[4], argv[5:]
    _PYCACHE[0], _RUN_ROOT[0] = os.path.join(root, "pycache"), root  # the run's own prefix, as this process has

    def started(judge):
        sys.stdout.write(canonical({"start": judge}) + "\n")
        sys.stdout.flush()
    try:
        _load_judges(judges_dir)
        table = get_content(Path(store) / "tables", table_sha)["folders"]
        payload = {"results": judge_film(store, table, film, judges, root, started)}
    except Fault as fault:
        payload = {"fault": str(fault)}
    except MemoryError:
        payload = {"fault": "MemoryError"}
    except Exception as error:  # the runner's own failure in this film: NO VERDICT, never a result
        payload = {"fault": f"the film's process failed: {type(error).__name__}: {error}"}
    sys.stdout.write(canonical(payload))
    sys.stdout.flush()
    return 0


def verify_file(path, size, sha):
    try:
        if os.path.getsize(path) != size:
            return f"{path}: size {os.path.getsize(path)}, expected {size}"
        if sha256_file(path) != sha:
            return f"{path}: sha256 differs"
    except FileNotFoundError:
        return f"{path}: missing"
    return None


def store_extras(store, films_doc):
    """(folders, files) in the store's films/ that the files table films.json pins does not name: other manifests'
    films (one store serves every manifest: a branch adds films before it lands). No result reads them: the judges see
    only pinned files (sealed views), the ruler and the drag need read only pinned files, and snapshot never adds an input
    to a stored film; run and bless count them in a note."""
    try:
        table = files_table(store, films_doc)
    except (OSError, ValueError):
        return 0, 0
    root = Path(store) / "films"
    known_dirs = {""} | {str(Path(f)) for f in table} | {str(p) for f in table for p in Path(f).parents if str(p) != "."}
    folders = files = 0
    for path in root.rglob("*") if root.is_dir() else []:
        rel = path.relative_to(root)
        if path.name.startswith("."):
            continue  # a part file of a snapshot in progress
        if path.is_dir():
            folders += str(rel) not in known_dirs
        elif str(rel.parent) not in table or path.name not in table[str(rel.parent)]:
            files += 1
    return folders, files


def extras_note(store, films_doc):
    folders, files = store_extras(store, films_doc)
    return (f"; the store also holds {folders} folder(s) and {files} file(s) this manifest does not pin (other "
            "manifests' films; no result reads them)") if folders or files else ""


def verify_store(store, films_doc, films, jobs):
    """Problems with the store against the files table whose hash films.json pins: a pinned file of FILMS' folders
    missing, of another size or content, or a folder of FILMS the table does not record. Files and folders the table
    does not pin are not problems: one store serves every manifest, and the judges run in sealed views that hold only
    the pinned files (review 6 of #33930, finding A); store_extras counts them."""
    try:
        table = files_table(store, films_doc)
    except (OSError, ValueError) as error:
        return [f"the files table: {error}"]
    root = Path(store) / "films"
    problems = []
    folders = sorted({f.rsplit("/", 1)[0] for f in films})
    work = []
    for folder in folders:
        entry = table.get(folder)
        if entry is None:
            problems.append(f"{folder}: not in the files table")
            continue
        for name, (size, sha) in entry.items():
            work.append((root / folder / name, (size, sha)))
    with concurrent.futures.ThreadPoolExecutor(max(1, jobs)) as pool:
        for problem in pool.map(lambda w: verify_file(w[0], *w[1]), work):
            if problem:
                problems.append(problem)
    return problems


class RunnerTimeout(Fault):
    """The judges did not finish within the run's deadline: NO VERDICT, never a difference."""


def code_state(judges_dir):
    """sha256 of every file the film processes load: the judges (JUDGE_FILES) and this runner."""
    out = {}
    for rel in JUDGE_FILES:
        path = Path(judges_dir).resolve() / rel
        out[rel] = sha256_file(path) if path.exists() else None
    out["judge_goldens.py"] = sha256_file(Path(__file__).resolve())
    return out


def judge_all(store, films_doc, films, judges_dir, jobs, deadline_s=None, film_s=FILM_SECONDS):
    """Every judge result of FILMS: {film: {judge: ...}}, and the slowest film's seconds. Each film runs in its own
    process (the module text above); at most JOBS at once. A film past FILM_S seconds, or the whole run past
    DEADLINE_S, ends its process group (this run's own children) and raises Fault; so does a film's fault, and a
    judge or runner file that changed while the films were judged (each film process loads them from disk when it
    starts, so the films would not all have one judge: review 3 of #33930, note 8)."""
    before = code_state(judges_dir)
    results, slowest = _judge_all(store, films_doc, films, judges_dir, jobs, deadline_s, film_s)
    after = code_state(judges_dir)
    moved = sorted(rel for rel in before if before[rel] != after[rel])
    if moved:
        raise Fault(f"{', '.join(moved)} changed during the run: the films were not all judged by one judge")
    return results, slowest


def _judge_all(store, films_doc, films, judges_dir, jobs, deadline_s, film_s):
    root = Path(store) / SCRATCH
    root.mkdir(exist_ok=True)
    run_root = Path(tempfile.mkdtemp(prefix=f"run-{os.getpid()}-", dir=root))
    table_sha = films_doc["files_table"]
    queue = list(films)
    running = {}  # pid -> (Popen, film, started, chunks)
    closed = {}   # pid -> its pidfd (or None) once its output ended: it counts against its budget until it exits
    results, slowest = {}, (0.0, None)
    selector = selectors.DefaultSelector()
    started_run = time.monotonic()
    pycache = str(run_root / "pycache")  # this run's own bytecode (finding A of review 2)

    def end(proc):
        try:
            os.killpg(proc.pid, signal.SIGKILL)  # the film's own process group: our child and its children
        except ProcessLookupError:
            pass
        proc.wait()

    def finish(pid):
        """A film whose output ended and whose process exited: its result, or a Fault."""
        nonlocal slowest
        proc, film, started, chunks = running.pop(pid)
        code = proc.wait()
        slowest = max(slowest, (time.monotonic() - started, film))
        lines = b"".join(chunks).split(b"\n")
        try:
            payload = json.loads(lines[-1] or b"null")
        except ValueError:
            payload = None
        if not isinstance(payload, dict) or code != 0:
            raise Fault(f"{film}: the film's process ended with code {code} and "
                        f"{'no result' if not isinstance(payload, dict) else 'a result'}")
        if "fault" in payload:
            raise Fault(f"{film}: {payload['fault']}")
        results[film] = payload["results"]

    try:
        while queue or running:
            while queue and len(running) < max(1, jobs):
                film = queue.pop(0)
                proc = subprocess.Popen(_python(str(Path(__file__).resolve()), "_judge-film", str(store), table_sha,
                                                str(Path(judges_dir).resolve()), str(run_root), film,
                                                *films_doc["films"][film]["judges"], prefix=pycache),
                                        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, start_new_session=True)
                running[proc.pid] = (proc, film, time.monotonic(), [])
                selector.register(proc.stdout, selectors.EVENT_READ, ("out", proc.pid))
            now_t = time.monotonic()
            budget_left = min(started + film_s for _, _, started, _ in running.values()) - now_t
            if deadline_s is not None:
                budget_left = min(budget_left, started_run + deadline_s - now_t)
            if any(fd is None for fd in closed.values()):  # no pidfd on this system: look again soon
                budget_left = min(budget_left, 0.05)
            for key, _ in selector.select(timeout=max(0.0, budget_left)):
                kind, pid = key.data
                if kind == "out":
                    block = os.read(key.fileobj.fileno(), 1 << 20)
                    if block:
                        running[pid][3].append(block)
                        continue
                    # The output ended; the process has not necessarily (a judge can close its stdout and go on).
                    # It stays in `running`, so its budget still holds; its exit is an event of its own.
                    selector.unregister(key.fileobj)
                    key.fileobj.close()
                    try:
                        fd = os.pidfd_open(pid)
                    except (AttributeError, OSError):
                        fd = None
                    closed[pid] = fd
                    if fd is not None:
                        selector.register(fd, selectors.EVENT_READ, ("exit", pid))
                    continue
                selector.unregister(key.fileobj)
                os.close(closed.pop(pid))
                finish(pid)
            for pid in [p for p, fd in closed.items() if fd is None and running[p][0].poll() is not None]:
                del closed[pid]
                finish(pid)
            now_t = time.monotonic()
            late = [(film, chunks) for proc, film, started, chunks in running.values() if now_t - started >= film_s]
            if late:
                film, chunks = late[0]
                begun = re.findall(rb'\{"start":"([a-z_]+)"\}', b"".join(chunks))
                judge = begun[-1].decode() if begun else "loading the judges"
                raise Fault(f"{film}: {judge} did not finish in the film's budget of {film_s:.0f} s (--film-seconds)")
            if deadline_s is not None and now_t - started_run >= deadline_s:
                raise RunnerTimeout(f"{len(queue) + len(running)} films not judged within {deadline_s:.0f} s: "
                                    + ", ".join(sorted(f for _, f, _, _ in running.values())[:8]))
    finally:
        for proc, _, _, _ in list(running.values()):
            end(proc)
            proc.stdout.close()
        for fd in closed.values():
            if fd is not None:
                os.close(fd)
        selector.close()
        shutil.rmtree(run_root, ignore_errors=True)
    return results, slowest


def select(films_doc, only):
    films = sorted(films_doc.get("films") or {})
    if only:
        films = [f for f in films if any(fnmatch.fnmatch(f, g) for g in only)]
    return films


def newest_mtime(folder):
    return max((p.stat().st_mtime for p in Path(folder).iterdir() if p.is_file()), default=0.0)


def utc_seconds():
    return datetime.datetime.now(datetime.timezone.utc).timestamp()


def utc_now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _git(cwd, *args):
    done = subprocess.run(["git", "-C", str(cwd), *args], capture_output=True, text=True)
    if done.returncode != 0:
        raise RuntimeError(f"git {' '.join(args[:2])} in {cwd}: {done.stderr.strip()[:200]}")
    return done.stdout.strip()


def git_state(judges_dir):
    """The judges' and the runner's checkouts: {"commit", "blobs" (the judge files), "dirty" (judge files with
    uncommitted changes), "runner": {"commit", "blob", "dirty"}}, or None when the judges' folder is no checkout. The
    runner is part of what a golden pins: it makes the judges' inputs (the trace judge's scale, frames and events) and
    normalizes their results."""
    try:
        _git(judges_dir, "rev-parse", "--show-toplevel")
    except (RuntimeError, FileNotFoundError):
        return None
    paths = [str(Path(judges_dir).resolve() / rel) for rel in JUDGE_FILES]
    runner = Path(__file__).resolve()
    state = {"commit": _git(judges_dir, "rev-parse", "HEAD"), "dirty": _git(judges_dir, "status", "--porcelain", "--", *paths),
             "blobs": {rel: _git(judges_dir, "hash-object", path) for rel, path in zip(JUDGE_FILES, paths)}}
    try:
        state["runner"] = {"commit": _git(runner.parent, "rev-parse", "HEAD"), "blob": _git(runner.parent, "hash-object", str(runner)),
                           "dirty": _git(runner.parent, "status", "--porcelain", "--", str(runner))}
    except (RuntimeError, FileNotFoundError):
        state["runner"] = {"commit": None, "blob": hashlib.sha1(b"blob %d\0" % runner.stat().st_size + runner.read_bytes()).hexdigest(),
                           "dirty": f"{runner}: not in a git checkout"}
    return state


def runner_blob():
    runner = Path(__file__).resolve()
    data = runner.read_bytes()
    return hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()


# ---------------------------------------------------------------------------------------------------------------
# TRUTH tier: facts known without the judges
# ---------------------------------------------------------------------------------------------------------------
CLASS_HI, CLASS_LO = 160, 96  # a channel >= HI is on, <= LO is off, between: no class (a glyph, a blend, chrome)
RULER_EDGE_FRAMES = 6         # a ruler fact's first and last frame are exact: it must not hold this far beyond
UNIT_TEST_GLOBS = ("test_video_judge*.py", "video-cases/test_judge_*.py")
UNIT_TEST_TIMEOUT_S = 900


def _scan_layout(path):
    with open(path, "rb") as f:
        head = json.loads(f.readline())
        data = f.read()
    rows, cols = head["rows"], head["columns"]
    record = 8 + len(rows) * head["width"] * 4 + len(cols) * head["height"] * 4
    return head, data, record, len(data) // record


def _scan_line(head, data, record, frame, line, at):
    """The BGRA bytes of scan LINE ("row" or "col") AT (device px) in complete frame FRAME."""
    width, height, rows, cols = head["width"], head["height"], head["rows"], head["columns"]
    if line == "row":
        offset = frame * record + 8 + rows.index(at) * width * 4
        return data[offset:offset + width * 4]
    offset = frame * record + 8 + len(rows) * width * 4 + cols.index(at) * height * 4
    return data[offset:offset + height * 4]


def _color_class(hex_color):
    value = int(str(hex_color).lstrip("#"), 16)
    r, g, b = (value >> 16) & 255, (value >> 8) & 255, value & 255
    return tuple(1 if c >= CLASS_HI else 0 if c <= CLASS_LO else -1 for c in (b, g, r))


def _class_runs(pixels, want):
    """[(first px, last px)] of the runs of pixels whose class is WANT."""
    out, start, n = [], None, len(pixels) // 4
    for x in range(n):
        b, g, r = pixels[4 * x], pixels[4 * x + 1], pixels[4 * x + 2]
        cls = tuple(1 if c >= CLASS_HI else 0 if c <= CLASS_LO else -1 for c in (b, g, r))
        if cls == want:
            start = x if start is None else start
        elif start is not None:
            out.append((start, x - 1))
            start = None
    if start is not None:
        out.append((start, n - 1))
    return out


def _same_frames_as_the_judge(base, data, record, count):
    """The ruler counts scan records; video_judge counts the complete frames of frames.json and matches each record
    to one by its time (within 1 ms). A fact compares the two counts, so they must be one frame each, in order:
    else ValueError (NO VERDICT; review 2 of #33930, note D)."""
    doc = read_json(f"{base}.mov.frames.json", {}) or {}
    complete = sorted(float(e[0]) for e in doc.get("frames") or [] if len(e) > 1 and str(e[1]) == "complete")
    if len(data) != count * record:
        raise ValueError(f"the scan has {len(data) - count * record} bytes after its last whole record")
    if count != len(complete):
        raise ValueError(f"the scan has {count} records and frames.json {len(complete)} complete frames: the ruler's "
                         "frame numbers would not be the judge's")
    for k, t in enumerate(complete):
        (r,) = struct.unpack_from("<d", data, k * record)
        if not abs(r - t) <= 0.001:
            raise ValueError(f"scan record {k} is at {r:.6f} s, complete frame {k} at {t:.6f} s: the ruler's frame "
                             "numbers would not be the judge's (complete frames)")


def ruler_check(base, fact):
    """Whether the film at BASE shows FACT, read from its exact scan lines with no judge code: on scan line
    fact["line"] ("row" or "col") at fact["at"] (device px), a run of fact["class"] (a fixture color: each channel
    on, >= 160, or off, <= 96) of at least fact["min_run_px"] px starts inside fact["x"] in every complete frame of
    fact["frames"] (inclusive), and in none of the RULER_EDGE_FRAMES frames before and after them."""
    head, data, record, count = _scan_layout(f"{base}.mov.scan")
    _same_frames_as_the_judge(base, data, record, count)
    want, (lo, hi), (first, last) = _color_class(fact["class"]), fact["x"], fact["frames"]
    need = int(fact.get("min_run_px", 4))

    def shows(frame):
        runs = _class_runs(_scan_line(head, data, record, frame, fact["line"], fact["at"]), want)
        return any(lo <= a <= hi and b - a + 1 >= need for a, b in runs)

    if not (0 <= first <= last < count):
        return {"holds": False, "missing_in": [], "present_outside": [], "frames": count,
                "error": f"frames {first}..{last} are not in the film's {count} complete frames"}
    missing = [f for f in range(first, last + 1) if not shows(f)]
    outside = [f for f in list(range(max(0, first - RULER_EDGE_FRAMES), first))
               + list(range(last + 1, min(count, last + 1 + RULER_EDGE_FRAMES))) if shows(f)]
    return {"holds": not missing and not outside, "missing_in": missing, "present_outside": outside, "frames": count}


class Unchecked(Exception):
    """A TRUTH expectation the result cannot answer (its list is missing; an absence whose check did not look): NO
    VERDICT, never met."""


def _unmet_need(judge, name, result, film):
    """The first input NAME's check needs (NAMES) that RESULT, with FILM (the film's pinned inputs: "movie", its movie
    is in the store; "hid_drag", its events.json has a HID drag), does not show, as the words of NEEDS; None when all
    show."""
    for need in NAMES[judge][name][1]:
        words, shows = NEEDS[need]
        if not shows(result, film):
            return words
    return None


def _expectation(result, expect, movie=False, hid_drag=False):
    """None when the judge RESULT meets the TRUTH expectation EXPECT, else why not; Unchecked when RESULT cannot
    answer it. A name is read at the severity its judge writes it with (NAMES). An absence fails when the judge
    reports the name; when it does not, it holds only where the name's own check looked (NAMES' needs, as the result
    shows them; reviews 5 and 6 of #33930, finding A and B): else Unchecked. MOVIE: the film's movie is in the store;
    HID_DRAG: the film's pinned events.json has a HID drag."""
    film = {"movie": movie, "hid_drag": hid_drag}
    if not isinstance(result, dict) or result.get("error") and len(result) == 1:
        return f"the judge gave no result: {json.dumps(result)[:200]}"
    judge = expect.get("judge")
    listed = KIND_LIST.get(judge)
    if listed and not isinstance(result.get(listed), list):
        raise Unchecked(f"{judge}'s result has no {listed} list")
    if "defect_frames" in expect:  # every frame of these spans is inside some defect finding of the judge
        spans = [f.get("frames") for f in result.get("findings") or [] if f.get("severity") == "defect"
                 and isinstance(f.get("frames"), list) and len(f["frames"]) == 2]
        missed = [k for lo, hi in expect["defect_frames"] for k in range(lo, hi + 1)
                  if not any(a <= k <= b for a, b in spans)]
        if missed:
            return f"{len(missed)} frames of {expect['defect_frames']} are in no defect finding (first {missed[:6]})"
        return None
    if "check" in expect or "absent_check" in expect:  # video_judge findings, at the name's own severity
        name = expect.get("check", expect.get("absent_check"))
        severity = NAMES["video_judge"][name][0]
        hits = [f for f in result.get("findings") or [] if f.get("check") == name and f.get("severity") == severity]
        if "check" in expect:
            if expect.get("frames") is not None and not any(f.get("frames") == list(expect["frames"]) for f in hits):
                seen = [f.get("frames") for f in hits]
                return f"no {name!r} {severity} over exactly frames {expect['frames']} (it reports {seen or 'none'})"
            return None if hits else f"no {name!r} {severity}"
        if hits:
            return f"must not report {name!r} ({severity}), reports it over frames {[f.get('frames') for f in hits]}"
        unmet = _unmet_need("video_judge", name, result, film)
        if unmet:
            raise Unchecked(f"{unmet}: an absence of {name!r} needs it")
        return None
    if "kind" in expect or "absent_kind" in expect:  # judge_trace defects
        kinds = collections.Counter(d.get("kind") for d in result.get("defects") or [])
        if "kind" in expect:
            want = int(expect.get("count", 1))
            return None if kinds.get(expect["kind"], 0) >= want else \
                f"no {expect['kind']!r} defect ({dict(kinds) or 'none'})"
        name = expect["absent_kind"]
        n = kinds.get(name, 0)
        if n:
            return f"must not report {name!r}, reports {n}"
        unmet = _unmet_need("judge_trace", name, result, film)
        if unmet:
            raise Unchecked(f"{unmet}: an absence of {name!r} needs it")
        return None
    return f"an expectation this runner does not know: {json.dumps(expect)[:200]}"


NO_VERDICT_TRUTH = "a TRUTH fact cannot be checked on the stored film (each line says why)"


def read_truth(manifest, films_doc):
    """(truth.json's document, why its facts cannot be checked): the one read of truth.json per command, so the facts
    checked are the facts validated (review 4 of #33930, note 1). A missing or broken file is a problem."""
    try:
        truth = load_truth(manifest)
    except ValueError as error:
        return None, [str(error)]
    return truth, truth_problems(truth, films_doc)


def load_truth(manifest):
    """truth.json of MANIFEST; ValueError when it is missing or no object (a deleted truth.json is no pass)."""
    doc = read_json(Path(manifest) / "truth.json")
    if not isinstance(doc, dict) or not isinstance(doc.get("facts"), list):
        raise ValueError(f"{Path(manifest) / 'truth.json'} is missing or has no facts list (an empty TRUTH tier is "
                         '{"v": 1, "facts": []})')
    return doc


EXPECT_KINDS = ("check", "defect_frames", "absent_check", "kind", "absent_kind")
EXPECT_KEYS = {"judge", "check", "frames", "defect_frames", "absent_check", "kind", "count", "absent_kind"}
RULER_KEYS = {"line", "at", "class", "x", "frames", "min_run_px"}
FACT_KEYS = {"id", "film", "why", "ruler", "expect"}
# The judge whose result each expectation kind reads (video_judge's findings; judge_trace's defects). An expectation
# on any other judge would read a list that result does not have: it checks nothing (review 3 of #33930, finding A).
KIND_JUDGE = {"check": "video_judge", "defect_frames": "video_judge", "absent_check": "video_judge",
              "kind": "judge_trace", "absent_kind": "judge_trace"}
KIND_LIST = {"video_judge": "findings", "judge_trace": "defects"}
def _panes_at_rest(result):
    """The most panes at rest of any motion judge_trace judged (its gap and overlap checks look only between
    neighbours at rest)."""
    motions = [m.get("motion") for m in result.get("motions") or [] if isinstance(m, dict)] + [result.get("motion")]
    return max((len(m.get("panes_at_rest") or []) for m in motions if isinstance(m, dict)), default=0)


# What a name's check needs to have had for an ABSENCE of the name to mean that it looked (R4), with the words NO
# VERDICT says when the result does not show it. Each is read from the judge's result, except the movie: the film's
# movie pinned in the store (video_judge decodes it for its movie checks).
NEEDS = {
    "frames": ("video_judge judged no frame of this film", lambda r, film: bool(r.get("frames"))),
    "motion": ("video_judge judged no motion window of this film (its checks look only inside motion windows)",
               lambda r, film: bool(r.get("motion"))),
    "trace": ("the film has no trace samples (video_judge's pacing.trace is false)",
              lambda r, film: bool((r.get("pacing") or {}).get("trace"))),
    "tracked": ("video_judge tracked no divider on this film (tracked_dividers is 0): its divider checks did not look",
                lambda r, film: bool(r.get("tracked_dividers"))),
    "model": ("video_judge compared no tracked divider with the trace (model_lag is empty)",
              lambda r, film: bool(r.get("model_lag"))),
    "movie": ("the film has no movie in the store: video_judge's movie checks did not look",
              lambda r, film: film["movie"]),
    "drag": ("the film has no HID drag that video_judge placed (none in its pinned events.json, or the result's hid_clock "
             "has no offset): jump back is a reversal against a drag",
             lambda r, film: film["hid_drag"] and (r.get("hid_clock") or {}).get("offset_s") is not None),
    "input": ("video_judge's result does not show the input this check starts from (it writes no count of inputs)",
              lambda r, film: False),
    "moved": ("video_judge's result does not show a tracked divider that moved (check_steps judges only dividers that "
              "moved more than 2 px; tracked_dividers counts every track)", lambda r, film: False),
    "judged": ("judge_trace judged no motion of this film", lambda r, film: r.get("motion") is not None),
    "travelled": ("judge_trace judged no edge that travelled in a motion of 2 or more frames (it checks reverse, lurch and "
                  "end-jump only on edges whose net travel is over 1 device px, and one step shows none of them)",
                  lambda r, film: any(isinstance(m, dict) and m.get("travel")
                                      and ((m.get("motion") or {}).get("frames") or 0) >= 2 for m in r.get("motions") or [])),
    "neighbours": ("judge_trace judged no motion with 2 or more panes at rest (it checks gap and overlap only between "
                   "neighbours at rest)", lambda r, film: _panes_at_rest(r) >= 2),
}
# Needs that no result shows: an absence of a name with one can never be checked (truth_problems refuses the fact).
NEVER_SHOWN = frozenset({"input", "moved"})
# Every name each judge reports, as its source writes it (a test pins the names and video_judge's severities to the
# source): (the severity its judge writes it with, what its check needs; see NEEDS). video_judge writes each name at
# one severity: 14 are defects, 5 notes, 4 recorder findings. Every video_judge check but the model grid reads complete
# frames (a film with none is judged on its trace only). A judge PR that adds a name or changes one adds it here.
NAMES = {
    "video_judge": {
        # pacing: the refreshes of each motion window; the trace says why a refresh brought no frame
        "dropped frames": ("defect", ("frames", "motion")),
        "idle refresh in motion": ("defect", ("frames", "motion")),
        "capture stall in motion": ("recorder", ("frames", "motion")),
        "content wait": ("note", ("frames", "motion", "trace")),
        "frame gap during slow input": ("note", ("frames", "motion", "input")),
        "main thread missed refreshes before the first frame": ("defect", ("frames", "motion", "trace", "input")),
        # blends: the scanned frames of each motion window against its frames at rest
        "half-pixel blend": ("defect", ("frames", "motion")),
        # dividers: the dividers tracked along the scan lines in each motion window
        "gap or overlap": ("defect", ("frames", "motion", "tracked")),
        "divider not shown": ("defect", ("frames", "motion", "trace", "tracked")),
        "jump": ("defect", ("frames", "motion", "tracked", "moved")),
        "jump back": ("defect", ("frames", "motion", "tracked", "moved", "drag")),
        "jump back (animation)": ("note", ("frames", "motion", "tracked", "moved")),
        # model: the tracked dividers' frames against the trace's dividers
        "shown geometry not in the model": ("defect", ("frames", "motion", "trace", "tracked", "model")),
        # content size: the trace's content sizes in each motion window
        "content not at final size after motion": ("defect", ("frames", "motion", "trace")),
        "content size during motion": ("note", ("frames", "motion", "trace")),
        # movie: the decoded movie of each motion window, with the trace
        "blank pane": ("defect", ("frames", "motion", "trace", "movie")),
        "flash": ("defect", ("frames", "motion", "trace", "movie")),
        "content stretched": ("defect", ("frames", "motion", "trace", "movie")),
        "reflow": ("note", ("frames", "motion", "trace", "movie")),
        # recorder: every complete frame; capture gaps only around motion (at rest a capture may be silent)
        "encoder dropped frames": ("recorder", ("frames",)),
        "scan count mismatch": ("recorder", ("frames",)),
        "capture stall": ("recorder", ("frames", "motion")),
        # the trace alone, every sample, with or without a motion window
        "model edge off the device-pixel grid": ("defect", ("trace",)),
    },
    "judge_trace": {
        **{kind: ("defect", ("judged",)) for kind in ("dropped", "off-grid")},
        **{kind: ("defect", ("judged", "travelled")) for kind in ("end-jump", "lurch", "reverse")},
        **{kind: ("defect", ("judged", "neighbours")) for kind in ("gap", "overlap", "overlap-fading")},
    },
}
JUDGE_NAMES = {judge: frozenset(names) for judge, names in NAMES.items()}


def _span_problem(span):
    ok = (isinstance(span, (list, tuple)) and len(span) == 2 and all(type(v) is int for v in span)
          and span[0] <= span[1])
    return None if ok else f"{json.dumps(span)} is not a span [first, last] with first <= last"


def truth_problems(truth, films_doc):
    """Why a TRUTH fact of TRUTH (load_truth's document: read once per command, so the facts checked are the facts
    validated) cannot be checked (each names the fact): a film not in films.json, no check at all, a ruler or an
    expectation of an unknown form, an empty or reversed span, a name that is no text or that its judge does not
    report. Such a fact is NO VERDICT in run and in bless, never a pass (review 2 of #33930, finding C: run skipped a
    fact of an unknown film; some shapes were met by any result)."""
    problems, seen = [], set()
    films = (films_doc or {}).get("films") or {}
    for fact in truth["facts"]:
        fid = fact.get("id") if isinstance(fact, dict) else None
        if not isinstance(fact, dict) or not fid or not isinstance(fid, str):
            problems.append(f"a fact with no id (a text): {json.dumps(fact)[:120]}")
            continue
        if not isinstance(fact.get("film"), str):
            problems.append(f"{fid}: its film is a folder/name text, not {json.dumps(fact.get('film'))[:80]}")
            continue
        if fid in seen:
            problems.append(f"{fid}: two facts have this id")
        seen.add(fid)
        unknown_keys = set(fact) - FACT_KEYS
        if unknown_keys:
            problems.append(f"{fid}: unknown keys {sorted(unknown_keys)} (a fact has {', '.join(sorted(FACT_KEYS))})")
        if not isinstance(fact.get("why"), str) or not fact["why"].strip():
            problems.append(f"{fid}: no why (the evidence: who proved it, how)")
        if fact.get("film") not in films:
            problems.append(f"{fid}: its film {fact.get('film')!r} is not in films.json")
        film_judges_listed = set((films.get(fact.get("film")) or {}).get("judges") or [])
        ruler, expects = fact.get("ruler"), fact.get("expect") or []
        if "ruler" in fact and (not isinstance(ruler, dict) or not ruler):  # null, {}, [] and "" too: no form
            problems.append(f"{fid}: a ruler is an object of {', '.join(sorted(RULER_KEYS))}, not {json.dumps(ruler)[:80]}")
            continue
        if "expect" in fact and (not isinstance(fact["expect"], list) or not fact["expect"]):  # null, {}, [], "" too
            problems.append(f"{fid}: an expect is a non-empty list of expectations, not {json.dumps(fact['expect'])[:80]}")
            continue
        if not ruler and not expects:
            problems.append(f"{fid}: no ruler fact and no expectation: it checks nothing")
        if ruler:
            unknown = set(ruler) - RULER_KEYS
            missing = {"line", "at", "class", "x", "frames"} - set(ruler)
            if unknown or missing or ruler.get("line") not in ("row", "col"):
                problems.append(f"{fid}: a ruler of an unknown form (unknown {sorted(unknown)}, missing {sorted(missing)})")
            for field in ("x", "frames"):
                why = _span_problem(ruler.get(field))
                if field in ruler and why:
                    problems.append(f"{fid}: ruler {field}: {why}")
            if type(ruler.get("at")) is not int or not isinstance(ruler.get("class"), str) \
                    or ("min_run_px" in ruler and type(ruler["min_run_px"]) is not int):
                problems.append(f"{fid}: a ruler's at and min_run_px are whole numbers and its class a text: "
                                f"{json.dumps(ruler)[:160]}")
        for expect in expects:
            kinds = [k for k in EXPECT_KINDS if k in expect] if isinstance(expect, dict) else []
            unknown = set(expect) - EXPECT_KEYS if isinstance(expect, dict) else {"(not an object)"}
            if unknown or len(kinds) != 1 or not expect.get("judge") or expect.get("judge") not in JUDGES:
                problems.append(f"{fid}: an expectation of an unknown form {json.dumps(expect)[:160]} (one of "
                                f"{', '.join(EXPECT_KINDS)}, a judge of {', '.join(JUDGES)}"
                                + (f"; unknown {sorted(unknown)}" if unknown else "") + ")")
                continue
            if KIND_JUDGE.get(kinds[0]) != expect["judge"]:
                problems.append(f"{fid}: {kinds[0]} reads {KIND_JUDGE.get(kinds[0])}'s result, not "
                                f"{expect['judge']}'s: it would check nothing")
            elif kinds[0] in ("check", "absent_check", "kind", "absent_kind") and not isinstance(expect[kinds[0]], str):
                problems.append(f"{fid}: {kinds[0]} names one {expect['judge']} name as a text, not "
                                f"{json.dumps(expect[kinds[0]])[:80]}")
            elif kinds[0] in ("check", "absent_check", "kind", "absent_kind") \
                    and expect[kinds[0]] not in JUDGE_NAMES.get(expect["judge"], ()):
                problems.append(f"{fid}: {expect['judge']} reports no {expect[kinds[0]]!r} (its names: "
                                f"{', '.join(sorted(JUDGE_NAMES.get(expect['judge'], ())))})")
            elif kinds[0] in ("absent_check", "absent_kind"):
                never = [NEEDS[n][0] for n in NAMES[expect["judge"]][expect[kinds[0]]][1] if n in NEVER_SHOWN]
                if never:
                    problems.append(f"{fid}: an absence of {expect[kinds[0]]!r} can never be checked: {never[0]}")
            if fact.get("film") in films and expect["judge"] not in film_judges_listed:
                problems.append(f"{fid}: {expect['judge']} does not judge {fact.get('film')} "
                                f"(its judges: {', '.join(sorted(film_judges_listed)) or 'none'})")
            if "frames" in expect and (kinds != ["check"] or _span_problem(expect["frames"])):
                problems.append(f"{fid}: frames belongs to a check expectation and is a span: {json.dumps(expect)[:160]}")
            if "count" in expect and (kinds != ["kind"] or type(expect["count"]) is not int or expect["count"] < 1):
                problems.append(f"{fid}: count belongs to a kind expectation and is at least 1: {json.dumps(expect)[:160]}")
            if kinds == ["defect_frames"]:
                spans = expect["defect_frames"]
                if not isinstance(spans, list) or not spans:
                    problems.append(f"{fid}: defect_frames is empty: it checks nothing")
                else:
                    problems += [f"{fid}: defect_frames {why}" for why in map(_span_problem, spans) if why]
    return problems


def _has_hid_drag(path):
    """Whether the events.json at PATH has a HID drag: an entry of kind "drag" with numeric t_sent and t_returned (as
    video_judge's _drag_direction reads them; an entry with no times is never active)."""
    try:
        hid = (read_json(path, {}) or {}).get("hid") or []
    except (OSError, ValueError, AttributeError):
        return False
    return any(isinstance(h, dict) and h.get("kind") == "drag" and all(type(h.get(k)) in (int, float)
                                                                       for k in ("t_sent", "t_returned")) for h in hid)


def _film_hid_drag(store, films_doc, film, table=None):
    """Whether FILM's events.json, read only when the files table pins it, has a HID drag."""
    table = files_table(store, films_doc) if table is None else table
    folder, _, name = str(film).rpartition("/")
    if f"{name}.events.json" not in (table.get(folder) or {}):
        return False
    return _has_hid_drag(Path(store) / "films" / folder / f"{name}.events.json")


def check_truth(store, truth, films_doc, results, films=None):
    """(passed, total, failures, no_verdict) of the facts of TRUTH (load_truth's document) on RESULTS (per film and
    judge, as judge_all gives), for the facts of FILMS (default: every fact). A ruler fact the film does not show, or an
    expectation its result cannot answer, is NO VERDICT (the film, the fact or the judge's coverage is wrong); an
    expectation a judge does not meet is a TRUTH failure."""
    passed = total = 0
    failures, no_verdict = [], []
    table = files_table(store, films_doc)
    for fact in truth["facts"]:
        fid, film = fact.get("id"), fact.get("film")
        if films is not None and film not in films:
            continue
        folder, _, name = str(film).rpartition("/")
        pinned = table.get(folder) or {}
        movie = f"{name}.mov" in pinned
        hid_drag = _film_hid_drag(store, films_doc, film, table)
        base = str(Path(store) / "films" / film)
        if fact.get("ruler"):
            total += 1
            # The ruler reads the store by name, outside a sealed view: only the film's pinned scan and frames.
            unpinned = [f"{name}.{kind}" for kind in ("mov.scan", "mov.frames.json") if f"{name}.{kind}" not in pinned]
            try:
                if unpinned:
                    raise ValueError(f"the ruler reads only pinned files: {', '.join(unpinned)} is not pinned")
                got = ruler_check(base, fact["ruler"])
            except (OSError, ValueError, KeyError, TypeError) as error:
                got = {"holds": False, "error": f"{type(error).__name__}: {error}"}
            if got["holds"]:
                passed += 1
            else:
                no_verdict.append(f"{fid} ({film}): the ruler fact does not hold on the stored film: "
                                  f"{json.dumps({k: v for k, v in got.items() if k != 'holds'})[:300]}")
        for expect in fact.get("expect") or []:
            total += 1
            judge = expect.get("judge")
            if film not in results or judge not in results[film]:
                no_verdict.append(f"{fid} ({film}): {judge} did not judge this film")
                continue
            try:
                why = _expectation(results[film][judge]["result"], expect, movie=movie, hid_drag=hid_drag)
            except Unchecked as error:
                no_verdict.append(f"{fid} ({film}): {judge}: {error}")
                continue
            if why:
                failures.append(f"TRUTH FAIL {fid} ({film}): {judge}: {why}")
            else:
                passed += 1
    return passed, total, failures, no_verdict


def unit_tests(judges_dir, store=None):
    """Runs the judges' unit tests (UNIT_TEST_GLOBS in JUDGES_DIR) in their own process: (ran, failed, skipped, the
    names), or None when the folder has none. The tests get STORE as JUDGE_GOLDENS_STORE (a test that judges a stored
    film reads it from the store this run judges). A skipped test checks nothing: bless and run say NO VERDICT."""
    judges_dir = Path(judges_dir).resolve()
    env = dict(os.environ, **({"JUDGE_GOLDENS_STORE": str(Path(store).resolve())} if store is not None else {}))
    files = sorted({p for g in UNIT_TEST_GLOBS for p in judges_dir.glob(g)})
    if not files:
        return None
    ran = failed = skipped = 0
    for path in files:
        name = str(path.relative_to(judges_dir))
        with tempfile.TemporaryDirectory(prefix="judge-unit-") as pycache:
            try:
                done = subprocess.run([sys.executable, "-I", "-X", f"pycache_prefix={pycache}", str(path)],
                                      capture_output=True, text=True, cwd=str(path.parent), timeout=UNIT_TEST_TIMEOUT_S,
                                      env=env)
            except subprocess.TimeoutExpired:
                raise Fault(f"the judges' unit tests in {name} did not finish in {UNIT_TEST_TIMEOUT_S} s")
        if done.returncode < 0:
            raise Fault(f"the judges' unit tests in {name} were ended by signal {-done.returncode} (the machine, "
                        "not a test)")
        text = done.stdout + done.stderr
        m = re.search(r"^Ran (\d+) tests?", text, re.M)
        if not m:
            tail = [line for line in text.splitlines() if line.strip()][-1:]
            raise Fault(f"the judges' unit tests in {name} reported no count (exit {done.returncode}: "
                        f"{tail[0][:200] if tail else 'no output'})")
        n = int(m.group(1))
        ran += n
        skipped += sum(int(x) for x in re.findall(r"skipped=(\d+)", text))
        if done.returncode != 0:
            bad = re.search(r"FAILED \(([^)]*)\)", text)
            counts = [int(x) for x in re.findall(r"(?:failures|errors)=(\d+)", bad.group(1))] if bad else []
            if not counts:
                raise Fault(f"the judges' unit tests in {name} exited {done.returncode} with no failure count")
            failed += sum(counts)
    return ran, failed, skipped, [str(p.relative_to(judges_dir)) for p in files]


# ---------------------------------------------------------------------------------------------------------------
# bless and run
# ---------------------------------------------------------------------------------------------------------------
def cmd_bless(opts):
    store, manifest = Path(opts.store), Path(opts.manifest)
    films_doc = read_json(manifest / "films.json")
    if not films_doc:
        print(f"REFUSED: no films.json in {manifest} (run snapshot first)", file=sys.stderr)
        return 2
    judges_state = git_state(opts.judges)
    if not opts.no_git_check:
        if judges_state is None:
            print(f"REFUSED: {opts.judges} is not in a git checkout: a bless names the judges' commit", file=sys.stderr)
            return 2
        if judges_state["dirty"]:
            print(f"REFUSED: uncommitted judge files (a bless names the judges' commit):\n{judges_state['dirty']}",
                  file=sys.stderr)
            return 2
        if judges_state["runner"]["dirty"]:
            print("REFUSED: uncommitted runner (a bless names the runner it ran with; the runner makes the judges' "
                  f"inputs and normalizes their results):\n{judges_state['runner']['dirty']}", file=sys.stderr)
            return 2
    films = select(films_doc, None)
    truth, truth_bad = read_truth(manifest, films_doc)
    if truth_bad:
        print("REFUSED (NO VERDICT): truth.json has facts that cannot be checked:\n  " + "\n  ".join(truth_bad[:40]),
              file=sys.stderr)
        return 2
    problems = verify_store(store, films_doc, films, opts.jobs)
    if problems:
        print("REFUSED (NO VERDICT): the store is not the one films.json records:\n  " + "\n  ".join(problems[:40]),
              file=sys.stderr)
        return 2
    try:
        results, slowest = judge_all(store, films_doc, films, opts.judges, opts.jobs, opts.deadline_minutes * 60,
                                     opts.film_seconds)
    except Fault as fault:
        print(f"REFUSED (NO VERDICT): {fault}", file=sys.stderr)
        return 2
    passed, total, failures, no_verdict = check_truth(store, truth, films_doc, results)
    if no_verdict:
        print(f"REFUSED (NO VERDICT): {NO_VERDICT_TRUTH}:\n  " + "\n  ".join(no_verdict), file=sys.stderr)
        return 2
    try:
        unit = unit_tests(opts.judges, store)
    except Fault as fault:
        print(f"REFUSED (NO VERDICT): {fault}", file=sys.stderr)
        return 2
    if unit is not None and unit[2]:
        print(f"REFUSED (NO VERDICT): {unit[2]} of the judges' unit tests were skipped in {', '.join(unit[3])}: a "
              "skipped test checks nothing", file=sys.stderr)
        return 2
    if unit is None or unit[1]:
        failures.append("unit tests: " + ("none in the judges folder" if unit is None else
                                          f"{unit[1]} of {unit[0]} failed in {', '.join(unit[3])}"))
    if failures:
        print("REFUSED: the judges fail the TRUTH tier, which no bless can change:\n  " + "\n  ".join(failures),
              file=sys.stderr)
        return 2
    old = read_json(manifest / "expected.json", {}) or {}
    expected_dir = store / "expected"
    expected_dir.mkdir(parents=True, exist_ok=True)
    changed, entries = [], {}
    for film in films:
        entries[film] = {}
        for judge, got in sorted(results[film].items()):
            if put_content(expected_dir, got["result"]) != got["sha256"]:
                raise RuntimeError(f"{film} {judge}: the stored result does not hash to its digest")
            entries[film][judge] = {"sha256": got["sha256"], "summary": got["summary"]}
        if (old.get("films") or {}).get(film) != entries[film]:
            changed.append(film)
    history = list(old.get("history") or [])
    history.append({"at": utc_now(), "reason": opts.reason, "films": len(films), "changed": changed,
                    "judges": {k: v for k, v in (judges_state or {}).items() if k in ("commit", "blobs", "dirty")},
                    "runner": (judges_state or {}).get("runner") or {"blob": runner_blob()},
                    "slowest_film_s": round(slowest[0], 1),
                    **({"git_check": False} if opts.no_git_check else {})})
    write_json(manifest / "expected.json", {"v": 1, "toolchain": toolchain(), "calls": CALLS, "history": history,
                                            "films": entries})
    print(f"blessed {len(films)} films ({sum(len(v) for v in entries.values())} results); changed {len(changed)}; "
          f"truth: {passed} of {total}; slowest film {slowest[0]:.1f} s ({slowest[1]}): {opts.reason}"
          f"{extras_note(store, films_doc)}")
    return 0


def cmd_run(opts):
    store, manifest = Path(opts.store), Path(opts.manifest)
    films_doc, expected = read_json(manifest / "films.json"), read_json(manifest / "expected.json")
    if not films_doc or not expected:
        print(f"NO VERDICT: no films.json or expected.json in {manifest}", file=sys.stderr)
        return 2
    now, then = toolchain(), expected.get("toolchain") or {}
    if now != then:
        print(f"NO VERDICT: the toolchain is not the blessed one (a different toolchain can change a result by itself): "
              f"blessed {json.dumps(then)}, now {json.dumps(now)}. Bless again with the new toolchain and a reason.",
              file=sys.stderr)
        return 2
    if expected.get("calls") != CALLS:
        print(f"NO VERDICT: the judges were blessed with other calls: {json.dumps(expected.get('calls'))}", file=sys.stderr)
        return 2
    films = select(films_doc, opts.only)
    if not films:
        print(f"NO VERDICT: no film matches {opts.only or 'the manifest'}: a run that judges nothing proves nothing",
              file=sys.stderr)
        return 2
    truth, truth_bad = read_truth(manifest, films_doc)
    if truth_bad:
        print("NO VERDICT: truth.json has facts that cannot be checked:\n  " + "\n  ".join(truth_bad[:40]),
              file=sys.stderr)
        return 2
    missing = [f for f in select({"films": expected.get("films") or {}}, opts.only) if f not in films_doc["films"]]
    problems = verify_store(store, films_doc, films, opts.jobs) + [f"{f}: in expected.json, not in films.json" for f in missing]
    for film in films:
        for judge, entry in sorted(((expected.get("films") or {}).get(film) or {}).items()):
            try:
                load_expected(store, entry["sha256"])
            except (OSError, ValueError, KeyError, TypeError) as error:
                problems.append(f"{film} {judge}: the blessed result {str(entry.get('sha256'))[:12]} cannot be read: {error}")
    if problems:
        print("NO VERDICT: the store is not the one films.json and expected.json record:\n  " + "\n  ".join(problems[:40]),
              file=sys.stderr)
        return 2
    try:
        results, slowest = judge_all(store, films_doc, films, opts.judges, opts.jobs, opts.deadline_minutes * 60,
                                     opts.film_seconds)
    except Fault as fault:
        print(f"NO VERDICT: {fault}", file=sys.stderr)
        return 2
    total = same = 0
    diffs, report = [], {}
    for film in films:
        want = (expected.get("films") or {}).get(film) or {}
        report[film] = {}
        for judge in sorted(set(want) | set(results[film])):
            total += 1
            got, exp = results[film].get(judge), want.get(judge)
            if got and exp and got["sha256"] == exp["sha256"]:
                same += 1
                report[film][judge] = "reproduced"
                continue
            report[film][judge] = "different"
            if not exp:
                diffs.append(f"DIFF {judge} {film}: no blessed result (a new film or judge: bless it)")
                continue
            if not got:
                diffs.append(f"DIFF {judge} {film}: the judge did not run (its input file is gone from films.json)")
                continue
            detail = summary_delta(exp["summary"], got["summary"])
            try:
                paths = first_paths(load_expected(store, exp["sha256"]), got["result"])
            except (OSError, ValueError) as error:
                paths = [f"(the blessed full result cannot be read: {error})"]
            diffs.append(f"DIFF {judge} {film}: {detail or 'same summary'}\n      " + "\n      ".join(paths))
    for line in sorted(diffs):
        print(line)
    t_passed, t_total, t_failures, t_no_verdict = check_truth(store, truth, films_doc, results, set(films))
    for line in t_failures:
        print(line)
    try:
        unit = None if opts.no_unit_tests else unit_tests(opts.judges, store)
    except Fault as fault:
        print(f"NO VERDICT: {fault}", file=sys.stderr)
        return 2
    unit_line, unit_failed = "unit tests: NOT RUN (--no-unit-tests)", False
    if not opts.no_unit_tests:
        if unit is None:
            unit_line, unit_failed = f"TRUTH FAIL unit tests: none in {Path(opts.judges).resolve()}", True
        else:
            ran, failed, skipped, names = unit
            unit_line = (f"unit tests: {ran - failed} of {ran}" + (f" ({skipped} skipped)" if skipped else "")
                         + f" in {', '.join(names)}")
            if failed:
                unit_line, unit_failed = "TRUTH FAIL " + unit_line, True
    blessed_runner = ((expected.get("history") or [{}])[-1].get("runner") or {}).get("blob")
    runner_note = "" if blessed_runner in (None, runner_blob()) else \
        f"; the runner changed since the bless ({str(blessed_runner)[:12]} -> {runner_blob()[:12]}): a difference may be the runner's"
    print(f"judge goldens: {len(films)} films, judges in {Path(opts.judges).resolve()}: reproduced {same} of {total}; "
          f"truth: {t_passed} of {t_total}; {unit_line}; slowest film {slowest[0]:.1f} s ({slowest[1]}){runner_note}"
          f"{extras_note(store, films_doc)}")
    if opts.json:
        write_json(opts.json, {"reproduced": same, "results": total, "films": report, "differences": sorted(diffs),
                               "truth": {"passed": t_passed, "total": t_total, "failures": t_failures,
                                         "no_verdict": t_no_verdict}, "unit_tests": unit_line})
    if t_no_verdict:
        print(f"NO VERDICT: {NO_VERDICT_TRUTH}:\n  " + "\n  ".join(t_no_verdict), file=sys.stderr)
        return 2
    if unit is not None and unit[2]:
        print(f"NO VERDICT: {unit[2]} of the judges' unit tests were skipped in {', '.join(unit[3])}: a skipped test "
              "checks nothing", file=sys.stderr)
        return 2
    return 0 if same == total and not t_failures and not unit_failed else 1


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if argv[:1] == ["_judge-film"]:
        return _film_main(argv[1:])
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("command", choices=("snapshot", "bless", "run"))
    ap.add_argument("--store", default=str(DEFAULT_STORE))
    ap.add_argument("--manifest", default=str(DEFAULT_MANIFEST))
    ap.add_argument("--source", help="snapshot: the gallery folder to copy films from")
    ap.add_argument("--folder", action="append", help="snapshot: only folders matching this glob (repeatable)")
    ap.add_argument("--judges", default=str(HERE), help="the folder with video_judge.py and video-cases/")
    ap.add_argument("--reason", help="bless: why the results change (named in the history)")
    ap.add_argument("--only", action="append", help="run: only films matching this glob (repeatable)")
    ap.add_argument("--jobs", type=int, default=max(1, min(32, (os.cpu_count() or 4) // 4)))
    ap.add_argument("--json", help="run: write the per-film report here")
    ap.add_argument("--no-git-check", action="store_true", help="bless: accept uncommitted judges (tests only)")
    ap.add_argument("--no-unit-tests", action="store_true",
                    help="run: do not run the judges' unit tests (said in the result line; for older judges only)")
    ap.add_argument("--film-seconds", type=float, default=FILM_SECONDS,
                    help=f"bless and run: NO VERDICT when one film's judges have not finished in this long (default {FILM_SECONDS})")
    ap.add_argument("--deadline-minutes", type=float, default=60.0,
                    help="bless and run: NO VERDICT when the judges have not finished in this long (default 60)")
    ap.add_argument("--settled-minutes", type=float, default=10.0,
                    help="snapshot: take a folder only when no file in it changed for this long (default 10)")
    ap.add_argument("--lock-seconds", type=float, default=600.0,
                    help="snapshot: wait this long for another snapshot's lock on the store (default 600)")
    opts = ap.parse_args(argv)
    if opts.command == "snapshot":
        if not opts.source:
            ap.error("snapshot needs --source")
        return cmd_snapshot(opts)
    if opts.command == "bless":
        if not opts.reason:
            ap.error("bless needs --reason")
        return cmd_bless(opts)
    return cmd_run(opts)


def guarded_main(argv=None):
    """main(), with every failure of the runner itself (a worker process that died, a judge module that did not
    load, an interrupt) as NO VERDICT (exit 2): exit 1 means only "a result changed"."""
    try:
        return main(argv)
    except (Exception, KeyboardInterrupt) as error:  # the runner failed: say so, never as a difference
        print(f"NO VERDICT: the runner failed: {type(error).__name__}: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    try:
        os.nice(10)
    except OSError:
        pass
    sys.exit(guarded_main())
