#!/usr/bin/env python3
"""Mint this job's tokens from the CI pool Apps (one more GitHub API hour each, beside github.token).

    CI_POOL_APPS='[{"name":..,"app_id":..,"installation_id":..},...]'   (vars.CMUX_CI_POOL_APPS)
    CI_POOL_KEYS='-----BEGIN ... KEY-----...'  every pool's PEM, in CI_POOL_APPS's order (secrets.CMUX_CI_POOL_KEYS)
    CI_POOL_PERMISSIONS='{"actions":"write"}'  what this job's tokens may do (default: read the repo's contents)
    python3 scripts/ci/ci_pool_tokens.py

Each token is masked, then written to $GITHUB_ENV: CI_POOL_GH_TOKEN (the first pool, chosen by run id so runs spread
over the pools) and CI_POOL_GH_TOKEN_SPARES (the rest, space-separated). A job's step reads them as

    GH_TOKEN: ${{ env.CI_POOL_GH_TOKEN || github.token }}
    GH_TOKEN_SPARES: ${{ env.CI_POOL_GH_TOKEN_SPARES }} ${{ github.token }}

so its gh calls go out on a pool first and fall back to github.token (scripts/ci/gh_budget_wait.sh moves a
rate-limited call to the next pool at once). It never fails the job: no pool, a bad key or a refused mint prints one
line and writes nothing, and the step keeps github.token. The pool Apps and their secret are made by leo-workspace
tools/gh-app-new ci-add / ci-create / ci-publish (machines/gh-ci-pools.json).
"""
from __future__ import annotations

import base64
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

API = os.environ.get("GITHUB_API_URL", "https://api.github.com")
PEM_RE = re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----", re.S)


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def app_jwt(app_id: int, pem: str, now: int) -> str:
    head = b64url(json.dumps({"alg": "RS256", "typ": "JWT"}).encode())
    body = b64url(json.dumps({"iat": now - 60, "exp": now + 540, "iss": str(app_id)}).encode())
    with tempfile.NamedTemporaryFile("w", dir=os.environ.get("RUNNER_TEMP"), delete=False) as f:
        os.chmod(f.name, 0o600)
        f.write(pem)
        key = f.name
    try:
        sig = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key], input=f"{head}.{body}".encode(),
                             capture_output=True, timeout=20, check=True).stdout
    finally:
        os.unlink(key)
    return f"{head}.{body}.{b64url(sig)}"


def mint(app: dict, pem: str, repo: str, perms: dict, now: int) -> str:
    req = urllib.request.Request(
        f"{API}/app/installations/{int(app['installation_id'])}/access_tokens", method="POST",
        data=json.dumps({"repositories": [repo.split("/", 1)[1]], "permissions": perms}).encode(),
        headers={"Authorization": f"Bearer {app_jwt(int(app['app_id']), pem, now)}",
                 "Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"})
    with urllib.request.urlopen(req, timeout=20) as r:
        token = json.load(r).get("token")
    if not isinstance(token, str) or not token:
        raise ValueError("no token in GitHub's answer")
    return token


def main() -> int:
    try:
        apps = json.loads(os.environ.get("CI_POOL_APPS") or "[]")
    except ValueError:
        apps = None
    pems = PEM_RE.findall(os.environ.get("CI_POOL_KEYS") or "")
    if not apps or not isinstance(apps, list) or not pems:
        print("ci pool: no pool App here (CMUX_CI_POOL_APPS or CMUX_CI_POOL_KEYS unset); the job keeps github.token")
        return 0
    if len(pems) != len(apps):
        print(f"ci pool: {len(apps)} Apps but {len(pems)} keys; the job keeps github.token")
        return 0
    try:
        perms = json.loads(os.environ.get("CI_POOL_PERMISSIONS") or '{"contents":"read"}')
    except ValueError:
        print("ci pool: CI_POOL_PERMISSIONS is not JSON; the job keeps github.token")
        return 0
    repo = os.environ.get("GITHUB_REPOSITORY", "")
    start = int(os.environ.get("GITHUB_RUN_ID") or 0) % len(apps)
    order = list(range(start, len(apps))) + list(range(start))
    now = int(time.time())
    tokens, said = [], []
    for i in order:
        name = str(apps[i].get("name") or f"pool {i + 1}")
        try:
            token = mint(apps[i], pems[i], repo, perms, now)
        except urllib.error.HTTPError as err:
            said.append(f"{name}: HTTP {err.code}")
            continue
        except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as err:
            said.append(f"{name}: {type(err).__name__}")
            continue
        print(f"::add-mask::{token}")
        tokens.append((name, token))
    env = os.environ.get("GITHUB_ENV")
    if tokens and env:
        with open(env, "a", encoding="utf-8") as f:
            f.write(f"CI_POOL_GH_TOKEN={tokens[0][1]}\n")
            f.write(f"CI_POOL_GH_TOKEN_SPARES={' '.join(t for _, t in tokens[1:])}\n")
    print(f"ci pool: {len(tokens)} of {len(apps)} pools minted ({', '.join(n for n, _ in tokens) or 'none'})"
          + (f"; not minted: {', '.join(said)}" if said else "") + "; github.token is the last fallback")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as err:  # noqa: BLE001 - a mint never fails the job
        print(f"ci pool: stopped ({type(err).__name__}); the job keeps github.token")
        sys.exit(0)
