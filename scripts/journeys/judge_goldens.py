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
import multiprocessing
import os
import platform
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
DEFAULT_STORE = Path("/work/goldens/judge-films")
DEFAULT_MANIFEST = HERE / "judge-goldens"
# Files a judge reads: the film's JSON, its exact scan lines and its movie. Derived media (.view.mp4, posters, PNG
# stills, logs) are not judged and not copied.
KEEP_SUFFIXES = (".json", ".scan", ".mov")
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
JUDGE_SCAN_TIMEOUT_S = 900
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
    return normalize(repr(value), roots)


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
    """A short reading of RESULT for a reviewer (expected.json, and the difference lines of `run`)."""
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
    Returns the sha256."""
    text = canonical(value)
    sha = hashlib.sha256(text.encode()).hexdigest()
    folder = Path(folder)
    folder.mkdir(parents=True, exist_ok=True)
    target = folder / f"{sha}.json"
    if not target.exists():
        tmp = folder / f".{sha}.part"
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


def snapshot_folder(source, store, folder):
    """Copies FOLDER's judged files into the store, read-only. Returns ({file: [size, sha256]}, [problems]). A store
    file that differs from the source is never replaced (the store is immutable): it is a problem."""
    src_dir, dst_dir = Path(source) / folder, Path(store) / "films" / folder
    files, problems = {}, []
    dst_dir.mkdir(parents=True, exist_ok=True)
    if not os.access(dst_dir, os.W_OK):
        os.chmod(dst_dir, 0o755)
    for path in sorted(src_dir.iterdir()):
        if not path.is_file() or not path.name.endswith(KEEP_SUFFIXES):
            continue
        sha, size = sha256_file(path), path.stat().st_size
        dst = dst_dir / path.name
        if dst.exists():
            kept = sha256_file(dst)
            if kept != sha:
                problems.append(f"{folder}/{path.name}: the store copy differs from the source; the store is immutable "
                                "(a changed film needs a new folder name)")
            files[path.name] = [dst.stat().st_size, kept]
            continue
        tmp = dst_dir / f".{path.name}.part"
        copy_reflink(path, tmp)
        if sha256_file(tmp) != sha or sha256_file(path) != sha:
            os.remove(tmp)
            problems.append(f"{folder}/{path.name}: the source changed while it was copied; not taken")
            continue
        os.chmod(tmp, 0o444)
        os.replace(tmp, dst)
        files[path.name] = [size, sha]
    os.chmod(dst_dir, 0o555)
    return files, problems


def cmd_snapshot(opts):
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
    with concurrent.futures.ThreadPoolExecutor(max(1, opts.jobs)) as pool:
        jobs = {folder: pool.submit(snapshot_folder, opts.source, store, folder) for folder in found}
        for folder, names in found.items():
            files, issues = jobs[folder].result()
            problems += issues
            if issues:
                continue
            # A folder may gain new films later (a new round published into it); a recorded file never changes and
            # is never dropped (snapshot_folder already refused a changed one).
            old = table.get(folder) or {}
            conflicts = [n for n in old if n in files and files[n] != old[n]]
            if conflicts:
                problems.append(f"{folder}: {', '.join(conflicts)} are not the files films.json records; the store is "
                                "immutable")
                continue
            merged = dict(old)
            merged.update(files)
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
# Judging (worker processes)
# ---------------------------------------------------------------------------------------------------------------
_MODULES = {}
_JUDGES_DIR = []


def _init_worker(judges_dir):
    """Loads the judges of JUDGES_DIR in this fresh worker process (spawned: nothing of the parent's imports)."""
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
            raise RuntimeError(f"{name} loaded from {where}, not from {judges_dir}")
        _MODULES[name] = module


def _judge_scan(base):
    """judge_scan.py as its own process (it has a command line only): its exit code and the report it wrote."""
    import tempfile
    script = os.path.join(_JUDGES_DIR[0], "video-cases", "judge_scan.py")
    with tempfile.TemporaryDirectory(prefix="judge-scan-") as tmp:
        out = os.path.join(tmp, "report.json")
        done = subprocess.run([sys.executable, "-I", script, f"{base}.mov.scan", "--trace", f"{base}.trace.json",
                               "--scale", str(_scale_of(base)), "--json", out], capture_output=True, text=True,
                              timeout=JUDGE_SCAN_TIMEOUT_S, cwd=tmp)
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


def judge_film(store, film, judges):
    """Every judge of FILM: {judge: {"sha256", "summary", "result"}}."""
    base = str(Path(store) / "films" / film)
    roots = [str(Path(store) / "films"), str(store)]
    out = {}
    for judge in judges:
        try:
            result = _call(judge, base)
        except SystemExit as error:
            result = {"error": f"SystemExit: {error.code}"}
        except Exception as error:  # a judge that raises gives that as its result (a fix of it then shows)
            result = {"error": f"{type(error).__name__}: {error}"}
        result = normalize(result, roots)
        out[judge] = {"sha256": digest(result), "summary": summary(judge, result), "result": result}
    return film, out


def verify_file(path, size, sha):
    try:
        if os.path.getsize(path) != size:
            return f"{path}: size {os.path.getsize(path)}, expected {size}"
        if sha256_file(path) != sha:
            return f"{path}: sha256 differs"
    except FileNotFoundError:
        return f"{path}: missing"
    return None


def verify_store(store, films_doc, films, jobs):
    """Problems with the store files of FILMS' folders (missing, other size, other content), against the files table
    whose hash films.json pins."""
    try:
        table = files_table(store, films_doc)
    except (OSError, ValueError) as error:
        return [f"the files table: {error}"]
    folders = sorted({f.rsplit("/", 1)[0] for f in films})
    work = []
    for folder in folders:
        entry = table.get(folder)
        if entry is None:
            work.append((None, f"{folder}: not in the files table"))
            continue
        for name, (size, sha) in entry.items():
            work.append((Path(store) / "films" / folder / name, (size, sha)))
    problems = [w[1] for w in work if w[0] is None]
    with concurrent.futures.ThreadPoolExecutor(max(1, jobs)) as pool:
        for problem in pool.map(lambda w: verify_file(w[0], *w[1]), [w for w in work if w[0] is not None]):
            if problem:
                problems.append(problem)
    return problems


class RunnerTimeout(RuntimeError):
    """The judges did not finish within the run's deadline (a judge that hangs): NO VERDICT, never a difference."""


def judge_all(store, films_doc, films, judges_dir, jobs, deadline_s=None):
    """Every judge result of FILMS, judged in spawned workers that import only JUDGES_DIR's judges. A run longer than
    DEADLINE_S raises RunnerTimeout naming the films still running (their workers are ended)."""
    ctx = multiprocessing.get_context("spawn")
    results = {}
    pool = concurrent.futures.ProcessPoolExecutor(max(1, jobs), mp_context=ctx, initializer=_init_worker,
                                                  initargs=(str(judges_dir),))
    try:
        futures = {pool.submit(judge_film, str(store), film, films_doc["films"][film]["judges"]): film for film in films}
        try:
            for future in concurrent.futures.as_completed(futures, timeout=deadline_s):
                film, out = future.result()
                results[film] = out
        except concurrent.futures.TimeoutError:
            left = sorted(film for future, film in futures.items() if not future.done())
            for proc in list(getattr(pool, "_processes", {}).values()):
                proc.terminate()  # our own spawned workers only (this pool's children)
            raise RunnerTimeout(f"{len(left)} films not judged within {deadline_s:.0f} s (a judge that hangs?): "
                                + ", ".join(left[:8]))
    finally:
        pool.shutdown(wait=False, cancel_futures=True)
    return results


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


def git_state(judges_dir):
    """(commit, {judge file: blob}, uncommitted judge files) of the judges' checkout, or None when it is no checkout."""
    git = ["git", "-C", str(judges_dir)]
    try:
        top = subprocess.run(git + ["rev-parse", "--show-toplevel"], capture_output=True, text=True, check=True).stdout.strip()
        commit = subprocess.run(git + ["rev-parse", "HEAD"], capture_output=True, text=True, check=True).stdout.strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None
    paths = [str(Path(judges_dir).resolve() / rel) for rel in JUDGE_FILES]
    dirty = subprocess.run(git + ["status", "--porcelain", "--", *paths], capture_output=True, text=True).stdout.strip()
    blobs = {}
    for rel, path in zip(JUDGE_FILES, paths):
        blobs[rel] = subprocess.run(git + ["hash-object", path], capture_output=True, text=True).stdout.strip()
    return {"commit": commit, "top": top, "blobs": blobs, "dirty": dirty}


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


def ruler_check(base, fact):
    """Whether the film at BASE shows FACT, read from its exact scan lines with no judge code: on scan line
    fact["line"] ("row" or "col") at fact["at"] (device px), a run of fact["class"] (a fixture color: each channel
    on, >= 160, or off, <= 96) of at least fact["min_run_px"] px starts inside fact["x"] in every complete frame of
    fact["frames"] (inclusive), and in none of the RULER_EDGE_FRAMES frames before and after them."""
    head, data, record, count = _scan_layout(f"{base}.mov.scan")
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


def _expectation(result, expect):
    """None when the judge RESULT meets the TRUTH expectation EXPECT, else why not."""
    if not isinstance(result, dict) or result.get("error") and len(result) == 1:
        return f"the judge gave no result: {json.dumps(result)[:200]}"
    if "defect_frames" in expect:  # every frame of these spans is inside some defect finding of the judge
        spans = [f.get("frames") for f in result.get("findings") or [] if f.get("severity") == "defect"
                 and isinstance(f.get("frames"), list) and len(f["frames"]) == 2]
        missed = [k for lo, hi in expect["defect_frames"] for k in range(lo, hi + 1)
                  if not any(a <= k <= b for a, b in spans)]
        if missed:
            return f"{len(missed)} frames of {expect['defect_frames']} are in no defect finding (first {missed[:6]})"
        return None
    if "check" in expect or "absent_check" in expect:  # video_judge findings
        defects = [f for f in result.get("findings") or [] if f.get("severity") == "defect"]
        if "check" in expect:
            hits = [f for f in defects if f.get("check") == expect["check"]]
            if expect.get("frames") is not None and not any(f.get("frames") == list(expect["frames"]) for f in hits):
                seen = [f.get("frames") for f in hits]
                return f"no {expect['check']!r} defect over exactly frames {expect['frames']} (it reports {seen or 'none'})"
            if not hits:
                return f"no {expect['check']!r} defect"
            return None
        hits = [f.get("frames") for f in defects if f.get("check") == expect["absent_check"]]
        return f"must not report {expect['absent_check']!r}, reports it over frames {hits}" if hits else None
    if "kind" in expect or "absent_kind" in expect:  # judge_trace defects
        kinds = collections.Counter(d.get("kind") for d in result.get("defects") or [])
        if "kind" in expect:
            want = int(expect.get("count", 1))
            return None if kinds.get(expect["kind"], 0) >= want else \
                f"no {expect['kind']!r} defect ({dict(kinds) or 'none'})"
        n = kinds.get(expect["absent_kind"], 0)
        return f"must not report {expect['absent_kind']!r}, reports {n}" if n else None
    return f"an expectation this runner does not know: {json.dumps(expect)[:200]}"


def load_truth(manifest):
    return read_json(Path(manifest) / "truth.json", {"v": 1, "facts": []}) or {"v": 1, "facts": []}


def check_truth(store, manifest, results, films=None):
    """(passed, total, failures, no_verdict) of the truth facts on RESULTS (per film and judge, as judge_all gives),
    for the facts of FILMS (default: every fact). A ruler fact the film does not show is NO VERDICT (the film or the
    fact is wrong); an expectation a judge does not meet is a TRUTH failure."""
    passed = total = 0
    failures, no_verdict = [], []
    for fact in load_truth(manifest).get("facts") or []:
        fid, film = fact.get("id"), fact.get("film")
        if films is not None and film not in films:
            continue
        base = str(Path(store) / "films" / film)
        if fact.get("ruler"):
            total += 1
            try:
                got = ruler_check(base, fact["ruler"])
            except (OSError, ValueError, KeyError) as error:
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
                failures.append(f"TRUTH FAIL {fid} ({film}): {judge} did not judge this film")
                continue
            why = _expectation(results[film][judge]["result"], expect)
            if why:
                failures.append(f"TRUTH FAIL {fid} ({film}): {judge}: {why}")
            else:
                passed += 1
    return passed, total, failures, no_verdict


def unit_tests(judges_dir):
    """Runs the judges' unit tests (UNIT_TEST_GLOBS in JUDGES_DIR) in their own process: (ran, failed, skipped, the
    names), or None when the folder has none."""
    judges_dir = Path(judges_dir).resolve()
    files = sorted({p for g in UNIT_TEST_GLOBS for p in judges_dir.glob(g)})
    if not files:
        return None
    ran = failed = skipped = 0
    for path in files:
        done = subprocess.run([sys.executable, "-I", str(path)], capture_output=True, text=True, cwd=str(path.parent),
                              timeout=UNIT_TEST_TIMEOUT_S)
        text = done.stdout + done.stderr
        m = re.search(r"^Ran (\d+) tests?", text, re.M)
        n = int(m.group(1)) if m else 0
        ran += n
        skipped += sum(int(x) for x in re.findall(r"skipped=(\d+)", text))
        if done.returncode != 0 or not m:
            bad = re.search(r"FAILED \(([^)]*)\)", text)
            counts = [int(x) for x in re.findall(r"(?:failures|errors)=(\d+)", bad.group(1))] if bad else []
            failed += sum(counts) or max(1, n)
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
    films = select(films_doc, None)
    problems = verify_store(store, films_doc, films, opts.jobs)
    if problems:
        print("REFUSED (NO VERDICT): the store is not the one films.json records:\n  " + "\n  ".join(problems[:40]),
              file=sys.stderr)
        return 2
    results = judge_all(store, films_doc, films, opts.judges, opts.jobs, opts.deadline_minutes * 60)
    passed, total, failures, no_verdict = check_truth(store, manifest, results)
    if no_verdict:
        print("REFUSED (NO VERDICT): a TRUTH ruler fact does not hold:\n  " + "\n  ".join(no_verdict), file=sys.stderr)
        return 2
    unit = unit_tests(opts.judges)
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
                    **({"git_check": "skipped (--no-git-check)"} if opts.no_git_check else {})})
    write_json(manifest / "expected.json", {"v": 1, "toolchain": toolchain(), "calls": CALLS, "history": history,
                                            "films": entries})
    print(f"blessed {len(films)} films ({sum(len(v) for v in entries.values())} results); changed {len(changed)}; "
          f"truth: {passed} of {total}: {opts.reason}")
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
    missing = [f for f in select({"films": expected.get("films") or {}}, opts.only) if f not in films_doc["films"]]
    problems = verify_store(store, films_doc, films, opts.jobs) + [f"{f}: in expected.json, not in films.json" for f in missing]
    if problems:
        print("NO VERDICT: the store is not the one films.json records:\n  " + "\n  ".join(problems[:40]), file=sys.stderr)
        return 2
    results = judge_all(store, films_doc, films, opts.judges, opts.jobs, opts.deadline_minutes * 60)
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
    t_passed, t_total, t_failures, t_no_verdict = check_truth(store, manifest, results, set(films))
    for line in t_failures:
        print(line)
    unit = None if opts.no_unit_tests else unit_tests(opts.judges)
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
    print(f"judge goldens: {len(films)} films, judges in {Path(opts.judges).resolve()}: reproduced {same} of {total}; "
          f"truth: {t_passed} of {t_total}; {unit_line}")
    if opts.json:
        write_json(opts.json, {"reproduced": same, "results": total, "films": report, "differences": sorted(diffs),
                               "truth": {"passed": t_passed, "total": t_total, "failures": t_failures,
                                         "no_verdict": t_no_verdict}, "unit_tests": unit_line})
    if t_no_verdict:
        print("NO VERDICT: a TRUTH ruler fact does not hold on the stored film:\n  " + "\n  ".join(t_no_verdict),
              file=sys.stderr)
        return 2
    return 0 if same == total and not t_failures and not unit_failed else 1


def main(argv=None):
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
    ap.add_argument("--deadline-minutes", type=float, default=60.0,
                    help="bless and run: NO VERDICT when the judges have not finished in this long (default 60)")
    ap.add_argument("--settled-minutes", type=float, default=10.0,
                    help="snapshot: take a folder only when no file in it changed for this long (default 10)")
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
