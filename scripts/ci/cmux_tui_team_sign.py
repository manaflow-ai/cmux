#!/usr/bin/env python3
"""The Team-signed darwin build of a cmux-tui tree: what hot-apply swaps into a Team-signed app.

    cmux_tui_team_sign.py plan KEY                    is tree KEY published, and its Team-signed set not yet?
    cmux_tui_team_sign.py fetch KEY OUT               KEY's darwin cmux and companions, checked, into OUT/
    cmux_tui_team_sign.py manifest KEY OUT --team T --commit C --run-url U
                                                      OUT/completion.json for the files OUT holds, once signed
    cmux_tui_team_sign.py verify OUT                  OUT's files hash to OUT/completion.json (the publish job)
    cmux_tui_team_sign.py objects OUT                 the R2 object keys and local files to upload, in order

Why: the tree builds cmux-tui-artifacts.yml publishes (files.cmux.com/cmux-tui/tree/KEY/) are ad-hoc
signed. A Team-signed app (a NIGHTLY) has no install key, so its daemon proves a connection is the app
only when the daemon itself is signed by the app's team (cmux-link app_caller.rs, prover A). An ad-hoc
daemon swapped into a NIGHTLY verifies no app connection, and Cloud stops answering
(cmuxterm-hq#11364). cmux-tui-team-signed.yml signs the same bytes with the identity the NEXT
nightly signs with, the way the nightly signs its bundled helpers (sign-cmux-bundle-helpers.sh:
hardened runtime, a timestamp, cmux-helper.entitlements), and publishes them beside the ad-hoc ones:

    cmux-tui/tree/KEY/team-signed/SHA256/FILE    each signed file, by its own sha256 (write-once)
    cmux-tui/tree/KEY/team-signed/completion.json  written last, once: the set, its team and source

FILE is the name the app bundles it under (bin/cmux, bin/cmux-cloud, ...), so codesign's identifier
is the nightly's. The signed files sit under their own digests, so two runs that sign one key at once
never mix their files: the completion.json that lands first names one whole set. The unsigned bytes
are the ones hot-apply would take for KEY: the darwin cmux from the tree (checked against its
completion.json and .sha256), and the companions from the commit manifest its source.json names.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import deadline_http  # noqa: E402

TUI_BASE = os.environ.get("CMUX_TEAM_SIGN_TUI_BASE") or "https://files.cmux.com/cmux-tui/tree"
COMMIT_BASE = os.environ.get("CMUX_TEAM_SIGN_COMMIT_BASE") or TUI_BASE.rsplit("/", 1)[0]
PREFIX = "cmux-tui/tree"
TARGET = "aarch64-apple-darwin"  # the NEXT app is arm64 only
MAIN = "cmux"
# hot-apply.py COMPANIONS, word for word (tests/test_cmux_tui_team_sign.py holds them equal): the
# published artifact, and the file in the app's bin/.
COMPANIONS = (("app-host", "cmux-app-host"), ("cloud-server", "cmux-cloud"), ("browser-host", "cmux-browser-host"),
              ("host", "cmux-tui-host"), ("holder", "cmux-holder"),
              ("agent-screen-detection", "cmux-agent-screen-detection"))
SCHEMA = 1
HEX40 = re.compile(r"[0-9a-f]{40}")
HEX64 = re.compile(r"[0-9a-f]{64}")
TEAM = re.compile(r"[A-Z0-9]{10}")


def fetch(url: str, timeout: float = 300) -> bytes:
    """URL's body within TIMEOUT seconds in all; an error status raises urllib's HTTPError."""
    # files.cmux.com answers Python's default user agent with 403.
    request = urllib.request.Request(url, headers={"User-Agent": "cmux-team-sign/1"})
    return deadline_http.request(request, timeout, raise_errors=True)[1]


def fetch_json(url: str) -> dict:
    body = json.loads(fetch(url, timeout=60))
    if not isinstance(body, dict):
        raise RuntimeError(f"{url} is not a JSON object")
    return body


def absent(url: str) -> bool:
    """URL answers 404 (anything else but a 200 is an error: a flaky read never reads as absent)."""
    try:
        fetch(url, timeout=60)
        return False
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return True
        raise


def sha256(body: bytes) -> str:
    return hashlib.sha256(body).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def check_key(key: str) -> str:
    if not HEX40.fullmatch(key):
        raise SystemExit(f"usage: KEY must be a 40-hex tree key, not {key!r}")
    return key


def unsigned_set(key: str) -> tuple[str, dict[str, tuple[str, str] | None]]:
    """(the tree's source commit, {file: (url, sha256) or None}) for KEY's darwin build: the same
    bytes and checks as hot-apply.py fetch_cmux and fetch_companions."""
    name = f"cmux-tui-{TARGET}"
    completion = fetch_json(f"{TUI_BASE}/{key}/completion.json")
    if completion.get("key") != key:
        raise RuntimeError(f"{TUI_BASE}/{key}/completion.json names key {completion.get('key')!r}")
    want = (completion.get("binaries") or {}).get(name)
    published = fetch(f"{TUI_BASE}/{key}/{name}.sha256", timeout=60).decode().split()[0]
    if not want or want != published:
        raise RuntimeError(f"{name}: completion.json says {want}, {name}.sha256 says {published}")
    owner = fetch_json(f"{TUI_BASE}/{key}/source.json").get("commit") or ""
    if not HEX40.fullmatch(owner):
        raise RuntimeError(f"{TUI_BASE}/{key}/source.json names no commit, so its companions are unknown")
    binaries = fetch_json(f"{COMMIT_BASE}/{owner}/manifest.json").get("binaries") or {}
    files: dict[str, tuple[str, str] | None] = {MAIN: (f"{TUI_BASE}/{key}/{name}", want)}
    for artifact, file in COMPANIONS:
        asset = f"cmux-tui-{artifact}-{TARGET}"
        digest = binaries.get(asset)
        files[file] = (f"{COMMIT_BASE}/{owner}/{asset}", digest) if digest else None
    for file, entry in files.items():
        if entry and not HEX64.fullmatch(entry[1]):
            raise RuntimeError(f"{file}: published sha256 {entry[1]!r} is not 64 hex")
    return owner, files


def plan(args) -> int:
    """key=, tree_published=, needed= lines for $GITHUB_OUTPUT."""
    key = check_key(args.key)
    published = not absent(f"{TUI_BASE}/{key}/completion.json")
    signed = not absent(f"{TUI_BASE}/{key}/team-signed/completion.json")
    print(f"key={key}")
    print(f"tree_published={str(published).lower()}")
    print(f"needed={str(published and not signed).lower()}")
    if not published:
        print(f"tree {key} is not published: nothing to sign yet", file=sys.stderr)
    elif signed:
        print(f"tree {key} already has its Team-signed set: {TUI_BASE}/{key}/team-signed/completion.json",
              file=sys.stderr)
    return 0


def fetch_set(args) -> int:
    """OUT/FILE for each file of KEY's darwin build, each checked, and OUT/unsigned.json."""
    key = check_key(args.key)
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    owner, files = unsigned_set(key)
    record = {"key": key, "commit": owner, "files": {}}
    for file, entry in files.items():
        if entry is None:
            record["files"][file] = None
            continue
        url, want = entry
        body = fetch(url)
        if sha256(body) != want:
            raise RuntimeError(f"{url} does not hash to {want}")
        (out / file).write_bytes(body)
        os.chmod(out / file, 0o755)
        record["files"][file] = {"unsigned_sha256": want, "from": url}
        print(f"{file}: {len(body)} bytes, sha256 {want}")
    (out / "unsigned.json").write_text(json.dumps(record, indent=1, sort_keys=True) + "\n")
    return 0


def manifest(args) -> int:
    """OUT/completion.json naming each signed file in OUT by its sha256."""
    key = check_key(args.key)
    out = Path(args.out)
    if not TEAM.fullmatch(args.team or ""):
        raise RuntimeError(f"--team must be a 10-character Team ID, not {args.team!r}")
    if not HEX40.fullmatch(args.commit or ""):
        raise RuntimeError(f"--commit must be a full sha, not {args.commit!r}")
    unsigned = json.loads((out / "unsigned.json").read_text())
    if unsigned.get("key") != key:
        raise RuntimeError(f"{out}/unsigned.json is for key {unsigned.get('key')!r}, not {key}")
    files: dict[str, dict | None] = {}
    for file, entry in unsigned["files"].items():
        if entry is None:
            files[file] = None
            continue
        signed = sha256_file(out / file)
        if signed == entry["unsigned_sha256"]:
            raise RuntimeError(f"{file} still has its unsigned bytes: it was not signed")
        files[file] = {"sha256": signed, "unsigned_sha256": entry["unsigned_sha256"],
                       "size": (out / file).stat().st_size}
    completion = {
        "schema": SCHEMA,
        "key": key,
        "target": TARGET,
        "team": args.team,
        "commit": args.commit,
        "treeCommit": unsigned.get("commit"),
        "runUrl": args.run_url,
        "files": files,
    }
    (out / "completion.json").write_text(json.dumps(completion, indent=1, sort_keys=True) + "\n")
    print(json.dumps(completion, indent=1, sort_keys=True))
    return 0


def read_completion(out: Path) -> dict:
    completion = json.loads((out / "completion.json").read_text())
    if completion.get("schema") != SCHEMA or not HEX40.fullmatch(completion.get("key") or ""):
        raise RuntimeError(f"{out}/completion.json is not a schema {SCHEMA} Team-signed set")
    if not TEAM.fullmatch(completion.get("team") or ""):
        raise RuntimeError(f"{out}/completion.json names no Team ID")
    files = completion.get("files")
    if not isinstance(files, dict) or set(files) != {MAIN, *(file for _, file in COMPANIONS)}:
        raise RuntimeError(f"{out}/completion.json must name {MAIN} and every companion")
    if not files.get(MAIN):
        raise RuntimeError(f"{out}/completion.json has no {MAIN}")
    return completion


def verify(args) -> int:
    out = Path(args.out)
    completion = read_completion(out)
    for file, entry in completion["files"].items():
        if entry is None:
            continue
        if not HEX64.fullmatch(entry.get("sha256") or "") or sha256_file(out / file) != entry["sha256"]:
            raise RuntimeError(f"{out}/{file} does not hash to the {entry.get('sha256')} completion.json names")
    print(f"{out}: {sum(1 for e in completion['files'].values() if e)} signed files match completion.json "
          f"(key {completion['key']}, team {completion['team']})")
    return 0


def objects(args) -> int:
    """`OBJECT_KEY LOCAL_FILE` lines, the signed files first and completion.json last."""
    out = Path(args.out)
    completion = read_completion(out)
    key = completion["key"]
    for file, entry in sorted(completion["files"].items()):
        if entry:
            print(f"{PREFIX}/{key}/team-signed/{entry['sha256']}/{file} {out / file}")
    print(f"{PREFIX}/{key}/team-signed/completion.json {out / 'completion.json'}")
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[1] if __doc__ else None)
    sub = parser.add_subparsers(dest="command", required=True)
    one = sub.add_parser("plan")
    one.add_argument("key")
    one.set_defaults(run=plan)
    one = sub.add_parser("fetch")
    one.add_argument("key")
    one.add_argument("out")
    one.set_defaults(run=fetch_set)
    one = sub.add_parser("manifest")
    one.add_argument("key")
    one.add_argument("out")
    one.add_argument("--team", required=True)
    one.add_argument("--commit", required=True)
    one.add_argument("--run-url", default="")
    one.set_defaults(run=manifest)
    one = sub.add_parser("verify")
    one.add_argument("out")
    one.set_defaults(run=verify)
    one = sub.add_parser("objects")
    one.add_argument("out")
    one.set_defaults(run=objects)
    args = parser.parse_args(argv)
    try:
        return args.run(args)
    except (RuntimeError, OSError, ValueError) as error:
        print(f"cmux_tui_team_sign: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
