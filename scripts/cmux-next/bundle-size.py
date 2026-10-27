#!/usr/bin/env python3
"""Measures the cmux NEXT app bundle and checks it against a size budget.

    bundle-size.py report APP [--dmg DMG] [--compressed] [--json OUT]
    bundle-size.py check  APP --budget BUDGET.json --variant arm64 [--dmg DMG]
    bundle-size.py story  --app APP --out DIR [--tag TAG] [--build-config bench]

`report` prints the bundle by component: bytes on disk (file sizes, symlinks
not followed, so the CEF framework's top-level links count once) and, with
--compressed, an xz -6 estimate of what each component adds to the LZMA DMG.

`check` fails (exit 1) and names every rule that is broken:
  - a path that matches one of the variant's `forbidden` globs (files that a
    feature never reads, e.g. the x86_64 V8 snapshot in an arm64 app);
  - a component over its `components` cap;
  - the whole app over `app_max_bytes`, or the DMG over `dmg_max_bytes`.

The budget is a ratchet: when a cut lands, lower its caps to the new size
plus a little headroom, so the size never grows back unnoticed. See
plans/cmux-next/bundle-size-DESIGN.md.

`story` is the perf lab's builder story bundle-size
(scripts/perf-lab/stories.d/bundle-size.json): the size of each bench build
as cmux-perf-result/v1 in DIR, bundle.app_bytes and
bundle.cef_framework_bytes, with the report attached (bundle-size.json). The
build is the bundle's own (CMUXCommit, CMUXBuildConfiguration) and the host
is the builder's (chip and memory, no display). Exit 2 when the bundle cannot
be described truthfully; nothing is written then.
"""

from __future__ import annotations

import argparse
import fnmatch
import hashlib
import importlib.util
import json
import lzma
import os
import sys
from pathlib import Path

MIB = 1024 * 1024
HERE = Path(__file__).resolve().parent
PERF_LAB = HERE.parent / "perf-lab"
STORY = "bundle-size"
CEF_FRAMEWORK = "Contents/Frameworks/Chromium Embedded Framework.framework"
# result-v1 build.measure_version of the story: bump it when what it measures, or how, changes.
STORY_MEASURE_VERSION = 1
REPORT_FILE = "bundle-size.json"

# Components the report lists on their own; everything else in a listed
# parent folder is grouped under that parent. Paths are relative to the .app.
DEFAULT_COMPONENT_ROOTS = (
    "Contents/Frameworks",
    "Contents/Resources",
    "Contents/MacOS",
    "Contents/Library",
    "Contents/PlugIns",
    "Contents/Helpers",
    "Contents/XPCServices",
)


def walk_files(root: Path):
    """Yields (relative posix path, size) for every regular file under root."""
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        dirnames.sort()
        for name in sorted(filenames):
            p = Path(dirpath) / name
            if p.is_symlink() or not p.is_file():
                continue
            yield p.relative_to(root).as_posix(), p.stat().st_size


def all_paths(root: Path):
    """Every file, directory and symlink under root, relative, posix."""
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        for name in dirnames + filenames:
            yield (Path(dirpath) / name).relative_to(root).as_posix()


def component_of(rel: str, roots=DEFAULT_COMPONENT_ROOTS) -> str:
    """The component a file belongs to: <root>/<first child>, e.g.
    Contents/Frameworks/Chromium Embedded Framework.framework."""
    for r in roots:
        if rel == r or rel.startswith(r + "/"):
            rest = rel[len(r) + 1:]
            first = rest.split("/", 1)[0] if rest else ""
            return f"{r}/{first}" if first else r
    return rel.split("/", 2)[0] + "/" + (rel.split("/", 2)[1] if rel.count("/") else "")


def measure(app: Path) -> dict:
    """Sizes of the app by component, plus the file list."""
    if not (app / "Contents").is_dir():
        raise SystemExit(f"bundle-size: {app} is not an app bundle (no Contents/)")
    comps: dict[str, int] = {}
    files: dict[str, int] = {}
    for rel, size in walk_files(app):
        files[rel] = size
        c = component_of(rel)
        comps[c] = comps.get(c, 0) + size
    return {"app_bytes": sum(files.values()), "components": comps, "files": files}


def compressed_size(app: Path, rels: list[str]) -> int:
    """xz -6 size of the concatenated files: an estimate of DMG bytes."""
    comp = lzma.LZMACompressor(preset=6)
    n = 0
    for rel in rels:
        with open(app / rel, "rb") as f:
            while chunk := f.read(4 * MIB):
                n += len(comp.compress(chunk))
    return n + len(comp.flush())


def matches(rel: str, pattern: str) -> bool:
    """fnmatch where `**/` may also match nothing (top level)."""
    if fnmatch.fnmatchcase(rel, pattern):
        return True
    if pattern.startswith("**/"):
        return fnmatch.fnmatchcase(rel, pattern[3:])
    return False


def check(app: Path, budget: dict, variant: str, dmg: Path | None) -> list[str]:
    """The broken rules, empty when the app fits its budget."""
    try:
        rules = budget["variants"][variant]
    except KeyError:
        return [f"budget has no variant {variant!r}"]
    m = measure(app)
    problems: list[str] = []
    for pattern in rules.get("forbidden", []):
        hits = sorted(p for p in all_paths(app) if matches(p, pattern))
        for hit in hits[:5]:
            problems.append(f"forbidden: {hit} (rule {pattern})")
        if len(hits) > 5:
            problems.append(f"forbidden: {len(hits) - 5} more paths match {pattern}")
    for comp, cap in sorted(rules.get("components", {}).items()):
        size = m["components"].get(comp, 0)
        if size > cap:
            problems.append(
                f"component over budget: {comp} is {size} bytes ({size / MIB:.1f} MiB), cap {cap} ({cap / MIB:.1f} MiB)"
            )
    cap = rules.get("app_max_bytes")
    if cap is not None and m["app_bytes"] > cap:
        problems.append(f"app over budget: {m['app_bytes']} bytes ({m['app_bytes'] / MIB:.1f} MiB), cap {cap} ({cap / MIB:.1f} MiB)")
    cap = rules.get("dmg_max_bytes")
    if cap is not None:
        if dmg is None:
            problems.append("dmg_max_bytes is set but no --dmg was given")
        else:
            size = dmg.stat().st_size
            if size > cap:
                problems.append(f"DMG over budget: {dmg.name} is {size} bytes ({size / MIB:.1f} MiB), cap {cap} ({cap / MIB:.1f} MiB)")
    return problems


def report(app: Path, dmg: Path | None, compressed: bool) -> dict:
    m = measure(app)
    rows = []
    by_comp: dict[str, list[str]] = {}
    for rel in m["files"]:
        by_comp.setdefault(component_of(rel), []).append(rel)
    for comp, size in sorted(m["components"].items(), key=lambda kv: -kv[1]):
        row = {"component": comp, "bytes": size}
        if compressed:
            row["xz_bytes"] = compressed_size(app, by_comp[comp])
        rows.append(row)
    out = {"app": app.name, "app_bytes": m["app_bytes"], "components": rows}
    if dmg is not None:
        out["dmg"] = dmg.name
        out["dmg_bytes"] = dmg.stat().st_size
    return out


def print_report(r: dict) -> None:
    print(f"{r['app']}: {r['app_bytes'] / MIB:.1f} MiB on disk")
    if "dmg_bytes" in r:
        print(f"{r['dmg']}: {r['dmg_bytes'] / MIB:.1f} MiB")
    for row in r["components"]:
        if row["bytes"] < 512 * 1024:
            continue
        xz = f"  xz {row['xz_bytes'] / MIB:7.1f} MiB" if "xz_bytes" in row else ""
        print(f"  {row['bytes'] / MIB:8.1f} MiB{xz}  {row['component']}")


class StoryError(RuntimeError):
    """The story cannot describe this bundle truthfully (no CEF framework, no build sha or config, no host)."""


def _load(name: str, path: Path):
    """The module at `path`, once per process: `python3 -I` puts no script folder on sys.path."""
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module  # before exec: a dataclass resolves its module through sys.modules
    try:
        spec.loader.exec_module(module)
    except BaseException:
        del sys.modules[name]
        raise
    return module


def story_series(app: Path) -> tuple[dict, list[tuple[str, int]]]:
    """(the report, [(metric, bytes)]) of a bench build: the whole app and its CEF framework."""
    out = report(app, None, compressed=False)
    cef = next((row["bytes"] for row in out["components"] if row["component"] == CEF_FRAMEWORK), None)
    if cef is None:
        raise StoryError(f"{app.name} has no {CEF_FRAMEWORK}: not a cmux-next bench build")
    return out, [("bundle.app_bytes", out["app_bytes"]), ("bundle.cef_framework_bytes", cef)]


def write_story(app: Path, out_dir: Path, build, host, run=None, session: str = "light") -> Path:
    """The report into OUT_DIR, then one result-v1 file of the story's metrics naming its digest. `build`, `host`
    and `run` are perf_result values (the CLI reads them from the bundle and this builder); returns the file."""
    perf_result = _load("perf_result", PERF_LAB / "perf_result.py")
    document, series = story_series(app)
    out_dir.mkdir(parents=True, exist_ok=True)
    data = (json.dumps(document, indent=1, sort_keys=True) + "\n").encode("utf-8")
    temporary = out_dir / f".{REPORT_FILE}.tmp"
    temporary.write_bytes(data)
    os.replace(temporary, out_dir / REPORT_FILE)
    attachment = perf_result.Attachment(digest=f"sha256:{hashlib.sha256(data).hexdigest()}", kind=STORY)
    run = run or perf_result.Run.start()
    results = [perf_result.Result(story=STORY, metric=metric, unit="bytes", better="lower", samples=[size],
                                  build=build, host=host, engine="none", session=session, run=run,
                                  attachments=[attachment])
               for metric, size in series]
    return perf_result.write_ndjson(out_dir, results, repo_root=HERE.parent.parent)


def story_main(a, environ=os.environ) -> int:
    """`story`: the bundle's build (bench_launch.build_sha and build_config, the runner's PERF_LAB_CONFIG or
    --build-config stated) and the builder's host block (incremental_build.host_block: chip and memory decide a
    build, a display does not)."""
    bench_launch = _load("bench_launch", HERE / "bench_launch.py")
    builder = _load("perf_lab_incremental_build", PERF_LAB / "stories" / "incremental_build.py")
    perf_result = _load("perf_result", PERF_LAB / "perf_result.py")
    app = a.app.resolve()
    try:
        if a.tag and a.tag != bench_launch.tag_of(str(app)):
            raise StoryError(f"--tag {a.tag} is not the tag of {app.name}")
        stated = a.build_config or environ.get("PERF_LAB_CONFIG") or None
        build = perf_result.Build(sha=bench_launch.build_sha(str(app), environ),
                                  config=bench_launch.build_config(str(app), bench_launch.main_binary(str(app)), stated),
                                  measure_version=STORY_MEASURE_VERSION)
        host = perf_result.Host.from_dict(builder.host_block(builder.read_host_facts()).to_dict())
        path = write_story(app, a.out, build, host, session=environ.get("PERF_LAB_SESSION") or "light")
    except (StoryError, bench_launch.RecordError, builder.StoryError, perf_result.ResultError) as error:
        print(f"bundle-size: story refused: {error}", file=sys.stderr)
        return 2
    print(f"bundle-size: {app.name}: wrote {path}")
    return 0


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("story", help="the perf lab's builder story: result-v1 sizes of a bench build")
    s.add_argument("--app", type=Path, required=True)
    s.add_argument("--out", type=Path, required=True)
    s.add_argument("--tag", help="the lab runner's tag of --app (checked against the bundle's name)")
    s.add_argument("--build-config", choices=("bench", "bench-checks", "release", "debug"),
                   help="the config of a bench-hooks bundle that does not stamp it")
    r = sub.add_parser("report")
    r.add_argument("app", type=Path)
    r.add_argument("--dmg", type=Path)
    r.add_argument("--compressed", action="store_true")
    r.add_argument("--json", type=Path)
    c = sub.add_parser("check")
    c.add_argument("app", type=Path)
    c.add_argument("--budget", type=Path, required=True)
    c.add_argument("--variant", required=True)
    c.add_argument("--dmg", type=Path)
    a = ap.parse_args(argv)
    if a.cmd == "story":
        return story_main(a)
    if a.cmd == "report":
        out = report(a.app, a.dmg, a.compressed)
        print_report(out)
        if a.json:
            a.json.write_text(json.dumps(out, indent=2) + "\n")
        return 0
    budget = json.loads(a.budget.read_text())
    problems = check(a.app, budget, a.variant, a.dmg)
    for p in problems:
        print(f"bundle-size: {p}", file=sys.stderr)
    if problems:
        print("bundle-size: over budget; see plans/cmux-next/bundle-size-DESIGN.md", file=sys.stderr)
        return 1
    print(f"bundle-size: {a.app.name} fits the {a.variant} budget")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
