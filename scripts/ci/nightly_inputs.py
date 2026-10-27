#!/usr/bin/env python3
"""Hand the cmux-next web bundles and third-party notices from Linux to the Mac build.

  nightly_inputs.py pack-web DIR --source-key KEY    (Linux, after build-web-bundles.sh --force)
  nightly_inputs.py install-web DIR                  (Mac, before xcodebuild)
  nightly_inputs.py pack-notices DIR                 (Linux, after generate-third-party-notices.sh)
  nightly_inputs.py install-notices DIR              (Mac, after xcodebuild)
  nightly_inputs.py bundle-notices APP               (Mac: put THIRD_PARTY_LICENSES.md into APP)

nightly.yml's build-nightly-inputs job builds both on Linux beside
build-nightly-app, from the commit `decide` checked out, with the same commands
the Mac ran. Neither depends on the build host: the bundles are JavaScript built
by bun and node (cmux-next.yml's DEV builds already ship bundles built on Linux)
and the notices come from `cargo tree --target <apple triple>` and Cargo.lock.

The Mac never waits for them. An install that finds no hand-off, or one that
does not match this checkout, exits 3 and the step builds here as before:
  - web bundles: the tar's sha256, and the source key (web-bundle-key.py
    --source, every input the bundles are built from) equal to this checkout's.
  - notices: the file's sha256, and the commit it was generated at equal to this
    checkout's HEAD (the notices link first-party sources at that commit).
Any other exit status is an error.

The notices reach the app after xcodebuild: the Release build copies the
committed THIRD_PARTY_LICENSES.md, and bundle-notices replaces exactly that
copy (Contents/Resources/THIRD_PARTY_LICENSES.md, which must still equal the
committed file) with this tree's notices, as the build copied them before.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
# The outputs build-web-bundles.sh --from installs (its PANE, PAGES, ACTIVITY,
# APP and the palette ranker). The inspector page is committed, not handed off.
WEB_OUTPUTS = (
    "Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/Resources/agent-pane",
    "Packages/macOS/CmuxNext/Sources/CmuxNextPages/Resources/pages",
    "Packages/macOS/CmuxNext/Sources/CmuxNextAgentActivity/Resources/agent-activity",
    "Resources/markdown-viewer/webviews-app",
    "Packages/macOS/CmuxNext/Sources/CmuxNextPalette/Resources/palette-ranker.js",
)
WEB_TAR, WEB_RECORD = "web-bundles.tar", "web-bundles.json"
NOTICES, NOTICES_RECORD = "THIRD_PARTY_LICENSES.md", "notices.json"
APP_NOTICES = "Contents/Resources/THIRD_PARTY_LICENSES.md"
NOT_USABLE = 3


class NotUsable(Exception):
    pass


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def git(*args: str) -> str:
    return subprocess.run(["git", "-C", str(ROOT), *args], check=True, capture_output=True, text=True).stdout.strip()


def head() -> str:
    return git("rev-parse", "HEAD")


def write_record(path: Path, record: dict) -> None:
    path.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")


def read_record(directory: Path, name: str, payload: str) -> dict:
    record_path, payload_path = directory / name, directory / payload
    if not record_path.is_file() or not payload_path.is_file():
        raise NotUsable(f"no hand-off in {directory}")
    record = json.loads(record_path.read_text())
    if sha256(payload_path) != record.get("sha256"):
        raise NotUsable(f"{payload} does not match the sha256 its record names")
    return record


def pack_web(out: Path, source_key: str) -> None:
    out.mkdir(parents=True, exist_ok=True)
    with tarfile.open(out / WEB_TAR, "w", format=tarfile.PAX_FORMAT) as archive:
        for relative in WEB_OUTPUTS:
            if not (ROOT / relative).exists():
                raise SystemExit(f"error: the web bundle build left no {relative}")
            archive.add(ROOT / relative, arcname=relative)
    write_record(out / WEB_RECORD, {"commit": head(), "source_key": source_key, "sha256": sha256(out / WEB_TAR)})
    print(f"packed the web bundles of source key {source_key[:12]} ({(out / WEB_TAR).stat().st_size} bytes)")


def safe_members(archive: tarfile.TarFile):
    for member in archive.getmembers():
        name = member.name
        inside = any(name == output or name.startswith(output + "/") for output in WEB_OUTPUTS)
        if name.startswith("/") or ".." in Path(name).parts or not inside:
            raise NotUsable(f"refusing archive member {name!r}")
        if not (member.isfile() or member.isdir()):
            raise NotUsable(f"refusing archive member {name!r}: not a file or directory")
        yield member


def install_web(directory: Path) -> None:
    record = read_record(directory, WEB_RECORD, WEB_TAR)
    here = subprocess.run([sys.executable, str(ROOT / "scripts/cmux-next/web-bundle-key.py"), str(ROOT), "--source"],
                          check=True, capture_output=True, text=True).stdout.strip()
    if record.get("source_key") != here:
        raise NotUsable(f"built for source key {str(record.get('source_key'))[:12]} (commit "
                        f"{str(record.get('commit'))[:11]}), this checkout is {here[:12]}")
    with tempfile.TemporaryDirectory(prefix="nightly-web-bundles-") as staged:
        with tarfile.open(directory / WEB_TAR) as archive:
            archive.extractall(staged, members=list(safe_members(archive)))
        subprocess.run([str(ROOT / "scripts/cmux-next/build-web-bundles.sh"), "--from", staged], check=True)
    print(f"installed the web bundles built by build-nightly-inputs at {str(record.get('commit'))[:11]} (source key {here[:12]})")


def pack_notices(out: Path) -> None:
    out.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(ROOT / NOTICES, out / NOTICES)
    write_record(out / NOTICES_RECORD, {"commit": head(), "sha256": sha256(out / NOTICES)})
    print(f"packed THIRD_PARTY_LICENSES.md ({(out / NOTICES).stat().st_size} bytes)")


def install_notices(directory: Path) -> None:
    record = read_record(directory, NOTICES_RECORD, NOTICES)
    commit = head()
    if record.get("commit") != commit:
        raise NotUsable(f"generated at {str(record.get('commit'))[:11]}, this checkout is {commit[:11]}")
    shutil.copyfile(directory / NOTICES, ROOT / NOTICES)
    print(f"took THIRD_PARTY_LICENSES.md generated by build-nightly-inputs at {commit[:11]}")


def bundle_notices(app: Path) -> None:
    bundled = app / APP_NOTICES
    committed = subprocess.run(["git", "-C", str(ROOT), "show", f"HEAD:{NOTICES}"], check=True, capture_output=True).stdout
    if not bundled.is_file():
        raise SystemExit(f"error: {bundled} is missing: the Release build did not copy {NOTICES}")
    if bundled.read_bytes() != committed:
        raise SystemExit(f"error: {bundled} is not the committed {NOTICES} the Release build copies; refusing to replace it")
    shutil.copyfile(ROOT / NOTICES, bundled)
    os.chmod(bundled, 0o644)
    print(f"bundled this tree's {NOTICES} ({bundled.stat().st_size} bytes, sha256 {sha256(bundled)[:12]})")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    pack = commands.add_parser("pack-web")
    pack.add_argument("dir", type=Path)
    pack.add_argument("--source-key", required=True)
    for name in ("install-web", "pack-notices", "install-notices"):
        commands.add_parser(name).add_argument("dir", type=Path)
    commands.add_parser("bundle-notices").add_argument("app", type=Path)
    args = parser.parse_args(argv)
    try:
        if args.command == "pack-web":
            pack_web(args.dir, args.source_key)
        elif args.command == "install-web":
            install_web(args.dir)
        elif args.command == "pack-notices":
            pack_notices(args.dir)
        elif args.command == "install-notices":
            install_notices(args.dir)
        else:
            bundle_notices(args.app)
    except NotUsable as reason:
        print(f"the build-nightly-inputs hand-off is not usable here: {reason}")
        return NOT_USABLE
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
