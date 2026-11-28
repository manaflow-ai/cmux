#!/usr/bin/env python3
"""The signed patch bundles (cmuxterm-hq docs/rfd/0224-one-update-system.md, phase 5: a fix to a
few files ships to hosts on one build without a new build).

cmux-tui/patches/<channel>/<target>.json in this repo names one bundle:
  {"id": "fix-1", "base": "<full commit of the build it applies onto>", "days": 14,
   "files": [{"path": "web/app.js", "source": "<repo path of the new content>"}]}
.github/workflows/cmux-patch-bundle.yml makes its payload here, signs it with the web update key
(scripts/cmux-next/web-ota-pointer.py sign) and writes files.cmux.com/cmux-tui/bundles/<channel>/
<target>.json. acpmux reads it on every `host self-update` tick (cmux-tui/crates/acpmux/src/cli/
host_self_update_bundle.rs), verifies it (cmux_signed_envelope::patch_bundle::verify), writes its
files and keeps them only while the daemon's status answers; a rolled-back id is never tried again.

  cmux-patch-bundle.py payload --manifest M --target T --now N --root R --out OUT

The limits match the Rust reader, so a bundle CI publishes is one every reader takes.
"""

import argparse
import base64
import hashlib
import json
import os
import re
import sys

PURPOSE = "cmux-patch-bundle"
PAYLOAD_SCHEMA = 1
MAX_BUNDLE_BYTES = 8 * 1024 * 1024
MAX_FILES = 64
MAX_NAME = 64
MAX_PATH = 512
MAX_DAYS = 90
NAME = re.compile(r"^[a-z0-9._-]+$")
COMMIT = re.compile(r"^[0-9a-f]{40}$")
# Payload bytes grow by about 4/3 in base64, plus the envelope and one signature.
MAX_PAYLOAD_BYTES = (MAX_BUNDLE_BYTES - 4096) * 3 // 4


class Refused(Exception):
    pass


def valid_id(name):
    return isinstance(name, str) and 0 < len(name) <= MAX_NAME and bool(NAME.match(name))


def valid_path(path):
    # The reader's rule: each `/` part non-empty, no leading dot, no `\`, NUL or `:`.
    if not isinstance(path, str) or not path or len(path) > MAX_PATH:
        return False
    return all(
        part and len(part) <= MAX_NAME and not part.startswith(".")
        and not any(c in part for c in "\\\0:")
        for part in path.split("/")
    )


def payload(manifest, target, now, root):
    if not isinstance(manifest, dict) or not set(manifest) <= {"id", "base", "days", "files"}:
        raise Refused('a bundle manifest is {"id", "base", "files", ["days"]} and nothing else')
    bundle_id, base, files = manifest.get("id"), manifest.get("base"), manifest.get("files")
    days = manifest.get("days", 14)
    if not valid_id(bundle_id):
        raise Refused(f"bundle id {bundle_id!r} is not [a-z0-9._-] of at most {MAX_NAME}")
    if not valid_id(target):
        raise Refused(f"target {target!r} is not [a-z0-9._-] of at most {MAX_NAME}")
    if not isinstance(base, str) or not COMMIT.match(base):
        raise Refused(f"base {base!r} is not a full 40-hex commit")
    if isinstance(days, bool) or not isinstance(days, int) or not 0 < days <= MAX_DAYS:
        raise Refused(f"days {days!r} is not 1 to {MAX_DAYS}")
    if not isinstance(files, list) or not 0 < len(files) <= MAX_FILES:
        raise Refused(f"a bundle has 1 to {MAX_FILES} files")
    root = os.path.realpath(root)
    seen, out = set(), []
    for entry in files:
        if not isinstance(entry, dict) or set(entry) != {"path", "source"}:
            raise Refused('a file is {"path", "source"} and nothing else')
        path, source = entry["path"], entry["source"]
        if not valid_path(path):
            raise Refused(f"path {path!r} is not a plain relative path")
        if path in seen:
            raise Refused(f"path {path!r} is in the bundle twice")
        seen.add(path)
        full = os.path.realpath(os.path.join(root, source)) if isinstance(source, str) else ""
        if not full.startswith(root + os.sep) or not os.path.isfile(full):
            raise Refused(f"source {source!r} is not a file in the repo")
        with open(full, "rb") as f:
            content = f.read()
        out.append({
            "path": path,
            "sha256": hashlib.sha256(content).hexdigest(),
            "content": base64.b64encode(content).decode(),
        })
    body = {
        "schema": PAYLOAD_SCHEMA, "purpose": PURPOSE, "id": bundle_id, "target": target,
        "base": base, "issued_at": now, "expires_at": now + days * 86400, "files": out,
    }
    if len(json.dumps(body, separators=(",", ":")).encode()) > MAX_PAYLOAD_BYTES:
        raise Refused(f"the bundle payload is over {MAX_PAYLOAD_BYTES} bytes")
    return body


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("payload")
    p.add_argument("--manifest", required=True)
    p.add_argument("--target", required=True)
    p.add_argument("--now", type=int, required=True)
    p.add_argument("--root", default=".")
    p.add_argument("--out", required=True)
    args = parser.parse_args(argv)
    try:
        with open(args.manifest, "rb") as f:
            manifest = json.load(f)
        body = payload(manifest, args.target, args.now, args.root)
    except (Refused, ValueError, OSError) as err:
        print(f"cmux-patch-bundle: {args.manifest}: {err}", file=sys.stderr)
        return 2
    with open(args.out, "w") as f:
        json.dump(body, f, separators=(",", ":"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
