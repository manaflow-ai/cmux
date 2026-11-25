#!/usr/bin/env python3
"""Ask the controller for a signed input-keyed receipt, or record one (cmuxterm-hq RFD 0016 "Borg without Bazel").

Leo, 2026-11-20 (ask-8ed2d4d7c2): "the whole point is we can do what the point of doing Bazel is, which is to run
Borg without needing Bazel. You can just do the Borg."

The controller (cmuxterm-hq build-fleet/cmd/controller/input_receipt.go, POST /github/input-receipt) identifies the
run by its GitHub Actions OIDC token. It computes the check's input key itself from git trees: every unit of
scripts/ci/receipt-inputs/CHECK.txt, read from the trusted tree (the base). It never trusts a key the run sends.

  lookup CHECK [--output FILE]   hit=true only when the controller holds a verified signed receipt under the key
        and answered the same key this checkout computes. A change to a pinned file (the check's own `*` inputs or
        a line of base scripts/ci/check-paths.txt) is never a hit. On a hit the controller posts the receipt as
        the check run `cmux/receipt: <check>` on the head. Any error is hit=false, and the job runs.
  record CHECK                   after a green feat-cmux-next push: the controller signs and stores the receipt
        under the key (the first green wins). A pull request cannot record.

Writes hit=, input_key= and reason= to --output (GITHUB_OUTPUT). Always exits 0: a failed ask means the job runs.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.parse
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import receipt_input_key as rik  # noqa: E402

ENDPOINT = "https://gh-events.cmux.com/github/input-receipt"
AUDIENCE = "cmux-ci-input-receipt"
TIMEOUT = 20


def oidc_token(env=os.environ) -> str:
    url = env["ACTIONS_ID_TOKEN_REQUEST_URL"] + "&" + urllib.parse.urlencode({"audience": AUDIENCE})
    request = urllib.request.Request(url, headers={"Authorization": f"Bearer {env['ACTIONS_ID_TOKEN_REQUEST_TOKEN']}"})
    with urllib.request.urlopen(request, timeout=TIMEOUT) as response:  # user-agent: GitHub's OIDC token URL, no CDN of ours
        return json.load(response)["value"]


def ask(op: str, check: str, token: str, endpoint: str = ENDPOINT) -> dict:
    body = json.dumps({"op": op, "class": check}).encode()
    request = urllib.request.Request(endpoint, data=body, method="POST", headers={
        "Authorization": f"Bearer {token}", "Content-Type": "application/json",
        # gh-events.cmux.com (Cloudflare) answers urllib's default User-Agent with 403 (error 1010): every ask missed.
        "User-Agent": "cmux-ci receipt_signed"})
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
            return json.load(response)
    except urllib.error.HTTPError as err:
        try:
            answer = json.load(err)
        except ValueError:
            answer = {}
        answer.setdefault("reason", f"HTTP {err.code}")
        answer["hit"] = False
        return answer


def all_units_key(check: str) -> str:
    units = sorted({unit for unit, _, _ in rik.load_inputs(check) if unit != "*"})
    return rik.input_key(check, units)[0]


def verdict(answer: dict, local_key: str) -> tuple[bool, str]:
    """A hit only when the controller says hit and keyed this checkout's inputs to the same key."""
    if answer.get("hit") is not True:
        return False, str(answer.get("reason") or answer.get("error") or "no receipt under this key")
    if answer.get("input_key") != local_key:
        return False, f"controller key {answer.get('input_key')!r} is not this checkout's {local_key}"
    return True, "signed receipt " + str(answer.get("check_run_url") or "")


def main(argv: list[str] | None = None, env=os.environ, token_fn=oidc_token, ask_fn=ask) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("op", choices=["lookup", "record"])
    parser.add_argument("check", choices=sorted(rik.CHECKS))
    parser.add_argument("--output", type=Path)
    args = parser.parse_args(argv)
    hit, key, reason = False, "", ""
    try:
        key = all_units_key(args.check)
        answer = ask_fn(args.op, args.check, token_fn(env))
        if args.op == "lookup":
            hit, reason = verdict(answer, key)
        else:
            reason = "recorded" if answer.get("recorded") else str(answer.get("reason") or answer.get("error") or "kept")
    except Exception as err:  # noqa: BLE001 - any failure means no skip
        reason = f"{type(err).__name__}: {err}"
    line = f"ci-receipt: {args.check} {args.op} hit={str(hit).lower()} input_key={key} ({reason})"
    print(line)
    if env.get("GITHUB_STEP_SUMMARY"):
        with open(env["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as handle:
            handle.write(line + "\n")
    if args.output:
        with args.output.open("a", encoding="utf-8") as handle:
            handle.write(f"hit={str(hit).lower()}\ninput_key={key}\nreason={reason.splitlines()[0] if reason else ''}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
