#!/usr/bin/env python3
"""Leo's session archive bucket (ask-a7a0aa9b7b) in the cmux Cloudflare account.

Leo: "let's go ahead we already have access to the keys and such. it... should probably be under the cmux
cloudflare account. just isolate it to me and we can compress stuff so we can read it later"

`check` reads only: what the token can do, and whether the bucket exists and is private.
`create` creates cmux-leo-session-archive when missing, keeps it private (no r2.dev, no custom domain) with no
expiring lifecycle rule, mints an account-owned token with Object Read and Write on that bucket only, derives its
S3 credential (access key = token id, secret = sha256 of the token value) and writes it sealed (RSA-OAEP-SHA256)
to SEAL_PUBKEY, a base64 DER public key whose private half lives only on the fleet controller. Nothing secret is
printed or written unsealed: the credential goes to openssl's stdin.
"""
import base64
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request

BUCKET = "cmux-leo-session-archive"
TOKEN_NAME = f"{BUCKET}-controller"
PERMISSION = "Workers R2 Storage Bucket Item Write"


class CloudflareError(RuntimeError):
    def __init__(self, method, path, status, codes=()):
        self.status = status
        super().__init__(f"Cloudflare {method} {path}: HTTP {status} {list(codes)}")


def account():
    value = os.environ.get("CLOUDFLARE_ACCOUNT_ID", "")
    if not re.fullmatch(r"[a-f0-9]{32}", value):
        raise RuntimeError("invalid CLOUDFLARE_ACCOUNT_ID")
    return value


def api(path, method="GET", value=None):
    if not os.environ.get("CLOUDFLARE_API_TOKEN"):
        raise RuntimeError("missing CLOUDFLARE_API_TOKEN")
    request = urllib.request.Request(
        f"https://api.cloudflare.com/client/v4/accounts/{account()}/{path}",
        data=json.dumps(value).encode() if value is not None else None,
        headers={"Authorization": f"Bearer {os.environ['CLOUDFLARE_API_TOKEN']}", "Content-Type": "application/json"},
        method=method)
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            body = json.load(response)
    except urllib.error.HTTPError as error:
        try:
            codes = [e.get("code") for e in json.load(error).get("errors", [])]
        except Exception:
            codes = []
        raise CloudflareError(method, path, error.code, codes) from None  # never the body: it may hold a value
    if body.get("success") is not True:
        raise CloudflareError(method, path, 200, [e.get("code") for e in body.get("errors", [])])
    return body.get("result")


def can(path):
    try:
        api(path)
        return "yes"
    except CloudflareError as error:
        return f"no (HTTP {error.status})"


def bucket_exists():
    try:
        api(f"r2/buckets/{BUCKET}")
        return True
    except CloudflareError as error:
        if error.status == 404:
            return False
        raise


def assert_private():
    managed = api(f"r2/buckets/{BUCKET}/domains/managed")
    if managed.get("enabled"):
        api(f"r2/buckets/{BUCKET}/domains/managed", "PUT", {"enabled": False})
        print("r2.dev was on; turned it off")
    custom = api(f"r2/buckets/{BUCKET}/domains/custom").get("domains", [])
    if custom:
        raise RuntimeError(f"{BUCKET} has {len(custom)} custom domain(s); Leo's archive must have none")
    rules = (api(f"r2/buckets/{BUCKET}/lifecycle") or {}).get("rules", [])
    keep = [r for r in rules if not r.get("deleteObjectsTransition")]
    if len(keep) != len(rules):
        api(f"r2/buckets/{BUCKET}/lifecycle", "PUT", {"rules": keep})
        print(f"removed {len(rules) - len(keep)} expiring lifecycle rule(s)")
    print(f"{BUCKET}: r2.dev off, no custom domain, no expiring lifecycle rule ({len(keep)} other rule(s))")


def check():
    print(f"bucket list: {can('r2/buckets?per_page=1')}")
    print(f"token permission groups: {can('tokens/permission_groups')}")
    print(f"account tokens: {can('tokens?per_page=1')}")
    if bucket_exists():
        assert_private()
    else:
        print(f"{BUCKET}: absent (a dispatch creates it)")


def seal(plaintext, pubkey_b64):
    der = base64.b64decode(pubkey_b64.strip(), validate=True)
    with tempfile.TemporaryDirectory() as tmp:
        key = os.path.join(tmp, "seal.der")
        with open(key, "wb") as f:
            f.write(der)
        return subprocess.run(
            ["openssl", "pkeyutl", "-encrypt", "-pubin", "-keyform", "DER", "-inkey", key,
             "-pkeyopt", "rsa_padding_mode:oaep", "-pkeyopt", "rsa_oaep_md:sha256", "-pkeyopt", "rsa_mgf1_md:sha256"],
            input=plaintext, capture_output=True, check=True).stdout


def create(out):
    pubkey = os.environ.get("SEAL_PUBKEY", "")
    if not pubkey:
        raise RuntimeError("SEAL_PUBKEY (base64 DER RSA public key) is required to mint the credential")
    acct = account()
    if bucket_exists():
        print(f"{BUCKET}: exists")
    else:
        api("r2/buckets", "POST", {"name": BUCKET})
        print(f"{BUCKET}: created")
    assert_private()
    groups = api("tokens/permission_groups")
    group = next((g for g in groups if g.get("name") == PERMISSION), None)
    if not group:
        raise RuntimeError(f"no permission group named {PERMISSION!r}")
    token = api("tokens", "POST", {
        "name": TOKEN_NAME,
        "policies": [{"effect": "allow", "permission_groups": [{"id": group["id"]}],
                      "resources": {f"com.cloudflare.edge.r2.bucket.{acct}_default_{BUCKET}": "*"}}]})
    credential = json.dumps({
        "endpoint": f"https://{acct}.r2.cloudflarestorage.com",
        "bucket": BUCKET,
        "access_key_id": token["id"],
        "secret_access_key": hashlib.sha256(token["value"].encode()).hexdigest(),
        "note": f"ask-a7a0aa9b7b: Object Read and Write on {BUCKET} only (account token {TOKEN_NAME})",
    }).encode()
    with open(out, "wb") as f:
        f.write(seal(credential, pubkey))
    print(f"minted token id {token['id']} ({PERMISSION} on {BUCKET}); sealed credential: {out}")


if __name__ == "__main__":
    if sys.argv[1] == "check":
        check()
    elif sys.argv[1] == "create":
        create(sys.argv[2])
    else:
        raise SystemExit("usage: leo-session-archive-bucket.py check | create OUT")
