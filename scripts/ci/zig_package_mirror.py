#!/usr/bin/env python3
"""Every Zig package a cmux build fetches comes from a host we control.

codeberg.org went down on 2026-11-11 (about 10:00Z) and every cold Zig build of
libghostty-vt failed: ghostty-next's translate_c tarball pins aro to
git+https://codeberg.org/ziglang/arocc, and Zig fetched it at build time
("unable to discover remote git server capabilities: ProtocolError"). The
Cloud journey, the cmux-tui artifacts and the live conformance checks went red
on every pull request.

The fix is one rule: no build fetches from a third-party host. Every package in
the Zig dependency tree of each Ghostty source (ghostty-next, ghostty), the
transitive ones too, is copied to the GitHub release named in
scripts/ci/zig-packages.lock, pinned by Zig package hash and by the sha256 of
the copy. Zig reads <global cache>/p/<hash>.tar.gz before it fetches a URL and
checks the package hash of what it unpacks (lib/compiler/Maker/Fetch.zig in
Zig 0.17), so the builds put the copies there first:

  - ghostty-vt-sys's build.rs (every cargo build of libghostty-vt): the `vt`
    packages,
  - scripts/ci/seed-zig-package-archives.sh (the ghostty-zig-packages action and
    every `zig build --fetch=all`): the source's packages.

In CI (CI=true) both run Zig with no route to any other host
(CMUX_ZIG_MIRROR_ONLY, default on in CI), so a package missing from the mirror
fails the build that needs it, named, instead of fetching it upstream.

Commands:

  check [--online]   The detector (ci-guards.yml): every URL dependency in every
                     build.zig.zon of the tree, and every dependency those
                     packages name in turn, is on an allowed host or mirrored in
                     the lock. --online also downloads every mirrored copy,
                     checks its sha256 and reads its own build.zig.zon, so the
                     transitive dependencies the lock records are the real ones.
  lock DIR...        Rebuild the lock from directories of Zig p/<hash>.tar.gz
                     archives (a `zig build --fetch=all` cache): prints the
                     lock, and the archives to upload with --upload-list FILE.

Hosts we control: ALLOWED_PREFIXES below. A new dependency on another host
lands with its copy: `zig build --fetch=all` with an empty cache, then
`zig_package_mirror.py lock <cache>/p --upload-list up.txt > lock`, and upload
the files in up.txt to the release (gh release upload zig-packages ... -R
manaflow-ai/ghostty-next).
"""

from __future__ import annotations

import argparse
import hashlib
import io
import re
import sys
import tarfile
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LOCK = ROOT / "scripts/ci/zig-packages.lock"
# The Ghostty sources whose Zig trees cmux builds (submodules at the repo root),
# and the repo's own Zig packages (bindings).
SOURCES = ("ghostty-next", "ghostty")
# URL prefixes on hosts we control: the lock's mirror must be under one. Every
# URL dependency, these hosts' included, must be in the lock: a package on our
# host can still name a third-party package, and only its lock entry's deps
# let the transitive scan see that.
ALLOWED_PREFIXES = (
    "https://github.com/manaflow-ai/",
)
SKIP_PARTS = {"zig-pkg", ".zig-cache", "zig-cache", "zig-out", ".git"}

DEP_BLOCK = re.compile(r"\.(@\"[^\"]+\"|[A-Za-z_][A-Za-z0-9_]*)\s*=\s*\.\{")
FIELD = re.compile(r"\.(url|hash|path|lazy)\s*=\s*(\"(?:[^\"\\]|\\.)*\"|true|false)")


def strip_comments(text: str) -> str:
    """The ZON text with // comments outside strings removed."""
    out = []
    for line in text.splitlines():
        quoted = False
        i = 0
        cut = len(line)
        while i < len(line):
            c = line[i]
            if c == "\\" and quoted:
                i += 2
                continue
            if c == '"':
                quoted = not quoted
            elif not quoted and line.startswith("//", i):
                cut = i
                break
            i += 1
        out.append(line[:cut])
    return "\n".join(out)


@dataclass
class Dep:
    name: str
    url: str | None = None
    hash: str | None = None
    path: str | None = None
    lazy: bool = False


def parse_deps(text: str) -> list[Dep]:
    """The entries of a build.zig.zon's `.dependencies = .{ ... }`."""
    code = strip_comments(text)
    start = re.search(r"\.dependencies\s*=\s*\.\{", code)
    if not start:
        return []
    # The dependencies block: from its brace to the matching one.
    i = start.end()
    depth = 1
    body_start = i
    quoted = False
    while i < len(code) and depth:
        c = code[i]
        if c == "\\" and quoted:
            i += 2
            continue
        if c == '"':
            quoted = not quoted
        elif not quoted:
            if c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
        i += 1
    body = code[body_start:i - 1]
    deps = []
    for match in DEP_BLOCK.finditer(body):
        # Only top-level entries of the block (depth 0 inside it).
        prefix = body[:match.start()]
        if prefix.count("{") - prefix.count("}") != 0:
            continue
        j = match.end()
        d = 1
        while j < len(body) and d:
            if body[j] == "{":
                d += 1
            elif body[j] == "}":
                d -= 1
            j += 1
        entry = body[match.end():j - 1]
        dep = Dep(name=match.group(1).strip('@"'))
        for key, value in FIELD.findall(entry):
            if key == "lazy":
                dep.lazy = value == "true"
            else:
                setattr(dep, key, value[1:-1])
        deps.append(dep)
    return deps


def allowed(url: str) -> bool:
    return any(url.startswith(prefix) for prefix in ALLOWED_PREFIXES)


@dataclass
class Entry:
    hash: str
    sha256: str
    tags: set[str]
    upstream: str
    deps: list[str] = field(default_factory=list)


@dataclass
class Lock:
    mirror: str
    entries: dict[str, Entry]


def read_lock(path: Path | None = None) -> Lock:
    path = path or LOCK
    mirror = ""
    entries: dict[str, Entry] = {}
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        # A line that starts with # is a comment (a git+ URL's #commit is not).
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if parts[0] == "mirror" and len(parts) == 2:
            mirror = parts[1]
            continue
        if len(parts) != 5:
            raise SystemExit(f"{path}:{number}: want `HASH SHA256 TAGS UPSTREAM DEPS`, got {raw!r}")
        hash_, sha, tags, upstream, deps = parts
        if not re.fullmatch(r"[0-9a-f]{64}", sha):
            raise SystemExit(f"{path}:{number}: {sha!r} is not a sha256")
        if hash_ in entries:
            raise SystemExit(f"{path}:{number}: {hash_} is listed twice")
        entries[hash_] = Entry(hash_, sha, set(tags.split(",")), upstream,
                               [] if deps == "-" else deps.split(","))
    if not mirror:
        raise SystemExit(f"{path}: no `mirror URL-PREFIX` line")
    return Lock(mirror, entries)


def write_lock(lock: Lock) -> str:
    lines = [
        "# Every Zig package the Ghostty sources' trees name, mirrored on a host we control.",
        "# Written by scripts/ci/zig_package_mirror.py lock; checked by its check (ci-guards.yml).",
        "# Builds read <mirror><hash>.tar.gz into Zig's p/ before Zig runs; Zig checks the hash.",
        "# HASH SHA256-OF-THE-COPY TAGS UPSTREAM-URL DEPS(the hashes its own build.zig.zon names)",
        "# Tags: the source trees that name it; `vt` = fetched by ghostty-vt-sys's build.rs.",
        f"mirror {lock.mirror}",
    ]
    for entry in sorted(lock.entries.values(), key=lambda e: e.hash):
        lines.append(" ".join([
            entry.hash, entry.sha256, ",".join(sorted(entry.tags)), entry.upstream,
            ",".join(entry.deps) or "-",
        ]))
    return "\n".join(lines) + "\n"


def zons(tree: Path):
    for path in sorted(tree.rglob("build.zig.zon")):
        if SKIP_PARTS.intersection(path.relative_to(tree).parts):
            continue
        yield path


def cmux_zons() -> list[Path]:
    """The repo's own build.zig.zon files (git ls-files: not the submodules)."""
    import subprocess
    out = subprocess.run(["git", "-C", str(ROOT), "ls-files", "-z", "--", "*build.zig.zon"],
                         capture_output=True, check=True).stdout.decode()
    return [ROOT / f for f in out.split("\0") if f]


def archive_zon(data: bytes) -> str | None:
    """The package's own build.zig.zon from a p/<hash>.tar.gz (any root dir)."""
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:*") as tar:
        names = [m for m in tar.getmembers() if m.isfile()]
        roots = {m.name.split("/", 1)[0] for m in names}
        candidates = ["build.zig.zon"]
        if len(roots) == 1 and all("/" in m.name for m in names):
            candidates.insert(0, f"{next(iter(roots))}/build.zig.zon")
        for member in names:
            if member.name.lstrip("./") in candidates:
                return tar.extractfile(member).read().decode("utf-8", "replace")
    return None


def url_deps(text: str) -> list[Dep]:
    return [d for d in parse_deps(text) if d.url]


# ---------------------------------------------------------------- check


def check(online: bool, sources: list[str]) -> int:
    lock = read_lock()
    problems: list[str] = []
    if not allowed(lock.mirror):
        problems.append(f"the lock's mirror {lock.mirror} is not on a host we control ({', '.join(ALLOWED_PREFIXES)})")

    roots: dict[str, set[str]] = {}
    trees = [(name, list(zons(ROOT / name))) for name in sources]
    trees.append(("cmux", cmux_zons()))
    for name, files in trees:
        if name != "cmux" and not (ROOT / name / "build.zig.zon").is_file():
            problems.append(f"{name}/build.zig.zon is missing: run `git submodule update --init --depth 1 {name}` first")
            continue
        found: set[str] = set()
        for zon in files:
            rel = zon.relative_to(ROOT)
            for dep in url_deps(zon.read_text(encoding="utf-8", errors="replace")):
                if not dep.hash:
                    problems.append(f"{rel}: .{dep.name} ({dep.url}) has no .hash, so it cannot be pinned or mirrored")
                    continue
                found.add(dep.hash)
                entry = lock.entries.get(dep.hash)
                if entry is None and allowed(dep.url):
                    # On our host, but its own build.zig.zon can still name a third-party
                    # package: only a lock entry (its deps, re-read by --online) lets the
                    # transitive scan below see through it.
                    problems.append(f"{rel}: .{dep.name} ({dep.url}) is on a host we control but {dep.hash} is not in {LOCK.relative_to(ROOT)}, so its own dependencies are never checked")
                elif entry is None:
                    problems.append(f"{rel}: .{dep.name} fetches {dep.url} (a third-party host) and {dep.hash} is not mirrored in {LOCK.relative_to(ROOT)}")
                elif name != "cmux" and name not in entry.tags:
                    problems.append(f"{rel}: {dep.hash} is mirrored but not tagged {name}, so {name}'s seed skips it")
        roots[name] = found

    # Transitive: every dependency a mirrored package names is mirrored too.
    for name, found in roots.items():
        seen: set[str] = set()
        queue = sorted(found)
        while queue:
            h = queue.pop()
            if h in seen:
                continue
            seen.add(h)
            entry = lock.entries.get(h)
            if entry is None:
                continue  # reported above: every URL dependency must be in the lock
            for dep in entry.deps:
                if dep not in lock.entries:
                    problems.append(f"{h} (mirrored) depends on {dep}, which is not mirrored: a build would fetch it from its third-party host")
                elif name != "cmux" and name not in lock.entries[dep].tags:
                    problems.append(f"{dep} (a dependency of {h}) is not tagged {name}")
                queue.append(dep)
    vt = {h for h, e in lock.entries.items() if "vt" in e.tags}
    for h in sorted(vt):
        for dep in lock.entries[h].deps:
            if dep in lock.entries and dep not in vt:
                problems.append(f"{dep} (a dependency of vt package {h}) is not tagged vt")

    if online:
        problems += check_online(lock)

    if problems:
        for problem in problems:
            print(f"zig-package-mirror: {problem}", file=sys.stderr)
        print("next: mirror the package (scripts/ci/zig_package_mirror.py's docstring: fetch with an empty "
              "Zig cache, `lock` the cache's p/, upload the listed archives to the release) and commit the lock",
              file=sys.stderr)
        return 1
    total = sum(len(v) for v in roots.values())
    print(f"zig-package-mirror: ok: {len(lock.entries)} packages mirrored at {lock.mirror}; "
          f"{total} URL dependencies across {', '.join(roots)} are mirrored or on hosts we control"
          + (" (online: every copy downloaded and checked)" if online else ""))
    return 0


def fetch(url: str) -> bytes:
    last: Exception | None = None
    for _ in range(3):
        try:
            with urllib.request.urlopen(url, timeout=120) as response:  # noqa: S310 (https mirror)
                return response.read()
        except Exception as error:  # retried
            last = error
    raise RuntimeError(f"could not download {url}: {last}")


def check_online(lock: Lock) -> list[str]:
    problems = []
    for entry in sorted(lock.entries.values(), key=lambda e: e.hash):
        url = f"{lock.mirror}{entry.hash}.tar.gz"
        try:
            data = fetch(url)
        except RuntimeError as error:
            problems.append(str(error))
            continue
        sha = hashlib.sha256(data).hexdigest()
        if sha != entry.sha256:
            problems.append(f"{url}: sha256 {sha}, the lock pins {entry.sha256}")
            continue
        text = archive_zon(data)
        real = sorted(d.hash for d in url_deps(text or "") if d.hash)
        if real != sorted(entry.deps):
            problems.append(f"{entry.hash}: its build.zig.zon names {real or '-'}, the lock records {entry.deps or '-'}")
    return problems


# ---------------------------------------------------------------- lock


def build_lock(dirs: list[Path], upload_list: Path | None, vt: set[str]) -> int:
    archives: dict[str, Path] = {}
    for d in dirs:
        for path in sorted(d.glob("*.tar.gz")):
            archives.setdefault(path.name[: -len(".tar.gz")], path)
    try:
        old = read_lock()
    except (FileNotFoundError, SystemExit):
        old = Lock("https://github.com/manaflow-ai/ghostty-next/releases/download/zig-packages/", {})
    lock = Lock(old.mirror, {})
    upstream: dict[str, str] = {}
    tags: dict[str, set[str]] = {}
    queue: list[tuple[str, str]] = []
    for name in SOURCES:
        tree = ROOT / name
        if not (tree / "build.zig.zon").is_file():
            raise SystemExit(f"{name} is not checked out: git submodule update --init --depth 1 {name}")
        for zon in zons(tree):
            for dep in url_deps(zon.read_text(encoding="utf-8", errors="replace")):
                if dep.hash:
                    upstream.setdefault(dep.hash, dep.url)
                    queue.append((dep.hash, name))
    missing = []
    while queue:
        h, name = queue.pop()
        if name in tags.setdefault(h, set()):
            continue
        tags[h].add(name)
        if h in lock.entries:
            for dep in lock.entries[h].deps:
                queue.append((dep, name))
            continue
        path = archives.get(h)
        if path is None:
            if h in old.entries:
                e = old.entries[h]
                lock.entries[h] = Entry(h, e.sha256, set(), e.upstream, list(e.deps))
                for dep in e.deps:
                    queue.append((dep, name))
            else:
                missing.append(h)
            continue
        data = path.read_bytes()
        deps = url_deps(archive_zon(data) or "")
        for dep in deps:
            if dep.hash:
                upstream.setdefault(dep.hash, dep.url)
                queue.append((dep.hash, name))
        lock.entries[h] = Entry(h, hashlib.sha256(data).hexdigest(), set(), upstream.get(h, "-"),
                                sorted(d.hash for d in deps if d.hash))
    for h, entry in lock.entries.items():
        entry.tags = set(tags[h]) | ({"vt"} if h in vt else set())
    # The vt set is closed under dependencies.
    changed = True
    while changed:
        changed = False
        for entry in list(lock.entries.values()):
            if "vt" in entry.tags:
                for dep in entry.deps:
                    if dep in lock.entries and "vt" not in lock.entries[dep].tags:
                        lock.entries[dep].tags.add("vt")
                        changed = True
    if missing:
        print("zig-package-mirror: no archive for " + ", ".join(sorted(set(missing))), file=sys.stderr)
        return 1
    sys.stdout.write(write_lock(lock))
    if upload_list:
        upload_list.write_text("".join(f"{archives[h]}\n" for h in sorted(lock.entries) if h in archives and h not in old.entries))
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    c = sub.add_parser("check")
    c.add_argument("--online", action="store_true")
    c.add_argument("--source", action="append", choices=SOURCES,
                   help="a Ghostty source to check (default: both)")
    l = sub.add_parser("lock")
    l.add_argument("dirs", nargs="+", type=Path)
    l.add_argument("--upload-list", type=Path)
    l.add_argument("--vt", default="", help="comma-separated hashes ghostty-vt-sys's build fetches")
    args = parser.parse_args(argv)
    if args.command == "check":
        return check(args.online, args.source or list(SOURCES))
    vt = {h for h in args.vt.split(",") if h}
    if not vt:
        try:
            vt = {h for h, e in read_lock().entries.items() if "vt" in e.tags}
        except (FileNotFoundError, SystemExit):
            vt = set()
    return build_lock(args.dirs, args.upload_list, vt)


if __name__ == "__main__":
    sys.exit(main())
