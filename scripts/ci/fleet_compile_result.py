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
  none   no usable verdict: no record within --no-record seconds, a record that does not match,
         unavailable, or the --wait deadline passed. The caller compiles as before.
  down   the build controller, which serves the results, was reached and did not answer (the CDN's 524,
         or this read's own timeout) for DOWN_AFTER seconds, counted from the start of the first read that
         failed. A compile submits to that same process, so the caller gives no verdict at once instead of
         submitting; a caller that does not know the word compiles as before. A service that cannot be
         reached at all (no connection, the tunnel's 502 or 530) is still "none" after DOWN_AFTER: the
         controller may answer its own address.
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
RECIPE = 2
# 2026-11-23 09:30-12:10Z the controller answered a plain read of this service in 78 s and the CDN cut reads at
# 100 s (HTTP 524): the old two-minute bound, counted from the end of a failed read, took 6.4-7.5 min to say "none",
# and each compile then submitted to the same controller ended with no verdict 5-8.5 min later (48 of 52 app compile
# jobs from 10:00 to 10:50Z).
DOWN_AFTER = 60
# The CDN in front of the service ends a request with no answer at 100 s (524), and the service holds a read of a
# queued or running record for up to its `wait`: a hold of 300 s ends such a read in a 524 at 100 s even with the
# controller healthy. A 60 s hold answers within the CDN's bound, so a 524 means the controller did not answer.
HOLD_MAX = 60
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
        return state, f"tip check {state}: {record.get('log_url') or ''}".strip()
    if state == "unavailable":
        return "none", "the tip check gave no verdict (unavailable)"
    if state == "superseded":
        return "superseded", f"a newer push tip is checked instead: {record.get('superseded_by') or 'unnamed'}"
    return "pending", f"tip check {state or 'queued'}"


NO_ANSWER = -1  # fetch's code for a read that timed out: something took it and did not answer


def fetch(url, timeout):
    """(HTTP code, parsed body or None); code 0 when nothing could be reached, NO_ANSWER when the read timed out."""
    try:
        # The CDN refuses urllib's default user agent with 403 (handbook cdn-refuses-the-default-client).
        req = urllib.request.Request(url, headers={"User-Agent": "cmux-ci-fleet-compile-result/1"})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            body = r.read()
            code = r.status
    except urllib.error.HTTPError as e:
        return e.code, None
    except TimeoutError:
        return NO_ANSWER, None
    except urllib.error.URLError as e:
        return (NO_ANSWER if isinstance(e.reason, TimeoutError) else 0), None
    except (OSError, ValueError):
        return 0, None
    try:
        return code, json.loads(body)
    except ValueError:
        return code, None


def read(sha, repo, pr="", wait=1500, no_record=600, results=RESULTS, fetch=fetch, now=time.monotonic,
         sleep=time.sleep, gap=30, down_after=DOWN_AFTER, phase=""):
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
    down_unanswered = None  # every failed read since down_since was the controller not answering
    seen_record = False
    last = "no read"
    while True:
        left = deadline - now()
        if left <= 1:
            return "none", f"no verdict in {wait} s ({last})"
        hold = int(min(max(left - 30, 1), HOLD_MAX))
        asked = now()
        code, body = fetch(f"{base}&wait={hold}", hold + 15)
        if code == 200:
            down_since = down_unanswered = None
            seen_record = True
            word, last = judge(body, sha, repo, PHASES[phase])
            if word != "pending":
                return word, last
        elif code == 429:
            last = "too many waiters (HTTP 429)"  # an answer: the service is up and busy
        elif code == 404:
            down_since = down_unanswered = None
            last = "no record yet"
            if not seen_record and now() - start >= no_record:
                return "none", f"the tip check has no record of this head after {no_record} s"
        else:
            unanswered = code in (524, NO_ANSWER)
            last = "no answer in time" if code == NO_ANSWER else f"HTTP {code}" if code else "not reached"
            # Counted from when the failed read was sent: one read the CDN holds 100 s before its 524 is
            # already past the bound.
            down_since = down_since if down_since is not None else asked
            down_unanswered = unanswered and (down_unanswered is not False)
            if now() - down_since >= down_after:
                if down_unanswered:
                    return "down", f"the controller did not answer ({last}) for {now() - down_since:.0f} s"
                return "none", f"results service down ({last})"
        sleep(min(gap, max(deadline - now(), 0)))


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
