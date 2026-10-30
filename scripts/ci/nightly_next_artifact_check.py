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

  expected-commit --repo OWNER/NAME --build BUILD
      The source commit of BUILD: the head of the nightly-next nightly.yml run that made it (build =
      run id + two-digit attempt), as nightly_next_fix_forward.build_commit reads it and the durable
      verdict records it (nightly_next_train.checked_verdict). Prints commit=<40 hex> for
      GITHUB_OUTPUT; exit 1 when the run cannot be read or is not a nightly-next publishing run.
      Needs GH_TOKEN for `gh api`.

  commit --plist Info.plist --expected SHA
      Fails (exit 1) unless the app's CMUXCommit is a valid commit (7 to 40 lowercase hex; nightly.yml
      stamps the build commit's first 7) and SHA (40 hex) starts with it, so a stale or misassembled
      DMG that carries the expected build number but another commit never passes. Prints
      commit=<CMUXCommit> for GITHUB_OUTPUT and writes the comparison to GITHUB_STEP_SUMMARY.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import importlib.util
import os
from pathlib import Path
import plistlib
import re
import sys

HERE = Path(__file__).resolve().parent
VERIFY = HERE / "release-signer" / "verify_appcast_item.py"
# nightly.yml env NIGHTLY_NEXT_SPARKLE_PUBLIC_KEY (tests/test_nightly_next_artifact_check.py keeps them equal).
NIGHTLY_NEXT_SPARKLE_PUBLIC_KEY = "IOPItMLjtc4NsROTNZ6a/jsUW+C4fcicl6SNjVVvzRM="


FULL_SHA = re.compile(r"^[0-9a-f]{40}$")
APP_COMMIT = re.compile(r"^[0-9a-f]{7,40}$")


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


def check_commit(app_commit: str, expected: str) -> str:
    """The app's CMUXCommit once it names EXPECTED; Mismatch otherwise."""
    if not FULL_SHA.match(expected):
        raise Mismatch(f"the expected source commit {expected!r} is not a 40-hex SHA")
    if not APP_COMMIT.match(app_commit):
        raise Mismatch(f"the app's CMUXCommit {app_commit!r} is not a commit SHA")
    if not expected.startswith(app_commit):
        raise Mismatch(f"the app was built from {app_commit}, the build's nightly-next run is at {expected}")
    return app_commit


def read_app_commit(plist: Path) -> str:
    with plist.open("rb") as handle:
        value = plistlib.load(handle).get("CMUXCommit", "")
    return value.strip() if isinstance(value, str) else ""


def expected_commit(repo: str, build: str, api=None) -> str:
    """The head of BUILD's nightly-next run; Mismatch when there is none."""
    sys.path.insert(0, str(HERE))
    import nightly_next_fix_forward as fix_forward  # noqa: PLC0415

    errors: list[str] = []

    def reading(path: str, *rest, **kwargs):
        try:
            return (api or fix_forward.gh_api)(path, *rest, **kwargs)
        except Exception as error:  # noqa: BLE001 - build_commit treats it as no run; keep the reason
            detail = (getattr(error, "stderr", "") or "").strip()  # gh's own message
            errors.append(detail or str(error).strip() or type(error).__name__)
            raise

    try:
        run = fix_forward.build_run(build)
    except ValueError as error:
        raise Mismatch(str(error)) from None
    commit = fix_forward.build_commit(reading, repo, build)
    if not commit:
        why = f"could not read run {run}: {errors[-1]}" if errors else \
            f"run {run} is not a nightly-next publishing run of {repo}"
        raise Mismatch(f"build {build} has no source commit ({why})")
    return commit


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
    e = sub.add_parser("expected-commit")
    e.add_argument("--repo", required=True)
    e.add_argument("--build", required=True)
    c = sub.add_parser("commit")
    c.add_argument("--plist", type=Path, required=True)
    c.add_argument("--expected", default="")
    args = parser.parse_args(argv)
    if args.command == "expected-commit":
        try:
            commit = expected_commit(args.repo, args.build)
        except Mismatch as error:
            print(f"::error title=nightly-next source commit::{error}", file=sys.stderr)
            return 1
        print(f"commit={commit}")
        return 0
    if args.command == "commit":
        app_commit = read_app_commit(args.plist)
        try:
            check_commit(app_commit, args.expected)
        except Mismatch as error:
            print(f"::error title=nightly-next app commit::{error}", file=sys.stderr)
            _summary(f"- Source commit: **mismatch**: {error}")
            return 1
        print(f"commit={app_commit}")
        _summary(f"- Source commit: the app's CMUXCommit `{app_commit}` is the build's nightly-next run head "
                 f"`{args.expected}`")
        return 0
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
