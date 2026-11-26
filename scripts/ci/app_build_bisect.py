#!/usr/bin/env python3
"""Bisect a cmux NEXT regression between a good and a bad build, with a probe run on a GUI Mac, and name the
culprit PR to the lane that reverts or fixes it forward.

Leo, 2026-11-21: "we ought to have good recovery and bisecting either automatically or agents being able to just
say "actually let's go back to this other version :)" and/or the user should be able to easily access it too".

    app_build_bisect.py plan  --good G --bad B [--json]
    app_build_bisect.py run   --good G --bad B --probe CMD [--host H] [--build-cmd CMD] [--state F]
                              [--tell CMD] [--comment] [--max-probes N] [--dry-run]
    app_build_bisect.py verdict --state F [--tell CMD] [--comment]

G and B are a nightly build number (`4495068035301`), a commit (full or short sha) or any ref. A build becomes its
commit through the nightly feed (each appcast item carries `cmux:sourceCommit`), else through the nightly.yml run it
was made by (a nightly-next build number is `<run id><attempt, 2 digits>`; nightly_next_fix_forward.build_commit).
A train commit (two parents) stands for its feat-cmux-next car, its second parent.

The range is the first-parent commits of feat-cmux-next after G up to B, oldest first, each with its PR (the `(#N)`
of its squash subject; a commit without one is a direct push and is named by sha and author). Commits a published
build was made from (the feed's items) are probed first, as `cmux app try` reaches them without a build; then the
rest of the range in midpoint order. Each probe is git bisect's contract:

    exit 0    good            exit 125  no build for this commit (skip: try a neighbour)
    exit 1-124, 126, 127  bad other  the probe itself broke (stop: no verdict from it)

CMD is a shell command with `{sha}` (and `{short}`, `{pr}`) filled in. --host runs it on that GUI host with
`reach HOST` (which itself falls back to a cmux Remote route, tools/remote_route.py, on a machine with no fleet key);
without --host it runs here, for a host-side driver. The probe for "chat does not work" is
scripts/ci/app-bisect-probe.sh: `cmux app try` the commit into a side-by-side copy of NIGHTLY, then `cmux app
health --json` against that copy (chat starts, the model picker has models, a terminal echoes).
scripts/ci/app-bisect-pane-params-probe.py is a probe that needs no Mac, for the class that broke chat on 2026-11-21:
the page sends a param the app relay's params rule refuses (every chat's initialize refused as transport.intent_invalid).
Its first run: good build 4490607108701 to Leo's NIGHTLY at 229690498cfd, 196 commits, 8 probes, culprit #46563.

When the commits left between the last good and the first bad have no build (every probe skipped), --build-cmd
(`{sha}`), when given, is run for the middle one and that commit probed again: it is the only step that builds.
Without it the verdict is the narrowed range and the command that would narrow it further.

State is a JSON file (--state, default .git/app-build-bisect/<good>-<bad>.json): every probe's result, so a rerun
resumes and `verdict` re-reads it. The verdict names the culprit (first bad commit), its PR and author, and is sent
with --tell (a command reading the text on stdin, e.g. `lane-gh send cosmic-gray/base-reds -`) and, with --comment,
as a comment on the culprit PR. The rule it serves: a PR that broke the base, its owner reverts or fixes forward.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import urllib.request

sys.path.insert(0, str(Path(__file__).resolve().parent))
import nightly_next_fix_forward as fix_forward  # noqa: E402

REPO = "manaflow-ai/cmux"
BASE = "feat-cmux-next"
FEEDS = ("https://files-next.cmux.com/nightly-next/appcast-arm64.xml",)
SQUASH = re.compile(r"\(#([1-9][0-9]*)\)\s*$")
SHA = re.compile(r"^[0-9a-f]{7,40}$")
BUILD = re.compile(r"^[0-9]{9,}$")
GOOD, BAD, SKIP = "good", "bad", "skip"
PROBE_TIMEOUT_S = int(os.environ.get("APP_BISECT_PROBE_TIMEOUT", "1800"))
BUILD_TIMEOUT_S = int(os.environ.get("APP_BISECT_BUILD_TIMEOUT", "5400"))


def git(*args: str) -> str:
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout.strip()


# ---- builds ----------------------------------------------------------------------------------------------------

def feed_items(text: str) -> list[dict]:
    """The appcast's items: build number, source commit, date, and the builds it carries deltas from."""
    out = []
    for item in text.split("<item>")[1:]:
        version = re.search(r"<sparkle:version>\s*([0-9]+)\s*</sparkle:version>", item)
        commit = re.search(r"sourceCommit[^>]*>\s*([0-9a-f]{40})\s*<", item)
        date = re.search(r"<pubDate>(.*?)</pubDate>", item)
        if version:
            out.append({"build": version.group(1), "commit": commit.group(1) if commit else None,
                        "date": date.group(1).strip() if date else "",
                        "delta_from": re.findall(r'sparkle:deltaFrom="([0-9]+)"', item)})
    return out


def read_feeds(feeds) -> list[dict]:
    items: list[dict] = []
    for url in feeds:
        try:
            if url.startswith(("http://", "https://")):
                req = urllib.request.Request(url, headers={"User-Agent": "app-build-bisect"})
                with urllib.request.urlopen(req, timeout=30) as resp:  # noqa: S310 - our own feed
                    text = resp.read().decode("utf-8", "replace")
            else:
                text = Path(url).read_text()
        except (OSError, ValueError) as err:
            print(f"app_build_bisect: feed {url} unreadable: {err}", file=sys.stderr)
            continue
        items += feed_items(text)
    return items


def car(sha: str) -> str:
    """A train commit's feat-cmux-next car (its second parent); any other commit is itself."""
    parents = git("rev-list", "--parents", "-n", "1", sha).split()[1:]
    return parents[1] if len(parents) == 2 and not on_base(sha) else sha


def on_base(sha: str) -> bool:
    try:
        git("merge-base", "--is-ancestor", sha, f"origin/{BASE}")
        return True
    except subprocess.CalledProcessError:
        return False


def resolve(point: str, items: list[dict], api=fix_forward.gh_api) -> dict:
    """A build number, sha or ref as {point, build, commit}: commit is a full sha on the base's history."""
    build = point if BUILD.match(point) else None
    commit = None
    if build:
        commit = next((i["commit"] for i in items if i["build"] == build and i["commit"]), None)
        if not commit:
            commit = fix_forward.build_commit(api, REPO, build)
        if not commit:
            raise SystemExit(f"app_build_bisect: build {build} is in no feed and has no nightly-next run here; "
                             "pass its commit instead")
    else:
        commit = point
    try:
        full = git("rev-parse", "--verify", f"{commit}^{{commit}}")
    except subprocess.CalledProcessError:
        subprocess.run(["git", "fetch", "-q", "--filter=blob:none", "origin", commit], check=False)
        full = git("rev-parse", "--verify", f"{commit}^{{commit}}")
    if not build:
        build = next((i["build"] for i in items if i["commit"] == full), None)
    return {"point": point, "build": build, "commit": car(full)}


# ---- the range -------------------------------------------------------------------------------------------------

def commits(good: str, bad: str) -> list[dict]:
    """First-parent commits after good up to bad, oldest first, each with its PR and author."""
    log = git("log", "--first-parent", "--reverse", "--format=%H%x1f%an%x1f%cI%x1f%s", f"{good}..{bad}")
    out = []
    for line in filter(None, log.splitlines()):
        sha, author, date, subject = line.split("\x1f", 3)
        found = SQUASH.search(subject)
        out.append({"sha": sha, "pr": int(found.group(1)) if found else None, "author": author, "date": date,
                    "subject": subject})
    return out


def plan(good: dict, bad: dict, items: list[dict]) -> dict:
    rng = commits(good["commit"], bad["commit"])
    built = {i["commit"]: i["build"] for i in items if i["commit"]}
    for c in rng:
        if c["sha"] in built:
            c["build"] = built[c["sha"]]
    return {"good": good, "bad": bad, "range": rng,
            "compare": f"https://github.com/{REPO}/compare/{good['commit'][:12]}...{bad['commit'][:12]}"}


# ---- the bisect ------------------------------------------------------------------------------------------------

def window(rng: list[dict], results: dict) -> tuple[int, int]:
    """(lo, hi): indices into rng such that everything <= lo is good (lo = -1: the good point) and hi is the first
    known bad (len(rng)-1: the bad point, known bad by definition)."""
    lo, hi = -1, len(rng) - 1
    for i, c in enumerate(rng):
        r = results.get(c["sha"])
        if r == BAD and i < hi:
            hi = i
            break
    for i in range(hi - 1, -1, -1):
        if results.get(rng[i]["sha"]) == GOOD:
            lo = i
            break
    return lo, hi


def next_probe(rng: list[dict], results: dict) -> int | None:
    """The commit to probe next: inside the open window, a commit with a published build nearest its middle
    first, then any untried commit nearest the middle (git bisect skip's neighbour walk). None: nothing left."""
    lo, hi = window(rng, results)
    open_ = [i for i in range(lo + 1, hi) if rng[i]["sha"] not in results]
    if not open_:
        return None
    mid = (lo + hi) / 2
    built = [i for i in open_ if rng[i].get("build")]
    return min(built or open_, key=lambda i: (abs(i - mid), i))


def fill(cmd: str, c: dict) -> str:
    return cmd.replace("{sha}", c["sha"]).replace("{short}", c["sha"][:12]).replace("{pr}", str(c.get("pr") or ""))


def run_on(host: str | None, cmd: str, timeout: int) -> tuple[int, str]:
    argv = ["reach", host, cmd] if host else ["bash", "-lc", cmd]
    try:
        done = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired as err:
        return 124, f"timed out after {timeout}s: {(err.stdout or '')[-2000:]}"
    return done.returncode, ((done.stdout or "") + (done.stderr or ""))[-4000:]


def classify(rc: int) -> str | None:
    if rc == 0:
        return GOOD
    if rc == 125:
        return SKIP
    if 1 <= rc <= 127 and rc not in (126, 127):
        return BAD
    return None


def verdict(state: dict) -> dict:
    rng, results = state["range"], state["results"]
    lo, hi = window(rng, results)
    between = rng[lo + 1:hi + 1]
    v = {"good": state["good"], "bad": state["bad"], "probes": len(state.get("log", [])),
         "last_good": rng[lo]["sha"] if lo >= 0 else state["good"]["commit"], "first_bad": rng[hi]["sha"] if rng else None}
    if len(between) == 1:
        v.update(kind="culprit", culprit=between[0])
    else:
        v.update(kind="range", candidates=between,
                 why=("every commit in it was skipped (no published build); --build-cmd builds the middle one"
                      if all(results.get(c["sha"]) == SKIP for c in between[:-1]) else "the bisect stopped early"))
    return v


def bisect(state: dict, probe: str, host: str | None, build_cmd: str | None, max_probes: int, save) -> dict:
    rng, results = state["range"], state.setdefault("results", {})
    log = state.setdefault("log", [])
    built: set[str] = set(state.setdefault("built", []))
    while len(log) < max_probes:
        i = next_probe(rng, results)
        if i is None:
            lo, hi = window(rng, results)
            skipped = [j for j in range(lo + 1, hi) if results.get(rng[j]["sha"]) == SKIP and rng[j]["sha"] not in built]
            if not (build_cmd and skipped):
                break
            j = min(skipped, key=lambda k: abs(k - (lo + hi) / 2))
            c = rng[j]
            print(f"build {c['sha'][:12]} ({'#' + str(c['pr']) if c['pr'] else 'direct push'})", flush=True)
            rc, out = run_on(None, fill(build_cmd, c), BUILD_TIMEOUT_S)
            built.add(c["sha"])
            state["built"] = sorted(built)
            log.append({"sha": c["sha"], "step": "build", "rc": rc, "tail": out[-1500:]})
            if rc == 0:
                results.pop(c["sha"], None)
            save(state)
            continue
        c = rng[i]
        rc, out = run_on(host, fill(probe, c), PROBE_TIMEOUT_S)
        result = classify(rc)
        log.append({"sha": c["sha"], "step": "probe", "rc": rc, "result": result, "tail": out[-1500:]})
        print(f"probe {c['sha'][:12]} {'#' + str(c['pr']) if c['pr'] else 'direct push'}: rc {rc} -> {result}",
              flush=True)
        if result is None:
            state["stopped"] = f"the probe broke at {c['sha'][:12]} (exit {rc}); its tail is in the state's log"
            save(state)
            break
        results[c["sha"]] = result
        save(state)
    return verdict(state)


# ---- telling ---------------------------------------------------------------------------------------------------

def text(v: dict) -> str:
    good, bad = v["good"], v["bad"]
    head = (f"app-build-bisect: cmux NEXT broke between build {good.get('build') or '?'} "
            f"({good['commit'][:12]}, good) and build {bad.get('build') or '?'} ({bad['commit'][:12]}, bad); "
            f"{v['probes']} probes.")
    if v["kind"] == "culprit":
        c = v["culprit"]
        who = f"#{c['pr']}" if c["pr"] else f"direct push {c['sha'][:12]}"
        return (f"{head} Culprit: {who} \"{c['subject']}\" by {c['author']} (first bad {c['sha'][:12]}, last good "
                f"{v['last_good'][:12]}). Its owner reverts it or fixes forward on {BASE}.")
    names = ", ".join(f"#{c['pr']}" if c["pr"] else c["sha"][:12] for c in v["candidates"])
    return (f"{head} Narrowed to {len(v['candidates'])} commits after {v['last_good'][:12]}: {names}. "
            f"Not one culprit: {v.get('why')}.")


def tell(v: dict, tell_cmd: str | None, comment: bool) -> list[str]:
    done, body = [], text(v)
    if tell_cmd:
        sent = subprocess.run(["bash", "-c", tell_cmd], input=body, text=True, capture_output=True)
        done.append(f"told `{tell_cmd}` (rc {sent.returncode}){': ' + sent.stderr.strip()[-300:] if sent.returncode else ''}")
    if comment and v["kind"] == "culprit" and v["culprit"]["pr"]:
        pr = str(v["culprit"]["pr"])
        rc = subprocess.run(["gh", "pr", "comment", pr, "-R", REPO, "--body-file", "-"], input=body, text=True,
                            capture_output=True).returncode
        done.append(f"commented on #{pr} (rc {rc})")
    return done


# ---- cli -------------------------------------------------------------------------------------------------------

def state_path(arg: str | None, good: dict, bad: dict) -> Path:
    if arg:
        return Path(arg)
    common = Path(git("rev-parse", "--git-common-dir")).resolve()
    return common / "app-build-bisect" / f"{good['commit'][:12]}-{bad['commit'][:12]}.json"


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="command", required=True)
    for name in ("plan", "run"):
        s = sub.add_parser(name)
        s.add_argument("--good", required=True)
        s.add_argument("--bad", required=True)
        s.add_argument("--feed", action="append", default=None)
        s.add_argument("--json", action="store_true")
        s.add_argument("--state")
    r = sub.choices["run"]
    r.add_argument("--probe", required=True)
    r.add_argument("--host")
    r.add_argument("--build-cmd")
    r.add_argument("--max-probes", type=int, default=12)
    r.add_argument("--tell")
    r.add_argument("--comment", action="store_true")
    r.add_argument("--dry-run", action="store_true", help="print the plan and the first probe, run nothing")
    v = sub.add_parser("verdict")
    v.add_argument("--state", required=True)
    v.add_argument("--tell")
    v.add_argument("--comment", action="store_true")
    args = p.parse_args(argv)

    if args.command == "verdict":
        state = json.loads(Path(args.state).read_text())
        out = verdict(state)
        print(json.dumps(out, indent=1))
        print(text(out))
        for line in tell(out, args.tell, args.comment):
            print(line)
        return 0 if out["kind"] == "culprit" else 2

    items = read_feeds(args.feed or FEEDS)
    good, bad = resolve(args.good, items), resolve(args.bad, items)
    pl = plan(good, bad, items)
    if args.command == "plan" or args.dry_run:
        if args.json:
            print(json.dumps(pl, indent=1))
        else:
            print(f"good {good['commit'][:12]} (build {good['build']}), bad {bad['commit'][:12]} (build {bad['build']}): "
                  f"{len(pl['range'])} first-parent commits  {pl['compare']}")
            for c in pl["range"]:
                tag = f"#{c['pr']}" if c["pr"] else "push"
                print(f"  {c['sha'][:12]} {tag:>7} {('build ' + c['build']) if c.get('build') else '':<19} "
                      f"{c['author'][:16]:<16} {c['subject'][:90]}")
        if args.command == "run":
            i = next_probe(pl["range"], {})
            print("first probe:", fill(args.probe, pl["range"][i]) if i is not None else "none (empty range)")
        return 0
    path = state_path(args.state, good, bad)
    path.parent.mkdir(parents=True, exist_ok=True)
    state = json.loads(path.read_text()) if path.exists() else {}
    if state.get("range") and [c["sha"] for c in state["range"]] == [c["sha"] for c in pl["range"]]:
        state.update(good=good, bad=bad)
    else:
        state = dict(pl, results={}, log=[])

    def save(s: dict) -> None:
        path.write_text(json.dumps(s, indent=1))

    out = bisect(state, args.probe, args.host, args.build_cmd, args.max_probes, save)
    save(dict(state, verdict=out))
    print(text(out))
    print(f"state: {path}")
    for line in tell(out, args.tell, args.comment):
        print(line)
    return 0 if out["kind"] == "culprit" else 2


if __name__ == "__main__":
    sys.exit(main())
