#!/usr/bin/env python3
"""The signed config ring files (cmuxterm-hq docs/rfd/0224-one-update-system.md, "Hot patches":
flags first, so flipping a flag is the default fix for a bad feature, with no new build).

cmux-tui/rings/<ring>.json in this repo holds a ring's flags ({"flags": {name: bool|number|string}});
.github/workflows/cmux-config-ring.yml makes its payload here, signs it with the web update key
(scripts/cmux-next/web-ota-pointer.py sign) and writes files.cmux.com/cmux-tui/rings/<ring>.json.
acpmux reads that file on every `host self-update` tick (cmux_signed_envelope::config_ring::verify)
and keeps the seq it applied; it refuses an older seq, so the file only moves forward.

  cmux-config-ring.py payload --source SRC --ring R --seq N --now T [--days D] --out OUT
  cmux-config-ring.py seq --published FILE     # the seq of a published file, 0 when none
  cmux-config-ring.py newer --published FILE --payload OUT   # exit 0: publish; 3: a newer one is out

The limits match the Rust reader (cmux-tui/crates/cmux-signed-envelope/src/config_ring.rs), so a file
CI publishes is one every reader takes.
"""

import argparse
import base64
import json
import math
import re
import sys

PURPOSE = "cmux-config-ring"
PAYLOAD_SCHEMA = 1
MAX_RING_BYTES = 64 * 1024
MAX_FLAGS = 512
MAX_NAME = 64
MAX_STRING = 1024
NAME = re.compile(r"^[a-z0-9._-]+$")
# Payload bytes grow by about 4/3 in base64, plus the envelope and one signature.
MAX_PAYLOAD_BYTES = (MAX_RING_BYTES - 1024) * 3 // 4


class Refused(Exception):
    pass


def valid_name(name):
    return isinstance(name, str) and 0 < len(name) <= MAX_NAME and bool(NAME.match(name))


def checked_flags(source):
    if not isinstance(source, dict) or set(source) != {"flags"} or not isinstance(source["flags"], dict):
        raise Refused('a ring source is {"flags": {...}} and nothing else')
    flags = source["flags"]
    if len(flags) > MAX_FLAGS:
        raise Refused(f"{len(flags)} flags, over {MAX_FLAGS}")
    for name, value in flags.items():
        if not valid_name(name):
            raise Refused(f"flag name {name!r} is not [a-z0-9._-] of at most {MAX_NAME}")
        if isinstance(value, bool) or (isinstance(value, (int, float)) and math.isfinite(value)):
            continue
        if isinstance(value, str):
            if len(value.encode()) > MAX_STRING:
                raise Refused(f"flag {name}: the string is over {MAX_STRING} bytes")
            continue
        raise Refused(f"flag {name}: a value is a bool, a number or a string")
    return flags


def payload(args):
    if not valid_name(args.ring):
        raise Refused(f"ring name {args.ring!r} is not [a-z0-9._-] of at most {MAX_NAME}")
    if args.seq <= 0 or args.days <= 0:
        raise Refused("--seq and --days are positive")
    with open(args.source) as f:
        flags = checked_flags(json.load(f))
    body = {"schema": PAYLOAD_SCHEMA, "purpose": PURPOSE, "ring": args.ring, "seq": args.seq,
            "issued_at": args.now, "expires_at": args.now + args.days * 86400, "flags": flags}
    data = json.dumps(body, sort_keys=True, separators=(",", ":")).encode()
    if len(data) > MAX_PAYLOAD_BYTES:
        raise Refused(f"the payload is {len(data)} bytes, over {MAX_PAYLOAD_BYTES}")
    with open(args.out, "wb") as out:
        out.write(data)


def published_seq(path):
    """The seq of the published file at `path`: 0 when there is none or it is not a ring file
    (the signature is the reader's to check; this only keeps CI from moving the file back)."""
    try:
        with open(path, "rb") as f:
            envelope = json.loads(f.read() or b"null")
        body = json.loads(base64.b64decode(envelope["payload"]))
        if body.get("purpose") != PURPOSE:
            return 0
        return int(body["seq"])
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("payload")
    p.add_argument("--source", required=True)
    p.add_argument("--ring", required=True)
    p.add_argument("--seq", type=int, required=True, help="the source commit's time: later commits sort later")
    p.add_argument("--now", type=int, required=True)
    p.add_argument("--days", type=int, default=30, help="how long readers take it; the workflow passes 365")
    p.add_argument("--out", required=True)
    s = sub.add_parser("seq")
    s.add_argument("--published", required=True)
    n = sub.add_parser("newer")
    n.add_argument("--published", required=True)
    n.add_argument("--payload", required=True)
    args = parser.parse_args(argv)
    try:
        if args.command == "payload":
            payload(args)
        elif args.command == "seq":
            print(published_seq(args.published))
        else:
            with open(args.payload) as f:
                new = json.load(f)["seq"]
            old = published_seq(args.published)
            # The same seq is a re-sign (a later expiry): readers keep it as unchanged.
            if old > new:
                print(f"cmux-config-ring: seq {old} is published, newer than {new}: kept")
                return 3
            print(f"cmux-config-ring: publishing seq {new} over {old}")
    except Refused as error:
        print(f"::error::cmux-config-ring: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
