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

  expected-commit --repo OWNER/NAME --build BUILD --notes-base URL
      The commit BUILD was made from, as GITHUB_OUTPUT lines commit=<40 hex> and commit_source=.
      nightly.yml may build an earlier commit than its run's head (pin-cmux-tui.sh
      resolve-newest-published), and stamps that commit's first 7 hex as CMUXCommit. Its record is
      the build's signed release notes, URL/<BUILD>.json ("head", signed with the content-signing
      key, nightly.yml CONTENT_PUBLIC_KEY, in URL/<BUILD>.json.sig). A build with none (a recovered
      build; the notes job publishes only a run's own build) remains unknown. The workflow
      head can differ from the resolved artifact source, so it is never a fallback. Missing or
      unverifiable notes print commit= (empty) and a warning, and exit 0: the canary records no
      verdict and the next tick checks the build again.

  commit --plist Info.plist --expected SHA
      Fails (exit 1) unless the app's CMUXCommit is a valid commit (7 to 40 lowercase hex; nightly.yml
      stamps the build commit's first 7) and SHA (40 hex, expected-commit's) starts with it, so a stale
      or misassembled
      DMG that carries the expected build number but another commit never passes. Prints
      commit=<CMUXCommit> for GITHUB_OUTPUT and writes the comparison to GITHUB_STEP_SUMMARY.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import sys
import tempfile
import urllib.error
import urllib.request

HERE = Path(__file__).resolve().parent
VERIFY = HERE / "release-signer" / "verify_appcast_item.py"
# nightly.yml env NIGHTLY_NEXT_SPARKLE_PUBLIC_KEY (tests/test_nightly_next_artifact_check.py keeps them equal).
NIGHTLY_NEXT_SPARKLE_PUBLIC_KEY = "IOPItMLjtc4NsROTNZ6a/jsUW+C4fcicl6SNjVVvzRM="
# nightly.yml sign-release-notes env CONTENT_PUBLIC_KEY, the key the release notes are signed with (same test).
CONTENT_PUBLIC_KEY = "AnrDI4vqN4lFGX2IpzeWPZsa/Hk7yQMkVIKppFwAst4="


FULL_SHA = re.compile(r"^[0-9a-f]{40}$")
APP_COMMIT = re.compile(r"^[0-9a-f]{7,40}$")


class Mismatch(Exception):
    pass


class Unknown(Exception):
    """The expected commit cannot be read now: no verdict, the next tick tries again."""


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
        raise Mismatch(f"the app was built from {app_commit}, the build's source commit is {expected}")
    return app_commit


def read_app_commit(plist: Path) -> str:
    with plist.open("rb") as handle:
        value = plistlib.load(handle).get("CMUXCommit", "")
    return value.strip() if isinstance(value, str) else ""


def fetch_url(url: str) -> bytes | None:
    """URL's bytes, None on a 404; any other error raises."""
    request = urllib.request.Request(url, headers={"User-Agent": "cmux-nightly-next-canary/1", "Cache-Control": "no-cache"})
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return response.read()
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None
        raise


def signed_notes_head(build: str, notes_base: str, fetch, public_key: str | None = None) -> str | None:
    """The "head" of BUILD's signed release notes, None when they are not published; Unknown when
    they cannot be read or trusted."""
    public_key = public_key or CONTENT_PUBLIC_KEY
    nonce = f"?canary={os.environ.get('GITHUB_RUN_ID', '0')}"  # past a cached 404 from an earlier tick
    url = f"{notes_base.rstrip('/')}/{build}.json"
    try:
        body = fetch(url + nonce)
        if body is None:
            return None
        signature = fetch(f"{url}.sig{nonce}")
    except Exception as error:  # noqa: BLE001 - any read error is no answer this tick
        raise Unknown(f"could not read {url}: {error}") from None
    if signature is None:
        raise Unknown(f"{url} has no signature")
    try:
        raw = base64.b64decode(signature.strip(), validate=True)
        public = base64.b64decode(public_key, validate=True)
    except ValueError:
        raise Unknown(f"{url}.sig or the content key is not base64") from None
    with tempfile.NamedTemporaryFile() as copy:
        copy.write(body)
        copy.flush()
        if len(raw) != 64 or len(public) != 32 or not _ed25519_verify()(public, raw, copy.name):
            raise Unknown(f"{url}.sig does not verify with the content-signing key {public_key}")
    try:
        notes = json.loads(body)
    except ValueError:
        raise Unknown(f"{url} is not JSON") from None
    if not isinstance(notes, dict):
        raise Unknown(f"{url} is not a JSON object")
    head = str(notes.get("head", ""))
    if str(notes.get("build", "")) != build or not FULL_SHA.match(head):
        raise Unknown(f"{url} is not build {build}'s notes with a 40-hex head")
    return head


def expected_commit(repo: str, build: str, notes_base: str, api=None, fetch=fetch_url) -> tuple[str, str]:
    """(commit, where it came from) for BUILD; Unknown when it cannot be read now."""
    sys.path.insert(0, str(HERE))
    import nightly_next_fix_forward as fix_forward  # noqa: PLC0415

    try:
        fix_forward.build_run(build)
    except ValueError as error:
        raise Unknown(str(error)) from None
    head = signed_notes_head(build, notes_base, fetch)
    if head:
        return head, "its signed release notes"
    # The workflow head is not proof of the artifact source: nightly.yml may resolve an older
    # build_sha, and recovery builds deliberately have no signed notes. Waiting for a trusted
    # signed source record avoids rejecting a valid DMG (or accepting a mismatched one).
    raise Unknown(f"build {build} has no signed release notes; its artifact source is not proven")


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
    e.add_argument("--notes-base", required=True)
    c = sub.add_parser("commit")
    c.add_argument("--plist", type=Path, required=True)
    c.add_argument("--expected", default="")
    c.add_argument("--expected-source", default="")
    args = parser.parse_args(argv)
    if args.command == "expected-commit":
        try:
            commit, source = expected_commit(args.repo, args.build, args.notes_base)
        except Unknown as error:
            print(f"::warning title=nightly-next source commit::{error}; no verdict this tick", file=sys.stderr)
            _summary(f"- Source commit of build {args.build}: unknown ({error}); not checked, no verdict this tick")
            print("commit=\ncommit_source=")
            return 0
        print(f"commit={commit}\ncommit_source={source}")
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
        _summary(f"- Source commit: the app's CMUXCommit `{app_commit}` is the build's source commit "
                 f"`{args.expected}`" + (f" ({args.expected_source})" if args.expected_source else ""))
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
