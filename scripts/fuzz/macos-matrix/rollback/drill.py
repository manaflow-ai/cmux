#!/usr/bin/env python3
"""The Mac half of the weekly release rollback drill, in a disposable Tart guest (vm.sh --suite rollback-drill).

    drill.py --ssh admin@IP [--ssh-opt=-oX=Y ...] --out DIR [--bad N] [--budget-s S]

Leo, 2026-11-08: "btw all this "we're just doing one way" stuff how good/reliable are our designs? what can be
improved". Goal release-rollback-drilled (cmuxterm-hq goals/release-rollback-drilled.md).

cmux's nightly-next-rollback-drill.yml publishes a deliberately bad canary N and the build to keep K to the https drill
feed (DRILL_URL) at 09:15 UTC Mondays, names its run in the appcast (<cmux:drillRun>) and writes receipt.json beside it;
an hour later it pulls N through the real rollback jobs. This is the Mac half of cmuxterm-hq's
tools/fleet-reconcilers/release_rollback_drill.py (route r2, mac_feed live), ported to a Tart guest: the app's update
and rollback relaunch through LaunchServices with no environment (CmuxNextUpdater UpdateRelaunchBehind.swift,
RollbackSwap.swift), so it must run in the account's real home, and a Tart guest is thrown away whole. HQ's Linux job
judges the feed half (feed/rollback) and joins it with this result.json.

This runs on the Tart host (python3 -I, stdlib only). The guest has no python3: everything in it is /bin/sh, curl,
hdiutil, ditto, codesign and /usr/bin/perl, over ssh with the options vm.sh passes. Steps, each timed, in hq's shape
({flow, step, outcome ok|fail|skip, ms, note}; a step after a failed one is a skip naming what it needed):

  feed/pick        the drill appcast and receipt.json through files-next.cmux.com, accepted only as this week's
                   unpulled publish (this_weeks_publish); else result.json says why (`failure`) and the run stops.
                   No replay here: a Mac that comes after the pull fails.
  app/install-kept K's DMG (its enclosure on the drill feed) downloaded in the guest, its signature and team checked,
                   installed into /Applications and opened as a person opens it (`open`), until the bundled CLI's
                   `app identify --json` answers with build K and a socket.
  drill/serve      the app pointed at DRILL_URL through `updates.test_feed {url}` (a JSON-RPC line on the socket: the
                   release CLI refuses `app call`).
  app/sees-bad     `settings check-for-updates`, then updates.status until phase update_available: N reached the Mac.
                   seen_at is the host's UTC time of that answer (HQ refuses a pull ordered before it).
  app/install-bad  `settings install-available-update` (the app quits into N mid-answer, so its exit is decided by
                   the relaunch) until identify answers build N; kept_copy says whether K is kept in versions/.
  app/restore      back on K: already (restored_by pulled-build-watch), or `settings rollback-update --confirm`
                   (restored_by `settings rollback-update`) until identify answers build K; restore_s from that
                   command to K answering.

result.json: {"suite", "ok", "os", "bad_build", "kept_build", "receipt_run", "published_at", "mac_feed", "seen_at",
"seen_s", "restore_s", "restored_by", "kept_copy", "failed_steps", "failure", "steps"}.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
import time
import urllib.request

DRILL_URL = "https://files-next.cmux.com/nightly-next/drill/appcast-arm64.xml"
RECEIPT_URL = DRILL_URL.rsplit("/", 1)[0] + "/receipt.json"
RECEIPT_SCHEMA = "cmux.rollback-drill.receipt.v1"  # cmux scripts/ci/nightly_next_rollback_drill.py SCHEMA
RECEIPT_MAX_AGE_S = 3600  # published 09:15: a receipt older than this run's hour is another week's
PULLED_MAX_AGE_S = 12 * 3600  # a pulled receipt this old is still this week's: "already pulled", not "stale"
USER_AGENT = "cmux-release-rollback-drill/1"  # files-next.cmux.com answers Python-urllib's default with HTTP 403
TEAM_ID = "7WLXT3NR37"
DMG_BASE = "https://files-next.cmux.com/nightly-next/"  # the only host the guest downloads a DMG from
GUEST_DIR = "rollback-drill"  # under the guest's HOME
EVERY_S = 2

# Each step's own limit (s). Their sum is 1420 s; vm.sh also passes --budget-s (1380 s less the boot) and every
# limit is cut to what is left of it, so a major's whole cycle (clone, boot, the drill, stop, delete) stays under the
# worker's 25 min per-major bound. Nothing runs outside the budget: every guest command (Guest.sh) and every pause is
# cut to the time left, and the walk keeps RESERVE_S of it for the OS read and closing ssh.
PICK_READ_S = 15          # feed/pick: two reads (appcast, receipt)                                     30
INSTALL_KEPT_S = 240      # app/install-kept: download, attach, copy and verify K in the guest        240
LAUNCH_S = 120            #                   then `open` until identify answers K                     120
RPC_S = 30                # drill/serve: one updates.test_feed                                          30
CHECK_S = 30              # app/sees-bad: `settings check-for-updates`                                  30
OFFER_S = 120             #               updates.status until update_available                       120
INSTALL_S = 360           # app/install-bad: `settings install-available-update` (N's ~280 MB DMG)    360
RELAUNCH_S = 180          #                  the app quits and opens on N until identify answers      180
ROLLBACK_S = 120          # app/restore: `settings rollback-update --confirm`                          120
RESTORE_S = 180           #              the app quits and opens on K until identify answers          180
WRAP_S = 10               # the guest's OS version                                                      10
BUDGET_S = 1380           # the default --budget-s                                              sum: 1420
RESERVE_S = WRAP_S + 5    # the end of the budget the walk leaves for the OS read and `ssh -O exit`
# Signed by Apple's Developer ID chain with the team's own leaf, not only a TeamIdentifier the signer claims.
TEAM_REQUIREMENT = f'anchor apple generic and certificate leaf[subject.OU] = "{TEAM_ID}"'

# Linear-time item split: the lazy repeat only ever runs up to the text's last `</item>`.
ITEM = re.compile(r"<item>.*?</item>", re.S)
VERSION = re.compile(r"<sparkle:version>\s*([0-9]+)\s*</sparkle:version>")
COMMIT = re.compile(r"<cmux:sourceCommit[^>]*>([0-9a-f]{40})</cmux:sourceCommit>")
ENCLOSURE = re.compile(r'<enclosure\s+url="(' + re.escape(DMG_BASE) + r'[^"/\s]+\.dmg)"')
DRILL_RUN_TAG = re.compile(r"<cmux:drillRun\b")
DRILL_ATTEMPT = re.compile(r'\battempt="([0-9]+)"')
DRILL_RUN_TEXT = re.compile(r"\s*([0-9]+)\s*</cmux:drillRun>")
BUNDLE_ID = re.compile(r"com\.cmuxterm\.app(\.[a-z0-9]+(-[a-z0-9]+)*)*")
STEPS = (("feed", "pick"), ("app", "install-kept"), ("drill", "serve"), ("app", "sees-bad"), ("app", "install-bad"),
         ("app", "restore"))


# --- the drill feed and its receipt (pure) ------------------------------------------------------------------

def items(text: str) -> list[str]:
    last = text.rfind("</item>")
    return ITEM.findall(text, 0, last + len("</item>")) if last >= 0 else []


def entries(text: str) -> list[dict]:
    """{"build", "commit", "url"} of every item with a build number and a DMG beside the nightly feed."""
    out = []
    for item in items(text):
        version, url, commit = VERSION.search(item), ENCLOSURE.search(item), COMMIT.search(item)
        if version and url:
            out.append({"build": version.group(1), "commit": commit.group(1) if commit else None, "url": url.group(1)})
    return out


def pick(text: str) -> dict:
    """{"bad", "kept"} as hq's release_rollback_drill.pick has them: N the newest item with a source commit, K the
    newest before it with a commit, else the newest before it with any item of its own (the feed drops the commit
    from every item but the newest)."""
    found = entries(text)
    with_commit = [e for e in found if e["commit"]]
    if not with_commit:
        raise RuntimeError("the drill feed names no build with a source commit and a DMG")
    bad = max(with_commit, key=lambda e: int(e["build"]))
    before = [e for e in found if int(e["build"]) < int(bad["build"])]
    kept = (max((e for e in before if e["commit"]), key=lambda e: int(e["build"]), default=None)
            or max(before, key=lambda e: int(e["build"]), default=None))
    if kept is None:
        raise RuntimeError(f"the drill feed has no item before {bad['build']}: the drill needs K's own item")
    return {"bad": bad, "kept": kept}


def epoch(value) -> float:
    try:
        return dt.datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc).timestamp()
    except (TypeError, ValueError):
        raise RuntimeError(f"time {value!r} is not YYYY-MM-DDTHH:MM:SSZ") from None


def utc(seconds: float) -> str:
    return dt.datetime.fromtimestamp(seconds, dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def drill_run(appcast: str) -> str:
    """The cmux run and attempt the drill appcast names ("RUN/ATTEMPT"), or "" (hq's drill_run, linear time)."""
    pos = 0
    while (tag := DRILL_RUN_TAG.search(appcast, pos)) is not None:
        end = appcast.find(">", tag.end())
        if end < 0:
            break
        attempt, run = DRILL_ATTEMPT.search(appcast, tag.end(), end), DRILL_RUN_TEXT.match(appcast, end + 1)
        if attempt and run:
            return f"{run.group(1)}/{attempt.group(1)}"
        pos = end + 1
    return ""


def receipt_run(receipt: dict) -> str:
    publish = receipt.get("publish") or {}
    run, attempt = str(publish.get("run_id") or ""), str(publish.get("run_attempt") or "")
    return f"{run}/{attempt}" if run and attempt else ""


def match_receipt(receipt: dict, appcast: str) -> dict:
    if receipt.get("schema") != RECEIPT_SCHEMA:
        raise RuntimeError(f"stale receipt: schema {receipt.get('schema')!r}, not {RECEIPT_SCHEMA}")
    run, named = receipt_run(receipt), drill_run(appcast)
    if not run or run != named:
        raise RuntimeError(f"stale receipt: its publish run {run or 'none'} is not the drill feed's {named or 'none'}")
    picked = pick(appcast)
    builds = (picked["bad"]["build"], picked["kept"]["build"])
    if (str(receipt.get("bad_build")), str(receipt.get("kept_build"))) != builds:
        raise RuntimeError(f"stale receipt: builds {receipt.get('bad_build')}/{receipt.get('kept_build')}, "
                           f"the drill feed's {builds[0]}/{builds[1]}")
    return picked


def published_age(receipt: dict, now: float, limit: float) -> None:
    age = now - epoch(receipt.get("published_at"))
    if not -300 <= age <= limit:
        raise RuntimeError(f"stale receipt: published {int(age)} s before this run, not within {int(limit)} s")


def this_weeks_publish(receipt, appcast: str, now: float) -> dict:
    """match_receipt's pick for this week's unpulled publish, as hq's this_weeks_publish: the age is checked before
    the pull, so last week's pulled receipt is stale and this week's is "already pulled"."""
    if not isinstance(receipt, dict):
        raise RuntimeError("receipt.json is not a JSON object")
    if receipt.get("outcome") != "published" or receipt.get("pull_ordered_at"):
        if receipt.get("schema") != RECEIPT_SCHEMA:
            raise RuntimeError(f"stale receipt: schema {receipt.get('schema')!r}, not {RECEIPT_SCHEMA}")
        published_age(receipt, now, PULLED_MAX_AGE_S)
        raise RuntimeError(f"already pulled: the drill feed's publish was pulled before this run read it "
                           f"(outcome {receipt.get('outcome')!r}, pull ordered at {receipt.get('pull_ordered_at')})")
    picked = match_receipt(receipt, appcast)
    published_age(receipt, now, RECEIPT_MAX_AGE_S)
    return picked


# --- the app's answers (pure) -------------------------------------------------------------------------------

class Refused(RuntimeError):
    """The app answered {"ok": false}."""

    def __init__(self, method: str, error):
        self.code = error.get("code") if isinstance(error, dict) else None
        message = error.get("message") if isinstance(error, dict) else error
        super().__init__(f"{method}: {self.code or 'refused'}: {str(message)[:200]}")


def answer(method: str, text: str):
    """The result of one control socket answer line (hq's answer): Refused on {"ok": false} or an error."""
    text = (text or "").strip()
    if not text.startswith("{"):
        raise RuntimeError(f"{method}: {text[:200] or 'the socket closed with no answer'}")
    try:
        value = json.loads(text.splitlines()[0])
    except ValueError:
        raise RuntimeError(f"{method}: not JSON: {text[:200]}") from None
    if not isinstance(value, dict):
        raise RuntimeError(f"{method}: not an app answer: {text[:200]}")
    if value.get("ok") is True:
        return value.get("result")
    if value.get("ok") is False or "error" in value:
        raise Refused(method, value.get("error"))
    if "result" in value:
        return value["result"]  # the JSON-RPC envelope with no `ok`
    raise RuntimeError(f"{method}: not an app answer: {text[:200]}")


def parsed(text: str) -> dict:
    """The last JSON object line of a CLI's --json output, else the whole text as one, else {}."""
    for line in reversed((text or "").strip().splitlines()):
        try:
            value = json.loads(line)
        except ValueError:
            continue
        if isinstance(value, dict):
            return value
    try:
        value = json.loads(text)
    except (TypeError, ValueError):
        return {}
    return value if isinstance(value, dict) else {}


def result_of(value: dict) -> dict:
    """`app identify --json`'s object, whether the CLI printed the result or the whole answer."""
    inner = value.get("result") if isinstance(value, dict) else None
    return inner if isinstance(inner, dict) else value


def fields(text: str) -> dict:
    """"KEY value" lines (the guest install script's report) as a dict."""
    out = {}
    for line in (text or "").splitlines():
        key, _, value = line.partition(" ")
        if key.isupper():
            out[key] = value.strip()
    return out


def refused_as_pulled(message: str) -> bool:
    """`install-available-update` saying there is nothing to install ("cmux Is Up to Date"): no relaunch is coming."""
    return "Up to Date" in message


# --- the steps ------------------------------------------------------------------------------------------------

class Walk:
    """hq's og.Walk: each step timed; a step whose NEEDS did not pass is a skip that names it."""

    def __init__(self, clock=time.monotonic, echo=True, after=None):
        self.clock, self.steps, self.echo, self.after = clock, [], echo, after  # after(steps): each step's row written

    def step(self, flow: str, name: str, fn, needs: str | None = None):
        if needs and not self.passed(needs):
            return self.add(flow, name, "skip", None, f"needs {needs}, which did not pass")
        start = self.clock()
        try:
            note = fn()
        except Exception as error:  # noqa: BLE001 - every failure is the step's row
            return self.add(flow, name, "fail", int((self.clock() - start) * 1000), f"{type(error).__name__}: {error}")
        return self.add(flow, name, "ok", int((self.clock() - start) * 1000), note if isinstance(note, str) else "")

    def add(self, flow, name, outcome, ms, note) -> bool:
        self.steps.append({"flow": flow, "step": name, "outcome": outcome, "ms": ms, "note": str(note)[:600]})
        if self.after:
            self.after(self.steps)
        if self.echo:
            print(f"{outcome:>4} {flow}/{name}" + (f" {ms} ms" if ms is not None else "") + (f": {note}"[:400] if note else ""),
                  flush=True)
        return outcome == "ok"

    def passed(self, key: str) -> bool:
        return any(f"{s['flow']}/{s['step']}" == key and s["outcome"] == "ok" for s in self.steps)


class Budget:
    """The run's own deadline: every step limit, guest command and pause is cut to what is left of it. The walk
    (limit) stops RESERVE short of the end; the wrap-up after it (left with reserved=True) may use that too."""

    def __init__(self, seconds: float, clock=time.monotonic, reserve: float = 0):
        self.clock, self.end, self.reserve = clock, clock() + seconds, reserve
        self.wrapping = False

    def left(self) -> float:
        return self.end - self.clock() - (0 if self.wrapping else self.reserve)

    def limit(self, cap: float) -> float:
        left = self.left()
        if left < 1:
            raise RuntimeError("the run's time budget (--budget-s) is spent")
        return min(cap, left)


class Capped:
    """sh(cmd, timeout) with the timeout cut to the budget's time left: no guest command outlives the budget."""

    budget: Budget | None = None

    def sh(self, cmd: str, timeout: float) -> tuple[int, str, str]:
        if self.budget is not None:
            timeout = min(timeout, self.budget.left())
            if timeout < 1:
                return 124, "", "the run's time budget (--budget-s) is spent"
        return self.run(cmd, timeout)

    def run(self, cmd: str, timeout: float) -> tuple[int, str, str]:
        raise NotImplementedError


class Guest(Capped):
    """The VM over one multiplexed ssh connection (fuzz.py's Guest): /bin/sh commands, bounded on the host."""

    def __init__(self, target: str, ssh_opts: list[str], budget: Budget | None = None):
        self.budget = budget
        self.ctl_dir = tempfile.mkdtemp(prefix="drill-ssh-", dir="/tmp")
        self.base = ["ssh", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", "-o", "LogLevel=ERROR",
                     "-o", "ControlMaster=auto", "-o", f"ControlPath={self.ctl_dir}/ctl", "-o", "ControlPersist=600",
                     "-o", "ConnectTimeout=8", "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=3",
                     *ssh_opts, target]

    def run(self, cmd: str, timeout: float) -> tuple[int, str, str]:
        try:
            done = subprocess.run([*self.base, cmd], capture_output=True, text=True, timeout=timeout,
                                  stdin=subprocess.DEVNULL)
        except subprocess.TimeoutExpired:
            return 124, "", f"no answer within {int(timeout)} s"
        return done.returncode, done.stdout or "", done.stderr or ""

    def close(self) -> None:
        limit = min(5.0, self.budget.left()) if self.budget is not None else 5.0
        if limit >= 1:
            try:
                subprocess.run([*self.base[:-1], "-O", "exit", self.base[-1]], capture_output=True, timeout=limit,
                               stdin=subprocess.DEVNULL)
            except subprocess.TimeoutExpired:
                pass  # the master ends with ControlPersist, or with the guest when vm.sh deletes it
        try:
            os.rmdir(self.ctl_dir)
        except OSError:
            pass  # the master's socket is gone with it; a dir left in /tmp is harmless


# K's DMG into /Applications, in the guest ($1 the DMG's URL, $2 the User-Agent, $3 the code requirement: Apple's
# Developer ID anchor and the team's leaf). Prints KEY value lines.
INSTALL_SCRIPT = r'''
d=$HOME/rollback-drill; rm -rf "$d"; mkdir -p "$d/mnt" || exit 3
curl -fsSL --globoff --retry 2 --retry-delay 5 --retry-all-errors -A "$2" -o "$d/kept.dmg" "$1" || { echo "FAIL download: curl exit $?"; exit 1; }
hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$d/mnt" "$d/kept.dmg" >/dev/null || { echo "FAIL hdiutil attach"; exit 1; }
src=$(ls -d "$d"/mnt/*.app 2>/dev/null | head -1)
if [ -z "$src" ]; then hdiutil detach -force "$d/mnt" >/dev/null 2>&1; echo "FAIL the DMG holds no app"; exit 1; fi
app="/Applications/${src##*/}"
rm -rf "$app"; ditto "$src" "$app"; rc=$?
hdiutil detach -force "$d/mnt" >/dev/null 2>&1
[ "$rc" = 0 ] || { echo "FAIL copying the app: ditto exit $rc"; exit 1; }
codesign --verify --deep --strict -R="$3" "$app" 2>"$d/verify.txt" || { echo "FAIL signature or team: $(tail -c 300 "$d/verify.txt" | tr '\n' ' ')"; exit 1; }
echo "BUILD $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")"
echo "BUNDLE $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")"
xattr -cr "$app"
echo "APP $app"
'''

# One JSON-RPC line to the app's socket and its answer line, in the guest ($1 socket, $2 line, $3 seconds).
RPC_PERL = r'''
use Socket; use IO::Socket::UNIX;
my ($path, $line, $limit) = @ARGV;
local $SIG{ALRM} = sub { print STDERR "no answer within $limit s\n"; exit 124 }; alarm $limit;
my $s = IO::Socket::UNIX->new(Type => SOCK_STREAM, Peer => $path) or do { print STDERR "connect $path: $!\n"; exit 3 };
syswrite($s, "$line\n") or do { print STDERR "write: $!\n"; exit 3 };
my $buf = "";
while (index($buf, "\n") < 0) {
  my $n = sysread($s, my $chunk, 65536); last unless $n; $buf .= $chunk;
  if (length($buf) > 8 << 20) { print STDERR "the answer is over 8 MB\n"; exit 3 }
}
print $buf;
'''


class Drill:
    def __init__(self, guest: Guest, budget: Budget, expect_bad: str = "", read=None, wall=time.time,
                 clock=time.monotonic, pause=time.sleep):
        self.guest, self.budget, self.expect_bad = guest, budget, expect_bad
        self.read = read or read_served
        self.wall, self.clock, self.pause = wall, clock, pause
        self.result: dict = {"os": None, "bad_build": None, "kept_build": None, "receipt_run": None,
                             "published_at": None, "mac_feed": "live", "seen_at": None, "seen_s": None,
                             "restore_s": None, "restored_by": None, "kept_copy": None}
        self.app = self.cli = self.socket = ""

    # guest helpers
    def cmux(self, *words: str, timeout: float) -> tuple[int, str, str]:
        return self.guest.sh(" ".join(shlex.quote(w) for w in (self.cli, *words)), timeout)

    def identify(self) -> dict:
        code, out, _ = self.cmux("app", "identify", "--json", timeout=15)
        return result_of(parsed(out)) if code == 0 else {}

    def wait_build(self, build: str, cap: float) -> dict:
        limit = self.budget.limit(cap)
        end, last = self.clock() + limit, {}
        while self.clock() < end:
            last = self.identify()
            if str(last.get("build") or "") == build and last.get("socket_path"):
                self.socket = str(last["socket_path"])
                return last
            self.pause(max(0.0, min(EVERY_S, end - self.clock())))  # bounded by `limit`: the app opens on its own
        raise RuntimeError(f"the app did not answer as build {build} within {int(limit)} s"
                           f" (last: build {last.get('build') or 'none'})")

    def rpc(self, method: str, params: dict | None = None, cap: float = RPC_S):
        limit = self.budget.limit(cap)
        line = json.dumps({"id": 1, "method": method, "params": params or {}})
        cmd = " ".join(shlex.quote(w) for w in ("/usr/bin/perl", "-e", RPC_PERL, self.socket, line, str(int(limit))))
        code, out, err = self.guest.sh(cmd, min(limit + 15, self.budget.left()))
        if code != 0 and not out.strip():
            raise RuntimeError(f"{method}: exit {code}: {err.strip()[-200:]}")
        return answer(method, out)

    def cli_json(self, *words: str, cap: float) -> str:
        code, out, err = self.cmux("--json", *words, timeout=self.budget.limit(cap))
        if code != 0:
            raise RuntimeError(f"cmux {' '.join(words)}: exit {code}: {(err or out).strip()[-200:]}")
        return out

    # the steps
    def feed_pick(self) -> str:
        appcast = self.read(fresh(DRILL_URL, self.wall), self.budget.limit(PICK_READ_S))
        try:
            receipt = json.loads(self.read(fresh(RECEIPT_URL, self.wall), self.budget.limit(PICK_READ_S)))
        except ValueError:
            raise RuntimeError("receipt.json is not JSON") from None
        picked = this_weeks_publish(receipt, appcast, self.wall())
        if self.expect_bad and picked["bad"]["build"] != self.expect_bad:
            raise RuntimeError(f"the drill feed's bad build is {picked['bad']['build']}, not {self.expect_bad} (nightly:N)")
        self.bad, self.kept = picked["bad"], picked["kept"]
        self.result.update(bad_build=self.bad["build"], kept_build=self.kept["build"], receipt_run=drill_run(appcast),
                           published_at=receipt.get("published_at"))
        return (f"bad canary N {self.bad['build']}, kept K {self.kept['build']} from the drill feed of cmux run "
                f"{self.result['receipt_run']} (published {receipt.get('published_at')})")

    def install_kept(self) -> str:
        cmd = " ".join(shlex.quote(w) for w in ("/bin/sh", "-c", INSTALL_SCRIPT, "sh", self.kept["url"], USER_AGENT,
                                                    TEAM_REQUIREMENT))
        code, out, err = self.guest.sh(cmd, self.budget.limit(INSTALL_KEPT_S))
        got = fields(out)
        if code != 0 or "APP" not in got:
            raise RuntimeError(got.get("FAIL") or f"installing K in the guest: exit {code}: {(err or out).strip()[-200:]}")
        if got.get("BUILD") != self.kept["build"]:
            raise RuntimeError(f"K's DMG holds build {got.get('BUILD')}, not {self.kept['build']}")
        if not BUNDLE_ID.fullmatch(got.get("BUNDLE", "")):
            raise RuntimeError(f"unexpected bundle id {got.get('BUNDLE')!r}")
        self.app, self.bundle = got["APP"], got["BUNDLE"]
        self.cli = f"{self.app}/Contents/Resources/bin/cmux"
        code, out, err = self.guest.sh(f"/usr/bin/open {shlex.quote(self.app)}", 30)
        if code != 0:
            raise RuntimeError(f"open failed: {(err or out).strip()[-200:]}")
        ident = self.wait_build(self.kept["build"], LAUNCH_S)
        return f"{self.app} build {ident['build']} ({self.bundle}, team {TEAM_ID}) answers on {self.socket}"

    def serve(self) -> str:
        got = self.rpc("updates.test_feed", {"url": DRILL_URL})
        if (got or {}).get("test_feed") != DRILL_URL:
            raise RuntimeError(f"updates.test_feed answered test_feed {(got or {}).get('test_feed')!r}")
        return f"the app reads {DRILL_URL} (cmux run {self.result['receipt_run']})"

    def sees_bad(self) -> str:
        self.cli_json("settings", "check-for-updates", cap=CHECK_S)
        limit = self.budget.limit(OFFER_S)
        end, last = self.clock() + limit, {}
        while self.clock() < end:
            value = self.rpc("updates.status")
            last = value if isinstance(value, dict) else {}
            if last.get("phase") == "update_available":
                seen = self.wall()
                self.result["seen_at"] = utc(seen)
                self.result["seen_s"] = round(seen - epoch(self.result["published_at"]), 1)
                return (f"the Mac's Sparkle check offers {self.bad['build']} at {self.result['seen_at']}, "
                        f"{self.result['seen_s']} s after the publish")
            if last.get("phase") == "error":
                break
            self.pause(max(0.0, min(EVERY_S, end - self.clock())))  # bounded by `limit`: Sparkle's own check
        raise RuntimeError(f"the check finding {self.bad['build']}: not within {int(limit)} s (phase {last.get('phase')}; "
                           "log: " + " / ".join(str(x) for x in (last.get("log") or [])[-3:])[:300] + ")")

    def install_bad(self) -> str:
        refused = ""
        try:
            self.cli_json("settings", "install-available-update", cap=INSTALL_S)
        except RuntimeError as error:
            refused = str(error)  # the app quitting into N mid-answer looks the same; the relaunch decides
            if refused_as_pulled(refused):
                raise
        try:
            self.wait_build(self.bad["build"], RELAUNCH_S)
        except RuntimeError as error:
            raise RuntimeError(f"{error}; {refused}" if refused else str(error)) from None
        kept_dir = f"Library/Application Support/cmux-next/{self.bundle}/versions/{self.kept['build']}"
        code, _, _ = self.guest.sh(f"test -d \"$HOME\"/{shlex.quote(kept_dir)}", 15)
        self.result["kept_copy"] = code == 0
        return f"installed {self.bad['build']}; " + (f"K kept at ~/{kept_dir}" if code == 0 else f"no kept copy at ~/{kept_dir}")

    def restore(self) -> str:
        kept = self.kept["build"]
        now = self.identify()
        if str(now.get("build") or "") == kept and now.get("socket_path"):
            self.result["restore_s"], self.result["restored_by"] = 0.0, "pulled-build-watch"
            return f"back on {kept} already: the app followed the drill's pulled.json itself"
        start, closed = self.clock(), ""
        try:
            self.cli_json("settings", "rollback-update", "--confirm", cap=ROLLBACK_S)
        except RuntimeError as error:
            closed = str(error)  # the app quitting into K mid-answer looks the same as a refusal; the relaunch decides
        try:
            self.wait_build(kept, RESTORE_S)
        except RuntimeError as error:
            raise RuntimeError(f"{error}; {closed}" if closed else str(error)) from None
        self.result["restore_s"] = round(self.clock() - start, 1)
        self.result["restored_by"] = "settings rollback-update"
        return (f"back on {kept}, {self.result['restore_s']} s from `settings rollback-update` to the socket answering"
                + (f"; the call itself ended with: {closed[:200]}" if closed else ""))

    def run(self, walk: Walk) -> dict:
        prev = None
        self.guest.budget = self.budget  # every guest command, identify and open included, is cut to the time left
        for (flow, name), fn in zip(STEPS, (self.feed_pick, self.install_kept, self.serve, self.sees_bad,
                                            self.install_bad, self.restore)):
            walk.step(flow, name, fn, needs=prev)
            prev = f"{flow}/{name}"
        return judge(walk.steps, self.result)


def judge(steps: list[dict], result: dict) -> dict:
    failed = [f"{s['flow']}/{s['step']}" for s in steps if s["outcome"] != "ok"]
    first = next((s for s in steps if s["outcome"] == "fail"), None)
    return {**result, "suite": "rollback-drill", "ok": not failed and len(steps) == len(STEPS),
            "failed_steps": failed, "failure": f"{first['flow']}/{first['step']}: {first['note']}" if first else "",
            "steps": steps}


def fresh(url: str, wall=time.time) -> str:
    """URL with a query no cache has seen (files-next.cmux.com caches by URL)."""
    return f"{url}?drill={int(wall() * 1000)}"


def read_served(url: str, timeout: float) -> str:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Cache-Control": "no-cache"})
    with urllib.request.urlopen(request, timeout=timeout) as got:  # noqa: S310 - files-next.cmux.com only
        return got.read(16 << 20).decode("utf-8", "replace")


def write(out: str, result: dict) -> None:
    tmp = os.path.join(out, "result.json.tmp")
    with open(tmp, "w") as f:
        json.dump(result, f, indent=1, sort_keys=True)
    os.replace(tmp, os.path.join(out, "result.json"))


def drive(guest: Capped, budget: Budget, out: str, expect_bad: str = "", echo: bool = True, **drill_kw) -> dict:
    """The walk, then the guest's OS version, all within BUDGET; result.json is written after every step, so a run
    killed partway still leaves one (ok false until the last step)."""
    drill = Drill(guest, budget, expect_bad, **drill_kw)
    walk = Walk(drill.clock, echo=echo, after=lambda steps: write(out, judge(steps, drill.result)))
    result = drill.run(walk)
    write(out, result)
    budget.wrapping = True  # the OS read may use the reserve
    code, text, _ = guest.sh("sw_vers -productVersion", WRAP_S)
    result["os"] = drill.result["os"] = text.strip() if code == 0 else None
    write(out, result)
    return result


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--ssh", required=True)
    p.add_argument("--ssh-opt", action="append", default=[])
    p.add_argument("--out", required=True)
    p.add_argument("--bad", default="", help="nightly:N's N: the drill feed's bad build must be it")
    p.add_argument("--budget-s", type=float, default=BUDGET_S)
    a = p.parse_args(argv)
    if a.bad and not a.bad.isdigit():
        p.error("--bad takes digits")
    os.makedirs(a.out, exist_ok=True)
    budget = Budget(max(a.budget_s, 1), reserve=RESERVE_S)
    guest = Guest(a.ssh, a.ssh_opt, budget)
    try:
        result = drive(guest, budget, a.out, a.bad)
    finally:
        budget.wrapping = True
        guest.close()
    print("ROLLBACK-DRILL %s bad=%s kept=%s seen_s=%s restore_s=%s restored_by=%s failed=%s %s" % (
        "PASS" if result["ok"] else "FAIL", result.get("bad_build"), result.get("kept_build"), result.get("seen_s"),
        result.get("restore_s"), result.get("restored_by"), ",".join(result["failed_steps"]) or "-",
        result["failure"][:300]), flush=True)
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
