#!/usr/bin/env python3
"""Behavior tests of scripts/cmux-next/bundle-size.py on small synthetic apps."""

from __future__ import annotations

import json
import os
import plistlib
import struct
import subprocess
import sys
import tempfile
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
TOOL = ROOT / "scripts/cmux-next/bundle-size.py"
REAL_BUDGET = ROOT / "scripts/cmux-next/bundle-size-budget.json"
CEF = "Contents/Frameworks/Chromium Embedded Framework.framework"


def write(app: Path, rel: str, size: int) -> None:
    p = app / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_bytes(b"x" * size)


def run(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, "-I", str(TOOL), *args], capture_output=True, text=True)


def make_app(tmp: Path) -> Path:
    app = tmp / "cmux NEXT.app"
    write(app, "Contents/MacOS/cmux", 1000)
    write(app, f"{CEF}/Versions/A/Chromium Embedded Framework", 3000)
    write(app, f"{CEF}/Versions/A/Resources/v8_context_snapshot.arm64.bin", 100)
    # The framework's top-level links must not count twice.
    os.symlink("A", app / CEF / "Versions/Current")
    os.symlink("Versions/Current/Chromium Embedded Framework", app / CEF / "Chromium Embedded Framework")
    write(app, "Contents/Resources/bin/cmux", 500)
    return app


def budget(tmp: Path, **rules) -> Path:
    p = tmp / "budget.json"
    p.write_text(json.dumps({"schema": 1, "variants": {"arm64": rules}}))
    return p


def test_report_counts_files_once_per_component(tmp: Path) -> None:
    app = make_app(tmp)
    out = tmp / "r.json"
    r = run("report", str(app), "--json", str(out))
    assert r.returncode == 0, r.stderr
    data = json.loads(out.read_text())
    sizes = {c["component"]: c["bytes"] for c in data["components"]}
    assert sizes[CEF] == 3100, sizes
    assert sizes["Contents/MacOS/cmux"] == 1000
    assert sizes["Contents/Resources/bin"] == 500
    assert data["app_bytes"] == 4600


def test_fits_budget(tmp: Path) -> None:
    app = make_app(tmp)
    b = budget(tmp, app_max_bytes=5000, components={CEF: 3100}, forbidden=["**/*.map"])
    r = run("check", str(app), "--budget", str(b), "--variant", "arm64")
    assert r.returncode == 0, r.stderr
    assert "fits" in r.stdout


def test_forbidden_file_fails_and_is_named(tmp: Path) -> None:
    app = make_app(tmp)
    snap = f"{CEF}/Versions/A/Resources/v8_context_snapshot.x86_64.bin"
    write(app, snap, 100)
    write(app, "Contents/Resources/markdown-viewer/app.js.map", 10)
    b = budget(tmp, forbidden=[snap, "**/*.map"])
    r = run("check", str(app), "--budget", str(b), "--variant", "arm64")
    assert r.returncode == 1
    assert f"forbidden: {snap}" in r.stderr, r.stderr
    assert "forbidden: Contents/Resources/markdown-viewer/app.js.map" in r.stderr, r.stderr


def test_component_app_and_dmg_caps(tmp: Path) -> None:
    app = make_app(tmp)
    dmg = tmp / "x.dmg"
    dmg.write_bytes(b"d" * 50)
    b = budget(tmp, app_max_bytes=4599, dmg_max_bytes=49, components={"Contents/MacOS/cmux": 999})
    r = run("check", str(app), "--budget", str(b), "--variant", "arm64", "--dmg", str(dmg))
    assert r.returncode == 1
    assert "component over budget: Contents/MacOS/cmux is 1000 bytes" in r.stderr, r.stderr
    assert "app over budget: 4600 bytes" in r.stderr, r.stderr
    assert "DMG over budget: x.dmg is 50 bytes" in r.stderr, r.stderr


def test_dmg_cap_without_dmg_fails(tmp: Path) -> None:
    app = make_app(tmp)
    b = budget(tmp, dmg_max_bytes=10)
    r = run("check", str(app), "--budget", str(b), "--variant", "arm64")
    assert r.returncode == 1
    assert "no --dmg" in r.stderr


def test_unknown_variant_fails(tmp: Path) -> None:
    app = make_app(tmp)
    r = run("check", str(app), "--budget", str(budget(tmp)), "--variant", "x86_64")
    assert r.returncode == 1
    assert "no variant 'x86_64'" in r.stderr


def test_real_budget_rejects_the_x86_64_snapshot(tmp: Path) -> None:
    # The checked-in arm64 budget, on an app that is small enough but still
    # carries the Intel V8 snapshot an older nightly-next (50af7da) shipped.
    app = make_app(tmp)
    write(app, f"{CEF}/Versions/A/Resources/v8_context_snapshot.x86_64.bin", 100)
    dmg = tmp / "x.dmg"
    dmg.write_bytes(b"d")
    r = run("check", str(app), "--budget", str(REAL_BUDGET), "--variant", "arm64", "--dmg", str(dmg))
    assert r.returncode == 1
    assert "v8_context_snapshot.x86_64.bin" in r.stderr, r.stderr


def test_summary_names_the_overage_and_the_change_and_exits_0(tmp: Path) -> None:
    # Over budget is reported, not gated: the nightly shows it on every run.
    app = make_app(tmp)
    dmg = tmp / "x.dmg"
    dmg.write_bytes(b"d" * (3 * 1024 * 1024))
    b = budget(tmp, app_max_bytes=5000, dmg_max_bytes=2 * 1024 * 1024)
    out = tmp / "s.json"
    r = run("summary", str(app), "--budget", str(b), "--variant", "arm64", "--dmg", str(dmg),
            "--previous-dmg-bytes", str(2 * 1024 * 1024 + 512 * 1024), "--json", str(out))
    assert r.returncode == 0, r.stderr
    head = r.stdout.splitlines()[0]
    assert head == ("**DMG 3.0 MiB**: 1.0 MiB over its 2.0 MiB cap (arm64); "
                    "+0.5 MiB since the previous nightly (2.5 MiB)."), head
    assert "- DMG over budget: x.dmg" in r.stdout, r.stdout
    data = json.loads(out.read_text())
    assert data["over_budget"] is True
    assert data["dmg_delta_bytes"] == 512 * 1024
    assert data["app_bytes"] == 4600 and data["app_max_bytes"] == 5000


def test_summary_under_budget_without_a_previous_nightly(tmp: Path) -> None:
    app = make_app(tmp)
    dmg = tmp / "x.dmg"
    dmg.write_bytes(b"d" * 10)
    b = budget(tmp, app_max_bytes=5000, dmg_max_bytes=1024 * 1024)
    r = run("summary", str(app), "--budget", str(b), "--variant", "arm64", "--dmg", str(dmg))
    assert r.returncode == 0, r.stderr
    assert "under its 1.0 MiB cap (arm64); no previous nightly to compare." in r.stdout, r.stdout
    assert "Over budget" not in r.stdout, r.stdout


def macho(text: int, unwind: int, symbols: int, strsize: int) -> bytes:
    """A minimal arm64 Mach-O: __TEXT with __text and __eh_frame, and a symbol table."""
    import struct
    sect = lambda name, size: (name.ljust(16, b"\0") + b"__TEXT".ljust(16, b"\0")
                               + struct.pack("<QQIIIIIIII", 0, size, 0, 0, 0, 0, 0, 0, 0, 0))
    seg = struct.pack("<II", 0x19, 72 + 2 * 80) + b"__TEXT".ljust(16, b"\0") + struct.pack(
        "<QQQQiiII", 0, 0, 0, text + unwind, 5, 5, 2, 0) + sect(b"__text", text) + sect(b"__eh_frame", unwind)
    symtab = struct.pack("<IIIIII", 0x2, 24, 0, symbols, 0, strsize)
    header = struct.pack("<IiiIIIII", 0xFEEDFACF, 0x0100000C, 0, 2, 2, len(seg) + len(symtab), 0, 0)
    body = header + seg + symtab
    return body + b"\0" * (text + unwind + symbols * 16 + strsize)


def test_tree_splits_binaries_kinds_and_duplicates(tmp: Path) -> None:
    app = make_app(tmp)
    (app / "Contents/Resources/bin/cmux").write_bytes(macho(text=4000, unwind=1000, symbols=10, strsize=40))
    for page in ("a", "b"):
        write(app, f"Contents/Resources/pages/{page}/vendor.js", 2048)
    write(app, "Contents/Resources/fr.lproj/Localizable.strings", 300)
    write(app, "Contents/Resources/fonts/x.woff2", 50)
    out = tmp / "t.json"
    r = run("tree", str(app), "--json", str(out), "--jobs", "2")
    assert r.returncode == 0, r.stderr
    data = json.loads(out.read_text())
    cmux = next(b for b in data["binaries"] if b["path"] == "Contents/Resources/bin/cmux")
    assert cmux["parts"]["code and data"] == 4000 and cmux["parts"]["unwind tables"] == 1000, cmux
    assert cmux["parts"]["symbols"] == 10 * 16 + 40, cmux
    assert sum(cmux["parts"].values()) == cmux["bytes"], cmux
    kinds = {k["kind"]: k["bytes"] for k in data["kinds"]}
    assert kinds["JS"] == 4096 and kinds["localizations"] == 300 and kinds["fonts"] == 50, kinds
    dup = data["duplicates"]
    assert dup["extra_bytes"] == 2048, dup  # the second vendor.js
    assert any(g["paths"] == ["Contents/Resources/pages/a/vendor.js", "Contents/Resources/pages/b/vendor.js"]
               for g in dup["groups"]), dup
    assert data["app_bytes"] == sum(c["bytes"] for c in data["components"])
    assert 0 < data["dmg_estimate_bytes"] < data["app_bytes"], data["dmg_estimate_bytes"]
    assert "| `Contents/Resources/bin/cmux` |" in r.stdout, r.stdout


def fat(slices: list[bytes], wide: bool) -> bytes:
    """A fat Mach-O (FAT_MAGIC, or FAT_MAGIC_64 when wide) with each slice at a 4 KiB boundary."""
    import struct
    entry = 32 if wide else 20
    off = 4096
    archs, body = b"", b""
    for sl in slices:
        if wide:
            archs += struct.pack(">IIQQII", 0x0100000C, 0, off, len(sl), 12, 0)
        else:
            archs += struct.pack(">IIIII", 0x0100000C, 0, off, len(sl), 12)
        pad = -len(sl) % 4096
        body += sl + b"\0" * pad
        off += len(sl) + pad
    head = struct.pack(">II", 0xCAFEBABF if wide else 0xCAFEBABE, len(slices)) + archs
    assert len(head) == 8 + entry * len(slices)
    return head + b"\0" * (4096 - len(head)) + body


def test_tree_counts_fat_headers_and_padding(tmp: Path) -> None:
    app = make_app(tmp)
    sl = macho(text=1000, unwind=200, symbols=2, strsize=8)
    for name, wide in (("fat32", False), ("fat64", True)):
        (app / f"Contents/MacOS/{name}").write_bytes(fat([sl, sl], wide))
    # A Java class file starts 0xCAFEBABE too; its version (52) is no fat slice count.
    (app / "Contents/Resources/Thing.class").write_bytes(bytes.fromhex("cafebabe00000034") + b"\0" * 56)
    out = tmp / "t.json"
    r = run("tree", str(app), "--json", str(out), "--jobs", "1")
    assert r.returncode == 0, r.stderr
    data = json.loads(out.read_text())
    for name in ("fat32", "fat64"):
        b = next(x for x in data["binaries"] if x["path"] == f"Contents/MacOS/{name}")
        assert b["parts"]["code and data"] == 2000 and b["parts"]["unwind tables"] == 400, b
        assert sum(b["parts"].values()) == b["bytes"], b  # the fat header and padding are counted
    assert not any(x["path"].endswith("Thing.class") for x in data["binaries"]), data["binaries"]


def symbol_map(functions: list[tuple[str, int]]) -> bytes:
    """A cmux-symbols.bin (write-app-symbol-map.py's format) of (name, size) functions, in order."""
    def leb(n: int) -> bytes:
        out = bytearray()
        while True:
            byte, n = n & 0x7F, n >> 7
            out.append(byte | (0x80 if n else 0))
            if not n:
                return bytes(out)
    names = [name for name, _ in functions] + [""]
    deltas, previous, at = [], 0, 0x1000
    for _, size in functions + [("", 0)]:
        deltas.append(leb(at - previous))
        previous, at = at, at + size
    payload = struct.pack("<I", len(names)) + b"".join(deltas) + b"\0".join(n.encode() for n in names)
    raw = zlib.compressobj(9, zlib.DEFLATED, -15)
    body = raw.compress(payload) + raw.flush()
    return b"CMXSYM1\0" + struct.pack("<I", 1) + b"\x11" * 16 + struct.pack("<I", len(body)) + body


def test_tree_splits_the_app_code_by_language(tmp: Path) -> None:
    app = make_app(tmp)
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "cmux"}))
    (app / "Contents/Resources/cmux-symbols.bin").write_bytes(symbol_map([
        ("$s10CmuxNextApp4mainyyF", 700),
        ("_ZN4core3fmt5write17h0123456789abcdefE", 200),
        ("_RNvCs1_4core3fmt", 50),
        ("cmux_layout_reducer_apply", 30),
        ("ghostty_surface_new", 40),
        ("_ZN11spirv_cross8Compiler4compileEv", 25),
        ("sqlite3_prepare_v2", 15),
        ("objectdestroyTm", 10),
    ]))
    out = tmp / "t.json"
    r = run("tree", str(app), "--json", str(out), "--jobs", "1")
    assert r.returncode == 0, r.stderr
    lang = json.loads(out.read_text())["code_by_language"]
    assert lang["binary"] == "Contents/MacOS/cmux", lang
    assert lang["bytes"] == {"Swift": 710, "Rust": 280, "Zig": 40, "C++": 25, "C and other": 15}, lang["bytes"]
    assert "| Swift | 0.0 | 66.4% |" in r.stdout, r.stdout


def test_tree_without_a_symbol_map_has_no_language_split(tmp: Path) -> None:
    app = make_app(tmp)
    (app / "Contents/Resources/cmux-symbols.bin").write_bytes(b"CMXSYM1\0garbage")
    out = tmp / "t.json"
    r = run("tree", str(app), "--json", str(out), "--jobs", "1")
    assert r.returncode == 0, r.stderr
    assert "code_by_language" not in json.loads(out.read_text())


def main() -> int:
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    failed = 0
    for t in tests:
        with tempfile.TemporaryDirectory() as d:
            try:
                t(Path(d))
                print(f"ok {t.__name__}")
            except AssertionError as e:
                failed += 1
                print(f"FAIL {t.__name__}: {e}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
