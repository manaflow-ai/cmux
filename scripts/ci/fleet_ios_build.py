#!/usr/bin/env python3
"""fleet_ios_build.py: have the build fleet build an iOS output for this run's commit, from a Linux runner.

Before this, the calling job ran on a macOS gateway runner (vars.CI_EVAL_STEP_GATEWAY), the only runner that could
reach the controller, and that runner sat idle for the whole build while `cmux-ci ios-build` waited
(2026-11-25: 29 runs and 340 macOS minutes a day, for the kit's xcframework alone). The controller's public route
(cmuxterm-hq build-fleet/cmd/controller/ios_build_public.go) takes the job's own GitHub Actions OIDC token instead.
It reads the repository and the commit from the token, so a run can build only its own commit, never another ref.
It submits the same job `cmux-ci ios-build` does and hands back the output once the build passes.

  POST ROUTE  {"op": "submit", "what": "ffi"|"sim-products"|"kit-products"}  -> {"job", "state"}
  POST ROUTE  {"op": "status", "job": ID}                     -> {"job", "state"[, "verdict", "reason",
                                                                  "get_url", "get_until"]}
  POST ROUTE  {"op": "queue"}                                 -> {"queued", "oldest_queued_s"}

Before it submits, it asks for the queue a submit joins: when the oldest job there has already waited
--queue-timeout, it exits 2 at once instead of holding this runner that long for a job that would wait behind it
(run 45996304968, 2026-11-27: the kit-sim-fleet job held a cmux-linux runner 604 s, "job 862b085e... still queued
after 600 s", and built nothing). A route that does not answer the queue (an older controller, no route) is no
answer: it submits as before.

Exit codes are the same as `cmux-ci ios-build`'s, so the callers did not change:
  0  every output is in --out (a pass)
  1  the build failed (a verdict, with its reason on stderr)
  2  no answer: no token, the route is not enabled or not reachable, the deadline passed, or the output is
     missing. The caller builds the output itself, as before.

Usage: fleet_ios_build.py --what ffi|sim-products|kit-products --out DIR [--timeout 1500] [--queue-timeout 600]
"""
import argparse
import json
import os
import re
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

ROUTE = "https://gh-events.cmux.com/github/ios-build"
AUDIENCE = "cmux-ios-build"
# What each kind of build must leave in --out (build-fleet/ci-client.py IOS_BUILD_OUTPUTS).
OUTPUTS = {
    "ffi": ("CmuxMobileLinkFFI.xcframework", "CmuxMobileLinkFFI.swift"),
    "sim-products": ("ios-sim-build.tar.gz", "ios-sim-xctest-platform.tar.gz", "ios-sim-app.zip"),
    # The kit's simulator test build (cmux-next-ios-kit.yml kit-sim-fleet): what the Mac's sim-pack step packs.
    "kit-products": ("ios-sim-build.tar.gz", "ios-sim-xctest-platform.tar.gz"),
}
QUEUED = {"queued", "pending", "waiting"}
ENDED = {"done", "failed", "cancelled", "canceled", "error", "timeout", "timed_out", "lost"}
# The CDN in front of the route ends a request at 100 s; every call here answers at once.
CALL_TIMEOUT = 30
# The CDN refuses Python's default `Python-urllib/3.x` agent with HTTP 403 "error code: 1010" (a banned browser
# signature): every submit failed in 0 s that way (2026-11-26, run 45898219170), so name the client.
USER_AGENT = "cmux-ci-fleet-ios-build"
POLL_START, POLL_MAX = 5, 20
SUBMIT_RETRY_S = 120  # how long a submit retries a controller that is restarting
# A failed build's answer names its compiler errors (`errors`: file, line, col, message; at most 20), the file a path
# in this checkout. Each becomes a GitHub error annotation on that line, so a job that no longer builds on a Mac still
# shows what broke: run 45923302765 showed only "the build failed: build" for WorkspaceGroupTests.swift:476's error.
ERROR_FILE = re.compile(r"^(?:cmux-next-ios|Packages)/[A-Za-z0-9_./+-]+$")
MAX_ERRORS = 20


def annotation(err):
    """The `::error` workflow command for one answered error, or None for one that is not a checkout path and line."""
    if not isinstance(err, dict):
        return None
    path, line, col, msg = err.get("file"), err.get("line"), err.get("col"), err.get("message")
    if not (isinstance(path, str) and ERROR_FILE.match(path) and ".." not in path.split("/")):
        return None
    if not (isinstance(line, int) and line > 0 and isinstance(msg, str) and msg.strip()):
        return None
    def prop(v):
        return str(v).replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A").replace(":", "%3A").replace(",", "%2C")
    data = msg.strip()[:300].replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
    where = f"file={prop(path)},line={line}" + (f",col={col}" if isinstance(col, int) and col > 0 else "")
    return f"::error {where},title=build fleet::{data}"


def log(msg):
    print(f"fleet_ios_build: {msg}", file=sys.stderr, flush=True)


def oidc_token(env=os.environ, opener=urllib.request.urlopen):
    """The job's OIDC token for the route's audience, or None (no `permissions: id-token: write`)."""
    url, bearer = env.get("ACTIONS_ID_TOKEN_REQUEST_URL", ""), env.get("ACTIONS_ID_TOKEN_REQUEST_TOKEN", "")
    if not url or not bearer:
        return None
    req = urllib.request.Request(f"{url}&audience={AUDIENCE}", headers={"Authorization": f"Bearer {bearer}"})
    try:
        with opener(req, timeout=CALL_TIMEOUT) as resp:
            return json.load(resp).get("value") or None
    except (urllib.error.URLError, OSError, ValueError) as exc:
        log(f"no OIDC token: {exc}")
        return None


def call(token, body, opener=urllib.request.urlopen):
    """(status, answer dict, retry_after) for one POST; status 0 when the route did not answer."""
    req = urllib.request.Request(
        ROUTE, data=json.dumps(body).encode(), method="POST",
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json", "User-Agent": USER_AGENT})
    try:
        with opener(req, timeout=CALL_TIMEOUT) as resp:
            return resp.status, json.load(resp), None
    except urllib.error.HTTPError as exc:
        retry = exc.headers.get("Retry-After") if exc.headers else None
        return exc.code, {"error": exc.read(300).decode(errors="replace").strip()}, retry
    except (urllib.error.URLError, OSError, ValueError) as exc:
        return 0, {"error": str(exc)}, None


def extract(archive, out_dir, what):
    """Unpack out.tgz into out_dir (plain files and directories inside it only); True when every output is there."""
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive, "r:gz") as tar:
        members = tar.getmembers()
        for m in members:
            if m.name.startswith("/") or ".." in Path(m.name).parts or not (m.isfile() or m.isdir()):
                raise ValueError(f"out.tgz member {m.name!r} is not a plain file or directory inside it")
        tar.extractall(out_dir, members=members)
    return all((out_dir / name).exists() for name in OUTPUTS[what])


def run(what, out, timeout, queue_timeout, token, opener=urllib.request.urlopen, clock=time.monotonic,
        sleep=time.sleep):
    """`token` is the bearer, or a function that mints a fresh one. A job's OIDC token lives about five minutes
    and a build runs longer: the status poll got HTTP 401 "token refused: expired" at 344 s (2026-11-27, run
    45915442830), so on a 401 ask for a new token and send the call again, once."""
    mint = token if callable(token) else None
    bearer = [mint() if mint else token]

    def ask(body):
        status, ans, retry = call(bearer[0], body, opener)
        if status == 401 and mint:
            fresh = mint()
            if fresh:
                bearer[0] = fresh
                status, ans, retry = call(fresh, body, opener)
        return status, ans, retry

    start = clock()
    if not bearer[0]:
        log("no OIDC token (the job needs permissions: id-token: write)")
        return 2
    status, ans, _ = ask({"op": "queue"})
    oldest = ans.get("oldest_queued_s") if status == 200 else None
    if isinstance(oldest, (int, float)) and oldest >= queue_timeout:
        log(f"queue full: {ans.get('queued')} job(s) queued, the oldest {int(oldest)} s, past --queue-timeout "
            f"{queue_timeout} s; not submitting (the caller builds it itself)")
        return 2
    if status == 200 and isinstance(oldest, (int, float)):
        log(f"queue: {ans.get('queued')} job(s) queued, the oldest {int(oldest)} s")
    # A controller that is restarting answers 503 "the controller is starting; retry" for a few seconds; the
    # kit run 45926512987 (2026-11-27) gave up on its first 503 and the Mac built instead. Retry a submit that
    # got no answer, a 5xx or a 429 for up to SUBMIT_RETRY_S (the Mac fallback waits on this), except a route
    # that says it is not enabled: that answer does not change on a retry.
    wait = POLL_START
    while True:
        status, ans, retry = ask({"op": "submit", "what": what})
        if status == 200 and ans.get("job"):
            break
        log(f"submit: HTTP {status} {ans.get('error', '')}".rstrip())
        transient = status in (0, 429) or (status >= 500 and "not enabled" not in str(ans.get("error", "")))
        if not transient or clock() - start > min(queue_timeout, SUBMIT_RETRY_S):
            return 2
        try:
            pause = max(wait, int(retry)) if retry else wait
        except ValueError:
            pause = wait
        sleep(pause)
        wait = min(wait * 2, POLL_MAX)
    job = ans["job"]
    log(f"job {job} {ans.get('state', '')}".rstrip())
    queued_since, wait = start, POLL_START
    while True:
        now = clock()
        if now - start > queue_timeout + timeout:
            log(f"job {job}: no verdict in {int(now - start)} s")
            return 2
        status, ans, retry = ask({"op": "status", "job": job})
        state = ans.get("state", "") if status == 200 else ""
        if status == 200 and ans.get("verdict"):
            break
        if status == 200 and state in ENDED:
            log(f"job {job} ended {state} with no verdict")
            return 2
        if status == 200 and state not in QUEUED:
            queued_since = None  # running: only --timeout bounds it now
        elif queued_since is not None and now - queued_since > queue_timeout:
            log(f"job {job}: still queued after {queue_timeout} s")
            return 2
        if status not in (0, 200, 503) and status < 500:
            log(f"status: HTTP {status} {ans.get('error', '')}".rstrip())
            return 2
        try:
            pause = max(wait, int(retry)) if retry else wait
        except ValueError:
            pause = wait
        sleep(pause)
        wait = min(wait * 2, POLL_MAX)
    verdict = ans["verdict"]
    if verdict == "fail":
        errors = ans.get("errors") if isinstance(ans.get("errors"), list) else []
        lines = [a for a in map(annotation, errors[:MAX_ERRORS]) if a]
        log(f"job {job}: the build failed: {ans.get('reason') or 'build'}"
            + (f" ({len(lines)} compiler error{'s' if len(lines) != 1 else ''} below)" if lines else ""))
        for a in lines:
            print(a, flush=True)
        return 1
    if verdict != "pass" or not ans.get("get_url"):
        log(f"job {job}: verdict {verdict} with no output")
        return 2
    with tempfile.TemporaryDirectory() as scratch:
        archive = Path(scratch) / "out.tgz"
        try:
            # The store's presigned GET sits behind the same CDN as the route: urllib's default agent got HTTP 403
            # there for every passed build (run 45932893553, both kit fleet jobs), so it names the client too. No
            # bearer: the URL is its own credential.
            get = urllib.request.Request(ans["get_url"], headers={"User-Agent": USER_AGENT})
            with opener(get, timeout=600) as resp, open(archive, "wb") as f:
                while chunk := resp.read(1 << 20):
                    f.write(chunk)
            complete = extract(archive, out, what)
        except urllib.error.HTTPError as exc:
            log(f"job {job}: output unreadable: HTTP {exc.code} {store_reason(exc)}".rstrip())
            return 2
        except (urllib.error.URLError, OSError, ValueError, tarfile.TarError) as exc:
            log(f"job {job}: output unreadable: {exc}")
            return 2
    if not complete:
        log(f"job {job}: out.tgz lacks one of {', '.join(OUTPUTS[what])}")
        return 2
    log(f"job {job}: pass in {int(clock() - start)} s")
    return 0


def store_reason(exc):
    """The first line of a refused download's body, short: "error code: 1010" (the CDN) or the store's S3 <Code>."""
    try:
        text = exc.read(2048).decode("utf-8", "replace")
    except (OSError, ValueError, AttributeError):
        return ""
    code = re.search(r"<Code>([^<]{1,80})</Code>", text)
    return code.group(1) if code else " ".join(text.split())[:120]


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--what", required=True, choices=sorted(OUTPUTS))
    ap.add_argument("--out", required=True)
    ap.add_argument("--timeout", type=int, default=1500)
    ap.add_argument("--queue-timeout", type=int, default=600)
    args = ap.parse_args(argv)
    return run(args.what, args.out, args.timeout, args.queue_timeout, oidc_token)


if __name__ == "__main__":
    sys.exit(main())
