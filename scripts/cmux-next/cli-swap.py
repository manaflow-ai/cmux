#!/usr/bin/env python3
"""A merged commit's cmux CLI for the person typing `cmux`, without a new app and without touching it.

    cli-swap.py apply --tree-key KEY [--name NAME] [--sha SHA256] [--app APP]
    cli-swap.py status
    cli-swap.py undo

`apply` downloads the macOS CLI the "cmux-tui artifacts" workflow published for a feat-cmux-next
commit (https://files.cmux.com/cmux-tui/tree/KEY/; KEY is `scripts/cmux-next/pin-cmux-tui.sh key`
at that commit), checks its sha256 (the published one, or --sha), and keeps the copy outside any app.
Then it puts the copy where a cmux terminal finds it:

- The `cmux` a cmux terminal runs is resolved as that terminal resolves it: the first `cmux` on
  PATH (run this in a cmux terminal), or with --app, the app's Contents/Resources/bin, which the app
  puts first on its terminals' PATH.
- When that `cmux` is inside an app bundle it is never written: it is also the file the app runs its
  daemon from, and the bundle is signed. The copy goes beside it on PATH under its own name,
  ~/.local/bin/cmux-NAME (NAME defaults to the commit's first 12 characters), and plain `cmux` stays
  the app's own until the app updates.
- When it is a link outside any app (an install script's link), the link is pointed at the copy.

`undo` takes back everything `apply` did: the names it added go, the links point where they
pointed before. Nothing here relaunches or signals the app.
"""
from __future__ import annotations  # `X | None` on the system python3 of macOS (3.9)

import argparse
import hashlib
import json
import os
import platform
import re
import secrets
import shutil
import sys
import tempfile
import urllib.request
from pathlib import Path

BASE = os.environ.get("CMUX_CLI_SWAP_BASE") or "https://files.cmux.com/cmux-tui/tree"


def state_dir() -> Path:
    if os.environ.get("CMUX_CLI_SWAP_STATE_DIR"):
        return Path(os.environ["CMUX_CLI_SWAP_STATE_DIR"])
    home = Path.home()
    if sys.platform == "darwin":
        return home / "Library/Caches/cmux-next/cli-swap"
    return Path(os.environ.get("XDG_CACHE_HOME") or home / ".cache") / "cmux-next/cli-swap"


def target_triple() -> str:
    arch = "aarch64" if platform.machine() in ("arm64", "aarch64") else "x86_64"
    return f"{arch}-apple-darwin" if sys.platform == "darwin" else f"{arch}-unknown-linux-musl"


def fetch(url: str) -> bytes:
    with urllib.request.urlopen(url, timeout=300) as answer:
        return answer.read()


def terminal_cmux(app: str | None) -> Path | None:
    """The `cmux` a cmux terminal runs: --app's bundled one, else the first on this PATH."""
    if app:
        bundled = Path(app) / "Contents/Resources/bin/cmux"
        return bundled if bundled.exists() else None
    found = shutil.which("cmux")
    # Absolute, so the record still names it when undo runs from another directory.
    return Path(found).absolute() if found else None


def in_app_bundle(path: Path) -> bool:
    # The path itself as well as where it leads: a link inside a bundle is part of the signed bundle.
    return ".app/Contents/" in str(path.absolute()) or ".app/Contents/" in str(path.resolve())


# A tree key is a git hash; a name is one plain word. Either one becomes a path, so neither may hold a
# `/` or `..` that leads out of the cache or ~/.local/bin.
TREE_KEY = re.compile(r"[0-9a-f]{40}")
NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}")


def load(state: Path) -> list[dict]:
    try:
        return json.loads((state / "applied.json").read_text())
    except (OSError, ValueError):
        return []


def save(state: Path, records: list[dict]) -> None:
    state.mkdir(parents=True, exist_ok=True)
    (state / "applied.json").write_text(json.dumps(records, indent=2) + "\n")


def still_ours(record: dict) -> bool:
    """The path still points at this swap's copy; anything else changed it since and owns it now."""
    path = Path(record["path"])
    return path.is_symlink() and os.readlink(path) == record.get("to")


def relink(link: Path, to: str) -> None:
    # A fresh name each time: symlink_to fails rather than replace a file that is already there.
    while True:
        staged = link.with_name(f".{link.name}.cli-swap-{secrets.token_hex(8)}")
        try:
            staged.symlink_to(to)
            break
        except FileExistsError:
            continue
    os.replace(staged, link)


def command_apply(args) -> int:
    if not TREE_KEY.fullmatch(args.tree_key):
        print(f"cli-swap: --tree-key {args.tree_key!r} is not a tree hash; nothing changed", file=sys.stderr)
        return 2
    if args.name is not None and (not NAME.fullmatch(args.name) or ".." in args.name):
        print(f"cli-swap: --name {args.name!r} must be one plain word; nothing changed", file=sys.stderr)
        return 2
    state = state_dir()
    triple = args.target or target_triple()
    url = f"{BASE}/{args.tree_key}/cmux-tui-{triple}"
    try:
        want = args.sha or fetch(url + ".sha256").decode().split()[0]
        body = fetch(url)
    except (OSError, UnicodeDecodeError, IndexError) as error:
        # Not published (yet), no network, or a .sha256 that is not one: the same "nothing changed".
        print(f"cli-swap: could not read {url}: {error}; nothing changed", file=sys.stderr)
        return 1
    have = hashlib.sha256(body).hexdigest()
    if have != want:
        print(f"cli-swap: {url} has sha256 {have}, not {want}; nothing changed", file=sys.stderr)
        return 1
    copy = state / args.tree_key / "cmux"
    copy.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=copy.parent, delete=False) as part:
        part.write(body)
    os.chmod(part.name, 0o755)
    os.replace(part.name, copy)

    found = terminal_cmux(args.app)
    # A record whose path something else changed since is dropped: that path is theirs now.
    records = [r for r in load(state) if still_ours(r)]
    if found and not in_app_bundle(found) and found.is_symlink():
        # A second apply keeps the first's record, so undo points the link at what it was before any.
        record = next((r for r in records if r["kind"] == "link" and r["path"] == str(found)), None)
        if record is None:
            record = {"kind": "link", "path": str(found), "previous": os.readlink(found)}
            records.append(record)
        record["to"] = str(copy)
        relink(found, str(copy))
        save(state, records)
        print(f"cli-swap: `cmux` is {copy} now ({found} pointed at {record['previous']})")
        return 0
    name = f"cmux-{args.name or args.tree_key[:12]}"
    alias = Path.home() / ".local/bin" / name
    alias.parent.mkdir(parents=True, exist_ok=True)
    ours = any(r["kind"] == "alias" and r["path"] == str(alias) for r in records)
    if not ours and (alias.exists() or alias.is_symlink()):
        # Someone else's file or link: never replaced, so undo never removes it.
        print(f"cli-swap: {alias} is already there and not from cli-swap; nothing changed (pick another --name)",
              file=sys.stderr)
        return 1
    if not ours:
        records.append({"kind": "alias", "path": str(alias)})
    next(r for r in records if r["kind"] == "alias" and r["path"] == str(alias))["to"] = str(copy)
    relink(alias, str(copy))
    save(state, records)
    why = (f"{found} is inside an app bundle, which runs its daemon from that file and is never written"
           if found and in_app_bundle(found) else f"{found or 'no cmux on PATH'} is not a link this can repoint")
    print(f"cli-swap: run `{name}` ({alias} -> {copy}); plain `cmux` is unchanged: {why}")
    on_path = str(alias.parent) in os.environ.get("PATH", "").split(":")
    if not on_path:
        print(f"cli-swap: {alias.parent} is not on PATH here; run {alias} by its full path")
    return 0


def command_status(_args) -> int:
    records = load(state_dir())
    if not records:
        print("cli-swap: nothing applied")
    for record in records:
        path = Path(record["path"])
        now = os.readlink(path) if path.is_symlink() else "(gone)"
        print(f"{record['kind']}: {path} -> {now}" + (f" (was {record['previous']})" if "previous" in record else ""))
    return 0


def command_undo(_args) -> int:
    state = state_dir()
    left = []
    for record in reversed(load(state)):
        path = Path(record["path"])
        # Only what still points at this swap's copy: a link something else replaced or removed since
        # (a package manager, the person) is theirs now, and is left as it is.
        if not still_ours(record):
            print(f"cli-swap: {path} changed since the swap; left as it is", file=sys.stderr)
            left.append(record)
            continue
        if record["kind"] == "link":
            relink(path, record["previous"])
            print(f"cli-swap: {path} -> {record['previous']} again")
        else:
            path.unlink()
            print(f"cli-swap: removed {path}")
    save(state, [])
    return 1 if left else 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    apply = sub.add_parser("apply")
    apply.add_argument("--tree-key", required=True)
    apply.add_argument("--name")
    apply.add_argument("--sha")
    apply.add_argument("--app")
    apply.add_argument("--target")
    sub.add_parser("status")
    sub.add_parser("undo")
    args = parser.parse_args(argv)
    return {"apply": command_apply, "status": command_status, "undo": command_undo}[args.command](args)


if __name__ == "__main__":
    sys.exit(main())
