#!/usr/bin/env python3
"""The tui release dispatcher must conclude before its publishers stop waiting.

tui-publish-npm.yml and tui-publish-pypi.yml each poll the dispatching
cmux-tui-release.yml run, give up once their bounded wait expires, and then
refuse to publish unless that run's conclusion is `success`. The dispatcher's
own bookkeeping therefore sits inside a hard deadline it does not own.

It did not respect it. `record_publisher` looked up each publisher's run id for
the step summary with a 300s budget *each*, called twice after the dispatches,
and returned 1 on timeout -- which under `set -euo pipefail` failed the step and
turned the run red. Both halves are fatal on their own:

- taking longer than the publishers' wait makes them time out; and
- a red run is rejected by their conclusion gate forever, so a retry fails in
  about a second.

cmux-tui v0.13.0 was lost exactly this way on 2026-08-26. Every build, package,
verify and attest job in run 32998045028 succeeded; the dispatch step ran
18:31:03 -> 18:35:50 and failed; both publishers failed their wait at ~18:35:17
and skipped `publish`. 0.13.0 is absent from npm and PyPI to this day.

The dispatcher now asks each dispatch for the run it created
(return_run_details), so it spends no time after dispatching and polls nothing.
This test pins that: no lookup loop or sleep in the dispatch step, and a
dispatch that names no run may not fail the run.
"""

import os
import re
import sys

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WF = os.path.join(ROOT, ".github", "workflows")
RELEASE = os.path.join(WF, "cmux-tui-release.yml")
PUBLISHERS = [os.path.join(WF, "tui-publish-npm.yml"), os.path.join(WF, "tui-publish-pypi.yml")]

FAILURES = []


def _check(cond, msg):
    if not cond:
        FAILURES.append(msg)
        print(f"FAIL: {msg}")
    else:
        print(f"ok: {msg}")


def _publisher_wait_seconds(path):
    """The bounded wait a publisher gives the artifact run to complete."""
    text = open(path, encoding="utf-8").read()
    loop = re.search(r"for _ in \{1\.\.(\d+)\}; do", text)
    sleep = re.search(r"^\s*sleep (\d+)\s*$", text, re.M)
    if not loop or not sleep:
        return None
    return int(loop.group(1)) * int(sleep.group(1))


def main():
    release = open(RELEASE, encoding="utf-8").read()

    waits = {}
    for path in PUBLISHERS:
        name = os.path.basename(path)
        seconds = _publisher_wait_seconds(path)
        _check(seconds is not None, f"{name} still has a parseable bounded wait")
        if seconds is not None:
            waits[name] = seconds
            text = open(path, encoding="utf-8").read()
            _check(
                'artifact_conclusion" != "success"' in text,
                f"{name} still refuses to publish unless the artifact run succeeded",
            )

    step = release.split("      - name: Dispatch registry publishers\n", 1)
    _check(len(step) == 2, "the dispatcher still has its dispatch step")
    step = re.split(r"\n      - name:|\n  \S", step[1], maxsplit=1)[0] if len(step) == 2 else ""
    _check(
        "return_run_details=true" in step,
        "each dispatch answers with the run it created, so the dispatcher looks nothing up",
    )
    _check(
        not re.search(r"\bsleep\b|\bwhile\b|\buntil\b|gh run list|DISCOVERY_DEADLINE", step),
        "the dispatcher spends no time after dispatching inside the publishers' wait",
    )
    if waits:
        _check(min(waits.values()) >= 60, "the publishers still give the dispatching run time to conclude")

    # Losing the run id is a cosmetic loss; it must not redden the run.
    fn = release.split("dispatch_publisher() {", 1)
    _check(len(fn) == 2, "the dispatcher still defines dispatch_publisher")
    body = fn[1].split("\n          }", 1)[0] if len(fn) == 2 else ""
    _check("return 1" not in body, "a dispatch that names no run does not fail the step")
    _check("return 0" in body, "the dispatcher returns successfully without a run id")
    _check(
        "::warning::" in body,
        "a missing run id is still reported, so a missing summary link is visible",
    )

    if FAILURES:
        print(f"\n{len(FAILURES)} failure(s)")
        sys.exit(1)
    print("\nall tui publish dispatch budget tests passed")


if __name__ == "__main__":
    main()
