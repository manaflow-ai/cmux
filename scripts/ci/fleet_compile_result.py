#!/usr/bin/env python3
"""fleet_compile_result.py: read the build fleet's one compile of a head instead of compiling it again.

The controller's tip check (cmux_next_tip_check.go) compiles the app at every pull request head and
feat-cmux-next push in SwiftPM Release (-Onone), and the results service serves its record at
RESULTS/<sha>?repo=OWNER/NAME[&pr=N][&wait=S] (compile-status posts it as cmux-next/compile). The
fleet compile jobs (app-compile-fleet, swift-canary-fleet, release-compile-fast) compiled the same head
again: 2026-11-20..21, 5.2k of their 7.5k machine-minutes were on heads the tip check also compiled
(cmuxterm-hq docs/ci/fleet-282-2026-11-21.md). They call this first and compile only when it says
"none".

Prints one word on stdout and exits 0:
  pass   the record for exactly this sha and repo, recipe 2, release-onone, passed
  fail   that record failed (a compile verdict, not a fault)
  none   no usable verdict: no record within --no-record seconds, the service down, a record that
         does not match, unavailable, or the --wait deadline passed. The caller compiles as before.
  superseded  a feat-cmux-next push tip (no --pr) the controller will not check because a newer push
         tip is checked instead (its check covers this push's commits, and a red there names them).
         The caller confirms the branch head moved before it skips; a caller that does not know the
         word compiles as before.
With --phase app-debug it reads the pull request app compile's own check instead (the build fleet's Debug
`--app` compile of a same-repository pull request head, configuration "debug"): the controller submits it
when that job is queued or when this read names the pull request, and it never stands for the land Release.

Reasons go to stderr. Usage:
  fleet_compile_result.py --sha SHA --repo OWNER/NAME [--pr N] [--phase app-debug] [--wait 1500] [--no-record 600]
"""
import argparse
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

RESULTS = "https://gh-events.cmux.com/compile-checks/v1"
HOLD_MAX = 90  # under the gateway's ~100 s request limit
RECIPE = 2
CONFIGURATION = "release-onone"
# The phases a read can name, and the configuration each one's record carries.
PHASES = {"": CONFIGURATION, "app-debug": "debug"}


def judge(record, sha, repo, configuration=CONFIGURATION):
    """The verdict a record gives this head: pass, fail, pending (still running) or none."""
    if not isinstance(record, dict):
        return "none", "unreadable record"
    if record.get("sha") != sha or record.get("repo") != repo:
        return "none", f"record is for {record.get('repo')}@{record.get('sha')}"
    if record.get("recipe_version") != RECIPE or record.get("configuration") != configuration:
        return "none", f"record is recipe {record.get('recipe_version')} {record.get('configuration')}"
    state = record.get("state") or ""
    if state in ("pass", "fail"):
        # A red names why: the controller's reply carries the failing step's first error (hq#24624).
        detail = "; ".join(str(x) for x in (record.get("reason"), record.get("log_url")) if x)
        return state, f"tip check {state}: {detail}" if detail else f"tip check {state}"
    if state == "unavailable":
        return "none", "the tip check gave no verdict (unavailable)"
    if state == "superseded":
        return "superseded", f"a newer push tip is checked instead: {record.get('superseded_by') or 'unnamed'}"
    return "pending", f"tip check {state or 'queued'}"


# Answers that mean "busy, ask again later", not "down": the service's long-poll slots are full (429) or it is
# starting (503). They never count toward the service-down bound until BUSY_MAX has passed with nothing else.
BUSY = (429, 503)
BUSY_MAX = 900  # a service that only ever answers busy for 15 minutes is down after all
RETRY_AFTER_MAX = 120


def retry_after(headers):
    """Seconds a Retry-After header asks for (its seconds form), or None."""
    try:
        v = float((headers or {}).get("Retry-After", ""))
    except (TypeError, ValueError):
        return None
    return min(max(v, 1), RETRY_AFTER_MAX) if v == v else None


def fetch(url, timeout):
    """(HTTP code, parsed body or None, Retry-After seconds or None); code 0 when nothing answered."""
    try:
        # The CDN refuses urllib's default user agent with 403 (handbook cdn-refuses-the-default-client).
        req = urllib.request.Request(url, headers={"User-Agent": "cmux-ci-fleet-compile-result/1"})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            body = r.read()
            code = r.status
            after = retry_after(r.headers)
    except urllib.error.HTTPError as e:
        return e.code, None, retry_after(e.headers)
    except (urllib.error.URLError, OSError, ValueError):
        return 0, None, None
    try:
        return code, json.loads(body), after
    except ValueError:
        return code, None, after


def read(sha, repo, pr="", wait=1500, no_record=600, results=RESULTS, fetch=fetch, now=time.monotonic,
         sleep=time.sleep, gap=30, phase=""):
    """Wait up to `wait` s for this head's verdict; (word, reason)."""
    start = now()
    deadline = start + wait
    q = {"repo": repo}
    if pr:
        q["pr"] = pr
    if phase:
        q["phase"] = phase
    base = f"{results}/{sha}?{urllib.parse.urlencode(q)}"
    down_since = None
    busy_since = None
    seen_record = False
    last = "no read"
    wait_next = gap
    while True:
        left = deadline - now()
        if left <= 1:
            return "none", f"no verdict in {wait} s ({last})"
        # The results service sits behind a gateway that ends a request held about 100 s (HTTP 524),
        # so a 300 s hold read a healthy service as down and spent its two-minute grace on it.
        hold = int(min(max(left - 30, 1), HOLD_MAX))
        got = fetch(f"{base}&wait={hold}", hold + 15)
        code, body = got[0], got[1]
        after = got[2] if len(got) > 2 else None
        wait_next = gap
        if code == 200:
            down_since = busy_since = None
            seen_record = True
            word, last = judge(body, sha, repo, PHASES[phase])
            if word != "pending":
                return word, last
            if after:
                wait_next = after  # answered at once because the long-poll slots were full
        elif code == 404:
            down_since = busy_since = None
            last = "no record yet"
            if not seen_record and now() - start >= no_record:
                return "none", f"the tip check has no record of this head after {no_record} s"
        elif code in BUSY:
            # Busy is an answer: the service is up and asks us to come back (hq#24624: job 138782761400 read a 429
            # as "down" and failed closed). Back off as it says, else 30, 60, 120 s.
            down_since = None
            busy_since = busy_since if busy_since is not None else now()
            last = f"HTTP {code}, busy"
            if now() - busy_since >= BUSY_MAX:
                return "none", f"results service busy for {BUSY_MAX} s ({last})"
            wait_next = after or min(gap * 2 ** min(int((now() - busy_since) // gap), 2), 120)
        else:
            last = f"HTTP {code}" if code else "no answer"
            down_since = down_since if down_since is not None else now()
            # The results service is a cache, not a dependency: down for two minutes, compile here.
            if now() - down_since >= 120:
                return "none", f"results service down ({last})"
        sleep(min(wait_next, max(deadline - now(), 0)))


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--sha", required=True)
    p.add_argument("--repo", required=True)
    p.add_argument("--pr", default="")
    p.add_argument("--wait", type=int, default=1500)
    p.add_argument("--no-record", type=int, default=600)
    p.add_argument("--phase", default="", choices=sorted(PHASES))
    a = p.parse_args(argv)
    if len(a.sha) != 40 or any(c not in "0123456789abcdef" for c in a.sha):
        print(f"fleet compile result: bad sha {a.sha!r}", file=sys.stderr)
        print("none")
        return 0
    word, why = read(a.sha, a.repo, a.pr if a.pr.isdigit() else "", a.wait, a.no_record, phase=a.phase)
    print(f"fleet compile result for {a.sha}: {word} ({why})", file=sys.stderr)
    print(word)
    return 0


if __name__ == "__main__":
    sys.exit(main())
