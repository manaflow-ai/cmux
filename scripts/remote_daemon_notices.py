#!/usr/bin/env python3
"""THIRD_PARTY_LICENSES for the cmuxd-remote release binaries.

  remote_daemon_notices.py generate --daemon-root daemon/remote --out FILE

cmuxd-remote is built with CGO_ENABLED=0, so it links no libc: only the Go
standard library and runtime and its Go modules. `generate` lists the modules
the linux and darwin builds link (`go list -deps`), reads each module's license
files from the module cache (`go mod download -json`, which go.sum verifies)
and writes one text file with the Go texts and every module text.
daemon/remote/third-party/review.json (owned by the license review) names every
module, its license and the sha256 of each file; a module or text that it does
not list fails the run. The texts are what is reviewed: a new version of a
reviewed module, or a new Go minor version, whose license files hash the same as
the reviewed ones passes, so a security bump never waits for a review edit.
`generate --update-review` rewrites review.json for the linked versions.
build_remote_daemon_release_assets.sh writes the file as
cmuxd-remote-THIRD_PARTY_LICENSES[-<suffix>].txt beside the binaries. Python 3.9+
standard library only.
"""

from __future__ import annotations

import argparse
import dataclasses
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from typing import List

ROOT = Path(__file__).resolve().parents[1]
THIRD_PARTY = ROOT / "daemon/remote/third-party"
TEXTS = THIRD_PARTY
REVIEW = THIRD_PARTY / "review.json"
LICENSE_NAME = re.compile(r"^(LICEN[CS]E|COPYING|NOTICE|PATENTS|UNLICENSE)(\..*)?$", re.I)
PLATFORMS = (("linux", "amd64"), ("linux", "arm64"), ("darwin", "amd64"), ("darwin", "arm64"))


class NoticeError(RuntimeError):
    pass


@dataclasses.dataclass(frozen=True)
class Module:
    path: str
    version: str
    directory: Path


def load_review() -> dict:
    return json.loads(REVIEW.read_text(encoding="utf-8"))


def _text(data: bytes, label: str) -> str:
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        raise NoticeError(f"{label} is not UTF-8") from None


def license_digests(directory: Path) -> dict:
    """The sha256 of every license file in a directory (a module, or GOROOT)."""
    names = sorted(p.name for p in directory.iterdir() if p.is_file() and LICENSE_NAME.match(p.name))
    return {name: hashlib.sha256((directory / name).read_bytes()).hexdigest() for name in names}


def _go_texts_match(go_root: Path | None, files: dict) -> bool:
    try:
        return go_root is not None and license_digests(go_root) == files
    except OSError:
        return False


def write_atomically(path: Path, text: str) -> None:
    """Replace a file only once its new text is fully written."""
    temporary = path.with_name(f".{path.name}.tmp-{os.getpid()}")
    try:
        temporary.write_text(text, encoding="utf-8")
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def review_key(module: Module, review: dict) -> str:
    """The review.json key that reviews this module: its own version, or a
    reviewed version of the same module whose license files are identical."""
    key = f"{module.path}@{module.version}"
    if key in review["modules"]:
        return key
    same_path = [k for k in sorted(review["modules"]) if k.rsplit("@", 1)[0] == module.path]
    digests = license_digests(module.directory)
    for candidate in same_path:
        if review["modules"][candidate]["files"] == digests:
            return candidate
    if same_path:
        raise NoticeError(f"{key}: its license files differ from every reviewed version ({', '.join(same_path)}); review the new texts in daemon/remote/third-party/review.json")
    raise NoticeError(f"{key} is linked into cmuxd-remote but daemon/remote/third-party/review.json does not review it")


def updated_review(modules: List[Module], review: dict) -> dict:
    """review.json with each entry under the version the build links."""
    entries = dict(review["modules"])
    for module in modules:
        key = review_key(module, review)
        linked = f"{module.path}@{module.version}"
        if key != linked:
            entries[linked] = entries.pop(key, None) or review["modules"][key]
    return {**review, "modules": dict(sorted(entries.items()))}


def dump_review(review: dict) -> str:
    """review.json's layout: one line per module."""
    head = json.dumps({k: v for k, v in review.items() if k != "modules"}, indent=2)[:-2]
    lines = [f"    {json.dumps(k)}: {json.dumps(v)}" for k, v in review["modules"].items()]
    return head + ',\n  "modules": {\n' + ",\n".join(lines) + "\n  }\n}\n"


def compose(modules: List[Module], go_version: str, review: dict, go_root: Path | None = None) -> str:
    go = review["go"]
    if not re.fullmatch(re.escape(go["minor"]) + r"(\.[0-9]+)?", go_version) and not _go_texts_match(go_root, go["files"]):
        raise NoticeError(f"cmuxd-remote is built with {go_version}, but review.json reviews {go['minor']} and this Go's LICENSE and PATENTS differ from its texts; review them")
    out = [
        "Third-party notices for cmuxd-remote\n",
        "Generated by scripts/remote_daemon_notices.py; do not edit.\n\n",
        "cmuxd-remote is part of cmux (GPL-3.0-or-later). It is built with CGO_ENABLED=0 and statically\n",
        "contains the code below and no C library.\n\n",
        f"== Go standard library and runtime ({go_version}) ==\n",
        f"License: {go['license']}. Source: {go['source']}\n\n",
    ]
    for name, digest in sorted(go["files"].items()):
        data = (TEXTS / "go" / name).read_bytes()
        if hashlib.sha256(data).hexdigest() != digest:
            raise NoticeError(f"daemon/remote/third-party/go/{name} does not match review.json")
        out += [f"--- go/{name} ---\n", _text(data, f"go/{name}").rstrip("\n") + "\n\n"]
    seen = set()
    used = set()
    for module in sorted(modules, key=lambda m: (m.path, m.version)):
        key = f"{module.path}@{module.version}"
        if key in seen:
            continue
        seen.add(key)
        reviewed = review_key(module, review)
        used.add(reviewed)
        entry = review["modules"][reviewed]
        found = sorted(p.name for p in module.directory.iterdir() if p.is_file() and LICENSE_NAME.match(p.name))
        if found != sorted(entry["files"]):
            raise NoticeError(f"{key}: license files {found} differ from the reviewed {sorted(entry['files'])}")
        out.append(f"== {module.path} {module.version} ==\nLicense: {entry['license']}. Source: https://proxy.golang.org/{module.path}/@v/{module.version}.zip\n\n")
        for name in found:
            data = (module.directory / name).read_bytes()
            if hashlib.sha256(data).hexdigest() != entry["files"][name]:
                raise NoticeError(f"{key}: {name} differs from the reviewed text")
            out += [f"--- {name} ---\n", _text(data, f"{key} {name}").rstrip("\n") + "\n\n"]
    missing = sorted(set(review["modules"]) - used)
    if missing:
        raise NoticeError(f"review.json lists modules the build no longer links: {', '.join(missing)}; remove them")
    return "".join(out)


def _go(daemon_root: Path, *args: str, env: dict | None = None) -> str:
    result = subprocess.run(["go", "-C", str(daemon_root), *args], capture_output=True, text=True, env=env)
    if result.returncode != 0:
        raise NoticeError(f"go {' '.join(args)} failed:\n{result.stderr}")
    return result.stdout


def linked_modules(daemon_root: Path) -> List[Module]:
    keys = set()
    for goos, goarch in PLATFORMS:
        env = {**os.environ, "GOOS": goos, "GOARCH": goarch, "CGO_ENABLED": "0"}
        listing = _go(daemon_root, "list", "-deps", "-f", "{{with .Module}}{{if not .Main}}{{.Path}}@{{.Version}}{{end}}{{end}}", "./cmd/cmuxd-remote", env=env)
        keys.update(line for line in listing.split() if line)
    modules = []
    for key in sorted(keys):
        info = json.loads(_go(daemon_root, "mod", "download", "-json", key))
        modules.append(Module(info["Path"], info["Version"], Path(info["Dir"])))
    return modules


def main(argv: List[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    gen = sub.add_parser("generate")
    gen.add_argument("--daemon-root", type=Path, default=ROOT / "daemon/remote")
    gen.add_argument("--out", type=Path, required=True)
    gen.add_argument("--update-review", action="store_true",
                     help="also rewrite review.json under the linked versions (texts unchanged)")
    args = parser.parse_args(argv)
    try:
        go_version = _go(args.daemon_root, "env", "GOVERSION").strip()
        go_root = Path(_go(args.daemon_root, "env", "GOROOT").strip())
        modules = linked_modules(args.daemon_root)
        review = load_review()
        text = compose(modules, go_version, review, go_root=go_root)
        updated = dump_review(updated_review(modules, review)) if args.update_review else None
    except NoticeError as error:
        print(f"remote_daemon_notices: error: {error}", file=sys.stderr)
        return 1
    args.out.write_text(text, encoding="utf-8")
    if updated is not None:
        write_atomically(REVIEW, updated)
    print(f"remote_daemon_notices: wrote {args.out} ({go_version})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
