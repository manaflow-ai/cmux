#!/usr/bin/env python3
"""A staging Stack session for the agent test account, for the signed cmux NEXT DEV app.

The signed NEXT DEV build (com.cmuxterm.app.debug.next, a Release compile) signs in on the staging
Stack project, and on a Keychain miss restores its session from its file token store
(FallbackTokenStore, FileStackTokenStore: credentials.json, {"accessToken", "refreshToken"}, in
~/Library/Application Support/cmux/com.cmuxterm.app.debug.next/<staging project>/). So a session put
there opens the app signed in, with no password anywhere near the app.

This signs the agent account in over Stack's password API. The pair comes from the environment
(CMUX_DOGFOOD_STACK_EMAIL and _PASSWORD, cmux-next-vm-image-dev), never argv. Then one of:

  --seed               write that credentials.json for this user (0700 folder, 0600 file): the
                       runner's own launch in cloud-chat-proof.yml's `published` build;
  --pubkey FILE --out DIR
                       encrypt the session to an RSA public key and write DIR/session.enc (AES-256-CBC,
                       PBKDF2 key from a random secret) and DIR/key.enc (that secret, RSA-OAEP): the
                       only thing the workflow uploads. The private key never leaves the machine that
                       made it, which decrypts the session into credentials.json itself.

Prints nothing secret.
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import secrets
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

STACK = "https://api.stack-auth.com/api/v1/auth/password/sign-in"
# CloudConfiguration.developmentProjectID / developmentClientKey (the publishable key is public).
PROJECT = "454ecd03-1db2-4050-845e-4ce5b0cd9895"
CLIENT_KEY = "pck_xb63160bwe9699vtxfzfj6emmxpafg5mkjrtp6ehzxv5g"
BUNDLE_ID = "com.cmuxterm.app.debug.next"


def sign_in(email: str, password: str) -> dict:
    request = urllib.request.Request(STACK, method="POST", data=json.dumps(
        {"email": email, "password": password}).encode(), headers={
        "content-type": "application/json", "x-stack-project-id": PROJECT,
        "x-stack-publishable-client-key": CLIENT_KEY, "x-stack-access-type": "client"})
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            body = json.loads(response.read() or b"{}")
    except urllib.error.HTTPError as exc:
        code = ""
        try:
            code = str(json.loads(exc.read() or b"{}").get("code") or "")
        except ValueError:
            pass
        raise SystemExit(f"dev-signin-token: Stack refused the sign-in: HTTP {exc.code} {code}".rstrip())
    refresh, access = body.get("refresh_token"), body.get("access_token")
    if not refresh or not access:
        raise SystemExit("dev-signin-token: Stack answered without a session")
    return {"accessToken": access, "refreshToken": refresh}


def credentials_path(home: Path) -> Path:
    return home / "Library/Application Support/cmux" / BUNDLE_ID / PROJECT / "credentials.json"


def seed(session: dict, home: Path) -> Path:
    path = credentials_path(home)
    path.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as handle:
        json.dump(session, handle)
    os.chmod(path, 0o600)
    return path


def encrypt(session: dict, pubkey: Path, out: Path) -> None:
    out.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as scratch:
        secret = Path(scratch) / "secret"
        fd = os.open(secret, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as handle:
            handle.write(base64.b64encode(secrets.token_bytes(32)).decode() + "\n")
        payload = json.dumps({**session, "project": PROJECT, "bundleID": BUNDLE_ID, "issuedAt": int(time.time())})
        subprocess.run(["openssl", "enc", "-aes-256-cbc", "-md", "sha256", "-pbkdf2", "-iter", "200000", "-salt",
                        "-pass", f"file:{secret}", "-out", str(out / "session.enc")],
                       input=payload.encode(), check=True)
        subprocess.run(["openssl", "rsautl", "-encrypt", "-oaep", "-pubin", "-inkey", str(pubkey),
                        "-in", str(secret), "-out", str(out / "key.enc")], check=True, stderr=subprocess.DEVNULL)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--seed", action="store_true", help="write the app's credentials.json for this user")
    parser.add_argument("--pubkey", type=Path, help="an RSA public key (PEM) to encrypt the session to")
    parser.add_argument("--out", type=Path, help="where session.enc and key.enc go (with --pubkey)")
    args = parser.parse_args()
    if args.seed == bool(args.pubkey) or (args.pubkey and not args.out):
        parser.error("give --seed, or --pubkey FILE --out DIR")
    email = os.environ.get("CMUX_DOGFOOD_STACK_EMAIL", "")
    password = os.environ.get("CMUX_DOGFOOD_STACK_PASSWORD", "")
    if not email or not password:
        raise SystemExit("dev-signin-token: CMUX_DOGFOOD_STACK_EMAIL and _PASSWORD are not set")
    session = sign_in(email, password)
    if args.seed:
        print(f"dev-signin-token: seeded {seed(session, Path.home())}")
    else:
        encrypt(session, args.pubkey, args.out)
        print(f"dev-signin-token: wrote {args.out}/session.enc and key.enc")
    return 0


if __name__ == "__main__":
    sys.exit(main())
