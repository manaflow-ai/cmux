#!/usr/bin/env python3
"""fleet_fast_tier_result.py: read the build fleet's verdict on the cmux-next fast tier's Swift suites at a head.

The controller submits the fast tier's two light `scripts/ci/package-test-lane.sh suite PKG SUITES` steps for a
feat-cmux-next push head when `cmux-next fast tier (build fleet)` is queued (or when this read asks), judges them
(every step's ref is the head, its script and suites the ones asked for) and serves one verdict at
RESULTS/<sha>?repo=OWNER/NAME&phase=fast-tier[&ffi_repin=1][&home_render=A,B][&cmux_next=C,D][&wait=S]. The job
reads it from a Linux runner instead of holding a Mac to wait on the same steps.

Prints one word on stdout and exits 0:
  pass         every step passed at exactly this sha
  fail         a suite failed or did not build (a verdict, not a fault)
  queued       every unfinished step was still queued after --queue-wait seconds: the caller hands the
               suites back to a Mac, as for the client's exit 75
  unavailable  no verdict: the service down or too old to know the phase, the head unknown to it, a
               record that does not match, a step with no verdict, or still running at --wait. The caller
               runs the old Mac path.
Reasons go to stderr, one line per step. Usage:
  fleet_fast_tier_result.py --sha SHA --repo OWNER/NAME [--ffi-repin] [--home-render A,B] [--cmux-next C,D]
      [--wait 2400] [--queue-wait 1200] [--no-record 300]
"""
import argparse
import json
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

RESULTS = "https://gh-events.cmux.com/compile-checks/v1"
PHASE = "fast-tier"
HOLD_MAX = 90  # under the gateway's ~100 s request limit
SUITES = re.compile(r"^[A-Za-z0-9]+(,[A-Za-z0-9]+)*$")
SHA = re.compile(r"^[0-9a-f]{40}$")
STATES = ("pass", "fail", "queued", "running", "unavailable")
BUSY = (429, 503)
RETRY_AFTER_MAX = 120


def retry_after(headers):
    try:
        v = float((headers or {}).get("Retry-After", ""))
    except (TypeError, ValueError):
        return None
    return min(max(v, 1), RETRY_AFTER_MAX) if v == v else None


def fetch(url, timeout):
    """(HTTP code, parsed body or None, Retry-After seconds or None); code 0 when nothing answered."""
    try:
        # The CDN refuses urllib's default user agent with 403 (handbook cdn-refuses-the-default-client).
        req = urllib.request.Request(url, headers={"User-Agent": "cmux-ci-fleet-fast-tier-result/1"})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            body, code, after = r.read(), r.status, retry_after(r.headers)
    except urllib.error.HTTPError as e:
        return e.code, None, retry_after(e.headers)
    except (urllib.error.URLError, OSError, ValueError):
        return 0, None, None
    try:
        return code, json.loads(body), after
    except ValueError:
        return code, None, after


HOME_RENDER = "Packages/Shared/CmuxHomeRender"
CMUX_NEXT = "Packages/macOS/CmuxNext"


def registry_suites(entries):
    """The public endpoint accepts exactly these two packages; other registries need the gateway."""
    by_package = {}
    for entry in entries:
        if entry["kind"] == "swift":
            by_package.setdefault(entry["package"], []).append(entry["filter"])
    if by_package.keys() != {HOME_RENDER, CMUX_NEXT}:
        raise ValueError("the public fast-tier route does not cover these packages: " + ", ".join(by_package))
    return {package: ",".join(filters) for package, filters in by_package.items()}


def judge(record, sha, repo, want_steps, expected_suites=None):
    """(state, reasons): the record's verdict for this head, or unavailable for a record that is not this head's
    fast tier. want_steps is how many steps the read asked for."""
    if not isinstance(record, dict):
        return "unavailable", ["unreadable record"]
    if record.get("phase") != PHASE:
        # A controller that predates the phase answers its tip compile record: never a fast tier verdict.
        return "unavailable", [f"the results service does not know phase {PHASE} (answered {record.get('phase') or 'no phase'})"]
    if record.get("sha") != sha or str(record.get("repo", "")).lower() != repo.lower():
        return "unavailable", [f"record is for {record.get('repo')}@{record.get('sha')}"]
    state = record.get("state")
    steps = record.get("steps")
    if state not in STATES or not isinstance(steps, list) or len(steps) != want_steps:
        return "unavailable", [f"record state {state!r} with {len(steps) if isinstance(steps, list) else 'no'} steps"]
    reasons = []
    for s in steps:
        if not isinstance(s, dict):
            return "unavailable", ["unreadable step"]
        name = s.get("package") or s.get("name") or "step"
        st = s.get("state")
        ref = s.get("ref") or ""
        line = f"{name} ({s.get('suites', '')}): {st}"
        if s.get("job_id"):
            line += f", step {s['job_id']}"
        if s.get("exit_code") is not None:
            line += f", exit {s['exit_code']}"
        if s.get("reason"):
            line += f": {s['reason']}"
        reasons.append(line)
        # A verdict only from a step that ran this head.
        if st in ("pass", "fail") and ref != sha:
            return "unavailable", reasons + [f"{name}: its step tested {ref or 'no commit'}, not {sha}"]
    if expected_suites is not None and {s.get("package"): s.get("suites") for s in steps} != expected_suites:
        return "unavailable", reasons + ["the receipt does not cover the requested packages and suites"]
    return state, reasons


def read(sha, repo, ffi_repin=False, home_render="", cmux_next="", wait=2400, queue_wait=1200, no_record=300,
         results=RESULTS, fetch=fetch, now=time.monotonic, sleep=time.sleep, gap=15, expected_suites=None):
    """Wait up to `wait` s for the verdict; (word, reasons)."""
    q = {"repo": repo, "phase": PHASE}
    if ffi_repin:
        q["ffi_repin"] = "1"
    else:
        if home_render:
            q["home_render"] = home_render
        if cmux_next:
            q["cmux_next"] = cmux_next
    want = 1 if ffi_repin else 2
    base = f"{results}/{sha}?{urllib.parse.urlencode(q)}"
    start = now()
    deadline = start + wait
    down_since = busy_since = None
    last = ["no read"]
    while True:
        left = deadline - now()
        if left <= 1:
            return "unavailable", [f"still no verdict after {wait} s"] + last
        hold = int(min(max(left - 15, 1), HOLD_MAX))
        got = fetch(f"{base}&wait={hold}", hold + 15)
        code, body = got[0], got[1]
        after = got[2] if len(got) > 2 else None
        pause = gap
        if code == 200:
            down_since = busy_since = None
            state, last = judge(body, sha, repo, want, expected_suites)
            if state in ("pass", "fail", "unavailable"):
                return state, last
            if state == "queued" and now() - start >= queue_wait:
                return "queued", [f"still queued after {queue_wait} s"] + last
            pause = after or 1  # the read held; ask again at once
        elif code == 404:
            down_since = busy_since = None
            last = ["the results service does not know this head yet"]
            if now() - start >= no_record:
                return "unavailable", [f"the results service named no verified run at this head after {no_record} s"]
        elif code in BUSY:
            down_since = None
            busy_since = busy_since if busy_since is not None else now()
            last = [f"HTTP {code}, busy"]
            if now() - busy_since >= 600:
                return "unavailable", ["results service busy for 600 s"]
            pause = after or 30
        elif code == 400:
            return "unavailable", ["the results service refused the read (HTTP 400)"]
        else:
            last = [f"HTTP {code}" if code else "no answer"]
            down_since = down_since if down_since is not None else now()
            if now() - down_since >= 120:
                return "unavailable", [f"results service down ({last[0]})"]
        sleep(min(pause, max(deadline - now(), 0)))


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--sha", required=True)
    p.add_argument("--repo", required=True)
    p.add_argument("--ffi-repin", action="store_true")
    p.add_argument("--home-render", default="")
    p.add_argument("--cmux-next", default="")
    p.add_argument("--registry", help="Request every Swift suite in this batch registry")
    p.add_argument("--wait", type=int, default=2400)
    p.add_argument("--queue-wait", type=int, default=1200)
    p.add_argument("--no-record", type=int, default=300)
    a = p.parse_args(argv)
    if not SHA.match(a.sha):
        print(f"fleet fast tier: bad sha {a.sha!r}", file=sys.stderr)
        print("unavailable")
        return 0
    expected = None
    if a.registry:
        if a.ffi_repin or a.home_render or a.cmux_next:
            p.error("--registry supplies the complete suite selection")
        with open(a.registry, encoding="utf-8") as registry:
            entries = json.load(registry)["entries"]
        try:
            expected = registry_suites(entries)
        except ValueError as exc:
            print(f"fleet fast tier: {exc}", file=sys.stderr)
            print("unavailable")
            return 0
        a.home_render, a.cmux_next = expected[HOME_RENDER], expected[CMUX_NEXT]
    for v in (a.home_render, a.cmux_next):
        if v and not SUITES.match(v):
            print(f"fleet fast tier: suites must be names joined by commas: {v!r}", file=sys.stderr)
            print("unavailable")
            return 0
    word, reasons = read(a.sha, a.repo, a.ffi_repin, a.home_render, a.cmux_next, a.wait, a.queue_wait, a.no_record,
                         expected_suites=expected)
    for r in reasons:
        print(f"fleet fast tier: {r}", file=sys.stderr)
    print(word)
    return 0


if __name__ == "__main__":
    sys.exit(main())
