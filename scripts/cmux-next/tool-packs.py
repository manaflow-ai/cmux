#!/usr/bin/env python3
"""Tools few people use, downloaded on first use (CMUX-570, app size): split a signed tool out of
an app's Contents/Resources/bin into a pack the app fetches the first time it runs.

Usage (stdlib only; run with `python3 -I`):
  tool-packs.py split APP OUT --base-url https://files-next.cmux.com/tool-packs [--tool NAME ...]
  tool-packs.py measure APP [--tool NAME ...]

The default tool is cmux-mobile-host, the iPhone host: it runs only while Settings > Accounts >
iPhone > Allow iPhone Connections is on (off by default in NIGHTLY and stable) and an account is
signed in, so most installs never start it.

split takes each APP/Contents/Resources/bin/NAME (a regular file: it was signed by
scripts/sign-cmux-bundle.sh step 1, and its embedded signature travels with it), packs it
deterministically (one tar entry NAME, mode 0755, mtime 0, uid/gid 0; zstd -19 with no long window)
into OUT/NAME.tar.zst, and puts in its place a symlink to `cmux`, as bin/cmux-browser-host is. The
multicall `cmux` run under that name (cmux-tui/crates/cmux-tui-core/src/tool_packs.rs) downloads
the pack once, checks its size and SHA-256 and the tool's own SHA-256 against the pin, keeps it in
the user's cache and runs it as its child with the same arguments and streams (SIGTERM and SIGHUP
passed on, its exit status returned), so every caller (the app's IPhoneHostService, scripts) runs
bin/NAME as before. The pin, content addressed
(<base-url>/<sha256>/NAME.tar.zst), goes to APP/Contents/Resources/tool-packs.json and
OUT/tool-packs.json:
  {"version": 1, "tools": {"cmux-mobile-host": {"file_sha256": ..., "file_size": ...,
                                                "sha256": ..., "size": ..., "url": ...}}}
Run it after the app's inner code is signed and before the app itself is sealed
(scripts/sign-cmux-bundle.sh step 4c, CMUX_NEXT_TOOL_PACKS=1): the outer seal covers the pin.
scripts/cmux-next/publish-language-packs.sh uploads OUT (OUT is the language packs' OUT/tools) before
the appcast names the app.

measure packs the same tools without moving anything and prints the installed bytes a split
removes and the packed size.
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile

PIN_NAME = "tool-packs.json"
DEFAULT_TOOLS = ["cmux-mobile-host"]
# The multicall binary a split tool becomes a link to (cmux-tui/crates/cmux-tui/src/main.rs
# run_folded_host); it must know the name.
MULTICALL = "cmux"
KNOWN_TOOLS = {"cmux-mobile-host"}
ZSTD_LEVEL = 19
NAME_RE = re.compile(r"[a-z][a-z0-9-]{1,63}")


def die(message: str) -> None:
    print(f"tool-packs: {message}", file=sys.stderr)
    sys.exit(1)


def tool_path(app: Path, name: str) -> Path:
    if not NAME_RE.fullmatch(name) or name not in KNOWN_TOOLS:
        die(f"{name!r} is not a tool bin/{MULTICALL} runs from a pack (known: {', '.join(sorted(KNOWN_TOOLS))})")
    path = app / "Contents" / "Resources" / "bin" / name
    if path.is_symlink() or not path.is_file():
        die(f"{path} is not a regular file")
    if not os.access(path, os.X_OK):
        die(f"{path} is not executable")
    return path


def tar_bytes(name: str, data: bytes) -> bytes:
    """A deterministic tar of one executable file."""
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w", format=tarfile.PAX_FORMAT) as tar:
        info = tarfile.TarInfo(name)
        info.mtime = 0
        info.uid = info.gid = 0
        info.uname = info.gname = ""
        info.type = tarfile.REGTYPE
        info.mode = 0o755
        info.size = len(data)
        tar.addfile(info, io.BytesIO(data))
    return buffer.getvalue()


def zstd_compress(data: bytes) -> bytes:
    """zstd -19 (no --long: the decoder keeps its default window), as language-packs.py does."""
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


def check_base_url(url: str) -> str:
    if not (url.startswith("https://") or re.match(r"http://(localhost|127\.0\.0\.1)(:\d+)?(/|$)", url)):
        die(f"--base-url must be https (or http to localhost for tests): {url!r}")
    return url.rstrip("/")


def measure(args) -> None:
    app = Path(args.app)
    total = packed_total = 0
    for name in args.tool:
        data = tool_path(app, name).read_bytes()
        packed = len(zstd_compress(tar_bytes(name, data)))
        print(f"{name}: {len(data)} bytes installed ({mb(len(data))}), pack {packed} bytes ({mb(packed)})")
        total += len(data)
        packed_total += packed
    print(f"{len(args.tool)} tools: {mb(total)} removed from the app, {mb(packed_total)} of packs")


def split(args) -> None:
    app = Path(args.app)
    out = Path(args.out)
    base_url = check_base_url(args.base_url)
    resources = app / "Contents" / "Resources"
    app_pin = resources / PIN_NAME
    if app_pin.exists():
        die(f"{app_pin} exists: this app was split already")
    multicall = resources / "bin" / MULTICALL
    if multicall.is_symlink() or not multicall.is_file():
        die(f"{multicall} is not a regular file: a split tool is a link to it")
    if out.exists() and any(out.iterdir()):
        die(f"{out} is not empty")
    out.mkdir(parents=True, exist_ok=True)
    tools = {}
    removed = 0
    for name in args.tool:
        path = tool_path(app, name)
        data = path.read_bytes()
        pack = zstd_compress(tar_bytes(name, data))
        (out / f"{name}.tar.zst").write_bytes(pack)
        sha = hashlib.sha256(pack).hexdigest()
        tools[name] = {"file_sha256": hashlib.sha256(data).hexdigest(), "file_size": len(data),
                       "sha256": sha, "size": len(pack), "url": f"{base_url}/{sha}/{name}.tar.zst"}
        path.unlink()
        os.symlink(MULTICALL, path)
        removed += len(data)
        print(f"==> {name}: {len(data)} bytes moved, pack {len(pack)} bytes ({sha[:12]}); bin/{name} -> {MULTICALL}")
    pin = json.dumps({"version": 1, "tools": tools}, indent=2, sort_keys=True) + "\n"
    (out / PIN_NAME).write_text(pin)
    app_pin.write_text(pin)
    packed = sum(t["size"] for t in tools.values())
    print(f"==> {len(tools)} tool packs: {removed} bytes ({mb(removed)}) removed from the app, "
          f"{packed} bytes ({mb(packed)}) of packs; pin {app_pin}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    s = sub.add_parser("split")
    s.add_argument("app")
    s.add_argument("out")
    s.add_argument("--base-url", required=True)
    s.add_argument("--tool", nargs="+", default=DEFAULT_TOOLS, metavar="NAME")
    s.set_defaults(run=split)
    m = sub.add_parser("measure")
    m.add_argument("app")
    m.add_argument("--tool", nargs="+", default=DEFAULT_TOOLS, metavar="NAME")
    m.set_defaults(run=measure)
    args = parser.parse_args()
    args.run(args)


if __name__ == "__main__":
    main()
