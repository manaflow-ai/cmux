#!/usr/bin/env python3
"""Measures the cmux NEXT app bundle and checks it against a size budget.

    bundle-size.py report APP [--dmg DMG] [--compressed] [--json OUT]
    bundle-size.py check  APP --budget BUDGET.json --variant arm64 [--dmg DMG]
    bundle-size.py summary APP --budget BUDGET.json --variant arm64 --dmg DMG
                           [--previous-dmg-bytes N] [--json OUT]
    bundle-size.py tree   APP [--dmg DMG] [--json OUT] [--top N]

`report` prints the bundle by component: bytes on disk (file sizes, symlinks
not followed, so the CEF framework's top-level links count once) and, with
--compressed, an xz -6 estimate of what each component adds to the LZMA DMG.

`tree` is the full attribution (docs: cmuxterm-hq docs/perf/bundle-size.md):
each component, each Mach-O binary split into code, unwind tables, symbols and
signature, the bytes by kind (binaries, JS, CSS, HTML, fonts, images, wasm,
localizations, licenses), identical files shipped more than once, and the
largest files, and the app executable's code by language (Swift, Rust, C++,
Zig, C), read from the function map the app ships for in-app symbolication
(Contents/Resources/cmux-symbols.bin, written by scripts/write-app-symbol-map.py).
Its DMG column compresses every file on its own in 1 MiB LZMA
blocks, as a UDIF DMG does (its chunks are 1 MiB, so two copies of a file cost
twice in the DMG, unlike in `report --compressed`). It runs on Linux: get the
nightly's app with scripts/cmux-next/fetch-nightly-dmg.py.

`check` fails (exit 1) and names every rule that is broken:
  - a path that matches one of the variant's `forbidden` globs (files that a
    feature never reads, e.g. the x86_64 V8 snapshot in an arm64 app);
  - a component over its `components` cap;
  - the whole app over `app_max_bytes`, or the DMG over `dmg_max_bytes`.

`summary` prints the headline a nightly run shows: the DMG and app sizes, how
far each is over or under its cap, and the DMG's change since the previous
nightly (--previous-dmg-bytes, the published DMG's size). It always exits 0,
so it reports without gating.

The budget is a ratchet: when a cut lands, lower its caps to the new size
plus a little headroom, so the size never grows back unnoticed. See
plans/cmux-next/bundle-size-DESIGN.md.
"""

from __future__ import annotations

import argparse
import fnmatch
import hashlib
import json
import lzma
import os
import plistlib
import re
import struct
import sys
import zlib
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

MIB = 1024 * 1024

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


def mib(n: int) -> str:
    return f"{n / MIB:.1f} MiB"


def versus_cap(size: int, cap: int | None) -> str:
    if cap is None:
        return "no cap"
    if size > cap:
        return f"{mib(size - cap)} over its {mib(cap)} cap"
    return f"{mib(cap - size)} under its {mib(cap)} cap"


def summary(app: Path, budget: dict, variant: str, dmg: Path, previous_dmg_bytes: int | None) -> dict:
    """The sizes, caps and change a nightly run shows, and the rules it breaks."""
    rules = budget.get("variants", {}).get(variant, {})
    m = measure(app)
    dmg_bytes = dmg.stat().st_size
    out = {
        "variant": variant,
        "dmg": dmg.name,
        "dmg_bytes": dmg_bytes,
        "dmg_max_bytes": rules.get("dmg_max_bytes"),
        "app": app.name,
        "app_bytes": m["app_bytes"],
        "app_max_bytes": rules.get("app_max_bytes"),
        "previous_dmg_bytes": previous_dmg_bytes,
        "dmg_delta_bytes": None if previous_dmg_bytes is None else dmg_bytes - previous_dmg_bytes,
        "problems": check(app, budget, variant, dmg),
    }
    out["over_budget"] = bool(out["problems"])
    return out


def summary_lines(s: dict) -> list[str]:
    """Markdown for the run summary; the first line is the headline."""
    if s["dmg_delta_bytes"] is None:
        since = "no previous nightly to compare"
    else:
        d = s["dmg_delta_bytes"]
        sign = "+" if d >= 0 else "-"
        since = f"{sign}{mib(abs(d))} since the previous nightly ({mib(s['previous_dmg_bytes'])})"
    lines = [
        f"**DMG {mib(s['dmg_bytes'])}**: {versus_cap(s['dmg_bytes'], s['dmg_max_bytes'])} ({s['variant']}); {since}.",
        f"App {mib(s['app_bytes'])} on disk: {versus_cap(s['app_bytes'], s['app_max_bytes'])}.",
    ]
    if s["problems"]:
        lines.append("")
        lines.append("Over budget (cut the size, or raise the cap with a reason in the commit):")
        lines += [f"- {p}" for p in s["problems"]]
    return lines


# UDIF DMGs compress 1 MiB chunks (hdiutil ULMO), so a file's DMG cost is about
# its own 1 MiB blocks compressed one by one.
DMG_CHUNK = MIB
LZMA_RAW = [{"id": lzma.FILTER_LZMA2, "preset": 6}]

# Mach-O sections by what they are; anything else in __TEXT/__DATA counts as code and data.
UNWIND_SECTIONS = {"__eh_frame", "__gcc_except_tab", "__unwind_info"}
FONT_EXT = {".ttf", ".otf", ".woff", ".woff2"}
IMAGE_EXT = {".png", ".jpg", ".jpeg", ".gif", ".svg", ".webp", ".icns", ".tiff", ".ico", ".car", ".pdf"}
KIND_BY_EXT = {
    ".js": "JS", ".mjs": "JS", ".cjs": "JS", ".css": "CSS", ".html": "HTML", ".htm": "HTML",
    ".wasm": "wasm", ".json": "JSON", ".pak": "Chromium .pak", ".dat": "ICU/V8 data", ".bin": "data .bin",
    ".ts": "TS source", ".md": "Markdown",
}


def dmg_estimate(path: str) -> int:
    """Bytes the file adds to an LZMA UDIF DMG: each 1 MiB block compressed on its own."""
    n = 0
    with open(path, "rb") as f:
        while block := f.read(DMG_CHUNK):
            n += len(lzma.compress(block, format=lzma.FORMAT_RAW, filters=LZMA_RAW))
    return n


def sha256_of(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(4 * MIB):
            h.update(chunk)
    return h.hexdigest()


def macho_parts(data: bytes) -> dict[str, int] | None:
    """A Mach-O file's bytes split into code, unwind, symbols, signature and the rest;
    None when it is not a 64-bit Mach-O (thin or fat)."""
    if len(data) < 32:
        return None
    magic = struct.unpack(">I", data[:4])[0]
    if magic in (0xCAFEBABE, 0xCAFEBABF):  # fat (32- or 64-bit offsets): each slice, plus the fat header and alignment
        wide = magic == 0xCAFEBABF
        n = struct.unpack(">I", data[4:8])[0]
        entry = 32 if wide else 20
        if n == 0 or n > 16 or 8 + n * entry > len(data):  # Java class files share 0xCAFEBABE
            return None
        parts: dict[str, int] = {}
        for i in range(n):
            e = data[8 + entry * i: 8 + entry * (i + 1)]
            off, size = struct.unpack(">QQ", e[8:24]) if wide else struct.unpack(">II", e[8:16])
            for k, v in (macho_parts(data[off:off + size]) or {}).items():
                parts[k] = parts.get(k, 0) + v
        if not parts:
            return None
        rest = "headers, link edit and padding"
        parts[rest] = parts.get(rest, 0) + max(0, len(data) - sum(parts.values()))
        return parts
    magic = struct.unpack("<I", data[:4])[0]
    if magic != 0xFEEDFACF:
        return None
    ncmds = struct.unpack("<I", data[16:20])[0]
    parts = {"code and data": 0, "unwind tables": 0, "symbols": 0, "code signature": 0}
    off = 32
    for _ in range(ncmds):
        cmd, size = struct.unpack("<II", data[off:off + 8])
        if cmd == 0x19:  # LC_SEGMENT_64
            seg = data[off + 8: off + 24].rstrip(b"\0").decode(errors="replace")
            nsects = struct.unpack("<I", data[off + 64: off + 68])[0]
            so = off + 72
            for _s in range(nsects):
                sect = data[so: so + 16].rstrip(b"\0").decode(errors="replace")
                ssize = struct.unpack("<Q", data[so + 40: so + 48])[0]
                stype = struct.unpack("<I", data[so + 64: so + 68])[0] & 0xFF
                if stype not in (0x1, 0xC, 0x12):  # zerofill takes no file bytes
                    key = ("unwind tables" if sect in UNWIND_SECTIONS
                           else "debug info" if seg == "__DWARF" else "code and data")
                    parts[key] = parts.get(key, 0) + ssize
                so += 80
        elif cmd == 0x2:  # LC_SYMTAB
            _so, nsyms, _st, strsize = struct.unpack("<IIII", data[off + 8: off + 24])
            parts["symbols"] += nsyms * 16 + strsize
        elif cmd == 0x1D:  # LC_CODE_SIGNATURE
            parts["code signature"] += struct.unpack("<I", data[off + 12: off + 16])[0]
        off += size
    parts["headers, link edit and padding"] = max(0, len(data) - sum(parts.values()))
    return parts


def kind_of(rel: str) -> str:
    """What a non-Mach-O file is, for the by-kind table."""
    low = rel.lower()
    name = low.rsplit("/", 1)[-1]
    ext = os.path.splitext(name)[1]
    if ".lproj/" in low or "/locales/" in low or "/_locales/" in low:
        return "localizations"
    if "licen" in low or name.startswith(("copying", "notice", "credits")):
        return "licenses"
    if ".dsym/" in low:
        return "debug info"
    if "/_codesignature/" in low or name in ("coderesources", "embedded.provisionprofile"):
        return "code signature"
    if ext in FONT_EXT:
        return "fonts"
    if ext in IMAGE_EXT:
        return "images"
    return KIND_BY_EXT.get(ext, "other")


def file_facts(job: tuple[str, str]) -> dict:
    """One file's size, DMG estimate, hash and, for Mach-O, its parts (runs in a worker)."""
    root, rel = job
    path = os.path.join(root, rel)
    with open(path, "rb") as f:
        head = f.read(4)
    facts = {"rel": rel, "bytes": os.path.getsize(path), "dmg": dmg_estimate(path), "sha256": sha256_of(path)}
    if head in (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"):
        with open(path, "rb") as f:
            try:
                facts["macho"] = macho_parts(f.read())
            except struct.error:  # truncated load commands: counted as a plain file
                facts["macho"] = None
    return facts


SYMBOL_MAP = "Contents/Resources/cmux-symbols.bin"
# Unmangled names that are not C: Ghostty's C API is Zig, the app's Rust crates export C-ABI
# entry points, and Swift emits a few helpers without its mangling.
ZIG_PREFIXES = ("ghostty_",)
RUST_PREFIXES = ("cmux_", "uniffi_", "ffi_", "rust_")
SWIFT_PREFIXES = ("objectdestroy", "__swift_", "swift_")
RUST_LEGACY = re.compile(r"17h[0-9a-f]{16}E$")


def symbol_language(name: str) -> str:
    """The language a symbol map name was compiled from, by its mangling."""
    if name.startswith(("$s", "_$s", "$S")) or name.startswith(SWIFT_PREFIXES):
        return "Swift"
    if name.startswith("_R") or (name.startswith("_ZN") and RUST_LEGACY.search(name)) or name.startswith(RUST_PREFIXES):
        return "Rust"
    if name.startswith("_Z"):
        return "C++"
    if name.startswith(("-[", "+[")):
        return "Objective-C"
    if name.startswith(ZIG_PREFIXES):
        return "Zig"
    return "C and other"


def code_by_language(data: bytes) -> dict[str, int] | None:
    """__TEXT,__text bytes by language from a cmux-symbols.bin (its first slice), or None.

    The map names every function the linker kept a symbol for. A function with none (a static
    Zig or C function) counts toward the named one before it, so the Zig and C rows are close,
    not exact; Swift and Rust keep their names.
    """
    if data[:8] != b"CMXSYM1\0" or len(data) < 32:
        return None
    try:
        size, = struct.unpack_from("<I", data, 28)
        payload = zlib.decompress(data[32:32 + size], -15)
        count, = struct.unpack_from("<I", payload, 0)
        at, offsets, current = 4, [], 0
        for _ in range(count):
            value = shift = 0
            while True:
                byte = payload[at]
                at += 1
                value |= (byte & 0x7F) << shift
                shift += 7
                if not byte & 0x80:
                    break
            current += value
            offsets.append(current)
    except (struct.error, zlib.error, IndexError):
        return None
    names = payload[at:].split(b"\0")
    if len(names) < count:
        return None
    out: dict[str, int] = {}
    for i in range(count - 1):
        language = symbol_language(names[i].decode("latin-1"))
        out[language] = out.get(language, 0) + offsets[i + 1] - offsets[i]
    return dict(sorted(out.items(), key=lambda kv: -kv[1]))


def app_executable(app: Path) -> str:
    """Contents/MacOS/<CFBundleExecutable>, or the app's name when Info.plist does not say."""
    try:
        with open(app / "Contents/Info.plist", "rb") as f:
            name = plistlib.load(f).get("CFBundleExecutable")
    except (OSError, plistlib.InvalidFileException, ValueError):
        name = None
    return f"Contents/MacOS/{name if isinstance(name, str) and name else app.stem}"


def tree(app: Path, dmg: Path | None, top: int, jobs: int | None = None) -> dict:
    """The full attribution of the app (see `tree` in the module doc)."""
    if not (app / "Contents").is_dir():
        raise SystemExit(f"bundle-size: {app} is not an app bundle (no Contents/)")
    rels = [rel for rel, _ in walk_files(app)]
    with ProcessPoolExecutor(max_workers=jobs) as pool:
        facts = list(pool.map(file_facts, [(str(app), r) for r in rels], chunksize=16))
    comps: dict[str, dict] = {}
    kinds: dict[str, dict] = {}
    binaries = []
    by_hash: dict[str, list[dict]] = {}

    def add(table: dict, key: str, size: int, est: int) -> None:
        row = table.setdefault(key, {"bytes": 0, "dmg_bytes": 0, "files": 0})
        row["bytes"] += size
        row["dmg_bytes"] += est
        row["files"] += 1

    for f in facts:
        add(comps, component_of(f["rel"]), f["bytes"], f["dmg"])
        by_hash.setdefault(f["sha256"], []).append(f)
        parts = f.get("macho")
        if parts:
            binaries.append({"path": f["rel"], "bytes": f["bytes"], "dmg_bytes": f["dmg"], "parts": parts})
            # A binary's DMG bytes are shared out by its parts' sizes.
            for k, v in parts.items():
                share = round(f["dmg"] * v / f["bytes"]) if f["bytes"] else 0
                row = kinds.setdefault(f"Mach-O {k}", {"bytes": 0, "dmg_bytes": 0, "files": 0})
                row["bytes"] += v
                row["dmg_bytes"] += share
            kinds.setdefault("Mach-O code and data", {"bytes": 0, "dmg_bytes": 0, "files": 0})["files"] += 1
        else:
            add(kinds, kind_of(f["rel"]), f["bytes"], f["dmg"])
    dup_groups = []
    for group in by_hash.values():
        if len(group) > 1 and group[0]["bytes"] > 0:
            dup_groups.append({
                "bytes_each": group[0]["bytes"],
                "copies": len(group),
                "extra_bytes": group[0]["bytes"] * (len(group) - 1),
                "extra_dmg_bytes": group[0]["dmg"] * (len(group) - 1),
                "paths": sorted(g["rel"] for g in group),
            })
    dup_groups.sort(key=lambda g: -g["extra_bytes"])

    def rows(table: dict, label: str) -> list[dict]:
        return [{label: k, **v} for k, v in sorted(table.items(), key=lambda kv: -kv[1]["bytes"])]

    out = {
        "app": app.name,
        "app_bytes": sum(f["bytes"] for f in facts),
        "dmg_estimate_bytes": sum(f["dmg"] for f in facts),
        "files": len(facts),
        "components": rows(comps, "component"),
        "kinds": rows(kinds, "kind"),
        "binaries": sorted(binaries, key=lambda b: -b["bytes"]),
        "duplicates": {
            "extra_bytes": sum(g["extra_bytes"] for g in dup_groups),
            "extra_dmg_bytes": sum(g["extra_dmg_bytes"] for g in dup_groups),
            "groups": dup_groups[:top],
        },
        "largest_files": [{"path": f["rel"], "bytes": f["bytes"], "dmg_bytes": f["dmg"]}
                          for f in sorted(facts, key=lambda f: -f["bytes"])[:top]],
    }
    symbol_map = app / SYMBOL_MAP
    languages = code_by_language(symbol_map.read_bytes()) if symbol_map.is_file() else None
    if languages:
        out["code_by_language"] = {"binary": app_executable(app), "source": SYMBOL_MAP, "bytes": languages}
    if dmg is not None:
        out["dmg"] = dmg.name
        out["dmg_bytes"] = dmg.stat().st_size
    return out


def print_tree(t: dict, top: int) -> None:
    """The attribution as Markdown tables (MB = 10^6 bytes, as the doc uses)."""
    def mb(n: int) -> str:
        return f"{n / 1e6:.1f}"

    print(f"**{t['app']}**: {mb(t['app_bytes'])} MB on disk in {t['files']} files; "
          f"DMG estimate {mb(t['dmg_estimate_bytes'])} MB"
          + (f" (actual {t['dmg']}: {mb(t['dmg_bytes'])} MB)" if "dmg_bytes" in t else "") + ".")
    print("\n| Component | On disk (MB) | In DMG (MB) | Files |\n|---|---:|---:|---:|")
    for r in t["components"][:top]:
        print(f"| `{r['component']}` | {mb(r['bytes'])} | {mb(r['dmg_bytes'])} | {r['files']} |")
    print("\n| Kind | On disk (MB) | In DMG (MB) |\n|---|---:|---:|")
    for r in t["kinds"]:
        print(f"| {r['kind']} | {mb(r['bytes'])} | {mb(r['dmg_bytes'])} |")
    print("\n| Binary | On disk (MB) | In DMG (MB) | Code+data | Unwind | Symbols | Signature |\n|---|---:|---:|---:|---:|---:|---:|")
    for b in t["binaries"][:top]:
        p = b["parts"]
        print(f"| `{b['path']}` | {mb(b['bytes'])} | {mb(b['dmg_bytes'])} | {mb(p.get('code and data', 0))} | "
              f"{mb(p.get('unwind tables', 0))} | {mb(p.get('symbols', 0))} | {mb(p.get('code signature', 0))} |")
    lang = t.get("code_by_language")
    if lang:
        total = sum(lang["bytes"].values()) or 1
        print(f"\n`{lang['binary']}` code (`__text`) by language, from `{lang['source']}`:")
        print("\n| Language | MB | Share |\n|---|---:|---:|")
        for name, n in lang["bytes"].items():
            print(f"| {name} | {mb(n)} | {100 * n / total:.1f}% |")
    d = t["duplicates"]
    print(f"\nIdentical files shipped more than once: {mb(d['extra_bytes'])} MB extra on disk, "
          f"{mb(d['extra_dmg_bytes'])} MB in the DMG.")
    for g in d["groups"][:10]:
        print(f"- {g['copies']}x {g['bytes_each']} bytes: `{g['paths'][0]}`, `{g['paths'][1]}`")


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
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
    s = sub.add_parser("summary")
    s.add_argument("app", type=Path)
    s.add_argument("--budget", type=Path, required=True)
    s.add_argument("--variant", required=True)
    s.add_argument("--dmg", type=Path, required=True)
    s.add_argument("--previous-dmg-bytes", type=int)
    s.add_argument("--json", type=Path)
    t = sub.add_parser("tree")
    t.add_argument("app", type=Path)
    t.add_argument("--dmg", type=Path)
    t.add_argument("--json", type=Path)
    t.add_argument("--top", type=int, default=30)
    t.add_argument("--jobs", type=int)
    a = ap.parse_args(argv)
    if a.cmd == "tree":
        out = tree(a.app, a.dmg, a.top, a.jobs)
        print_tree(out, a.top)
        if a.json:
            a.json.write_text(json.dumps(out, indent=2) + "\n")
        return 0
    if a.cmd == "report":
        out = report(a.app, a.dmg, a.compressed)
        print_report(out)
        if a.json:
            a.json.write_text(json.dumps(out, indent=2) + "\n")
        return 0
    budget = json.loads(a.budget.read_text())
    if a.cmd == "summary":
        out = summary(a.app, budget, a.variant, a.dmg, a.previous_dmg_bytes)
        print("\n".join(summary_lines(out)))
        if a.json:
            a.json.write_text(json.dumps(out, indent=2) + "\n")
        return 0
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
