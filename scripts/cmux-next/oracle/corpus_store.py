#!/usr/bin/env python3
"""Generated oracle corpora that git does not carry (code-size decision 3, 2026-10-28).

The large generated suites of tests/oracle/corpus are not committed. tests/oracle/corpus-store.json lists them,
each with one of two kinds:

- `generate`: the suite is written at use time by its generator (deterministic, stdlib, under a second).
- `artifact`: the suite is a content-addressed tarball with a pinned sha256 (tests/oracle/corpus-store/<suite>
  .pin.json), stored like the CEF and Computer Use helper pins: key oracle-corpus/<sha256>/<asset> in the private
  R2 bucket, fetched and checked by scripts/cmux-next/ensure-cua-pinned-asset.sh (local cache, controller artifact
  store, then R2 with the read-only CMUX_CEF_R2_* credentials). The pin also has `tree_sha256`, the digest of the
  unpacked files. When no store can serve the tarball, the suite's generator writes it, and the result must have
  the pinned `tree_sha256` (the generators are deterministic: gen_tla.py fixes TLC's version and seeds).

Every reader of the repository corpus calls ensure() first (oracle.load_corpus, select_suites.load_cases,
gen_tla.py, the tests that read a stored suite), so a checkout works as before. Hand-written files of a suite
directory (`keep`, for example tla/README.md) stay in git and are never touched.

Usage:
  corpus_store.py ensure [--suite S ...] [--verify]   write the suites that are missing or stale
  corpus_store.py status                              one line per suite
  corpus_store.py pack SUITE --out FILE               the deterministic tarball of the suite on disk
  corpus_store.py verify-tarball SUITE FILE           FILE unpacks to the pin's tree_sha256 and file count
  corpus_store.py publish SUITE [--dry-run]           pack, upload (publish-cua-pinned-asset.sh) and write the pin;
                                                      run the suite's generator first, then commit the pin

Environment: CMUX_ORACLE_CORPUS_CACHE (default ~/.cache/cmux/oracle-corpus), CMUX_ORACLE_CORPUS_NO_GENERATE=1
(an artifact suite never falls back to its generator), and the variables of ensure-cua-pinned-asset.sh.
Stdlib only, Python 3.9+, safe under `python3 -I`.
"""

from __future__ import annotations

import argparse
import fcntl
import gzip
import hashlib
import io
import json
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Sequence

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
CORPUS = REPO / "tests" / "oracle" / "corpus"
MANIFEST = REPO / "tests" / "oracle" / "corpus-store.json"
ENSURE_ASSET = REPO / "scripts" / "cmux-next" / "ensure-cua-pinned-asset.sh"
PUBLISH_ASSET = REPO / "scripts" / "cmux-next" / "publish-cua-pinned-asset.sh"
STAGING = REPO / "tests" / "oracle" / "corpus-store"  # temporary dirs live here, outside the corpus tools' rglob
STAMP = ".corpus-store.stamp"  # not *.json: the suite tools read every *.json file
LOCK = ".corpus-store.lock"
PREFIX = "oracle-corpus"
_DONE: Dict[str, str] = {}  # suite -> result of this process ("error: ..." for a suite that could not be written)


class StoreError(Exception):
    pass


def manifest() -> Dict[str, dict]:
    return json.loads(MANIFEST.read_text(encoding="utf-8"))["suites"]


def is_repo_corpus(root: Path) -> bool:
    try:
        return Path(root).resolve() == CORPUS.resolve()
    except OSError:
        return False


def managed_files(directory: Path, keep: Iterable[str]) -> List[Path]:
    """The suite's generated files: every file but the hand-written `keep` ones and the stamp."""
    if not directory.is_dir():
        return []
    skip = set(keep) | {STAMP}
    return sorted(p for p in directory.rglob("*") if p.is_file() and p.relative_to(directory).as_posix() not in skip)


def tree_sha256(directory: Path, keep: Iterable[str] = ()) -> str:
    """sha256 of `<relative path>\\0<sha256 of the bytes>\\n` per generated file, sorted by path."""
    digest = hashlib.sha256()
    for path in managed_files(directory, keep):
        rel = path.relative_to(directory).as_posix()
        digest.update(f"{rel}\0{hashlib.sha256(path.read_bytes()).hexdigest()}\n".encode())
    return digest.hexdigest()


def pack(directory: Path, keep: Iterable[str], out: Path) -> None:
    """A tarball that depends on the file bytes only: sorted names, mtime 0, uid 0, mode 0644, gzip without a name."""
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w", format=tarfile.PAX_FORMAT) as tar:
        for path in managed_files(directory, keep):
            data = path.read_bytes()
            info = tarfile.TarInfo(path.relative_to(directory).as_posix())
            info.size, info.mtime, info.mode, info.uid, info.gid, info.uname, info.gname = len(data), 0, 0o644, 0, 0, "", ""
            tar.addfile(info, io.BytesIO(data))
    with open(out, "wb") as f, gzip.GzipFile(filename="", mode="wb", fileobj=f, mtime=0, compresslevel=9) as gz:
        gz.write(raw.getvalue())


def unpack(tarball: Path, dest: Path) -> None:
    with tarfile.open(tarball, "r:gz") as tar:
        for member in tar.getmembers():
            name = Path(member.name)
            if not member.isfile() or name.is_absolute() or ".." in name.parts:
                raise StoreError(f"{tarball.name}: refusing member {member.name!r}")
            target = dest / name
            target.parent.mkdir(parents=True, exist_ok=True)
            source = tar.extractfile(member)
            assert source is not None
            target.write_bytes(source.read())


def run_generator(spec: dict, out: Path) -> None:
    command = [arg.replace("{out}", str(out)) for arg in spec["generator"]]
    result = subprocess.run([sys.executable, "-I", str(REPO / command[0]), *command[1:]], cwd=REPO,
                            capture_output=True, text=True, check=False)
    if result.returncode:
        raise StoreError(f"{' '.join(spec['generator'])} failed ({result.returncode}): {result.stderr.strip()[-2000:]}")


def fetch(spec: dict) -> Optional[Path]:
    """The pinned tarball through ensure-cua-pinned-asset.sh (cache, controller store, R2), or None."""
    pin = REPO / spec["pin"]
    env = {k: v for k, v in os.environ.items() if k != "CMUX_CUA_ASSET_FILE"}  # that local copy is a CUA input
    env.setdefault("CMUX_CUA_ASSET_CACHE_DIR",
                   os.environ.get("CMUX_ORACLE_CORPUS_CACHE") or str(Path.home() / ".cache" / "cmux" / "oracle-corpus"))
    result = subprocess.run(["/bin/bash", str(ENSURE_ASSET), str(pin), "--optional"], cwd=REPO, env=env,
                            capture_output=True, text=True, check=False)
    path = result.stdout.strip().splitlines()[-1] if result.stdout.strip() else ""
    if result.returncode or not path or not Path(path).is_file():
        print(f"corpus_store: {spec['pin']}: {result.stderr.strip()[-400:] or 'no store has it'}", file=sys.stderr)
        return None
    return Path(path)


def install(staged: Path, directory: Path, keep: Iterable[str]) -> None:
    """Replace the suite's generated files with the staged ones; `keep` files stay."""
    for path in managed_files(directory, keep):
        path.unlink()
    for path in sorted(staged.rglob("*")):
        if path.is_file():
            target = directory / path.relative_to(staged)
            target.parent.mkdir(parents=True, exist_ok=True)
            os.replace(path, target)
    for path in sorted(directory.rglob("*"), reverse=True):  # directories the old set had and the new one does not
        if path.is_dir() and not any(path.iterdir()):
            path.rmdir()


def stamp_of(directory: Path) -> dict:
    try:
        return json.loads((directory / STAMP).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def ensure_suite(name: str, spec: dict, verify: bool = False) -> str:
    directory = CORPUS / name
    keep = spec.get("keep", [])
    pin = json.loads((REPO / spec["pin"]).read_text(encoding="utf-8")) if spec["kind"] == "artifact" else {}
    want = pin.get("tree_sha256")
    stamp = stamp_of(directory)
    if spec["kind"] == "artifact" and stamp.get("local") and not verify:
        # gen_tla.py wrote the suite here and it is not published yet: never overwrite it with the old pin.
        print(f"corpus_store: {name}: local files from its generator, not the pin; run corpus_store.py publish {name}",
              file=sys.stderr)
        return "local"
    if (spec["kind"] == "artifact" and not verify and stamp.get("tree_sha256") == want
            and stamp.get("files") == len(managed_files(directory, keep))):
        return "current"  # the stamp names this pin and every file is there (a checkout switch can delete files)
    directory.mkdir(parents=True, exist_ok=True)
    STAGING.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=f".tmp-{name}-", dir=STAGING) as tmp:
        # <tmp>/corpus/<suite>: a generator that writes beside the suite (gen_tla.py's ../../Expectations.d) stays in tmp
        staged = Path(tmp) / "corpus" / name
        staged.mkdir(parents=True)
        how = "generated"
        if spec["kind"] == "artifact":
            if tree_sha256(directory, keep) == want:
                how = "current"
            else:
                tarball = fetch(spec)
                if tarball is not None:
                    unpack(tarball, staged)
                    how = "fetched"
                elif os.environ.get("CMUX_ORACLE_CORPUS_NO_GENERATE") == "1":
                    raise StoreError(f"{name}: no store has {pin.get('sha256')} and CMUX_ORACLE_CORPUS_NO_GENERATE=1")
                else:
                    print(f"corpus_store: {name}: generating it ({' '.join(spec['generator'])})", file=sys.stderr)
                    run_generator(spec, staged)
                got = tree_sha256(staged, keep) if how != "current" else want
                if got != want:
                    raise StoreError(f"{name}: the {how} suite has tree_sha256 {got}, the pin {spec['pin']} has {want}: "
                                     f"regenerate it and run corpus_store.py publish {name}")
        else:
            run_generator(spec, staged)
            if tree_sha256(staged, keep) == tree_sha256(directory, keep):
                how = "current"
        if how != "current":
            (directory / STAMP).unlink(missing_ok=True)
            install(staged, directory, keep)
    if spec["kind"] == "artifact":
        write_stamp(directory, want, pin.get("sha256"), len(managed_files(directory, keep)))
    return how


def mark_local(directory: Path) -> None:
    """A generator wrote this repository suite: ensure keeps it (no overwrite by the old pin) until publish."""
    if MANIFEST.is_file() and is_repo_corpus(directory.parent) and directory.name in manifest():
        (directory / STAMP).write_text(json.dumps({"local": True}) + "\n", encoding="utf-8")


def write_stamp(directory: Path, tree: Optional[str], sha: Optional[str], files: int) -> None:
    (directory / STAMP).write_text(json.dumps({"tree_sha256": tree, "sha256": sha, "files": files}) + "\n",
                                   encoding="utf-8")


def ensure(root: Path = CORPUS, suites: Optional[Sequence[str]] = None, verify: bool = False,
           strict: bool = True) -> Dict[str, str]:
    """Write the stored suites of the repository corpus that are missing or stale (all of them, or `suites`; "all"
    means all). Another root (a test's temporary corpus) is left alone. Once per suite per process; a file lock
    serializes processes. strict raises StoreError for a suite that cannot be written; otherwise its result is
    "error: <why>" and the other suites are still written (a caller reports it as a load error of that suite)."""
    if not is_repo_corpus(root) or not MANIFEST.is_file():
        return {}
    specs = manifest()
    wanted = specs if not suites or "all" in suites else [s for s in suites if s in specs]
    out: Dict[str, str] = {s: _DONE[s] for s in wanted if s in _DONE and not verify}
    names = [s for s in wanted if s not in out]
    if names:
        CORPUS.mkdir(parents=True, exist_ok=True)
        with open(CORPUS / LOCK, "a+") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            for name in names:
                try:
                    out[name] = ensure_suite(name, specs[name], verify)
                except (StoreError, OSError, ValueError, tarfile.TarError) as error:
                    out[name] = f"error: {error}"
                _DONE[name] = out[name]
    failed = {n: r for n, r in out.items() if r.startswith("error: ")}
    if strict and failed:
        raise StoreError("; ".join(r[len("error: "):] for r in failed.values()))
    return out


def load_errors(root: Path, suites: Optional[Sequence[str]] = None) -> List[str]:
    """ensure(strict=False) as corpus load errors, one per suite that could not be written."""
    return [f"{name}: not written ({result[len('error: '):]})"
            for name, result in ensure(root, suites, strict=False).items() if result.startswith("error: ")]


def cmd_publish(name: str, dry_run: bool) -> int:
    spec = manifest()[name]
    if spec["kind"] != "artifact":
        raise StoreError(f"{name} is a `{spec['kind']}` suite; only artifact suites are published")
    directory, keep = CORPUS / name, spec.get("keep", [])
    files = managed_files(directory, keep)
    if not files:
        raise StoreError(f"{name}: no files in {directory}; run {' '.join(spec['generator'])} first")
    with tempfile.TemporaryDirectory() as tmp:
        tarball = Path(tmp) / f"{PREFIX}-{name}.tar.gz"
        pack(directory, keep, tarball)
        tree = tree_sha256(directory, keep)
        command = ["/bin/bash", str(PUBLISH_ASSET), "--file", str(tarball), "--prefix", PREFIX, "--pin", str(REPO / spec["pin"]),
                   "--field", "arch=any", "--field", f"suite={name}", "--field", f"tree_sha256={tree}",
                   "--field", f"files={len(files)}", "--field", f"generator={' '.join(spec['generator'])}"]
        if dry_run:
            command.append("--dry-run")
        code = subprocess.run(command, cwd=REPO, check=False).returncode
    if code == 0 and not dry_run:
        write_stamp(directory, tree, json.loads((REPO / spec["pin"]).read_text(encoding="utf-8"))["sha256"], len(files))
    return code


def verify_tarball(name: str, tarball: Path) -> List[str]:
    """Problems of a fetched tarball against its pin: the unpacked tree_sha256 and file count (check-pinned-assets)."""
    spec = manifest()[name]
    pin = json.loads((REPO / spec["pin"]).read_text(encoding="utf-8"))
    with tempfile.TemporaryDirectory() as tmp:
        unpack(tarball, Path(tmp))
        problems = []
        if tree_sha256(Path(tmp)) != pin.get("tree_sha256"):
            problems.append(f"{name}: tree_sha256 {tree_sha256(Path(tmp))} != pin {pin.get('tree_sha256')}")
        if str(len(managed_files(Path(tmp), ()))) != str(pin.get("files")):
            problems.append(f"{name}: {len(managed_files(Path(tmp), ()))} files != pin {pin.get('files')}")
    return problems


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(prog="corpus_store.py", description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    ens = sub.add_parser("ensure", help="write the suites that are missing or stale")
    ens.add_argument("--suite", action="append")
    ens.add_argument("--verify", action="store_true", help="hash every file, not only the stamp")
    sub.add_parser("status", help="one line per suite")
    pk = sub.add_parser("pack", help="the deterministic tarball of a suite on disk")
    pk.add_argument("suite")
    pk.add_argument("--out", type=Path, required=True)
    vt = sub.add_parser("verify-tarball", help="check a fetched tarball against its pin's tree_sha256 and files")
    vt.add_argument("suite")
    vt.add_argument("tarball", type=Path)
    pub = sub.add_parser("publish", help="pack, upload and write the pin")
    pub.add_argument("suite")
    pub.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)
    try:
        if args.command == "ensure":
            for name, how in ensure(CORPUS, args.suite, args.verify).items():
                print(f"corpus_store: {name}: {how}")
            return 0
        if args.command == "status":
            for name, spec in manifest().items():
                directory = CORPUS / name
                files = managed_files(directory, spec.get("keep", []))
                print(f"{name}: {spec['kind']}, {len(files)} files, tree_sha256 {tree_sha256(directory, spec.get('keep', []))}")
            return 0
        if args.command == "pack":
            spec = manifest()[args.suite]
            pack(CORPUS / args.suite, spec.get("keep", []), args.out)
            print(f"{args.out} sha256 {hashlib.sha256(args.out.read_bytes()).hexdigest()} "
                  f"tree_sha256 {tree_sha256(CORPUS / args.suite, spec.get('keep', []))}")
            return 0
        if args.command == "verify-tarball":
            problems = verify_tarball(args.suite, args.tarball)
            for problem in problems:
                print(f"corpus_store: {problem}", file=sys.stderr)
            return 1 if problems else 0
        return cmd_publish(args.suite, args.dry_run)
    except StoreError as error:
        print(f"corpus_store: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
