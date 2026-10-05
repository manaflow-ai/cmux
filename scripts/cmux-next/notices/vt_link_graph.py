#!/usr/bin/env python3
# Copyright 2026 Manaflow, Inc.
# SPDX-License-Identifier: GPL-3.0-or-later
"""The Zig packages whose code libghostty-vt.a really contains, per target.

  vt_link_graph.py generate --out vt-link-graph.json [--repo DIR]
                            [--target ZIG_TARGET ...] [--dwarfdump TOOL]

CI and Testbox only: it runs zig. For each target it builds libghostty-vt as
ghostty-vt-sys's build.rs does (the source and gitlink that
check_ghostty_vt_notices.py resolves, build.rs's -D flags) plus
-Dstrip=false, in a fresh copy with an empty Zig cache. It reads every source
path of the archive's DWARF (`llvm-dwarfdump --show-sources`) and attributes
each path:
  <src>/zig-pkg/<hash>/... or <cache>/p/<hash>/...   the Zig package <hash>
  <zig lib dir>/<top>/...                             Zig's lib, counted per top
                                                      directory (std, compiler_rt,
                                                      libc, libcxx, include)
  <src>/pkg/<name>/..., <src>/vendor/<name>/...       a vendored Ghostty directory
                                                      (ghostty_vendored.py reviews it)
  <src>/...                                           the Ghostty tree itself
  <cache>/..., <src>/.zig-cache/...                   generated (options, builtin)
  anything else                                       unattributed
check_ghostty_vt_notices.py --link-graph reads the result: the commit must be
the one it resolves, nothing may be unattributed, and every linked package
must be in a license manifest. The declared closure (build.zig.zon) stays the
blocking check; the graph says which declared packages are really linked.

Targets (default): aarch64-macos and x86_64-macos (bin/cmux and the
cmux-tui-ssh Mach-O binaries), x86_64-linux-musl and aarch64-linux-musl (the
Linux cmux-tui-ssh and npm binaries; build_support.rs zig_target_arg).
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
sys.path.insert(0, str(HERE))
import check_ghostty_vt_notices as vt  # noqa: E402

DEFAULT_TARGETS = ("aarch64-macos", "x86_64-macos", "x86_64-linux-musl", "aarch64-linux-musl")
FLAG = re.compile(r'\.arg\("(-D[^"]*)"\)')
PACKAGE_DIR = re.compile(r"^([^/]+)/")


def attribute(paths: list[str], src: str, cache: str, zig_lib: str) -> dict:
    """Sort DWARF source paths by owner (see the module docstring)."""
    files: dict[str, int] = {}
    vendored: dict[str, int] = {}
    lib: dict[str, int] = {}
    counts = {"ghostty_files": 0, "generated_files": 0}
    unattributed: set[str] = set()
    src, cache, zig_lib = (p.rstrip("/") + "/" for p in (src, cache, zig_lib))
    for raw in paths:
        path = os.path.normpath(raw.strip()) if raw.strip() else ""
        if not path:
            continue
        package = None
        for prefix in (src + "zig-pkg/", cache + "p/"):
            if path.startswith(prefix):
                match = PACKAGE_DIR.match(path[len(prefix):])
                package = match.group(1) if match else None
                break
        if package:
            files[package] = files.get(package, 0) + 1
        elif path.startswith(zig_lib):
            top = path[len(zig_lib):].split("/", 1)[0]
            lib[top] = lib.get(top, 0) + 1
        elif path.startswith(cache) or path.startswith(src + ".zig-cache/"):
            counts["generated_files"] += 1
        elif path.startswith(src):
            parts = path[len(src):].split("/")
            if len(parts) > 2 and parts[0] in ("pkg", "vendor"):
                key = f"{parts[0]}/{parts[1]}"
                vendored[key] = vendored.get(key, 0) + 1
            else:
                counts["ghostty_files"] += 1
        else:
            unattributed.add(path)
    return {
        "packages": sorted(files), "package_files": dict(sorted(files.items())),
        "vendored": dict(sorted(vendored.items())), "zig_lib": dict(sorted(lib.items())),
        **counts, "unattributed": sorted(unattributed),
    }


def zig_env_fields(text: str) -> dict[str, str]:
    """`zig env` prints JSON up to 0.15 and ZON (`.lib_dir = "..."`) since 0.16."""
    try:
        data = json.loads(text)
        return {k: v for k, v in data.items() if isinstance(v, str)}
    except ValueError:
        return dict(re.findall(r'^\s*\.([a-z_]+)\s*=\s*"([^"]*)"', text, re.M))


def run(*args: str, cwd: Path | None = None, env: dict | None = None) -> str:
    result = subprocess.run(list(args), cwd=cwd, env=env, capture_output=True, text=True)
    if result.returncode != 0:
        raise SystemExit(f"vt_link_graph: {' '.join(args)} failed ({result.returncode}):\n{result.stderr[-4000:]}")
    return result.stdout


def generate(args: argparse.Namespace) -> dict:
    repo = args.repo.resolve()
    path, commit = vt.resolve_vt_source(repo, "HEAD")
    url = run("git", "-C", str(repo), "config", "-f", ".gitmodules", f"submodule.{path}.url").strip()
    build_rs = run("git", "-C", str(repo), "show", f"HEAD:{vt.BUILD_RS}")
    flags = FLAG.findall(build_rs)
    if "-Demit-lib-vt=true" not in flags:
        raise SystemExit("vt_link_graph: could not read build.rs's zig flags")
    flags.append("-Dstrip=false")
    zig_env = zig_env_fields(run("zig", "env"))
    zig_lib = zig_env["lib_dir"]
    work = Path(tempfile.mkdtemp(prefix="vt-link-graph-"))
    base = work / "base"
    run("git", "init", "-q", str(base))
    run("git", "-C", str(base), "fetch", "-q", "--depth", "1", url, commit)
    graph = {
        "schema": 1, "source": path, "commit": commit, "zig": zig_env["version"],
        "flags": flags,
        "dwarfdump": next((l.strip() for l in run(args.dwarfdump, "--version").splitlines() if "version" in l.lower()), args.dwarfdump),
        "targets": {},
    }
    names = {p.package_hash: p.name for p in vt.declared_packages(base, commit)}
    for target in args.target or DEFAULT_TARGETS:
        src = work / f"src-{target}"
        cache = work / f"cache-{target}"
        (cache / "tmp").mkdir(parents=True)
        # A fresh worktree per target (no zig-pkg/); the depth-1 fetch has no
        # tags, so Ghostty's `git describe` sees none.
        run("git", "-C", str(base), "worktree", "add", "-q", "--detach", str(src), commit)
        version = re.search(r'^\s*\.version\s*=\s*"([^"]+)"', (src / "build.zig.zon").read_text(), re.M)
        command = ["zig", "build", *flags, f"-Dtarget={target}", "--prefix", str(work / f"out-{target}")]
        if version:
            command.insert(2, f"-Dversion-string={version.group(1)}")
        run(*command, cwd=src, env={**os.environ, "ZIG_GLOBAL_CACHE_DIR": str(cache)})
        [archive] = sorted((work / f"out-{target}").rglob("libghostty-vt.a"))
        sources = run(args.dwarfdump, "--show-sources", str(archive)).splitlines()
        entry = attribute(sources, str(src), str(cache), zig_lib)
        entry["names"] = {h: names.get(h, "") for h in entry["packages"]}
        entry["source_paths"] = len(sources)
        graph["targets"][target] = entry
        print(f"vt_link_graph: {target}: {len(entry['packages'])} packages, {len(sources)} source paths, "
              f"{len(entry['unattributed'])} unattributed", file=sys.stderr)
    if not args.keep:
        shutil.rmtree(work, ignore_errors=True)
    return graph


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    gen = sub.add_parser("generate")
    gen.add_argument("--repo", type=Path, default=ROOT)
    gen.add_argument("--out", type=Path, required=True)
    gen.add_argument("--target", action="append")
    gen.add_argument("--dwarfdump", default="llvm-dwarfdump")
    gen.add_argument("--keep", action="store_true", help="keep the work directory")
    args = parser.parse_args(argv)
    graph = generate(args)
    args.out.write_text(json.dumps(graph, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
