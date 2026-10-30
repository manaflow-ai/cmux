#!/usr/bin/env python3
"""Check a cmux NEXT DMG downloaded from the feed against what the feed promises.

The post-publish checks (nightly-next-canary.yml, nightly-next-launch-smoke.yml) download the
newest feed build's DMG. Its byte length alone says nothing about its bytes: a stale or corrupt
object of the same length would pass. The feed item's sparkle:edSignature is the digest the
pipeline publishes for those bytes (the signer checks it with verify_appcast_item.py before
publication, and Sparkle checks it before it installs an update), so the checks verify it over
the exact bytes they downloaded.

  dmg --dmg PATH --length N --ed-signature SIG [--public-key KEY]
      Fails (exit 1) unless the DMG is N bytes and SIG (base64, the feed item's
      sparkle:edSignature) verifies over its bytes with KEY (base64 Ed25519; default the pinned
      cmux NEXT key, nightly.yml NIGHTLY_NEXT_SPARKLE_PUBLIC_KEY). Prints sha256=<hex> of the
      bytes checked, for GITHUB_OUTPUT, and appends one line to GITHUB_STEP_SUMMARY when set.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import importlib.util
import os
from pathlib import Path
import sys

HERE = Path(__file__).resolve().parent
VERIFY = HERE / "release-signer" / "verify_appcast_item.py"
# nightly.yml env NIGHTLY_NEXT_SPARKLE_PUBLIC_KEY (tests/test_nightly_next_artifact_check.py keeps them equal).
NIGHTLY_NEXT_SPARKLE_PUBLIC_KEY = "IOPItMLjtc4NsROTNZ6a/jsUW+C4fcicl6SNjVVvzRM="


class Mismatch(Exception):
    pass


def _ed25519_verify():
    spec = importlib.util.spec_from_file_location("verify_appcast_item", VERIFY)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.ed25519_verify


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def check_dmg(dmg: Path, length: str, signature: str, public_key: str = NIGHTLY_NEXT_SPARKLE_PUBLIC_KEY) -> str:
    """The DMG's SHA-256 once its length and edSignature match the feed's; Mismatch otherwise."""
    size = dmg.stat().st_size
    if not length.isdigit() or int(length) != size:
        raise Mismatch(f"downloaded {size} bytes, the feed says {length or 'nothing'}")
    try:
        public = base64.b64decode(public_key, validate=True)
        raw = base64.b64decode(signature, validate=True)
    except ValueError:
        raise Mismatch("the feed's edSignature or the public key is not base64") from None
    if len(public) != 32 or len(raw) != 64:
        raise Mismatch("the feed's edSignature or the public key has the wrong length for Ed25519")
    if not _ed25519_verify()(public, raw, str(dmg)):
        raise Mismatch(f"the feed's edSignature does not verify over the downloaded bytes with {public_key}")
    return file_sha256(dmg)


def _summary(line: str) -> None:
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if path:
        with open(path, "a", encoding="utf-8") as out:
            out.write(line + "\n")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    d = sub.add_parser("dmg")
    d.add_argument("--dmg", type=Path, required=True)
    d.add_argument("--length", required=True)
    d.add_argument("--ed-signature", default="")
    d.add_argument("--public-key", default=NIGHTLY_NEXT_SPARKLE_PUBLIC_KEY)
    args = parser.parse_args(argv)
    try:
        sha256 = check_dmg(args.dmg, args.length, args.ed_signature, args.public_key)
    except Mismatch as error:
        print(f"::error title=nightly-next DMG::{args.dmg.name}: {error}", file=sys.stderr)
        _summary(f"- DMG: **mismatch**: {error}")
        return 1
    print(f"sha256={sha256}")
    _summary(f"- DMG: {args.length} bytes, edSignature verified with the pinned key, SHA-256 `{sha256}`")
    return 0


if __name__ == "__main__":
    sys.exit(main())
