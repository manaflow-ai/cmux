#!/usr/bin/env python3
"""The interaction latency benches of each cmux NEXT nightly: the ones its changes touched, run at its commit.

Leo, 2026-11-19, paraphrased: the app is still slow everywhere, and that has to change.
The perf cron (scripts/cmux-next/perf-cron.py) measures feat-cmux-next tips when a bench host is free, and went five
days with no measurement (2026-11-17 to 11-22). This runs on every push to nightly-next (.github/workflows/
nightly-interaction-latency.yml), on a Linux runner, and needs no Mac:

  plan     the files changed since the last nightly this measured (the state's head; else the push's `before`; else
           every bench is touched), and the interactions (INTERACTIONS) whose globs match one of them. An interaction
           still stale from an earlier nightly stays in the plan.
  run      each planned bench alone through webviews/bench/web-ui-suite.ts (`--only NAME`, so its rows are its own),
           cheapest first, until WALL_BUDGET_S is spent; the rest are left stale, with that reason.
  report   the state: per interaction its newest rows, the commit and time that measured them, and `stale` with
           stale_since (the first nightly that touched it and is not measured yet) and the reason. An interaction whose
           code no nightly touched keeps its rows and is not stale: its number still describes the shipped code.

The state is the newest `nightly-interaction-latency` artifact of this workflow on nightly-next (fetch-state); NOW in
cmuxterm-hq reads the same artifact (tools/fleet-reconcilers/now_benches.py) and marks a stale interaction's goal
unmet. Nothing gates on this: it publishes numbers.

  nightly_interaction_latency.py fetch-state --repo R --dir D
  nightly_interaction_latency.py plan --state D/state.json --head SHA [--before SHA] --out plan.json
  nightly_interaction_latency.py run --plan plan.json --webviews webviews --out results/
  nightly_interaction_latency.py report --state D/state.json --plan plan.json --results results/ --out out/
"""
from __future__ import annotations

import argparse
import datetime as dt
import fnmatch
import io
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
import zipfile

SCHEMA = "nightly-interaction-latency/v1"
ARTIFACT = "nightly-interaction-latency"
BRANCH = "nightly-next"
# One Linux job's whole bench time; a bench left unstarted past it stays stale ("not run: wall budget").
WALL_BUDGET_S = 90 * 60
# A change to any of these can move every interaction's number: the harness, the page shell, shared UI and the deps.
SHARED = (
    "webviews/package.json", "webviews/bun.lock", "webviews/vite.config.*", "webviews/index.html",
    "webviews/bench/*.ts", "webviews/src/main.tsx", "webviews/src/App.tsx", "webviews/src/router.tsx",
    "webviews/src/styles.css", "webviews/src/protocol/*", "webviews/src/kit/*", "webviews/src/ui/*",
    "webviews/src/theme/*", "webviews/src/layout/*", "webviews/src/motion/*", "webviews/src/scrollers.ts",
)
CHAT = ("webviews/src/agent-session/*", "webviews/test/support/papercutChat*")
# {interaction: (web-ui-suite bench name, the person's words for it, its own globs besides SHARED)}. `*` crosses `/`.
# A bench file (webviews/bench/<name>.bench.ts) touches only its own interaction; the other webviews/bench/*.ts files
# are the shared harness and helpers (SHARED).
INTERACTIONS = {
    "chat_open": ("chat-open", "open a chat", CHAT),
    "chat_switch": ("chat-switch", "switch between chats", CHAT),
    "composer_typing": ("composer-typing", "type in the chat composer", CHAT),
    "transcript_scroll": ("transcript-scroll-frame", "scroll a transcript", CHAT),
    "chat_fast_scroll": ("chat-fast-scroll", "fling a long chat", CHAT),
    "thread_rail_jump": ("thread-rail-jump", "jump with the thread rail", CHAT),
    "transcript_replay": ("transcript-replay", "load a long transcript", CHAT),
    "tool_call_burst": ("tool-call-burst", "watch a burst of tool calls", CHAT),
    "edit_turns_stream": ("edit-turns-stream", "watch edits stream in", CHAT),
    "transcript_rows": ("transcript-view-rows", "render transcript rows", CHAT),
    "settled_page": ("settled-page", "a chat page settling after load", CHAT),
    "all_chats_list": ("all-chats-list", "open the all-chats list", CHAT + ("webviews/src/sidebar/*",)),
    "sidebar_fling": ("sidebar-chats-fling", "fling the sidebar's chats", ("webviews/src/sidebar/*",)),
    "agent_activity": ("agent-activity-groups", "the agent activity list", ("webviews/src/agent-activity/*",)),
    "markdown_viewer": ("markdown-viewer-stress", "scroll a big markdown file", ("webviews/src/markdown-viewer/*",)),
}
# Each bench's timeout here, seconds, passed to web-ui-suite.ts as --timeout-s: the order (cheapest first) and the
# budget check before a start. The cmux-linux runner is two to three times slower than the perf runner the suite's own
# timeouts fit (thread-rail-jump and all-chats-list timed out at 90 s and transcript-replay at 300 s on every nightly
# from 2026-11-22; on a lane VM they take 51, 59 and 145 s), so these are about twice the suite's.
TIMEOUT_S = {"agent-activity-groups": 30, "edit-turns-stream": 30, "transcript-view-rows": 30, "chat-open": 200,
             "thread-rail-jump": 240, "all-chats-list": 240, "tool-call-burst": 240, "transcript-scroll-frame": 240,
             "chat-switch": 450, "transcript-replay": 600, "settled-page": 600, "sidebar-chats-fling": 600,
             "chat-fast-scroll": 900, "markdown-viewer-stress": 900, "composer-typing": 1500}
TOUCHED_KEEP = 8  # files named per touched interaction


def now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def matches(path: str, globs) -> bool:
    return any(fnmatch.fnmatchcase(path, g) for g in globs)


def is_test_file(path: str) -> bool:
    """A unit test moves no shipped code (webviews/test/support/papercutChat*, a bench input, is not one)."""
    name = path.rsplit("/", 1)[-1]
    return ".test." in name or ".spec." in name


def is_bench_file(path: str) -> bool:
    return path.startswith("webviews/bench/") and (path.endswith(".bench.ts") or path.endswith(".bench.tsx"))


def touched(changed: list[str] | None) -> dict[str, list[str]]:
    """{interaction: the changed files that touch it}. None (no known base) touches every interaction."""
    out = {}
    for key, (bench, _words, own) in INTERACTIONS.items():
        if changed is None:
            out[key] = ["(no earlier nightly measured: every interaction)"]
            continue
        mine = f"webviews/bench/{bench}.bench."
        hits = [p for p in changed if not is_test_file(p) and (p.startswith(mine) or matches(p, own)
                or (not is_bench_file(p) and matches(p, SHARED)))]
        if hits:
            out[key] = hits[:TOUCHED_KEEP]
    return out


def load_state(path: str | None) -> dict:
    try:
        with open(path or "") as f:
            state = json.load(f)
        if isinstance(state, dict) and state.get("schema") == SCHEMA and isinstance(state.get("interactions"), dict):
            return state
    except (OSError, ValueError):
        pass
    return {"schema": SCHEMA, "head": None, "interactions": {}}


def changed_files(base: str | None, head: str) -> list[str] | None:
    if not base or set(base) == {"0"}:
        return None
    p = subprocess.run(["git", "diff", "--name-only", "--no-renames", f"{base}..{head}"], capture_output=True, text=True)
    if p.returncode != 0:
        print(f"nightly-interaction-latency: cannot diff {base[:12]}..{head[:12]} ({p.stderr.strip()[:200]}); "
              "every interaction is touched", flush=True)
        return None
    return [line for line in p.stdout.splitlines() if line]


def plan(state: dict, head: str, before: str | None, changed: list[str] | None) -> dict:
    hit = touched(changed)
    pending = {}
    for key, (bench, _words, _own) in INTERACTIONS.items():
        prev = state["interactions"].get(key) or {}
        if key in hit:
            pending[key] = {"bench": bench, "touched_by": hit[key]}
        elif prev.get("stale") or not prev.get("measured_sha"):
            pending[key] = {"bench": bench, "touched_by": prev.get("touched_by") or ["(never measured)"]}
    order = sorted(pending, key=lambda k: (TIMEOUT_S.get(pending[k]["bench"], 600), k))
    return {"schema": SCHEMA, "head": head, "base": state.get("head") or before, "at": now_iso(),
            "changed": len(changed) if changed is not None else None, "run": [dict(pending[k], key=k) for k in order]}


def run(planned: dict, webviews: str, out_dir: str, budget_s: float = WALL_BUDGET_S,
        clock=time.monotonic, runner=subprocess.run) -> dict:
    """Run each planned bench alone; {key: {"ok", "why", "rows", "seconds"}}, also written to out_dir/results.json."""
    os.makedirs(out_dir, exist_ok=True)
    start, results = clock(), {}
    for item in planned["run"]:
        key, bench = item["key"], item["bench"]
        left = budget_s - (clock() - start)
        if left < TIMEOUT_S.get(bench, 600):
            results[key] = {"ok": False, "why": f"not run: {int(left)} s of the {int(budget_s)} s budget left"}
            continue
        report = os.path.join(os.path.abspath(out_dir), f"{bench}.json")
        t0 = clock()
        print(f"nightly-interaction-latency: {key} ({bench})", flush=True)
        p = runner(["bun", "bench/web-ui-suite.ts", "--only", bench, "--timeout-s", str(TIMEOUT_S.get(bench, 600)),
                    "--out", report], cwd=webviews)
        seconds = round(clock() - t0, 1)
        try:
            with open(report) as f:
                got = json.load(f)
        except (OSError, ValueError):
            got = {}
        rows = [r for r in got.get("rows") or [] if isinstance(r, dict) and isinstance(r.get("p95"), (int, float))]
        failed = [f for f in got.get("failed") or [] if isinstance(f, dict)]
        # Rows are a measurement even when the bench exited non-zero: a bench fails its own bound (a freeze, a p95
        # over its budget) after printing the rows that show it, and that slow number is what the board must see, not
        # a stale one. Its failure is kept as `note`. No rows is the only unmeasured outcome.
        note = (failed[0].get("why") if failed else None) or (f"exit {p.returncode}" if p.returncode else None)
        why = None if rows else (note or "no rows")
        results[key] = {"ok": why is None, "why": why, "note": note if rows else None, "rows": rows,
                        "seconds": seconds}
    with open(os.path.join(out_dir, "results.json"), "w") as f:
        json.dump(results, f, indent=1)
    return results


def report(state: dict, planned: dict, results: dict, runner_name: str | None = None) -> dict:
    """The next state: measured interactions take their rows; a touched one that did not measure is stale."""
    at, head = planned.get("at") or now_iso(), planned["head"]
    out = {"schema": SCHEMA, "head": head, "base": planned.get("base"), "at": at, "runner": runner_name,
           "interactions": {}}
    ran = {item["key"]: item for item in planned.get("run") or []}
    for key, (bench, words, _own) in INTERACTIONS.items():
        prev = dict(state["interactions"].get(key) or {})
        row = {"bench": bench, "interaction": words, "measured_sha": prev.get("measured_sha"),
               "measured_at": prev.get("measured_at"), "rows": prev.get("rows") or [], "runner": prev.get("runner"),
               "stale": False, "stale_since": None, "stale_sha": None, "why": None, "touched_by": []}
        if key in ran:
            got = results.get(key) or {"ok": False, "why": "no result (the run step did not finish)"}
            if got.get("ok"):
                row.update(measured_sha=head, measured_at=at, rows=got.get("rows") or [], runner=runner_name,
                           seconds=got.get("seconds"), note=got.get("note"))
            else:
                row.update(stale=True, why=got.get("why"), touched_by=ran[key].get("touched_by") or [],
                           stale_since=prev.get("stale_since") or at, stale_sha=prev.get("stale_sha") or head,
                           seconds=got.get("seconds"))
        out["interactions"][key] = row
    return out


def summary(state: dict) -> str:
    lines = [f"### Interaction latency at {str(state['head'])[:12]} (nightly-next)", "",
             "| interaction | bench | worst p95 / target | measured at | state |", "|---|---|---|---|---|"]
    for key, row in state["interactions"].items():
        rows = [r for r in row.get("rows") or [] if isinstance(r.get("target"), (int, float)) and r["target"] > 0]
        worst = max(rows, key=lambda r: r["p95"] / r["target"], default=None)
        val = (f"{worst['name']} {worst['p95']} / {worst['target']} {worst.get('unit') or 'ms'}" if worst else "-")
        when = str(row.get("measured_sha") or "never")[:12]
        st = (f"STALE since {row['stale_since']} ({row.get('why')}); touched by {', '.join(row['touched_by'][:3])}"
              if row.get("stale") else f"fresh; bench failed its own bound: {row['note']}" if row.get("note")
              else "fresh")
        lines.append(f"| {row['interaction']} | {row['bench']} | {val} | {when} | {st} |")
    return "\n".join(lines) + "\n"


# --- GitHub reads (fetch-state): the newest trusted artifact of this workflow on nightly-next ---

def _request(url: str, token: str, accept="application/vnd.github+json"):
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}", "Accept": accept,
                                               "X-GitHub-Api-Version": "2022-11-28"})
    return urllib.request.urlopen(req, timeout=60)


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def _download(url: str, token: str) -> bytes:
    """The artifact zip: GitHub answers 302 to a signed URL that must be fetched without our token."""
    opener = urllib.request.build_opener(_NoRedirect)
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    try:
        with opener.open(req, timeout=60) as r:
            return r.read()
    except urllib.error.HTTPError as e:
        if e.code not in (301, 302, 303, 307, 308):
            raise
        with urllib.request.urlopen(e.headers["Location"], timeout=120) as r:
            return r.read()


def trusted(artifact: dict, repo_id: int | None) -> bool:
    run = artifact.get("workflow_run") or {}
    return (not artifact.get("expired") and run.get("head_branch") == BRANCH
            and (repo_id is None or run.get("head_repository_id") == repo_id))


def fetch_state(repo: str, out_dir: str, token: str) -> bool:
    os.makedirs(out_dir, exist_ok=True)
    api = os.environ.get("GITHUB_API_URL", "https://api.github.com")
    rid = os.environ.get("GITHUB_REPOSITORY_ID", "")
    repo_id = int(rid) if rid.isdigit() else None
    with _request(f"{api}/repos/{repo}/actions/artifacts?name={ARTIFACT}&per_page=30", token) as r:
        found = json.load(r).get("artifacts") or []
    for a in sorted(found, key=lambda a: a.get("created_at") or "", reverse=True):
        if trusted(a, repo_id):
            zipfile.ZipFile(io.BytesIO(_download(a["archive_download_url"], token))).extractall(out_dir)
            print(f"nightly-interaction-latency: state from artifact {a['id']} ({a.get('created_at')})")
            return True
    print("nightly-interaction-latency: no earlier state; every interaction is touched")
    return False


def fetch_state_retrying(repo: str, out_dir: str, token: str, tries: int = 3, sleep=time.sleep, fetch=None):
    """fetch_state, retried; None when every try failed. An unread state is not "no state": planning from nothing
    would publish a state with every earlier number gone (run 45207965116: one 403 dropped 8 interactions' last
    rows), so the job stops instead and the next nightly reads the last state that was published."""
    fetch = fetch or fetch_state
    for attempt in range(tries):
        try:
            return fetch(repo, out_dir, token)
        except (OSError, ValueError, zipfile.BadZipFile) as e:
            print(f"nightly-interaction-latency: state not read, try {attempt + 1} of {tries} ({e})", flush=True)
            if attempt + 1 < tries:
                sleep(10 * (attempt + 1))
    print("nightly-interaction-latency: state not read; publishing nothing, so the last state stays the newest")
    return None


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    f = sub.add_parser("fetch-state")
    f.add_argument("--repo", required=True)
    f.add_argument("--dir", required=True)
    p = sub.add_parser("plan")
    p.add_argument("--state")
    p.add_argument("--head", required=True)
    p.add_argument("--before")
    p.add_argument("--out", required=True)
    r = sub.add_parser("run")
    r.add_argument("--plan", required=True)
    r.add_argument("--webviews", required=True)
    r.add_argument("--out", required=True)
    r.add_argument("--budget-s", type=float, default=WALL_BUDGET_S)
    rep = sub.add_parser("report")
    rep.add_argument("--state")
    rep.add_argument("--plan", required=True)
    rep.add_argument("--results", required=True)
    rep.add_argument("--out", required=True)
    rep.add_argument("--runner")
    o = ap.parse_args(argv)
    if o.cmd == "fetch-state":
        return 0 if fetch_state_retrying(o.repo, o.dir, os.environ.get("GH_TOKEN", "")) is not None else 1
    if o.cmd == "plan":
        state = load_state(o.state)
        base = state.get("head") or o.before
        out = plan(state, o.head, o.before, changed_files(base, o.head))
        with open(o.out, "w") as fh:
            json.dump(out, fh, indent=1)
        print(f"nightly-interaction-latency: {len(out['run'])} of {len(INTERACTIONS)} interactions to measure "
              f"({out['changed']} files changed since {str(out['base'])[:12]}): {', '.join(i['key'] for i in out['run'])}")
        return 0
    if o.cmd == "run":
        with open(o.plan) as fh:
            run(json.load(fh), o.webviews, o.out, o.budget_s)
        return 0
    with open(o.plan) as fh:
        planned = json.load(fh)
    try:
        with open(os.path.join(o.results, "results.json")) as fh:
            results = json.load(fh)
    except (OSError, ValueError):
        results = {}
    state = report(load_state(o.state), planned, results, o.runner)
    os.makedirs(o.out, exist_ok=True)
    with open(os.path.join(o.out, "state.json"), "w") as fh:
        json.dump(state, fh, indent=1)
    text = summary(state)
    print(text)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as fh:
            fh.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
