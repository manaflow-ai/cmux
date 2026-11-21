#!/usr/bin/env python3
"""A content-addressed cache of SwiftPM package builds, shared across the Mac minis.

    spm_action_cache.py key CHECKOUT PACKAGE [--root ROOT] [--arg A]...
    spm_action_cache.py stage CHECKOUT PACKAGE ROOT
    spm_action_cache.py pack ROOT PACKAGE KEY OUT
    spm_action_cache.py restore ROOT PACKAGE KEY ARCHIVE
    spm_action_cache.py get|put ROOT PACKAGE KEY STORE
    spm_action_cache.py bench CHECKOUT PACKAGE ROOT [--archive FILE] [--pack OUT] [--report FILE] [--arg A]...

The Mac half of the fleet's content-keyed build cache. The Linux pool keeps build outputs in
gs://cmux-linux-pool-cache-manaflow under keys that hash the content of the inputs, never a commit
or a tag (cmuxterm-hq build-fleet/swift-linux-builder/POOL.md "Build cache", hq#2132, hq#2169), and
any pool VM reuses what any other built. On the minis a SwiftPM build stays warm only on the mini,
slot and workspace path that made it (owned_spm_scratch.py: its fingerprint holds the workspace
path), so the same unchanged package is built from nothing on every other mini.

The key hashes what a `swift build` of PACKAGE reads, and nothing else:
  - the git tree id of PACKAGE and of every directory its build reaches: the local path
    dependencies of its manifest, transitively (`swift package dump-package`), target `path:`es
    outside the package, and the targets of tracked symlinks that leave it;
  - the value of every environment variable a manifest in that closure reads
    (`environment["NAME"]`);
  - the toolchain: `swift -version`, `xcodebuild -version`, the SDK version and build, the
    developer directory, the architecture;
  - the absolute path the package builds at (SwiftPM records absolute paths, so the minis build at
    one fixed ROOT, as the Linux pool builds at ~/lanes/pool/cmux on every VM);
  - the build arguments, and this file's bytes (the recipe).
A checkout with changes under any of those directories has no key: only clean trees are cached,
as on the pool, where only a clean exact-commit job stores.

`stage` puts exactly the tracked files of those trees at ROOT (untracked files never land), keeping each package's `.build`, and gives every file a modification time derived from
its blob id. The same content then has the same time on every mini, so a restored build sees
sources no newer than its objects, while a changed file gets another time and SwiftPM's own
incremental check still rebuilds it on a kept build.

A hit is the product, as the pool's app layer is: `restore` (or `get`) unpacks the stored
`.build` of exactly these inputs, and the step can run `swift test --skip-build`. `bench` measures
one arm (cold, kept, or restored from an archive another mini packed) and writes a JSON report.

Stores: `put` and `get` take a directory (on a mini, the shared one the worker gives its steps).
Across minis the archive moves as a fleet job artifact and a later job's input (content-addressed
by sha256 already); a key -> digest index in the fleet cache is the follow-up that lets CI steps
find it by key alone. Entries are written only from clean trees; a get whose manifest names another
key is a miss.
"""
from __future__ import annotations

import argparse
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time

RECIPE = "spm-ac/v1"
MANIFEST = "spm-ac-manifest.json"
# Content-derived file times: 2000-01-01 plus up to ten years, from the blob id.
MTIME_EPOCH = 946684800
MTIME_SPAN = 10 * 365 * 86400
ENV_READ = re.compile(r"""environment\s*\[\s*"([A-Za-z_][A-Za-z0-9_]*)"\s*\]""")
COMPILE_LINE = re.compile(r"^\[\d+/\d+\] Compiling ", re.M)


class NoKey(Exception):
    """The inputs cannot be keyed (a dirty tree, a path outside the checkout): build without the cache."""


def run(cmd: list[str], cwd: Path | None = None, check: bool = True, **kw) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, cwd=cwd, check=check, capture_output=True, text=True, **kw)


def repo_rel(checkout: Path, path: Path) -> str:
    try:
        rel = path.resolve().relative_to(checkout.resolve())
    except ValueError:
        raise NoKey(f"{path} is outside the checkout") from None
    return rel.as_posix() or "."


def dump_package(package: Path) -> dict:
    out = run(["swift", "package", "dump-package", "--package-path", str(package)]).stdout
    return json.loads(out)


def manifest_reach(package: Path, dump: dict) -> list[Path]:
    """What one manifest makes the build read outside the package directory: local path packages and
    target directories elsewhere."""
    found = []
    for dep in dump.get("dependencies", []):
        for entry in dep.get("fileSystem", []) or []:
            path = entry.get("path")
            if path:
                found.append(Path(path))
    for target in dump.get("targets", []):
        if target.get("path"):
            found.append((package / target["path"]).resolve())
    return found


def tracked_links_out(checkout: Path, rel: str) -> list[Path]:
    """The targets of tracked symlinks under rel that point out of it."""
    out = run(["git", "-C", str(checkout), "ls-files", "-s", "-z", "--", rel]).stdout
    base = (checkout / rel).resolve()
    found = []
    for row in filter(None, out.split("\0")):
        info, path = row.split("\t", 1)
        if info.split(" ")[0] != "120000":
            continue
        target = (checkout / path).parent / os.readlink(checkout / path)
        resolved = target.resolve()
        if base not in resolved.parents and resolved != base:
            found.append(resolved)
    return found


def closure(checkout: Path, package: Path, dump=dump_package) -> tuple[list[str], list[str]]:
    """The repo-relative paths the build of package reaches, ancestors only (a nested path folds into
    the one above it), and the environment variables its manifests read."""
    seen: set[str] = set()
    envs: set[str] = set()
    todo = [package.resolve()]
    while todo:
        current = todo.pop()
        rel = repo_rel(checkout, current)
        if rel in seen:
            continue
        seen.add(rel)
        if current.is_dir() and (current / "Package.swift").is_file():
            for manifest in current.glob("Package*.swift"):
                envs.update(ENV_READ.findall(manifest.read_text(encoding="utf-8", errors="replace")))
            todo.extend(manifest_reach(current, dump(current)))
        if current.is_dir():
            todo.extend(tracked_links_out(checkout, rel))
    ordered = sorted(seen, key=lambda p: (p.count("/"), p))
    kept: list[str] = []
    for rel in ordered:
        if not any(rel == k or rel.startswith(k + "/") or k == "." for k in kept):
            kept.append(rel)
    return sorted(kept), sorted(envs)


def tree_ids(checkout: Path, rels: list[str]) -> dict[str, str]:
    dirty = run(["git", "-C", str(checkout), "status", "--porcelain", "--untracked-files=no", "--", *rels]).stdout
    if dirty.strip():
        raise NoKey("the checkout has changes under " + ", ".join(rels))
    ids = {}
    for rel in rels:
        spec = "HEAD:" if rel == "." else f"HEAD:{rel}"
        got = run(["git", "-C", str(checkout), "rev-parse", spec], check=False)
        if got.returncode:
            raise NoKey(f"{rel} is not tracked")
        ids[rel] = got.stdout.strip()
    return ids


def toolchain() -> dict[str, str]:
    def out(cmd: list[str]) -> str:
        got = run(cmd, check=False)
        return (got.stdout + got.stderr).strip() if got.returncode == 0 else f"<{cmd[0]} failed: {got.returncode}>"
    return {
        # Without its "Target: arm64-apple-macosxNN" line: that is the host's OS, not what the build targets
        # (the manifest's platforms and the SDK, which is keyed, decide that), so minis on another macOS share.
        "swift": "\n".join(l for l in out(["swift", "-version"]).splitlines() if not l.startswith("Target:")),
        "xcodebuild": out(["xcodebuild", "-version"]),
        "sdk_version": out(["xcrun", "--show-sdk-version"]),
        "sdk_build": out(["xcrun", "--show-sdk-build-version"]),
        "developer_dir": out(["xcode-select", "-p"]),
        "arch": os.uname().machine,
    }


def key_inputs(checkout: Path, package: Path, root: Path, args: list[str], dump=dump_package, tools=toolchain) -> dict:
    rels, envs = closure(checkout, package, dump)
    return {
        "recipe": RECIPE,
        "tool": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "package": repo_rel(checkout, package),
        "build_path": str(root / repo_rel(checkout, package)),
        "trees": tree_ids(checkout, rels),
        "env": {name: os.environ.get(name, "<unset>") for name in envs},
        "toolchain": tools(),
        "args": list(args),
    }


def key_of(inputs: dict) -> str:
    return hashlib.sha256(json.dumps(inputs, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def blob_mtime(blob: str) -> int:
    return MTIME_EPOCH + int(blob[:12], 16) % MTIME_SPAN


def copy_file(src: Path, dst: Path) -> None:
    """dst as a copy of src: an APFS clone (no data blocks of its own) where the volume can, else a copy."""
    if sys.platform == "darwin":
        import ctypes
        libc = ctypes.CDLL(None, use_errno=True)
        if libc.clonefile(os.fsencode(src), os.fsencode(dst), 1) == 0:  # CLONE_NOFOLLOW
            return
    shutil.copyfile(src, dst)


def stage(checkout: Path, rels: list[str], root: Path) -> int:
    """Put the tracked files of rels at root, from checkout's working tree (key_inputs already found it clean,
    so it is HEAD's content), keeping every `.build`, with blob-derived file times. Copying from the tree
    (APFS clones) instead of `git archive` reads no object: in a blobless clone, archive fetched blobs one
    by one. Returns how many files it wrote."""
    root.mkdir(parents=True, exist_ok=True)
    for rel in rels:
        dest = root / rel
        if dest.is_dir() and not dest.is_symlink():
            for child in dest.iterdir():
                if child.name == ".build":
                    continue
                shutil.rmtree(child) if child.is_dir() and not child.is_symlink() else child.unlink()
        elif dest.exists() or dest.is_symlink():
            dest.unlink()
    listing = run(["git", "-C", str(checkout), "ls-files", "-s", "-z", "--", *rels]).stdout
    umask = os.umask(0)
    os.umask(umask)
    count = 0
    for row in filter(None, listing.split("\0")):
        info, path = row.split("\t", 1)
        mode, blob = info.split(" ")[:2]
        src, dst = checkout / path, root / path
        dst.parent.mkdir(parents=True, exist_ok=True)
        if mode == "120000":
            os.symlink(os.readlink(src), dst)
            continue
        if mode not in ("100644", "100755"):
            continue  # a submodule: not a file the build reads from this tree
        copy_file(src, dst)
        os.chmod(dst, (0o777 if mode == "100755" else 0o666) & ~umask)
        when = blob_mtime(blob)
        os.utime(dst, (when, when))
        count += 1
    return count


def compressor() -> list[str]:
    return ["zstd", "-T0", "-3", "-q"] if shutil.which("zstd") else ["gzip", "-1"]


def pack(root: Path, package: str, key: str, out: Path) -> dict:
    build = root / package / ".build"
    if not build.is_dir():
        raise RuntimeError(f"{build} does not exist")
    (build / MANIFEST).write_text(json.dumps({"key": key, "recipe": RECIPE, "package": package}) + "\n")
    out.parent.mkdir(parents=True, exist_ok=True)
    with open(out, "wb") as sink:
        tar = subprocess.Popen(["tar", "-c", "-f", "-", "-C", str(root / package), ".build"], stdout=subprocess.PIPE)
        subprocess.run(compressor(), stdin=tar.stdout, stdout=sink, check=True)
        tar.stdout.close()
        if tar.wait():
            raise RuntimeError("tar failed")
    digest = hashlib.sha256()
    with open(out, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            digest.update(chunk)
    return {"bytes": out.stat().st_size, "sha256": digest.hexdigest(), "compressor": compressor()[0]}


def decompressor(archive: Path) -> list[str]:
    with open(archive, "rb") as f:
        head = f.read(4)
    return ["zstd", "-d", "-q", "-c"] if head == b"\x28\xb5\x2f\xfd" else ["gzip", "-d", "-c"]


def restore(root: Path, package: str, key: str, archive: Path) -> bool:
    """Unpack archive as root/package/.build when its manifest names key; False (and nothing changed) when
    it names another key."""
    dest = root / package
    dest.mkdir(parents=True, exist_ok=True)
    scratch = Path(tempfile.mkdtemp(prefix=".spm-ac-", dir=dest))
    try:
        with open(archive, "rb") as source:
            unzip = subprocess.Popen(decompressor(archive), stdin=source, stdout=subprocess.PIPE)
            subprocess.run(["tar", "-x", "-f", "-", "-C", str(scratch)], stdin=unzip.stdout, check=True)
            unzip.stdout.close()
            if unzip.wait():
                raise RuntimeError("decompress failed")
        try:
            got = json.loads((scratch / ".build" / MANIFEST).read_text())
        except (OSError, ValueError):
            return False
        if got.get("key") != key:
            return False
        old = dest / ".build"
        if old.exists():
            trash = dest / f".spm-ac-trash-{os.getpid()}"
            old.rename(trash)
            shutil.rmtree(trash, ignore_errors=True)
        (scratch / ".build").rename(old)
        return True
    finally:
        shutil.rmtree(scratch, ignore_errors=True)


def store_path(store: Path, key: str) -> Path:
    return store / RECIPE.replace("/", "-") / key[:2] / f"{key}.tar"


def put(root: Path, package: str, key: str, store: Path) -> dict:
    final = store_path(store, key)
    final.parent.mkdir(parents=True, exist_ok=True)
    partial = final.with_name(f".{final.name}.{os.getpid()}")
    meta = pack(root, package, key, partial)
    os.replace(partial, final)
    final.with_suffix(".meta.json").write_text(json.dumps({**meta, "key": key, "at": int(time.time())}) + "\n")
    return meta


def get(root: Path, package: str, key: str, store: Path) -> bool:
    final = store_path(store, key)
    try:
        meta = json.loads(final.with_suffix(".meta.json").read_text())
    except (OSError, ValueError):
        return False
    if meta.get("key") != key or not final.is_file() or final.stat().st_size != meta.get("bytes"):
        return False
    return restore(root, package, key, final)


@contextlib.contextmanager
def held(root: Path):
    """One build at a time in root: the key holds its path, so a second job waits rather than build elsewhere."""
    root.parent.mkdir(parents=True, exist_ok=True)
    with open(f"{root}.lock", "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield


def swift_build(path: Path, args: list[str]) -> dict:
    started = time.monotonic()
    got = subprocess.run(["swift", "build", "--package-path", str(path), *args], capture_output=True, text=True)
    seconds = round(time.monotonic() - started, 2)
    out = got.stdout + got.stderr
    sys.stderr.write(out[-4000:])
    return {"exit": got.returncode, "seconds": seconds, "compile_jobs": len(COMPILE_LINE.findall(out))}


def bench(a: argparse.Namespace) -> dict:
    checkout, root = Path(a.checkout).resolve(), Path(a.root)
    package = Path(a.package) if Path(a.package).is_absolute() else checkout / a.package
    report: dict = {"host": os.uname().nodename, "arm": "restore" if a.archive else ("fresh" if a.fresh else "kept")}
    with held(root):
        t = time.monotonic()
        inputs = key_inputs(checkout, package, root, a.arg)
        key = key_of(inputs)
        report.update(key=key, key_seconds=round(time.monotonic() - t, 2), trees=inputs["trees"],
                      toolchain_digest=hashlib.sha256(json.dumps(inputs["toolchain"], sort_keys=True).encode()).hexdigest())
        rel = inputs["package"]
        if a.fresh or a.archive:
            shutil.rmtree(root, ignore_errors=True)
        t = time.monotonic()
        report["staged_files"] = stage(checkout, list(inputs["trees"]), root)
        report["stage_seconds"] = round(time.monotonic() - t, 2)
        if a.archive:
            t = time.monotonic()
            report["hit"] = restore(root, rel, key, Path(a.archive))
            report["restore_seconds"] = round(time.monotonic() - t, 2)
        report["build"] = swift_build(root / rel, a.arg)
        if a.pack and report["build"]["exit"] == 0:
            t = time.monotonic()
            report["pack"] = pack(root, rel, key, Path(a.pack))
            report["pack_seconds"] = round(time.monotonic() - t, 2)
    if a.report:
        Path(a.report).parent.mkdir(parents=True, exist_ok=True)
        Path(a.report).write_text(json.dumps(report, indent=2) + "\n")
    return report


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    k = sub.add_parser("key")
    k.add_argument("checkout")
    k.add_argument("package")
    k.add_argument("--root", default="/Users/Shared/cmux-build-fleet/spm-ac/root")
    k.add_argument("--arg", action="append", default=[])
    s = sub.add_parser("stage")
    s.add_argument("checkout")
    s.add_argument("package")
    s.add_argument("root")
    for name in ("pack", "restore", "get", "put"):
        c = sub.add_parser(name)
        c.add_argument("root")
        c.add_argument("package", help="repo-relative package path")
        c.add_argument("key")
        c.add_argument("path", help={"pack": "OUT", "restore": "ARCHIVE"}.get(name, "STORE"))
    b = sub.add_parser("bench")
    b.add_argument("checkout")
    b.add_argument("package")
    b.add_argument("root")
    b.add_argument("--archive")
    b.add_argument("--fresh", action="store_true", help="start from an empty root (the cold arm)")
    b.add_argument("--pack")
    b.add_argument("--report")
    b.add_argument("--arg", action="append", default=[])
    a = p.parse_args(argv)
    try:
        if a.cmd == "key":
            checkout = Path(a.checkout).resolve()
            inputs = key_inputs(checkout, checkout / a.package, Path(a.root), a.arg)
            print(json.dumps({"key": key_of(inputs), "inputs": inputs}, indent=2, sort_keys=True))
        elif a.cmd == "stage":
            checkout = Path(a.checkout).resolve()
            rels, _ = closure(checkout, checkout / a.package)
            print(stage(checkout, rels, Path(a.root)))
        elif a.cmd == "pack":
            print(json.dumps(pack(Path(a.root), a.package, a.key, Path(a.path))))
        elif a.cmd == "restore":
            return 0 if restore(Path(a.root), a.package, a.key, Path(a.path)) else 3
        elif a.cmd == "put":
            print(json.dumps(put(Path(a.root), a.package, a.key, Path(a.path))))
        elif a.cmd == "get":
            return 0 if get(Path(a.root), a.package, a.key, Path(a.path)) else 3
        elif a.cmd == "bench":
            print(json.dumps(bench(a), indent=2))
    except NoKey as err:
        print(f"spm_action_cache: no key: {err}", file=sys.stderr)
        return 4
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
