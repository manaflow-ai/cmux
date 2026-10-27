#!/usr/bin/env python3
"""Publish a remote feature change between nightlies: an operator tool, never a CI step.

  publish-flags.py --cohort C --off NAME [--off NAME ...] [--on NAME ...] --reason TEXT [--dry-run] [--test-key]

It loads the published `notes/flags.json`, verified with the content-signing public key (or, with no
published document, `release-notes/next/flags.json`), sets `Features` of cohort C (`default` for
everyone), raises `FeaturesSerial`, prints the diff, signs the result and uploads `flags.json`,
`flags.json.sig` and `history/<serial>.json(.sig)` (the reason and the change) next to it. The model is
Chrome's variations seed: a signed document with a serial that a client never lets go backwards
(components/variations/variations_seed_store.cc). The design is section 3.9 of
plans/cmux-next/chrome-parity/p12-perf-process.md.

- Only registered features (schemas/features/features.d) of kind killSwitch or perfPath are allowed.
- The document stays version 1 and passes nightly.yml's assertion, checked before anything is signed.
- Signing uses `release-notes.py sign`, the nightly's own command. The production key is the PEM file
  named by CMUX_CONTENT_SIGNING_KEY_PATH (decision D2); its path and content are never printed. Every
  file is verified with the destination's public key before upload.
- `history/<serial>.json` is written once, so two operators cannot publish the same serial; `flags.json`
  is replaced only while it still has the bytes this run loaded. The serial is the first one above the
  published and checkout serials with no history record, so a run that stopped after reserving one can
  run again. A published `flags.json` whose signature does not verify is published over only when it is
  the document of its serial's signed history record (a run that stopped before `flags.json.sig`).
- `--test-key` signs with the perf lab's committed test key (schemas/features/bench-test-signing-key.json,
  trusted only by bench builds) and publishes to perf-lab-test, never to the nightly feed.
- A production publish applies the same change and serial to release-notes/next/flags.json in this
  checkout. Land it before the next nightly, or the nightly republishes the old features.

Environment: AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY (R2), plus NIGHTLY_NEXT_R2_ENDPOINT and
CMUX_CONTENT_SIGNING_KEY_PATH for production, or CMUX_PERF_LAB_R2_ENDPOINT, CMUX_PERF_LAB_R2_BUCKET and
CMUX_PERF_LAB_FLAGS_BASE (the public URL of the bucket's perf-lab-test/ folder) with --test-key.
"""
from __future__ import annotations

import argparse
import base64
import copy
import dataclasses
import datetime
import difflib
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
from pathlib import Path
from typing import Callable, Mapping, Protocol

REPO = Path(__file__).resolve().parent.parent.parent
REGISTRY = REPO / "schemas/features/features.d"
CHECKOUT_FLAGS = REPO / "release-notes/next/flags.json"
TEST_KEY_FILE = REPO / "schemas/features/bench-test-signing-key.json"
RELEASE_NOTES = REPO / "scripts/cmux-next/release-notes.py"
UPLOADER = REPO / "scripts/ci/upload-r2-object.py"
NIGHTLY_GUARD = REPO / "scripts/ci/nightly-next-guard.py"

# The content-signing public key: ContentSignature.publicKey in the app, PUBLIC_KEY in the daemon's
# feature_flags.rs and CONTENT_PUBLIC_KEY in nightly.yml (the tests compare all four).
CONTENT_PUBLIC_KEY = "AnrDI4vqN4lFGX2IpzeWPZsa/Hk7yQMkVIKppFwAst4="
KEY_PATH_ENV = "CMUX_CONTENT_SIGNING_KEY_PATH"
ALLOWED_KINDS = ("killSwitch", "perfPath")
DEFAULT_COHORT = "default"
COHORT_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")
# Cache-Control of flags.json(.sig) in nightly.yml: a kill reaches the next fetch.
NO_CACHE = "no-cache, no-store, must-revalidate"
HISTORY_CACHE = "public, max-age=3600"
# PKCS#8 prefix of a raw Ed25519 private seed (RFC 8410).
ED25519_PKCS8_PREFIX = bytes.fromhex("302e020100300506032b657004220420")
# upload-r2-object.py's exit code for a refused conditional write (--conflict-exit-code).
CONFLICT_EXIT = 3
# Serials tried past a taken history record before giving up.
SERIAL_ATTEMPTS = 20


class PublishError(Exception):
    """Why nothing (more) was published; the message is for the operator."""


class Conflict(PublishError):
    """A conditional write was refused: a write-once key exists with other bytes, or the object to replace
    no longer has the bytes this run loaded."""


@dataclasses.dataclass(frozen=True)
class Destination:
    name: str
    base_url: str  # public URL of the folder holding notes/
    endpoint: str  # R2 S3 endpoint
    bucket: str
    key_prefix: str  # bucket key of that folder, ending in "/"
    public_key: str
    guard_keys: bool  # check every key with nightly-next-guard.py, as nightly.yml does

    def url(self, name: str) -> str:
        return f"{self.base_url.rstrip('/')}/notes/{name}"

    def key(self, name: str) -> str:
        return f"{self.key_prefix}notes/{name}"


def destination(test_key: bool, env: Mapping[str, str]) -> Destination:
    """The nightly feed (nightly.yml's NIGHTLY_NEXT_* values), or perf-lab-test with --test-key."""
    def need(name: str) -> str:
        value = env.get(name, "").strip()
        if not value:
            raise PublishError(f"set {name}")
        return value

    if test_key:
        return Destination("perf-lab-test", need("CMUX_PERF_LAB_FLAGS_BASE"), need("CMUX_PERF_LAB_R2_ENDPOINT"),
                           need("CMUX_PERF_LAB_R2_BUCKET"), "perf-lab-test/", test_signing_key()[0], False)
    return Destination("nightly-next", "https://files-next.cmux.com/nightly-next/next",
                       need("NIGHTLY_NEXT_R2_ENDPOINT"), "cmux-nightly-next", "nightly-next/next/",
                       CONTENT_PUBLIC_KEY, True)


def test_signing_key() -> tuple[str, str]:
    """(public key, private seed) of the perf lab's test key, both raw Ed25519 base64."""
    data = json.loads(TEST_KEY_FILE.read_text(encoding="utf-8"))
    return data["publicKey"], data["privateSeed"]


def registry(directory: Path = REGISTRY) -> dict[str, str]:
    """Feature name to kind, from the one-file-per-feature registry."""
    kinds = {}
    for path in sorted(directory.glob("*.json")):
        data = json.loads(path.read_text(encoding="utf-8"))
        kinds[data["name"]] = data["kind"]
    return kinds


def check_names(on: list[str], off: list[str], kinds: Mapping[str, str]) -> None:
    if not on and not off:
        raise PublishError("name at least one feature with --off or --on")
    both = sorted(set(on) & set(off))
    if both:
        raise PublishError(f"both --on and --off: {', '.join(both)}")
    for name in on + off:
        kind = kinds.get(name)
        if kind is None:
            raise PublishError(f"{name} is not a registered feature (schemas/features/features.d/{name}.json)")
        if kind not in ALLOWED_KINDS:
            raise PublishError(f"{name} is a {kind} feature; only killSwitch and perfPath features change remotely")


def nightly_assertion(document: object) -> bool:
    """nightly.yml's check before it signs release-notes/next/flags.json, as one predicate."""
    return version_one(document) and type(document.get("default", {}).get("FeaturesSerial")) is int


def version_one(document: object) -> bool:
    return (isinstance(document, dict) and document.get("version") == 1
            and isinstance(document.get("default", {}), dict) and isinstance(document.get("cohorts", {}), dict))


def serials(document: dict) -> list[int]:
    layers = [document.get("default", {})] + list(document.get("cohorts", {}).values())
    return [layer["FeaturesSerial"] for layer in layers
            if isinstance(layer, dict) and type(layer.get("FeaturesSerial")) is int]


def apply_change(document: dict, cohort: str, on: list[str], off: list[str], serial: int) -> dict:
    """A copy of `document` with cohort's Features set and every FeaturesSerial raised to `serial`.

    A cohort's Features replaces the default's whole (FeatureRemoteDocument), so a cohort's first
    change starts from the default's features. Every serial is raised so no cohort's resolved
    document keeps an old serial with new content.
    """
    result = copy.deepcopy(document)
    default = result.setdefault("default", {})
    cohorts = result.setdefault("cohorts", {})
    if cohort == DEFAULT_COHORT:
        layer = default
    else:
        layer = cohorts.setdefault(cohort, {})
    features = dict(layer.get("Features", default.get("Features", {})))
    features.update({name: "on" for name in on})
    features.update({name: "off" for name in off})
    layer["Features"] = features
    default["FeaturesSerial"] = serial
    for other in cohorts.values():
        if isinstance(other, dict) and "FeaturesSerial" in other:
            other["FeaturesSerial"] = serial
    return result


def cohort_features(document: dict, cohort: str) -> dict:
    """The Features a person in `cohort` gets: the cohort's own, else the default's."""
    layer = document.get("cohorts", {}).get(cohort, {}) if cohort != DEFAULT_COHORT else {}
    return layer.get("Features", document.get("default", {}).get("Features", {}))


def resolved_expiry(document: dict, cohort: str) -> str | None:
    layer = document.get("cohorts", {}).get(cohort, {}) if cohort != DEFAULT_COHORT else {}
    return layer.get("FeaturesExpiresAt", document.get("default", {}).get("FeaturesExpiresAt"))


def check_not_expired(document: dict, cohort: str, now: datetime.datetime) -> None:
    text = resolved_expiry(document, cohort)
    if text is None:
        return
    try:
        expires = datetime.datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError as error:
        raise PublishError(f"FeaturesExpiresAt {text!r} is not an ISO 8601 time") from error
    if expires <= now:
        raise PublishError(f"FeaturesExpiresAt {text} has passed, so the app would apply nothing; "
                           "change it in release-notes/next/flags.json first")


def render(document: dict) -> bytes:
    return (json.dumps(document, indent=2, ensure_ascii=False) + "\n").encode("utf-8")


def diff(before: dict, after: dict, label: str) -> str:
    lines = difflib.unified_diff(render(before).decode().splitlines(), render(after).decode().splitlines(),
                                 f"{label} (published)", f"{label} (new)", lineterm="")
    return "\n".join(lines)


# Seams: the network reads and the R2 writes.

Fetch = Callable[[str], "bytes | None"]  # the body, or None when the URL is not found


def http_fetch(url: str) -> bytes | None:
    request = urllib.request.Request(url, headers={"User-Agent": "cmux-publish-flags/1", "Cache-Control": "no-cache"})
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            return response.read()
    except urllib.error.HTTPError as error:
        if error.code in (403, 404):  # R2 answers a missing object with either
            return None
        raise PublishError(f"GET {url}: HTTP {error.code}") from error
    except OSError as error:
        raise PublishError(f"GET {url}: {error}") from error


class Uploader(Protocol):
    def put(self, path: Path, key: str, *, cache_control: str, write_once: bool = False,
            replace_sha256: str | None = None) -> None:
        """Writes the file at bucket key `key`; raises Conflict when a condition refuses it, PublishError
        when it fails otherwise."""


@dataclasses.dataclass
class R2Uploader:
    destination: Destination
    env: Mapping[str, str]

    def put(self, path: Path, key: str, *, cache_control: str, write_once: bool = False,
            replace_sha256: str | None = None) -> None:
        dest = self.destination
        if dest.guard_keys:
            guard_env = {**self.env, "NIGHTLY_NEXT_R2_BUCKET": dest.bucket, "NIGHTLY_NEXT_R2_PREFIX": dest.key_prefix}
            run([sys.executable, str(NIGHTLY_GUARD), "r2-key", dest.bucket, key], env=guard_env)
        command = [sys.executable, str(UPLOADER), "--file", str(path), "--endpoint-url", dest.endpoint,
                   "--bucket", dest.bucket, "--key", key, "--cache-control", cache_control,
                   "--content-type", "application/json" if key.endswith(".json") else "text/plain",
                   "--conflict-exit-code", str(CONFLICT_EXIT)]
        if write_once:
            command.append("--write-once")
        if replace_sha256:
            command += ["--replace-sha256", replace_sha256]
        run(command, env=dict(self.env), conflict_exit=CONFLICT_EXIT)


def run(command: list[str], env: Mapping[str, str] | None = None, conflict_exit: int | None = None) -> str:
    result = subprocess.run(command, capture_output=True, text=True, env=None if env is None else dict(env))
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip()
        error = Conflict if result.returncode == conflict_exit else PublishError
        raise error(f"{Path(command[1]).name} failed: {detail}")
    return result.stdout


# Signatures: the nightly's own sign and verify commands.

def sign(paths: list[Path], key_pem: Path, key_name: str) -> None:
    """Signs each file into `<file>.sig`. openssl's output names the key file, so none of it is shown."""
    result = subprocess.run([sys.executable, str(RELEASE_NOTES), "sign", "--key", str(key_pem), *map(str, paths)],
                            capture_output=True, text=True)
    if result.returncode != 0:
        raise PublishError(f"signing with {key_name} failed; is it an unencrypted Ed25519 PEM? "
                           "(the signer's output is not shown because it names the key file)")


def verified(path: Path, public_key: str) -> bool:
    result = subprocess.run([sys.executable, str(RELEASE_NOTES), "verify", "--public-key", public_key, str(path)],
                            capture_output=True, text=True)
    return result.returncode == 0


def bytes_verified(data: bytes, signature: bytes, public_key: str) -> bool:
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "flags.json"
        path.write_bytes(data)
        (Path(tmp) / "flags.json.sig").write_bytes(signature)
        return verified(path, public_key)


def write_test_key_pem(directory: Path) -> Path:
    """The test seed as a PKCS#8 PEM file for openssl, readable only by this user."""
    seed = base64.b64decode(test_signing_key()[1])
    der = ED25519_PKCS8_PREFIX + seed
    body = base64.encodebytes(der).decode().strip()
    path = directory / "test-key.pem"
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as out:
        out.write(f"-----BEGIN PRIVATE KEY-----\n{body}\n-----END PRIVATE KEY-----\n")
    return path


def production_key(env: Mapping[str, str]) -> Path:
    value = env.get(KEY_PATH_ENV, "").strip()
    if not value:
        raise PublishError(f"set {KEY_PATH_ENV} to the content-signing key's PEM file (decision D2)")
    path = Path(value)
    if not path.is_file():
        raise PublishError(f"{KEY_PATH_ENV} does not name a readable file")
    return path


# The publish.

@dataclasses.dataclass
class Current:
    document: dict
    raw: bytes | None  # the published bytes, None when the destination has no document yet
    unsigned: bool = False  # left by a run that stopped between the flags.json and flags.json.sig writes


def load_current(fetch: Fetch, dest: Destination, checkout: dict) -> Current:
    data = fetch(dest.url("flags.json"))
    if data is None:
        return Current(copy.deepcopy(checkout), None)
    signature = fetch(dest.url("flags.json.sig"))
    signed = signature is not None and bytes_verified(data, signature, dest.public_key)
    if not signed and not recorded(fetch, dest, data):
        raise PublishError(f"{dest.url('flags.json')} does not verify with the {dest.name} key and is not the "
                           "document of a signed history record; publish nothing over it until the nightly "
                           "republishes it")
    try:
        document = json.loads(data)
    except ValueError as error:
        raise PublishError(f"{dest.url('flags.json')} is not JSON: {error}") from error
    # A document from before the feature keys has no FeaturesSerial; the new one always gets one.
    if not version_one(document):
        raise PublishError(f"{dest.url('flags.json')} is not a version 1 flags document")
    return Current(document, data, unsigned=not signed)


def recorded(fetch: Fetch, dest: Destination, data: bytes) -> bool:
    """Whether `data` is the document of the signed history record of its own serial, which is what a run
    that stopped between the flags.json and flags.json.sig writes leaves published."""
    try:
        serial = json.loads(data)["default"]["FeaturesSerial"]
    except (ValueError, KeyError, TypeError):
        return False
    if type(serial) is not int:
        return False
    record = fetch(dest.url(f"history/{serial}.json"))
    record_signature = fetch(dest.url(f"history/{serial}.json.sig"))
    if record is None or record_signature is None or not bytes_verified(record, record_signature, dest.public_key):
        return False
    try:
        document = json.loads(record)["document"]
    except (ValueError, KeyError, TypeError):
        return False
    return isinstance(document, dict) and render(document) == data


def free_serial(fetch: Fetch, dest: Destination, serial: int) -> int:
    """The first serial from `serial` up with no history record. A run that stopped after reserving a
    serial, or a publish whose checkout change the nightly republished over, leaves records above it."""
    for candidate in range(serial, serial + SERIAL_ATTEMPTS):
        if fetch(dest.url(f"history/{candidate}.json")) is None:
            return candidate
    raise PublishError(f"history/{serial}.json to history/{serial + SERIAL_ATTEMPTS - 1}.json all exist; "
                       "check the destination's history before publishing")


@dataclasses.dataclass(frozen=True)
class Change:
    cohort: str
    on: list[str]
    off: list[str]
    reason: str
    published_at: str


def upload(change: Change, current: Current, serial: int, dest: Destination, uploader: Uploader,
           key: Path, key_name: str) -> None:
    """Signs and uploads the change at `serial`. Raises Conflict only when history/<serial>.json is taken."""
    document = apply_change(current.document, change.cohort, change.on, change.off, serial)
    history = {"serial": serial, "cohort": change.cohort, "on": change.on, "off": change.off,
               "reason": change.reason, "published_at": change.published_at, "destination": dest.name,
               "document": document}
    with tempfile.TemporaryDirectory() as tmp:
        folder = Path(tmp)
        flags = folder / "flags.json"
        flags.write_bytes(render(document))
        record = folder / f"{serial}.json"
        record.write_bytes(render(history))
        sign([flags, record], key, key_name)
        for path in (flags, record):
            if not verified(path, dest.public_key):
                raise PublishError(f"the signature of {path.name} does not verify with the {dest.name} public key; "
                                   f"is {key_name} the {dest.name} key?")
        # The write-once history file reserves the serial, then flags.json replaces only what was loaded.
        uploader.put(record, dest.key(f"history/{serial}.json"), cache_control=HISTORY_CACHE, write_once=True)
        try:
            uploader.put(Path(f"{record}.sig"), dest.key(f"history/{serial}.json.sig"),
                         cache_control=HISTORY_CACHE, write_once=True)
            if current.raw is None:
                uploader.put(flags, dest.key("flags.json"), cache_control=NO_CACHE, write_once=True)
            else:
                uploader.put(flags, dest.key("flags.json"), cache_control=NO_CACHE,
                             replace_sha256=hashlib.sha256(current.raw).hexdigest())
        except Conflict as error:
            raise PublishError(f"another publish changed the destination since it was loaded; run again to see "
                               f"its change: {error}") from error
        uploader.put(Path(f"{flags}.sig"), dest.key("flags.json.sig"), cache_control=NO_CACHE)


def publish(args: argparse.Namespace, *, env: Mapping[str, str], fetch: Fetch, uploader: Uploader | None,
            out: Callable[[str], None] = print, now: datetime.datetime | None = None,
            checkout_path: Path = CHECKOUT_FLAGS, kinds: Mapping[str, str] | None = None) -> int:
    now = now or datetime.datetime.now(datetime.timezone.utc)
    on, off = list(dict.fromkeys(args.on)), list(dict.fromkeys(args.off))
    if not COHORT_NAME.fullmatch(args.cohort):
        raise PublishError(f"cohort {args.cohort!r} is not a name")
    if not args.reason.strip():
        raise PublishError("--reason says why, for history/<serial>.json")
    check_names(on, off, registry() if kinds is None else kinds)
    dest = destination(args.test_key, env)

    checkout = json.loads(checkout_path.read_text(encoding="utf-8"))
    if not nightly_assertion(checkout):
        raise PublishError(f"{checkout_path} fails nightly.yml's flags.json assertion")
    current = load_current(fetch, dest, checkout)
    serial = free_serial(fetch, dest, max(serials(current.document) + serials(checkout)) + 1)
    document = apply_change(current.document, args.cohort, on, off, serial)
    unchanged = cohort_features(document, args.cohort) == cohort_features(current.document, args.cohort)
    if unchanged and not current.unsigned:
        raise PublishError(f"cohort {args.cohort} already has these features; nothing to publish")
    check_not_expired(document, args.cohort, now)
    if not nightly_assertion(document):
        raise PublishError("the new document fails nightly.yml's flags.json assertion")

    if current.unsigned:
        out("note: the published flags.json has no matching flags.json.sig (a publish stopped before it); "
            "this publish replaces both")
    out(f"{dest.name}: cohort {args.cohort}, FeaturesSerial {serial}")
    out(diff(current.document, document, "flags.json"))
    if args.cohort != DEFAULT_COHORT and "Features" not in current.document.get("cohorts", {}).get(args.cohort, {}):
        out(f"note: cohort {args.cohort} now has its own Features; later default changes do not reach it")
    if args.dry_run:
        out("dry run: nothing signed or uploaded")
        return 0
    if uploader is None:
        uploader = R2Uploader(dest, env)

    change = Change(args.cohort, on, off, args.reason.strip(), now.strftime("%Y-%m-%dT%H:%M:%SZ"))
    with tempfile.TemporaryDirectory() as tmp:
        if args.test_key:
            key, key_name = write_test_key_pem(Path(tmp)), "the perf lab's test key"
        else:
            key, key_name = production_key(env), f"the key in {KEY_PATH_ENV}"
        first = serial
        while True:
            try:
                upload(change, current, serial, dest, uploader, key, key_name)
                break
            except Conflict:
                # Another run reserved this serial after the probe (its flags.json write then decides).
                if serial + 1 - first >= SERIAL_ATTEMPTS:
                    raise PublishError(f"history/{first}.json to history/{serial}.json are all taken; "
                                       "check the destination's history before publishing") from None
                out(f"history/{serial}.json is taken; trying serial {serial + 1}")
                serial += 1
    out(f"published {dest.url('flags.json')} (serial {serial})")

    if not args.test_key:
        checkout_path.write_bytes(render(apply_change(checkout, args.cohort, on, off, serial)))
        out(f"wrote {checkout_path.relative_to(REPO) if checkout_path.is_relative_to(REPO) else checkout_path}: "
            "land it before the next nightly, which republishes that file")
    return 0


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--cohort", required=True, help="the cohort to change, or default for everyone")
    parser.add_argument("--off", action="append", default=[], metavar="NAME", help="turn a feature off (repeatable)")
    parser.add_argument("--on", action="append", default=[], metavar="NAME", help="turn a feature on (repeatable)")
    parser.add_argument("--reason", required=True, help="why, kept in history/<serial>.json")
    parser.add_argument("--dry-run", action="store_true", help="print the diff; sign and upload nothing")
    parser.add_argument("--test-key", action="store_true",
                        help="sign with the perf lab's test key and publish to perf-lab-test")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    try:
        return publish(args, env=os.environ, fetch=http_fetch, uploader=None)
    except PublishError as error:
        print(f"publish-flags: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
