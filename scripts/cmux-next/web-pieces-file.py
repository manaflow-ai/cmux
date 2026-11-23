#!/usr/bin/env python3
"""Make the payload of a web update channel's switch file (cmux-tui/crates/cmux-web-pieces).

The switch file (`cmux-next-web/ota/pieces-<channel>.json` on files.cmux.com) swaps one web piece
out of every app that follows the channel, with no app update: the piece is served from the last
good update on disk or from the app's own bundle until the file names it live again. It also
names whole updates never to serve. It is signed like the web update pointer (web-ota-pointer.py
`sign`, the same envelope and pinned key) and told apart by its `purpose`.

This script only makes the next payload from the one published now: the same switches with the
asked changes, and the next serial (an app refuses a serial older than the last it took, so a
file can never be replayed to undo a switch).

Usage:
  web-pieces-file.py payload --channel C [--current PAYLOAD.json] --out P
      [--out-of PIECE=last-good|bundled[:REASON]]...   swap a piece (or a finer id under it) out
      [--live PIECE]...                                serve it from the newest update again
      [--refuse KEY]... [--allow KEY]...               never serve this update / serve it again
      [--all-live]                                     drop every switch (the refuse list stays)

PAYLOAD.json is what `web-ota-pointer.py verify --pointer F --keys K --channel C --purpose
cmux-web-pieces --allow-expired` printed for the published file; without it the file is the
channel's first (serial 1).
"""
import argparse
import json
import re
import sys
import time

SCHEMA = 1
PURPOSE = "cmux-web-pieces"
# A drill- channel rehearses the one it names: no app reads it unless told to (web_pieces.rs CHANNELS).
CHANNELS = ("every-merge", "nightly", "drill-every-merge", "drill-nightly")
# cmux-web-pieces PIECES; tests/test_web_pieces_file.sh holds the two lists equal.
PIECES = ("agent-pane", "pages", "agent-activity", "webviews-app", "inspector")
SERVES = ("last-good", "bundled")
KEY = re.compile(r"[0-9a-f]{64}")
# A finer id: its piece, then `/` and a name the fix-forward tools give (a page, a PR).
PIECE_ID = re.compile(r"[a-z0-9-]+(/[A-Za-z0-9._-]+)*")
# cmux-web-pieces MAX_BYTES bounds the whole signed file (the payload is base64 inside it).
MAX_PAYLOAD_BYTES = 40 * 1024
MAX_REASON = 200


def fail(message):
    print(f"web-pieces-file: {message}", file=sys.stderr)
    sys.exit(1)


def piece_id(name):
    if not PIECE_ID.fullmatch(name) or name.split("/", 1)[0] not in PIECES:
        fail(f"{name!r} is no web piece; the pieces are {', '.join(PIECES)} (a finer id is PIECE/NAME)")
    return name


def make(args):
    if args.channel not in CHANNELS:
        fail(f"unknown channel {args.channel!r}; the channels are {', '.join(CHANNELS)}")
    pieces, refuse, serial = {}, [], 0
    if args.current:
        current = json.load(open(args.current))
        if current.get("purpose") != PURPOSE or current.get("channel") != args.channel:
            fail(f"{args.current} is not the switch file of {args.channel}")
        serial = current.get("serial")
        if not isinstance(serial, int) or isinstance(serial, bool) or serial < 1:
            fail(f"{args.current} has no serial")
        pieces = dict(current.get("pieces") or {})
        refuse = list(current.get("refuse") or [])
    if args.all_live:
        pieces = {}
    for name in args.live:
        if pieces.pop(piece_id(name), None) is None and not args.all_live:
            fail(f"{name} is not switched out")
    for word in args.out_of:
        name, _, rest = word.partition("=")
        serve, _, reason = rest.partition(":")
        if serve not in SERVES:
            fail(f"--out-of {word!r}: say {name}=last-good or {name}=bundled, then :REASON")
        if len(reason) > MAX_REASON:
            fail(f"--out-of {name}: the reason is longer than {MAX_REASON} characters")
        pieces[piece_id(name)] = {"serve": serve, "reason": reason}
    for key in args.allow:
        if key not in refuse:
            fail(f"{key} is not refused")
        refuse.remove(key)
    for key in args.refuse:
        if not KEY.fullmatch(key):
            fail(f"--refuse {key!r} is no update key (64 hex digits, the pointer's `key`)")
        if key not in refuse:
            refuse.append(key)
    payload = {"schema": SCHEMA, "purpose": PURPOSE, "channel": args.channel, "serial": serial + 1,
               "published_at": int(time.time()), "pieces": pieces, "refuse": sorted(refuse)}
    data = json.dumps(payload, sort_keys=True, separators=(",", ":"))
    if len(data.encode()) > MAX_PAYLOAD_BYTES:
        fail("the switch file is too large for the app to take; drop old refuse entries")
    with open(args.out, "w") as out:
        out.write(data)
    switched = ", ".join(f"{name} -> {value.get('serve')}" for name, value in sorted(pieces.items())) or "every piece live"
    print(f"{args.channel} switch file serial {serial + 1}: {switched}; {len(refuse)} update(s) refused")


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("payload")
    p.add_argument("--channel", required=True)
    p.add_argument("--current")
    p.add_argument("--out", required=True)
    p.add_argument("--out-of", action="append", default=[], metavar="PIECE=SERVE[:REASON]")
    p.add_argument("--live", action="append", default=[], metavar="PIECE")
    p.add_argument("--refuse", action="append", default=[], metavar="KEY")
    p.add_argument("--allow", action="append", default=[], metavar="KEY")
    p.add_argument("--all-live", action="store_true")
    sub.add_parser("pieces")
    args = parser.parse_args(argv)
    if args.command == "pieces":
        print("\n".join(PIECES))
        return 0
    make(args)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
