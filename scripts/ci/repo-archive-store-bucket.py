#!/usr/bin/env python3
"""The repo archive store (hq RFD 0065 pieces 1-2, decision d-d301c6c7ba) in the cmux Cloudflare account.

Leo, on d-d301c6c7ba: "cant you guys alr do this? i think another lane is workin on this"

`check` reads only: what the token can do, and whether the bucket exists, is private and has its expiry rule.
`create` creates cmux-repo-archive when missing, keeps it private (no r2.dev, no custom domain), sets one lifecycle
rule (objects under repo-archive/ expire after EXPIRE_DAYS; the publisher rewrites a live archive every 24 h, so
only superseded objects age out), and mints two account-owned tokens scoped to that bucket: Object Read and Write
for the controller's publisher, Object Read for VMs. Each S3 credential (access key = token id, secret = sha256 of
the token value) is written sealed (RSA-OAEP-SHA256) to SEAL_PUBKEY, a base64 DER public key whose private half
lives only on the fleet controller. Nothing secret is printed or written unsealed. Re-running mints fresh tokens.
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

BUCKET = "cmux-repo-archive"
PREFIX = "repo-archive/"
EXPIRE_DAYS = 7
RULE_ID = "repo-archive-expire-superseded"
TOKENS = {
    # sealed file suffix: (token name, permission group)
    "write": (f"{BUCKET}-publisher", "Workers R2 Storage Bucket Item Write"),
    "read": (f"{BUCKET}-vm-read", "Workers R2 Storage Bucket Item Read"),
}


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


RULE = {
    "id": RULE_ID,
    "enabled": True,
    "conditions": {"prefix": PREFIX},
    "deleteObjectsTransition": {"condition": {"type": "Age", "maxAge": EXPIRE_DAYS * 86400}},
}


def assert_private(fix):
    managed = api(f"r2/buckets/{BUCKET}/domains/managed")
    if managed.get("enabled"):
        if not fix:
            raise RuntimeError(f"{BUCKET} has r2.dev on")
        api(f"r2/buckets/{BUCKET}/domains/managed", "PUT", {"enabled": False})
        print("r2.dev was on; turned it off")
    custom = api(f"r2/buckets/{BUCKET}/domains/custom").get("domains", [])
    if custom:
        raise RuntimeError(f"{BUCKET} has {len(custom)} custom domain(s); the repo store must have none")
    rules = (api(f"r2/buckets/{BUCKET}/lifecycle") or {}).get("rules", [])
    others = [r for r in rules if r.get("id") != RULE_ID]
    ours = [r for r in rules if r.get("id") == RULE_ID]
    good = len(ours) == 1 and ours[0].get("enabled") is True \
        and (ours[0].get("conditions") or {}).get("prefix") == PREFIX \
        and ((ours[0].get("deleteObjectsTransition") or {}).get("condition") or {}).get("maxAge") == EXPIRE_DAYS * 86400
    if not good:
        if not fix:
            raise RuntimeError(f"{BUCKET} lacks its expiry rule {RULE_ID}")
        api(f"r2/buckets/{BUCKET}/lifecycle", "PUT", {"rules": others + [RULE]})
        print(f"set lifecycle rule {RULE_ID}: {PREFIX} expires after {EXPIRE_DAYS} days")
    print(f"{BUCKET}: r2.dev off, no custom domain, {RULE_ID} set ({len(others)} other rule(s))")


def check():
    print(f"bucket list: {can('r2/buckets?per_page=1')}")
    print(f"token permission groups: {can('tokens/permission_groups')}")
    print(f"account tokens: {can('tokens?per_page=1')}")
    if bucket_exists():
        assert_private(fix=False)
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


def create(out_dir):
    pubkey = os.environ.get("SEAL_PUBKEY", "")
    if not pubkey:
        raise RuntimeError("SEAL_PUBKEY (base64 DER RSA public key) is required to mint the credentials")
    acct = account()
    if bucket_exists():
        print(f"{BUCKET}: exists")
    else:
        api("r2/buckets", "POST", {"name": BUCKET})
        print(f"{BUCKET}: created")
    assert_private(fix=True)
    groups = api("tokens/permission_groups")
    os.makedirs(out_dir, exist_ok=True)
    for kind, (name, permission) in TOKENS.items():
        group = next((g for g in groups if g.get("name") == permission), None)
        if not group:
            raise RuntimeError(f"no permission group named {permission!r}")
        token = api("tokens", "POST", {
            "name": name,
            "policies": [{"effect": "allow", "permission_groups": [{"id": group["id"]}],
                          "resources": {f"com.cloudflare.edge.r2.bucket.{acct}_default_{BUCKET}": "*"}}]})
        credential = json.dumps({
            "store": f"https://{acct}.r2.cloudflarestorage.com/{BUCKET}",
            "access_key_id": token["id"],
            "secret_access_key": hashlib.sha256(token["value"].encode()).hexdigest(),
            "note": f"d-d301c6c7ba: {permission} on {BUCKET} only ({name})",
        }).encode()
        path = os.path.join(out_dir, f"repo-archive-{kind}.sealed")
        with open(path, "wb") as f:
            f.write(seal(credential, pubkey))
        print(f"minted token id {token['id']} ({permission} on {BUCKET}); sealed: {path}")


if __name__ == "__main__":
    if sys.argv[1] == "check":
        check()
    elif sys.argv[1] == "create":
        create(sys.argv[2])
    else:
        raise SystemExit("usage: repo-archive-store-bucket.py check | create OUT_DIR")
