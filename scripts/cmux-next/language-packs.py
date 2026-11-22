#!/usr/bin/env python3
"""Languages download on first use (CMUX-570): split an app's non-English strings and Chromium
locale paks into packs.

Usage (stdlib only; run with `python3 -I`):
  language-packs.py split APP OUT --base-url https://files-next.cmux.com/language-packs [--keep LANG ...]
  language-packs.py measure APP [--keep LANG ...]

Languages are APP/Contents/Info.plist CFBundleLocalizations minus "en", plus one per Chromium locale
pak in APP/Contents/Resources/ChromiumLocales (minus --keep). Only the CmuxNext package's SwiftPM
resource bundles (APP/Contents/Resources/CmuxNext_*.bundle) and those paks are split; every other
bundle, framework, Sparkle and uBlock stays in the app. Inside those bundles it takes each L.lproj
and each web page string table split per language (.../locales/L.js, the Settings page and the agent
pane; English and loader.js stay).

Chromium locale paks: scripts/cmux-next/embed-cef.sh moves every Chromium locale but en (en-US, the
fallback, stays in the framework) out of the framework to ChromiumLocales/<catalog>.lproj/locale.pak
when the pinned CEF loads locale paks from outside its framework (cef-manifest.json
"locale_paks_outside_framework"). A catalog joins the pack of the cmux language it serves
(zh_CN -> zh-Hans, zh_TW -> zh-Hant, pt_BR -> pt-BR, de -> de); a catalog with no cmux strings
(en_GB, es_419, pt_PT, sv, ...) is a pack of its own, named with its BCP 47 tag (en-GB, es-419,
pt-PT, sv). The pin says what a pack carries: "chromium" is its catalog, "strings" whether it has
cmux strings (a language without them shows Chromium's pages translated and cmux in English).

split moves each B/Contents/Resources/L.lproj into OUT/stage/L/B/Contents/Resources/L.lproj (with a
copy of B/Contents/Info.plist), packs each language deterministically (sorted tar entries, mtime 0,
uid/gid 0, mode 0644 files and 0755 dirs, no symlinks, paths relative to Contents/Resources, then
zstd -19 with no long-distance window, so any zstd decoder with its default window reads it) into
OUT/L.tar.zst, and writes the pins, content addressed (<base-url>/<sha256>/L.tar.zst), to
APP/Contents/Resources/language-packs.json and OUT/language-packs.json:
  {"version": 1, "packs": {"de": {"chromium": "de", "sha256": ..., "size": ..., "strings": true,
                               "url": ...}, ...}}
Run it after the app's inner code is signed and before the app itself is sealed
(scripts/sign-cmux-bundle.sh step 4, CMUX_NEXT_LANGUAGE_PACKS=1); the resource bundles carry no
signature of their own, so the outer seal covers what is left. scripts/cmux-next/publish-language-packs.sh
uploads OUT before the appcast names the app.

measure selects the same files without moving anything and prints files and bytes per language,
the total installed bytes a split removes, and the packed size.
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tarfile

BUNDLE_GLOB = "CmuxNext_*.bundle"
# Web page string tables split one file per language (webviews/scripts/pages/split-strings.mjs):
# BUNDLE/Contents/Resources/<...>/locales/<lang>.js. The page's loader asks for its language's file
# and the app serves it from the active pack (Bundle.languagePackFile); English and loader.js stay.
WEB_LOCALES_DIR = "locales"
CHROMIUM_DIR = "ChromiumLocales"
# The cmux languages whose Chromium catalog is not their own tag with "_" for "-".
CHROMIUM_CATALOG = {"zh-Hans": "zh_CN", "zh-Hant": "zh_TW"}
CATALOG_RE = re.compile(r"[a-z]{2,3}(_[A-Z0-9][A-Za-z0-9]{1,7})?")
PIN_NAME = "language-packs.json"
ZSTD_LEVEL = 19
LANG_RE = re.compile(r"[A-Za-z]{2,3}([-_][A-Za-z0-9]{2,8})*")


def die(message: str) -> None:
    print(f"language-packs: {message}", file=sys.stderr)
    sys.exit(1)


def languages(app: Path, keep: list[str]) -> list[str]:
    info = app / "Contents" / "Info.plist"
    if not info.is_file():
        die(f"no {info}")
    with info.open("rb") as handle:
        listed = plistlib.load(handle).get("CFBundleLocalizations") or []
    if not isinstance(listed, list) or not all(isinstance(lang, str) for lang in listed):
        die(f"{info}: CFBundleLocalizations is not a list of strings")
    skip = {"en", *keep}
    chosen = sorted({lang for lang in listed if lang not in skip})
    for lang in chosen:
        if not LANG_RE.fullmatch(lang):
            die(f"{info}: unexpected localization name {lang!r}")
    return chosen


def catalog_for(lang: str) -> str:
    """The Chromium catalog that serves the cmux language `lang` (pt-BR -> pt_BR)."""
    return CHROMIUM_CATALOG.get(lang, lang.replace("-", "_"))


def chromium_catalogs(app: Path) -> dict[str, Path]:
    """{catalog: its .lproj} under Contents/Resources/ChromiumLocales: one locale.pak each, never en."""
    root = app / "Contents" / "Resources" / CHROMIUM_DIR
    if not root.exists():
        return {}
    if root.is_symlink() or not root.is_dir():
        die(f"{root} is not a directory")
    found = {}
    for entry in sorted(root.iterdir()):
        name = entry.name[: -len(".lproj")] if entry.name.endswith(".lproj") else ""
        if not CATALOG_RE.fullmatch(name) or name == "en":
            die(f"{entry}: not a Chromium locale catalog that downloads (en stays in the framework)")
        if entry.is_symlink() or not entry.is_dir():
            die(f"{entry} is not a directory")
        files = lproj_files(entry)
        if [f.name for f in files] != ["locale.pak"]:
            die(f"{entry} holds {[f.name for f in files]}, not one locale.pak")
        found[name] = entry
    return found


def bundles(app: Path) -> list[Path]:
    found = sorted((app / "Contents" / "Resources").glob(BUNDLE_GLOB))
    if not found:
        die(f"no {BUNDLE_GLOB} under {app}/Contents/Resources")
    for bundle in found:
        if bundle.is_symlink() or not bundle.is_dir():
            die(f"{bundle} is not a directory")
        if (bundle / "Contents" / "_CodeSignature").exists():
            # A signed nested bundle would need re-signing after its .lproj leave; none is today.
            die(f"{bundle} is signed on its own; split it before it is signed")
    return found


def lproj_files(lproj: Path) -> list[Path]:
    """Every file under an .lproj, refusing symlinks and anything that is not a file or directory."""
    files = []
    for root, dirs, names in os.walk(lproj):
        for name in dirs + names:
            path = Path(root) / name
            if path.is_symlink():
                die(f"{path} is a symlink; language packs carry none")
        for name in names:
            path = Path(root) / name
            if not path.is_file():
                die(f"{path} is not a regular file")
            files.append(path)
    return sorted(files)


def selection(app: Path, keep: list[str]):
    """{lang: [(bundle, lproj, [files])]}, {lang: its Chromium .lproj} and the .lproj names no pack
    takes (for the summary)."""
    langs = languages(app, keep)
    chosen: dict[str, list] = {lang: [] for lang in langs}
    chromium: dict[str, Path] = {}
    # Every listed language, kept ones too: a kept zh-Hans keeps its zh_CN pak in the app.
    serves = {catalog_for(lang): lang for lang in languages(app, [])}
    for catalog, lproj in chromium_catalogs(app).items():
        lang = serves.get(catalog, catalog.replace("_", "-"))
        if lang in keep:
            continue
        if not LANG_RE.fullmatch(lang):
            die(f"{lproj}: unexpected Chromium locale name {catalog!r}")
        chosen.setdefault(lang, [])
        chromium[lang] = lproj
    left: set[str] = set()
    for bundle in bundles(app):
        resources = bundle / "Contents" / "Resources"
        if not resources.is_dir():
            continue
        for lproj in sorted(resources.glob("*.lproj")):
            lang = lproj.name[: -len(".lproj")]
            if lang in chosen:
                if lproj.is_symlink() or not lproj.is_dir():
                    die(f"{lproj} is not a directory")
                chosen[lang].append((bundle, lproj, lproj_files(lproj)))
            else:
                left.add(lang)
        for locales in sorted(p for p in resources.rglob(WEB_LOCALES_DIR) if p.is_dir() and not p.is_symlink()):
            for lang in chosen:
                web = locales / f"{lang}.js"
                if web.is_symlink():
                    die(f"{web} is a symlink; language packs carry none")
                if web.is_file():
                    chosen[lang].append((bundle, web, [web]))
    return dict(sorted(chosen.items())), chromium, sorted(left)


def tar_bytes(entries: list[tuple[str, Path | None]]) -> bytes:
    """A deterministic tar of (relative path, source file or None for a directory)."""
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w", format=tarfile.PAX_FORMAT) as tar:
        for name, source in sorted(entries, key=lambda entry: entry[0]):
            info = tarfile.TarInfo(name)
            info.mtime = 0
            info.uid = info.gid = 0
            info.uname = info.gname = ""
            if source is None:
                info.type = tarfile.DIRTYPE
                info.mode = 0o755
                tar.addfile(info)
            else:
                data = source.read_bytes()
                info.type = tarfile.REGTYPE
                info.mode = 0o644
                info.size = len(data)
                tar.addfile(info, io.BytesIO(data))
    return buffer.getvalue()


def pack_entries(items, chromium: Path | None = None) -> list[tuple[str, Path | None]]:
    """One language's tar entries, named relative to Contents/Resources of the app:
    each bundle's directories down to each moved .lproj or web locale file, its Info.plist, and the
    moved files; and ChromiumLocales/<catalog>.lproj/locale.pak."""
    entries: dict[str, Path | None] = {}
    if chromium is not None:
        entries[CHROMIUM_DIR] = None
        entries[f"{CHROMIUM_DIR}/{chromium.name}"] = None
        entries[f"{CHROMIUM_DIR}/{chromium.name}/locale.pak"] = chromium / "locale.pak"
    for bundle, top, files in items:
        base = bundle.parent
        directories = [d for d in [top, *top.parents] if d == bundle or bundle in d.parents]
        directories = [d for d in directories if d.is_dir()]
        if top.is_dir():
            directories += [p for p in top.rglob("*") if p.is_dir() and not p.is_symlink()]
        for directory in directories:
            entries[directory.relative_to(base).as_posix()] = None
        entries[f"{bundle.name}/Contents/Info.plist"] = bundle / "Contents" / "Info.plist"
        for path in files:
            entries[path.relative_to(base).as_posix()] = path
    return list(entries.items())


def zstd_compress(data: bytes) -> bytes:
    """zstd -19 (no --long: the daemon's decoder keeps its default window). The zstd CLI
    (Homebrew on the signing Macs, the zstd package on Linux) or Python 3.14's compression.zstd."""
    cli = shutil.which("zstd") or next((p for p in ("/opt/homebrew/bin/zstd", "/usr/local/bin/zstd")
                                        if os.access(p, os.X_OK)), None)
    if cli:
        done = subprocess.run([cli, f"-{ZSTD_LEVEL}", "-q", "-c", "--no-progress"], input=data,
                              stdout=subprocess.PIPE, check=False)
        if done.returncode != 0:
            die(f"{cli} failed with status {done.returncode}")
        return done.stdout
    try:
        from compression import zstd  # Python 3.14+
    except ImportError:
        die("no zstd: install the zstd CLI (brew install zstd, apt-get install zstd) or run Python 3.14+")
    return zstd.compress(data, level=ZSTD_LEVEL)


def mb(size: int) -> str:
    return f"{size / 1_000_000:.2f} MB"


def measure(args) -> None:
    app = Path(args.app)
    chosen, chromium, left = selection(app, args.keep)
    total_files = total_bytes = total_packed = total_chromium = 0
    print(f"{'lang':<8} {'bundles':>7} {'files':>6} {'chromium':>9} {'installed':>12} {'packed':>12}")
    for lang, items in chosen.items():
        pak = chromium.get(lang)
        files = [f for _, _, fs in items for f in fs] + ([pak / "locale.pak"] if pak else [])
        size = sum(f.stat().st_size for f in files)
        total_chromium += (pak / "locale.pak").stat().st_size if pak else 0
        packed = len(zstd_compress(tar_bytes(pack_entries(items, pak)))) if files else 0
        catalog = pak.name[: -len(".lproj")] if pak else "-"
        print(f"{lang:<8} {len(items):>7} {len(files):>6} {catalog:>9} {size:>12} {packed:>12}")
        total_files += len(files)
        total_bytes += size
        total_packed += packed
    print(f"{'total':<8} {'':>7} {total_files:>6} {len(chromium):>9} {total_bytes:>12} {total_packed:>12}")
    print(f"{len(chosen)} languages: {total_files} files, {mb(total_bytes)} installed bytes removed "
          f"({mb(total_chromium)} of them {len(chromium)} Chromium locale paks), {mb(total_packed)} of packs")
    if left:
        print(f"kept in the app: {', '.join(name + '.lproj' for name in left)}")


def check_base_url(url: str) -> str:
    if not (url.startswith("https://") or re.match(r"http://(localhost|127\.0\.0\.1)(:\d+)?(/|$)", url)):
        die(f"--base-url must be https (or http to localhost for tests): {url!r}")
    return url.rstrip("/")


def split(args) -> None:
    app = Path(args.app)
    out = Path(args.out)
    base_url = check_base_url(args.base_url)
    app_pin = app / "Contents" / "Resources" / PIN_NAME
    if app_pin.exists():
        die(f"{app_pin} exists: this app was split already")
    if out.exists() and any(out.iterdir()):
        die(f"{out} is not empty")
    chosen, chromium, left = selection(app, args.keep)
    stage = out / "stage"
    stage.mkdir(parents=True)
    packs = {}
    total_bytes = total_files = 0
    for lang, items in chosen.items():
        pak = chromium.get(lang)
        if not items and pak is None:
            print(f"==> {lang}: no {lang}.lproj or {WEB_LOCALES_DIR}/{lang}.js in any {BUNDLE_GLOB} and no Chromium pak; no pack")
            continue
        # Packed from the app (the same entries measure reads), then moved out of it.
        data = zstd_compress(tar_bytes(pack_entries(items, pak)))
        stage_lang = stage / lang
        moved = 0
        if pak is not None:
            moved += (pak / "locale.pak").stat().st_size
            total_files += 1
            (stage_lang / CHROMIUM_DIR).mkdir(parents=True, exist_ok=True)
            shutil.move(str(pak), str(stage_lang / CHROMIUM_DIR / pak.name))
        for bundle, top, files in items:
            moved += sum(f.stat().st_size for f in files)
            total_files += len(files)
            dest = stage_lang / top.relative_to(bundle.parent)
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(bundle / "Contents" / "Info.plist", stage_lang / bundle.name / "Contents" / "Info.plist")
            shutil.move(str(top), str(dest))
        asset = out / f"{lang}.tar.zst"
        asset.write_bytes(data)
        sha = hashlib.sha256(data).hexdigest()
        packs[lang] = {"sha256": sha, "size": len(data), "strings": bool(items),
                       "url": f"{base_url}/{sha}/{lang}.tar.zst"}
        if pak is not None:
            packs[lang]["chromium"] = pak.name[: -len(".lproj")]
        total_bytes += moved
        print(f"==> {lang}: {len(items)} bundles, Chromium {packs[lang].get('chromium', '-')}, "
              f"{moved} bytes moved, pack {len(data)} bytes ({sha[:12]})")
    chromium_dir = app / "Contents" / "Resources" / CHROMIUM_DIR
    if chromium_dir.is_dir() and not any(chromium_dir.iterdir()):
        chromium_dir.rmdir()
    pin = json.dumps({"version": 1, "packs": packs}, indent=2, sort_keys=True) + "\n"
    (out / PIN_NAME).write_text(pin)
    app_pin.write_text(pin)
    packed = sum(p["size"] for p in packs.values())
    print(f"==> {len(packs)} language packs: {total_files} files, {total_bytes} bytes ({mb(total_bytes)}) "
          f"removed from the app, {packed} bytes ({mb(packed)}) of packs; pin {app_pin}")
    if left:
        print(f"kept in the app: {', '.join(name + '.lproj' for name in left)}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    s = sub.add_parser("split")
    s.add_argument("app")
    s.add_argument("out")
    s.add_argument("--base-url", required=True)
    s.add_argument("--keep", nargs="+", default=[], metavar="LANG")
    s.set_defaults(run=split)
    m = sub.add_parser("measure")
    m.add_argument("app")
    m.add_argument("--keep", nargs="+", default=[], metavar="LANG")
    m.set_defaults(run=measure)
    args = parser.parse_args()
    args.run(args)


if __name__ == "__main__":
    main()
