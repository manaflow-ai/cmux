#!/usr/bin/env python3
"""The cmux-mobile-ffi pin: Packages/Shared/CmuxMobileFFI/mobile-ffi-pin.json.

    mobile_ffi_pin.py read PIN_FILE             -> "SHA CHECKSUM", or "unpinned"
    mobile_ffi_pin.py write SHA CHECKSUM PIN_FILE
    mobile_ffi_pin.py additive OLD.swift NEW.swift

The pin file has one format, written only by `write`:

    {"url": "https://github.com/manaflow-ai/cmux/releases/download/cmux-mobile-ffi-<sha>/CmuxMobileFFIFFI.xcframework.zip", "checksum": "<sha256>"}

or, before the first release, both fields empty (unpinned: the package declares no
targets and ios/CmuxiOS does not link it). `read` refuses anything else, so the
manifest, the check (check-mobile-ffi-pin.sh) and the re-pin
(publish-mobile-ffi-repin.sh) read one thing.

`additive` exits 0 when every public declaration line of OLD (the generated
uniffi Swift bindings) is still in NEW: the re-pin then cannot remove or change
an API the iOS app calls, so it may land on the base without the pull request's
iOS build. Standard library only (the hooks run /usr/bin/python3 3.9).
"""

from __future__ import annotations

import json
import re
import sys

REPO = "manaflow-ai/cmux"
ASSET = "CmuxMobileFFIFFI.xcframework.zip"
URL = re.compile(
    r"^https://github\.com/manaflow-ai/cmux/releases/download/cmux-mobile-ffi-([0-9a-f]{40})/"
    + re.escape(ASSET)
    + r"$"
)
CHECKSUM = re.compile(r"^[0-9a-f]{64}$")
SHA = re.compile(r"^[0-9a-f]{40}$")


def fail(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)
    sys.exit(1)


def url_for(sha: str) -> str:
    return f"https://github.com/{REPO}/releases/download/cmux-mobile-ffi-{sha}/{ASSET}"


def render(url: str, checksum: str) -> str:
    return json.dumps({"url": url, "checksum": checksum}) + "\n"


def read(path: str) -> str:
    try:
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
    except OSError as error:
        fail(f"cannot read {path}: {error}")
    try:
        data = json.loads(text)
    except ValueError as error:
        fail(f"{path} is not JSON: {error}")
    if not isinstance(data, dict) or sorted(data) != ["checksum", "url"]:
        fail(f"{path} must hold exactly the keys url and checksum")
    url, checksum = data["url"], data["checksum"]
    if not isinstance(url, str) or not isinstance(checksum, str):
        fail(f"{path}: url and checksum must be strings")
    if text != render(url, checksum):
        fail(f"{path} is not in its one format (scripts/cmux-next/mobile_ffi_pin.py write)")
    if url == "" and checksum == "":
        return "unpinned"
    match = URL.match(url)
    if not match:
        fail(f"{path}: url {url!r} is not a cmux-mobile-ffi release of {REPO}")
    if not CHECKSUM.match(checksum):
        fail(f"{path}: checksum {checksum!r} is not 64 lowercase hex characters")
    return f"{match.group(1)} {checksum}"


def write(sha: str, checksum: str, path: str) -> None:
    if not SHA.match(sha):
        fail(f"the source must be a 40-character sha, got {sha!r}")
    if not CHECKSUM.match(checksum):
        fail(f"the checksum must be 64 hex characters, got {checksum!r}")
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(render(url_for(sha), checksum))


def public_lines(path: str) -> list[str]:
    with open(path, encoding="utf-8") as handle:
        return [line.strip() for line in handle if re.match(r"^\s*(public|open)\s", line)]


def additive(old: str, new: str) -> None:
    kept = set(public_lines(new))
    missing = [line for line in public_lines(old) if line not in kept]
    if missing:
        print(f"{len(missing)} public declaration(s) of {old} are not in {new}, for example:")
        for line in missing[:10]:
            print(f"  {line}")
        sys.exit(1)
    print("the new bindings keep every public declaration of the old ones")


def main(argv: list[str]) -> None:
    if len(argv) == 2 and argv[0] == "read":
        print(read(argv[1]))
    elif len(argv) == 4 and argv[0] == "write":
        write(argv[1], argv[2], argv[3])
    elif len(argv) == 3 and argv[0] == "additive":
        additive(argv[1], argv[2])
    else:
        print("\n".join(__doc__.strip().splitlines()[2:5]), file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main(sys.argv[1:])
