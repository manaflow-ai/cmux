#!/usr/bin/env python3
"""Narrow account preflight and secret cleanup for the main-only canary job."""
import json
import os
from pathlib import Path
import re
import sys
import urllib.error
import urllib.request

def resource_name():
    run = os.environ.get("GITHUB_RUN_ID", "")
    attempt = os.environ.get("GITHUB_RUN_ATTEMPT", "")
    if not re.fullmatch(r"[1-9][0-9]{0,19}", run) or not re.fullmatch(r"[1-9][0-9]{0,3}", attempt):
        raise RuntimeError("canary requires a valid GitHub run ID and attempt")
    return f"cmux-ci-artifacts-canary-{run}-{attempt}"

CREATED = Path("artifacts/r2-canary/created-bucket.json")


class CloudflareError(RuntimeError):
    def __init__(self, method, path, status):
        self.status = status
        super().__init__(f"Cloudflare {method} {path}: HTTP {status}; check the existing repository token capability")


def api(path, method="GET", value=None):
    for name in ("CLOUDFLARE_ACCOUNT_ID", "CLOUDFLARE_API_TOKEN"):
        if not os.environ.get(name):
            raise RuntimeError(f"missing configured repository secret {name}")
    account = os.environ["CLOUDFLARE_ACCOUNT_ID"]
    if not re.fullmatch(r"[a-f0-9]{32}", account):
        raise RuntimeError("invalid configured Cloudflare account ID")
    request = urllib.request.Request(
        f"https://api.cloudflare.com/client/v4/accounts/{account}/{path}",
        data=json.dumps(value).encode() if value is not None else None,
        headers={"Authorization": f"Bearer {os.environ['CLOUDFLARE_API_TOKEN']}",
                 "Content-Type": "application/json"}, method=method)
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            body = json.load(response)
    except urllib.error.HTTPError as error:
        # Report precise capability/status, never the credential or response body.
        raise CloudflareError(method, path, error.code) from None
    if body.get("success") is not True:
        codes = [item.get("code") for item in body.get("errors", [])]
        raise RuntimeError(f"Cloudflare {method} {path}: API error codes {codes}")
    return body.get("result")


def main():
    mode = sys.argv[1]
    worker = bucket = resource_name()
    if mode == "config":
        source = Path("workers/ci-artifacts/wrangler.canary.jsonc")
        config = json.loads(source.read_text())
        config["name"] = worker
        config["r2_buckets"][0]["bucket_name"] = bucket
        source.with_name("wrangler.canary.runtime.json").write_text(json.dumps(config, indent=2) + "\n")
        return
    if mode == "delete-worker":
        if CREATED.exists() and json.loads(CREATED.read_text()).get("worker") == worker:
            api(f"workers/scripts/{worker}", "DELETE")
        return
    if mode == "cleanup-bucket":
        if CREATED.exists() and json.loads(CREATED.read_text()).get("bucket") == bucket:
            # The API refuses nonempty buckets; never recursively delete data.
            api(f"r2/buckets/{bucket}", "DELETE")
        return
    if mode == "delete-secret":
        errors = []
        for name in ("GITHUB_ARTIFACT_TOKEN", "CANARY_ACCESS_TOKEN"):
            try:
                api(f"workers/scripts/{worker}/secrets/{name}", "DELETE")
            except RuntimeError as error:
                errors.append(str(error))
        if errors:
            raise RuntimeError("; ".join(errors))
        return
    if mode != "preflight":
        raise SystemExit("expected preflight or delete-secret")
    # Authenticate the intended repository account before interpreting absence.
    subdomain = api("workers/subdomain").get("subdomain", "")
    if not re.fullmatch(r"[a-z0-9-]+", subdomain):
        raise RuntimeError("account has no usable workers.dev subdomain")
    try:
        api(f"workers/scripts/{worker}/settings")
    except CloudflareError as error:
        if error.status != 404:
            raise
    else:
        raise RuntimeError("per-run canary Worker already exists; refusing to overwrite")
    try:
        api(f"r2/buckets/{bucket}")
    except CloudflareError as error:
        if error.status != 404:
            raise
        api("r2/buckets", "POST", {"name": bucket})
        CREATED.parent.mkdir(parents=True, exist_ok=True)
        CREATED.write_text(json.dumps({"bucket": bucket, "worker": worker, "created_by_run": os.environ.get("GITHUB_RUN_ID")}) + "\n")
        api(f"r2/buckets/{bucket}")
    else:
        raise RuntimeError("per-run canary bucket already exists; refusing to reuse")
    managed = api(f"r2/buckets/{bucket}/domains/managed")
    custom = api(f"r2/buckets/{bucket}/domains/custom")
    if not isinstance(managed, dict) or managed.get("enabled") is not False:
        raise RuntimeError("canary bucket must have r2.dev disabled")
    if not isinstance(custom, dict) or custom.get("domains") != []:
        raise RuntimeError("canary bucket must have no custom public domains")
    lifecycle = api(f"r2/buckets/{bucket}/lifecycle")
    rules = lifecycle.get("rules", [])
    if not isinstance(rules, list):
        raise RuntimeError("invalid bucket lifecycle response")
    rule = {"id": "cmux-one-artifact-canary", "enabled": True,
            "conditions": {"prefix": "github/manaflow-ai/cmux/10610975375/"},
            "deleteObjectsTransition": {"condition": {"type": "Age", "maxAge": 86400}}}
    rules = [item for item in rules if item.get("id") != rule["id"]] + [rule]
    api(f"r2/buckets/{bucket}/lifecycle", "PUT", {"rules": rules})
    origin = f"https://{worker}.{subdomain}.workers.dev"
    with Path(os.environ["GITHUB_OUTPUT"]).open("a") as output:
        output.write(f"origin={origin}\nresource={worker}\n")
    receipt = Path("artifacts/r2-canary/preflight.json")
    receipt.parent.mkdir(parents=True, exist_ok=True)
    receipt.write_text(json.dumps({"worker": worker, "bucket": bucket, "origin": origin,
        "r2_dev_enabled": False, "custom_domains": [], "canary_lifecycle": rule,
        "bucket_created_this_run": CREATED.exists()}, indent=2) + "\n")
    print("Verified isolated private canary bucket and workers.dev account routing.")


if __name__ == "__main__":
    main()
