#!/usr/bin/env python3
"""THIRD_PARTY_LICENSES for the cmuxd-remote release binaries.

  remote_daemon_notices.py generate --daemon-root daemon/remote --out FILE [--update-review]
  remote_daemon_notices.py check --daemon-root daemon/remote [--update-review]

cmuxd-remote is built with CGO_ENABLED=0, so it links no libc: only the Go
standard library and runtime and its Go modules. `generate` lists the modules
the linux and darwin builds link (`go list -deps`), reads each module's license
files from the module cache (`go mod download -json`, which go.sum verifies)
and writes one text file with the Go texts and every module text.

daemon/remote/third-party/review.json records each module, its license and the
sha256 of each file. A dependency change never waits for a person when its
license is allowed (Leo, 2026-10-22: fix it, don't fail "without a review"):
  - a module whose files hash the same as a recorded entry (its own version or
    another of the same module) is approved by that entry;
  - any other module is approved when each of its license files is a license on
    the allowlist (license_match's signatures; check_app_crate_licenses.ALLOWED,
    the app's crate allowlist), and a NOTICE or PATENTS file that is no license
    ships as a notice;
  - Go itself the same way, from GOROOT's license files.
Only an unknown or disallowed license fails, naming the module, the file and
the license. Approvals the record does not have yet, and entries for modules
the build no longer links, are notes; `--update-review` writes the record.
`check` is the fast guard (cmux-next-remote-daemon.yml, on pull requests and
feat-cmux-next pushes): it prints the notes as warnings and fails only where
`generate` would. build_remote_daemon_release_assets.sh writes the file as
cmuxd-remote-THIRD_PARTY_LICENSES[-<suffix>].txt beside the binaries. Python
3.9+ standard library only.
"""

from __future__ import annotations

import argparse
import dataclasses
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
from typing import List

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "cmux-tui/build-support/notices"))
sys.path.insert(0, str(ROOT / "scripts/cmux-next"))
import license_match  # noqa: E402
from check_app_crate_licenses import ALLOWED  # noqa: E402

THIRD_PARTY = ROOT / "daemon/remote/third-party"
TEXTS = THIRD_PARTY
REVIEW = THIRD_PARTY / "review.json"
LICENSE_NAME = re.compile(r"^(LICEN[CS]E|COPYING|NOTICE|PATENTS|UNLICENSE)(\..*)?$", re.I)
# Shipped as found; a license text in one is still classified.
NOTICE_NAME = re.compile(r"^(NOTICE|PATENTS)(\..*)?$", re.I)
# Signatures that only qualify an allowed license (Apache-2.0 WITH LLVM-exception).
EXCEPTIONS = {"LLVM-exception"}
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


def classify(directory: Path, label: str) -> str:
    """The SPDX license of a directory's license files, when every one is allowed."""
    ids = set()
    names = sorted(license_digests(directory))
    for name in names:
        text = _text((directory / name).read_bytes(), f"{label} {name}")
        found = {i for i in license_match.SIGNATURES if license_match.matches(i, text)}
        refused = sorted(i for i in found if i not in ALLOWED and i not in EXCEPTIONS)
        if refused:
            raise NoticeError(f"{label}: {name} is {' and '.join(refused)}, which is not on the allowlist (scripts/cmux-next/check_app_crate_licenses.py ALLOWED); a person decides whether cmuxd-remote may ship it")
        if not found - EXCEPTIONS and not NOTICE_NAME.match(name):
            raise NoticeError(f"{label}: {name} is no license this check recognizes (cmux-tui/build-support/notices/license_match.py); a person reviews it")
        ids |= found - EXCEPTIONS
    if not ids:
        raise NoticeError(f"{label} ships no license file ({', '.join(names) or 'none'}); a person reviews it")
    return " AND ".join(sorted(ids))


def write_atomically(path: Path, text: str) -> None:
    """Replace a file only once its new text is fully written."""
    temporary = path.with_name(f".{path.name}.tmp-{os.getpid()}")
    try:
        temporary.write_text(text, encoding="utf-8")
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def review_entry(module: Module, review: dict) -> tuple[str | None, dict]:
    """The recorded key that approves a module and its entry, or (None, a new
    entry) when its allowed license approves it."""
    key = f"{module.path}@{module.version}"
    digests = license_digests(module.directory)
    same_path = [k for k in sorted(review["modules"]) if k.rsplit("@", 1)[0] == module.path]
    for candidate in sorted(same_path, key=lambda k: k != key):
        if review["modules"][candidate]["files"] == digests:
            return candidate, review["modules"][candidate]
    return None, {"license": classify(module.directory, key), "files": digests}


def go_entry(go_version: str, review: dict, go_root: Path | None) -> tuple[bool, dict, Path]:
    """Whether review.json's Go entry approves this Go, the entry, and where its texts are."""
    go = review["go"]
    if re.fullmatch(re.escape(go["minor"]) + r"(\.[0-9]+)?", go_version):
        return True, go, TEXTS / "go"
    if go_root is None:
        raise NoticeError(f"cmuxd-remote is built with {go_version}, but review.json records {go['minor']} and GOROOT was not given")
    try:
        digests = license_digests(go_root)
    except OSError as error:
        raise NoticeError(f"Go {go_version}: cannot read GOROOT's license files ({error})") from None
    if digests == go["files"]:
        return True, go, TEXTS / "go"
    minor = re.match(r"go[0-9]+\.[0-9]+", go_version)
    entry = {**go, "minor": minor.group(0) if minor else go_version, "license": classify(go_root, f"Go {go_version}"),
             "files": digests, "source": f"LICENSE files of GOROOT ({go_version})"}
    return False, entry, go_root


def updated_review(modules: List[Module], review: dict, go_version: str | None = None, go_root: Path | None = None) -> dict:
    """review.json for what the build links: every module under its linked
    version, approvals recorded, entries for modules no longer linked gone."""
    entries = {f"{m.path}@{m.version}": review_entry(m, review)[1] for m in modules}
    go = go_entry(go_version, review, go_root)[1] if go_version else review["go"]
    return {**review, "go": go, "modules": dict(sorted(entries.items()))}


def dump_review(review: dict) -> str:
    """review.json's layout: one line per module."""
    head = json.dumps({k: v for k, v in review.items() if k != "modules"}, indent=2)[:-2]
    lines = [f"    {json.dumps(k)}: {json.dumps(v)}" for k, v in review["modules"].items()]
    return head + ',\n  "modules": {\n' + ",\n".join(lines) + "\n  }\n}\n"


def compose(modules: List[Module], go_version: str, review: dict, go_root: Path | None = None,
            notes: list | None = None) -> str:
    notes = [] if notes is None else notes
    recorded, go, go_texts = go_entry(go_version, review, go_root)
    if not recorded:
        notes.append(f"Go {go_version}: approved automatically ({go['license']}); generate --update-review records it")
    out = [
        "Third-party notices for cmuxd-remote\n",
        "Generated by scripts/remote_daemon_notices.py; do not edit.\n\n",
        "cmuxd-remote is part of cmux (GPL-3.0-or-later). It is built with CGO_ENABLED=0 and statically\n",
        "contains the code below and no C library.\n\n",
        f"== Go standard library and runtime ({go_version}) ==\n",
        f"License: {go['license']}. Source: {go['source']}\n\n",
    ]
    for name, digest in sorted(go["files"].items()):
        data = (go_texts / name).read_bytes()
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
        reviewed, entry = review_entry(module, review)
        if reviewed is None:
            notes.append(f"{key}: approved automatically ({entry['license']}); generate --update-review records it")
        else:
            used.add(reviewed)
        out.append(f"== {module.path} {module.version} ==\nLicense: {entry['license']}. Source: https://proxy.golang.org/{module.path}/@v/{module.version}.zip\n\n")
        for name in sorted(entry["files"]):
            data = (module.directory / name).read_bytes()
            out += [f"--- {name} ---\n", _text(data, f"{key} {name}").rstrip("\n") + "\n\n"]
    for key in sorted(set(review["modules"]) - used):
        if key not in seen:
            notes.append(f"{key}: no longer linked; generate --update-review drops its entry")
    return "".join(out)


def update_go_texts(go: dict, go_texts: Path) -> None:
    """Copy an automatically approved Go's license files into third-party/go."""
    directory = TEXTS / "go"
    if go_texts == directory:
        return
    for old in directory.iterdir():
        if old.is_file() and old.name not in go["files"]:
            old.unlink()
    for name in go["files"]:
        shutil.copyfile(go_texts / name, directory / name)


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
    gen = sub.add_parser("generate", help="write the notices file")
    check = sub.add_parser("check", help="the fast guard: approve what is allowed, warn, fail only on a refused license")
    for command in (gen, check):
        command.add_argument("--daemon-root", type=Path, default=ROOT / "daemon/remote")
        command.add_argument("--update-review", action="store_true",
                             help="also rewrite review.json (and third-party/go) for what the build links")
    gen.add_argument("--out", type=Path, required=True)
    args = parser.parse_args(argv)
    annotate = os.environ.get("GITHUB_ACTIONS") == "true"
    notes: list = []
    try:
        go_version = _go(args.daemon_root, "env", "GOVERSION").strip()
        go_root = Path(_go(args.daemon_root, "env", "GOROOT").strip())
        modules = linked_modules(args.daemon_root)
        review = load_review()
        text = compose(modules, go_version, review, go_root=go_root, notes=notes)
        updated = updated_review(modules, review, go_version, go_root) if args.update_review else None
    except NoticeError as error:
        print(f"{'::error title=cmuxd-remote license::' if annotate else 'remote_daemon_notices: error: '}{error}", file=sys.stderr)
        return 1
    for note in notes:
        print(f"{'::warning title=cmuxd-remote license::' if annotate else 'remote_daemon_notices: note: '}{note}", file=sys.stderr)
    if args.command == "generate":
        args.out.write_text(text, encoding="utf-8")
        print(f"remote_daemon_notices: wrote {args.out} ({go_version})")
    if updated is not None:
        update_go_texts(updated["go"], go_entry(go_version, review, go_root)[2])
        write_atomically(REVIEW, dump_review(updated))
        print(f"remote_daemon_notices: updated {REVIEW.relative_to(ROOT)}")
    if args.command == "check":
        print(f"remote_daemon_notices: every license cmuxd-remote links is allowed ({len(modules)} modules, {go_version})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
