#!/usr/bin/env python3
"""Pull bad builds off the cmux NEXT feed (nightly-next-rollback.yml).

Sparkle offers an item only when its sparkle:version is above the running
CFBundleVersion, so a feed can never move an installed app down. A pull does
the part a feed can do: it takes the bad build, and every newer one, out of
appcast-arm64.xml, so the newest remaining item (the previous good build,
whose signed DMG is still on the nightly-next release) is what new installs
and every Mac still below the bad build get. Macs already on the bad build
keep it until a newer build is published, or roll back to the build they kept
(the app's updates.rollback control method). docs/ci/nightly-next-canary.md has
the whole procedure.

  plan --feed FILE [--bad BUILD | --to BUILD] --out FILE
  pulled [--existing FILE] --pulled "BUILD ..." --serve BUILD --reason TEXT --at ISO8601 --out FILE
  reconcile --record "BUILD ..." --serve BUILD --reason TEXT --at ISO8601
            --endpoint-url URL --bucket NAME --key KEY --work DIR [--attempts N] [--delay SECONDS]

pulled writes pulled.json, the list the app reads next to the appcast with each
update check (PulledBuildWatch.swift): [{"build", "reason", "pulledAt",
"serve"}], newest build first. It merges into the existing list (a missing
or unreadable FILE counts as empty), replaces an entry for a build pulled
again, drops the build now served (a --to that serves a pulled build again
clears it) and keeps the newest MAX_PULLED entries.

reconcile makes pulled.json on R2 list every --record build (job pulled-json):
it reads the object straight from R2, merges as pulled does, and writes it
back only while it still holds the bytes it read (--replace-sha256, or
--write-once while it is missing). A concurrent write or an HTTP error reads
again and retries, up to --attempts times; a list that already has every build
is left alone, so a re-run is a no-op once it holds. Exit 1 when it is still
not written after the last attempt.

--bad pulls BUILD and everything newer (default: the newest item).
--to keeps BUILD as the newest item and pulls everything above it.
The other items are copied byte for byte. Prints a JSON summary:
{"pulled": [...], "serving": "BUILD", "serving_url": "DMG URL",
"changed": true|false, "record": [...]}. "record" is what pulled.json
must list: the pulled builds, or, when nothing is pulled because an earlier
run already took the named build (--bad or --if-newest) off the feed, that
build, so a re-run still writes pulled.json. "record_complete" is false when
an earlier pull may also have taken builds this run cannot see: the ones above
a --bad build, or above a --to build. Only that earlier run's own outputs
("Re-run failed jobs") name them. An --if-newest pull takes that one build
alone, so its record is complete. Exit 0 also
when there is nothing to pull (changed false, no file written), 1 when the
pull would leave the feed empty, the target is not on the feed, or the feed
cannot be read.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

ITEM = re.compile(r"[ \t]*<item>.*?</item>[ \t]*\n?", re.S)
VERSION = re.compile(r"<sparkle:version>\s*([^<]*?)\s*</sparkle:version>")
# The item's full archive: the first enclosure (deltas follow it).
ENCLOSURE = re.compile(r'<enclosure\s[^>]*?url="([^"]+)"')


class Refused(Exception):
    pass


def items(text: str) -> list[tuple[re.Match[str], str]]:
    found = []
    for match in ITEM.finditer(text):
        version = VERSION.search(match.group(0))
        if version is None or not version.group(1).isdigit():
            raise Refused(f"an item has no numeric sparkle:version: {match.group(0)[:200]!r}")
        found.append((match, version.group(1)))
    if not found:
        raise Refused("the feed has no items")
    return found


def plan(text: str, bad: str | None = None, to: str | None = None,
         if_newest: str | None = None) -> tuple[str, dict]:
    """(new feed text, summary). The text is unchanged when nothing is pulled.

    IF_NEWEST pulls nothing (changed false) unless that build is the feed's newest: an automated
    pull of a bad build never takes a newer build published after the bad one was judged."""
    if bad is not None and to is not None:
        raise Refused("pass --bad or --to, not both")
    for value in (bad, to, if_newest):
        if value is not None and not value.isdigit():
            raise Refused(f"build {value!r} is not a number")
    found = items(text)
    builds = [version for _, version in found]
    if if_newest is not None and max(int(b) for b in builds) != int(if_newest):
        return text, unchanged(found, if_newest, complete=True)
    if to is not None:
        if to not in builds:
            raise Refused(f"build {to} is not on the feed (it has {', '.join(builds)})")
        cutoff = int(to) + 1
    else:
        cutoff = int(bad) if bad is not None else max(int(b) for b in builds)
    pulled = [m for m, version in found if int(version) >= cutoff]
    kept = [(m, version) for m, version in found if int(version) < cutoff]
    if not pulled:
        return text, unchanged(found, bad, complete=to is None and bad is None)
    if not kept:
        raise Refused(f"pulling {', '.join(builds)} would leave the feed empty; "
                      "publish a fixed build instead (nothing older is on the feed)")
    out, last = [], 0
    for match in pulled:
        out.append(text[last:match.start()])
        last = match.end()
    out.append(text[last:])
    pulled_builds = sorted((VERSION.search(m.group(0)).group(1) for m in pulled), key=int, reverse=True)
    match, serving = max(kept, key=lambda entry: int(entry[1]))
    return "".join(out), {"pulled": pulled_builds, "serving": serving, "serving_url": enclosure(match),
                          "changed": True, "record": pulled_builds, "record_complete": True}


def unchanged(found: list[tuple[re.Match[str], str]], named: str | None, complete: bool) -> dict:
    """The summary of a plan that pulls nothing. A named build above the served one and off the
    feed was pulled by an earlier run: it stays in "record" so a re-run reconciles pulled.json.
    COMPLETE: that earlier pull cannot have taken builds this run cannot name."""
    match, serving = max(found, key=lambda entry: int(entry[1]))
    gone = named is not None and int(named) > int(serving) and named not in {v for _, v in found}
    return {"pulled": [], "serving": serving, "serving_url": enclosure(match), "changed": False,
            "record": [named] if gone else [], "record_complete": complete}


MAX_PULLED = 50


def pulled_list(existing: str | None, pulled: list[str], serve: str, reason: str, at: str) -> list[dict]:
    """The merged pulled.json entries, newest build first."""
    for value in [*pulled, serve]:
        if not value.isdigit():
            raise Refused(f"build {value!r} is not a number")
    entries: dict[str, dict] = {}
    try:
        old = json.loads(existing) if existing else []
    except json.JSONDecodeError:
        old = []
    for entry in old if isinstance(old, list) else []:
        if isinstance(entry, dict) and str(entry.get("build", "")).isdigit():
            entries[str(entry["build"])] = entry
    for build in pulled:
        entries[build] = {"build": build, "reason": reason, "pulledAt": at, "serve": serve}
    entries.pop(serve, None)
    return sorted(entries.values(), key=lambda entry: int(entry["build"]), reverse=True)[:MAX_PULLED]


class StoreError(Exception):
    """pulled.json could not be read or written (an HTTP or network error)."""


def sha256(body: bytes) -> str:
    return hashlib.sha256(body).hexdigest()


def reconcile(read, write, record: list[str], serve: str, reason: str, at: str,
              attempts: int = 5, delay: float = 10.0, sleep=time.sleep) -> dict:
    """Make pulled.json list every RECORD build. READ() returns the object's bytes or None (missing);
    WRITE(body, replace_sha256) writes only while the object still has that SHA-256 (None: while it is
    missing) and returns False on a conflict. Both raise StoreError on an HTTP error. A conflict or an
    error reads again and retries, waiting DELAY * attempt; StoreError after the last attempt."""
    if not record:
        return {"written": False, "pulled": [], "attempts": 0}
    last = "no attempt"
    for attempt in range(1, attempts + 1):
        if attempt > 1:
            sleep(delay * (attempt - 1))
        try:
            body = read()
            text = body.decode("utf-8", "replace") if body is not None else None
            entries = pulled_list(text, record, serve, reason, at)
            try:
                listed = {str(e.get("build")) for e in json.loads(text) if isinstance(e, dict)} if text else set()
            except (json.JSONDecodeError, TypeError):
                listed = set()
            if set(record) <= listed and serve not in listed:
                return {"written": False, "pulled": [e["build"] for e in entries], "attempts": attempt}
            new = (json.dumps(entries, indent=2) + "\n").encode("utf-8")
            if write(new, None if body is None else sha256(body)):
                return {"written": True, "pulled": [e["build"] for e in entries], "attempts": attempt}
            last = "a concurrent write changed pulled.json"
        except StoreError as error:
            last = str(error)
        print(f"pulled.json attempt {attempt} of {attempts}: {last}", file=sys.stderr)
    raise StoreError(f"pulled.json not written after {attempts} attempts: {last}")


def r2_store(uploader: str, endpoint: str, bucket: str, key: str, work: Path):
    """read and write for reconcile, through scripts/ci/upload-r2-object.py."""
    common = ["--endpoint-url", endpoint, "--bucket", bucket, "--key", key]
    live, out = work / "pulled-live.json", work / "pulled.json"

    def call(args: list[str]) -> int:
        result = subprocess.run([sys.executable, uploader, *common, *args], capture_output=True, text=True)
        sys.stderr.write(result.stdout + result.stderr)
        return result.returncode

    def read() -> bytes | None:
        live.unlink(missing_ok=True)
        code = call(["--download-to", str(live)])
        if code == 22:
            return None
        if code != 0:
            raise StoreError(f"reading pulled.json failed (exit {code})")
        return live.read_bytes()

    def write(body: bytes, replace_sha256: str | None) -> bool:
        out.write_bytes(body)
        mode = ["--write-once"] if replace_sha256 is None else ["--replace-sha256", replace_sha256]
        code = call(["--file", str(out), "--content-type", "application/json",
                     "--cache-control", "no-cache, no-store, must-revalidate", *mode, "--conflict-exit-code", "3"])
        if code == 3:
            return False
        if code != 0:
            raise StoreError(f"writing pulled.json failed (exit {code})")
        return True

    return read, write


def enclosure(match: re.Match[str]) -> str:
    url = ENCLOSURE.search(match.group(0))
    if url is None:
        raise Refused(f"item has no enclosure: {match.group(0)[:200]!r}")
    return url.group(1)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("plan")
    p.add_argument("--feed", required=True)
    target = p.add_mutually_exclusive_group()
    target.add_argument("--bad")
    target.add_argument("--to")
    p.add_argument("--if-newest", help="pull nothing unless this build is the feed's newest")
    p.add_argument("--out", required=True)
    q = sub.add_parser("pulled")
    q.add_argument("--existing")
    q.add_argument("--pulled", required=True, help="space-separated builds")
    q.add_argument("--serve", required=True)
    q.add_argument("--reason", required=True)
    q.add_argument("--at", required=True)
    q.add_argument("--out", required=True)
    r = sub.add_parser("reconcile")
    r.add_argument("--record", required=True, help="space-separated builds pulled.json must list")
    r.add_argument("--serve", required=True)
    r.add_argument("--reason", required=True)
    r.add_argument("--at", required=True)
    r.add_argument("--endpoint-url", required=True)
    r.add_argument("--bucket", required=True)
    r.add_argument("--key", required=True)
    r.add_argument("--work", required=True, help="directory for the copies read and written")
    r.add_argument("--attempts", type=int, default=5)
    r.add_argument("--delay", type=float, default=10.0, help="seconds; the wait grows with each attempt")
    r.add_argument("--uploader", default=str(Path(__file__).resolve().with_name("upload-r2-object.py")))
    args = parser.parse_args(argv)
    if args.command == "reconcile":
        read, write = r2_store(args.uploader, args.endpoint_url, args.bucket, args.key, Path(args.work))
        try:
            result = reconcile(read, write, args.record.split(), args.serve, args.reason, args.at,
                               attempts=max(1, args.attempts), delay=args.delay)
        except (Refused, StoreError) as error:
            print(f"failed: {error}", file=sys.stderr)
            return 1
        print(json.dumps(result))
        return 0
    if args.command == "pulled":
        existing = None
        if args.existing:
            try:
                with open(args.existing, encoding="utf-8") as handle:
                    existing = handle.read()
            except (OSError, UnicodeDecodeError):
                existing = None
        try:
            entries = pulled_list(existing, args.pulled.split(), args.serve, args.reason, args.at)
        except Refused as error:
            print(f"refused: {error}", file=sys.stderr)
            return 1
        with open(args.out, "w", encoding="utf-8") as handle:
            json.dump(entries, handle, indent=2)
            handle.write("\n")
        print(json.dumps({"pulled": [entry["build"] for entry in entries]}))
        return 0
    try:
        with open(args.feed, encoding="utf-8") as handle:
            text = handle.read()
        new, summary = plan(text, bad=args.bad, to=args.to, if_newest=args.if_newest)
    except (OSError, UnicodeDecodeError, Refused) as error:
        print(f"refused: {error}", file=sys.stderr)
        return 1
    if summary["changed"]:
        with open(args.out, "w", encoding="utf-8") as handle:
            handle.write(new)
    print(json.dumps(summary))
    return 0


if __name__ == "__main__":
    sys.exit(main())
