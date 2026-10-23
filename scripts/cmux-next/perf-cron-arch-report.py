#!/usr/bin/env python3
"""Architecture count trend and regression issue for the scheduled perf cron (Linux report step, no swift).

perf-cron.py's `report` subcommand runs this after its perf comparison (one hook line, PL-perf-cron's file):

  perf-cron-arch-report.py --sha SHA --state STATE_JSON [--issue] [--dry-run]

1. Counts every architecture row at SHA with scripts/cmux-next/arch_counts.py (the full scan, the copy at SHA, run
   on the files of SHA exported from git into a temporary directory; the checkout itself is not read).
2. Reads plans/cmux-next/arch-ratchet.json at SHA (the ratchet: a count only goes down).
3. Keeps the last HISTORY_POINTS points under STATE_JSON's key `arch_history` (the other keys are left as they are).
4. Prints one trend table: row, ratchet value, the last TREND_VALUES values, now, and an arrow.
5. With --issue: when a row is over its ratchet value, opens or updates the one issue ISSUE_TITLE (ISSUE_MARK in
   its body, opened by the workflow's bot); it names each row, its package, the first sha where the row was seen
   higher and the commits in the range. When every row is back at or under the ratchet, it closes the issue.

It never fails the job: every error is printed and the exit code is 0. --dry-run prints the table and the issue
action and writes nothing (no state, no GitHub). Tests: scripts/cmux-next/tests/test_perf_cron_arch_report.py
(GitHub faked, git real in a temporary repository; run them yourself, no CI job runs them).
"""
import argparse, datetime, importlib.util, inspect, json, os, re, subprocess, sys, tempfile, time, traceback
import urllib.error, urllib.parse, urllib.request
from pathlib import Path

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
RATCHET_PATH = "plans/cmux-next/arch-ratchet.json"
LAYERS_PATH = "plans/cmux-next/architecture-layers.json"
COUNTS_SCRIPT = "scripts/cmux-next/arch_counts.py"
# What arch_counts.py reads at SHA: the CmuxNext Swift (sources, tests, Package.swift), the plans' JSON (layer map,
# ratchet) and the counting scripts. Only these are exported, so the scan stays well under 30 s.
# (directory, suffix, recursive)
EXPORT_PATHS = (("Packages/macOS/CmuxNext", ".swift", True), ("plans/cmux-next", ".json", False),
                ("scripts/cmux-next", ".py", False))
# The full-count entry points tried in order (the first that exists is called with the exported root, or with no
# argument when it takes none); then `arch_counts.py --json` in the exported root, its last JSON object.
COUNT_FUNCTIONS = ("full_counts", "compute_counts", "count_all", "counts", "compute", "measure")
STATE_KEY = "arch_history"
ISSUE_KEY = "arch_issue"
HISTORY_POINTS = 20
TREND_VALUES = 5
BRANCH = "feat-cmux-next"
ISSUE_TITLE = "cmux-next architecture count regression"
ISSUE_MARK = "<!-- cmux-next-arch-ratchet -->"
# The issue is this report's own only when the bot opened it and its body carries ISSUE_MARK.
ISSUE_AUTHOR = "github-actions[bot]"
RANGE_COMMITS_SHOWN = 40
DEEPEN_STEP = 500
DEEPEN_ROUNDS = 4
SHA_RE = re.compile(r"^[0-9a-f]{40}$")


def log(msg):
    print(f"perf-cron-arch: {msg}", flush=True)


def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


# ---------- git ----------

def git(root, *args, check=True, timeout=120):
    return subprocess.run(["git", "-C", root, *args], capture_output=True, text=True, check=check,
                          timeout=timeout).stdout.strip()


def resolve_sha(root, sha):
    full = git(root, "rev-parse", "--verify", "--end-of-options", f"{sha}^{{commit}}")
    if not SHA_RE.match(full):
        raise ValueError(f"{sha!r} is not a commit")
    return full


def file_at(root, sha, path):
    """The text of path at sha, or None when the commit has no such file."""
    proc = subprocess.run(["git", "-C", root, "show", f"{sha}:{path}"], capture_output=True, text=True, timeout=60)
    return proc.stdout if proc.returncode == 0 else None


def exported(path):
    for directory, suffix, recursive in EXPORT_PATHS:
        rest = path[len(directory) + 1:] if path.startswith(directory + "/") else None
        if rest and rest.endswith(suffix) and (recursive or "/" not in rest):
            return True
    return False


def export_tree(root, sha, dest):
    """Write the EXPORT_PATHS files of sha into dest from git objects (one ls-tree, one cat-file --batch), not from
    the checkout: SHA may differ from it, and the report's sparse checkout has none of these files on disk."""
    listing = subprocess.run(["git", "-C", root, "ls-tree", "-r", "-z", sha, "--", *(d for d, _, _ in EXPORT_PATHS)],
                             capture_output=True, check=True, timeout=120).stdout
    files = []
    for entry in listing.split(b"\0"):
        if not entry:
            continue
        meta, _, path = entry.partition(b"\t")
        mode, kind, oid = meta.split()
        name = path.decode(errors="surrogateescape")
        if kind == b"blob" and mode != b"120000" and exported(name):
            files.append((oid, name))
    blobs = subprocess.run(["git", "-C", root, "cat-file", "--batch"], input=b"".join(o + b"\n" for o, _ in files),
                           capture_output=True, check=True, timeout=120).stdout
    at = 0
    for oid, name in files:
        header_end = blobs.index(b"\n", at)
        header = blobs[at:header_end].split()
        if len(header) != 3 or header[0] != oid:
            raise RuntimeError(f"cannot read {name} at {sha[:12]}: {blobs[at:header_end][:200]!r}")
        size = int(header[2])
        body = blobs[header_end + 1:header_end + 1 + size]
        at = header_end + 1 + size + 1
        target = os.path.join(dest, name)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with open(target, "wb") as f:
            f.write(body)
    return len(files)


def is_ancestor(root, good, bad):
    """True: good is an ancestor of bad. False: not known in this (shallow) clone yet. None: complete and not."""
    proc = subprocess.run(["git", "-C", root, "merge-base", "--is-ancestor", "--end-of-options", good, bad],
                          capture_output=True, text=True, timeout=60)
    if proc.returncode == 0:
        return True
    return False if git(root, "rev-parse", "--is-shallow-repository", check=False) == "true" else None


def range_commits(root, good, bad):
    """[(sha, subject)] of the first-parent commits in good..bad (bad included), oldest first, or None (printed)
    when the range cannot be listed. The report's checkout is shallow: it is deepened first when needed."""
    for rounds in range(DEEPEN_ROUNDS + 1):
        have = is_ancestor(root, good, bad)
        if have:
            break
        if have is None or rounds == DEEPEN_ROUNDS:
            log(f"cannot list {good[:12]}..{bad[:12]}: {good[:12]} is not a known ancestor of {bad[:12]}")
            return None
        try:
            git(root, "fetch", "--no-tags", "--filter=blob:none", f"--deepen={DEEPEN_STEP}", "origin", BRANCH)
        except (subprocess.SubprocessError, OSError) as error:
            log(f"cannot deepen the checkout for {good[:12]}..{bad[:12]}: {error}")
            return None
    out = git(root, "log", "--first-parent", "--reverse", "--format=%H%x09%s", f"{good}..{bad}")
    return [tuple(line.split("\t", 1)) if "\t" in line else (line, "") for line in out.splitlines() if line]


# ---------- counts ----------

def flatten(value, prefix=""):
    """{"a": {"b": 3}, "_doc": ".."} -> {"a/b": 3}: integer leaves only; keys starting with '_' are metadata."""
    rows = {}
    if isinstance(value, dict):
        for key, sub in value.items():
            if not isinstance(key, str) or key.startswith("_"):
                continue
            rows.update(flatten(sub, f"{prefix}/{key}" if prefix else key))
    elif isinstance(value, int) and not isinstance(value, bool):
        rows[prefix] = value
    return rows


def ratchet_rows(data, count_rows):
    """The ratchet file's rows, keyed like count_rows: the file itself or one of its top-level objects (a file
    that wraps the counts in e.g. {"counts": {...}}), whichever shares the most row names with the counts."""
    candidates = [flatten(data)] + [flatten(v) for k, v in (data.items() if isinstance(data, dict) else [])
                                    if isinstance(v, dict) and not str(k).startswith("_")]
    return max(candidates, key=lambda rows: (len(rows.keys() & count_rows.keys()), len(rows)))


def last_json_object(text):
    for line in reversed((text or "").splitlines()):
        line = line.strip()
        if line.startswith("{"):
            try:
                value = json.loads(line)
            except ValueError:
                continue
            if isinstance(value, dict):
                return value
    try:
        value = json.loads(text)
        return value if isinstance(value, dict) else None
    except (TypeError, ValueError):
        return None


def counts_in(tree):
    """The full counts of the exported tree (a dict) via its own arch_counts.py."""
    script = os.path.join(tree, COUNTS_SCRIPT)
    if not os.path.exists(script):
        raise RuntimeError(f"{COUNTS_SCRIPT} is not in the commit (the ratchet-file slice has not landed there)")
    spec = importlib.util.spec_from_file_location("arch_counts_at_sha", script)
    mod = importlib.util.module_from_spec(spec)
    sys.path.insert(0, os.path.dirname(script))
    try:
        spec.loader.exec_module(mod)
        for name in COUNT_FUNCTIONS:
            fn = getattr(mod, name, None)
            if not callable(fn):
                continue
            try:
                takes_root = bool(inspect.signature(fn).parameters)
            except (TypeError, ValueError):
                takes_root = True
            value = fn(Path(tree)) if takes_root else fn()
            if isinstance(value, dict):
                return value
    finally:
        sys.path.remove(os.path.dirname(script))
    proc = subprocess.run([sys.executable, "-I", script, "--json"], cwd=tree, capture_output=True, text=True,
                          timeout=120)
    value = last_json_object(proc.stdout)
    if proc.returncode != 0 or value is None:
        raise RuntimeError(f"{COUNTS_SCRIPT} --json gave no counts (exit {proc.returncode}): "
                           f"{(proc.stderr or proc.stdout).strip()[-300:]}")
    return value


def package_names(tree):
    try:
        with open(os.path.join(tree, LAYERS_PATH)) as f:
            return set((json.load(f).get("targets") or {}).keys())
    except (OSError, ValueError, AttributeError):
        return set()


def package_of(row, packages):
    """The package a row names: a path part that is a CmuxNext target, else '-' (a whole-tree row)."""
    parts = row.split("/")
    for part in parts:
        if part in packages:
            return part
    for part in reversed(parts[1:]):
        if part.startswith(("Cmux", "CCmux")):
            return part
    return "-"


def measure(root, sha):
    """(rows, packages, ratchet rows or None) at sha."""
    with tempfile.TemporaryDirectory(prefix="arch-report-") as tree:
        export_tree(root, sha, tree)
        rows = flatten(counts_in(tree))
        packages = package_names(tree)
    raw = file_at(root, sha, RATCHET_PATH)
    ratchet = None
    if raw is not None:
        try:
            ratchet = ratchet_rows(json.loads(raw), rows)
        except ValueError as error:
            log(f"{RATCHET_PATH} at {sha[:12]} is not JSON ({error}): trend only, no regression check")
    return rows, packages, ratchet


# ---------- state ----------

def load_state(path):
    """(state, writable). A missing file starts empty; an unreadable one is never overwritten (it is the perf
    cron's state)."""
    try:
        with open(path) as f:
            state = json.load(f)
    except FileNotFoundError:
        return {}, True
    except (OSError, ValueError) as error:
        log(f"cannot read the state {path} ({error}): the history is not stored this run")
        return {}, False
    if not isinstance(state, dict):
        log(f"the state {path} is not a JSON object: the history is not stored this run")
        return {}, False
    return state, True


def history_of(state):
    hist = state.get(STATE_KEY)
    return [p for p in hist if isinstance(p, dict) and isinstance(p.get("sha"), str)
            and isinstance(p.get("rows"), dict)] if isinstance(hist, list) else []


def add_point(history, sha, rows, at):
    """The history with this point last (a point for the same sha replaces it), capped at HISTORY_POINTS."""
    hist = [p for p in history if p["sha"] != sha] + [{"sha": sha, "at": at, "rows": dict(rows)}]
    return hist[-HISTORY_POINTS:]


def save_state(path, state):
    tmp = f"{path}.arch-tmp"
    with open(tmp, "w") as f:
        json.dump(state, f, indent=1)
    os.replace(tmp, path)


# ---------- the trend and the regressions ----------

def arrow(prev, now):
    if prev is None:
        return "new"
    return "↑" if now > prev else "↓" if now < prev else "="


def trend_table(history, ratchet):
    """The table's lines. history ends with the point for now. Rows that are 0 everywhere are left out."""
    now = history[-1]["rows"]
    before = history[:-1]
    names = sorted(now, key=lambda n: (n.count("/"), n))
    lines = ["| row | ratchet | last values | now | |", "|---|---:|---|---:|---|"]
    shown = 0
    for name in names:
        past = [p["rows"].get(name) for p in before[-TREND_VALUES:]]
        limit = (ratchet or {}).get(name)
        if not now[name] and not limit and not any(past):
            continue
        prev = next((v for v in reversed(past) if v is not None), None)
        over = limit is not None and now[name] > limit
        values = " ".join("-" if v is None else str(v) for v in past) or "-"
        mark = arrow(prev, now[name]) + (" OVER" if over else "")
        lines.append(f"| {name} | {'-' if limit is None else limit} | {values} | {now[name]} | {mark} |")
        shown += 1
    if not shown:
        lines.append("| (every row is 0) | | | | |")
    return lines


def over_rows(history, ratchet, packages):
    """One entry per row over its ratchet value now: the first sha of the current run of points over the ratchet
    (where the row was first seen higher) and the last point at or under it before that run (None when the history
    does not reach one)."""
    out = []
    now = history[-1]["rows"]
    for name in sorted(now):
        limit = ratchet.get(name)
        if limit is None or now[name] <= limit:
            continue
        first, good = history[-1], None
        for point in reversed(history[:-1]):
            value = point["rows"].get(name)
            if value is not None and value > limit:
                first = point
                continue
            good = point if value is not None else None  # a point without the row is no known good value
            break
        out.append({"row": name, "package": package_of(name, packages), "ratchet": limit, "now": now[name],
                    "first_sha": first["sha"], "first_at": first.get("at"), "first_value": first["rows"][name],
                    "good_sha": good["sha"] if good else None,
                    "good_value": good["rows"].get(name) if good else None})
    return out


def issue_body(regs, sha, ratchet_note, ranges, run_url, repo):
    def link(s):
        return f"[`{s[:12]}`](https://github.com/{repo}/commit/{s})" if repo else f"`{s[:12]}`"
    lines = [ISSUE_MARK, "",
             f"An architecture count is over its ratchet value in `{RATCHET_PATH}` at {link(sha)}. A count only goes "
             "down: move the new code to the pattern the rule asks for (inject from the composition root, a seam "
             "adapter, a targeted observer, the domain package) or explain the rise in the ratchet file. Renaming a "
             "pattern to dodge the count is the same debt.", ""]
    if ratchet_note:
        lines += [ratchet_note, ""]
    lines += ["| row | package | ratchet | now | first seen higher | last at or under |", "|---|---|---:|---:|---|---|"]
    for r in regs:
        good = f"{link(r['good_sha'])} ({r['good_value']})" if r["good_sha"] else "before the kept history"
        lines.append(f"| {r['row']} | {r['package']} | {r['ratchet']} | {r['now']} | {link(r['first_sha'])} "
                     f"({r['first_value']}, {r.get('first_at') or '?'}) | {good} |")
    for key in sorted({(r["good_sha"], r["first_sha"]) for r in regs}, key=lambda k: [x or "" for x in k]):
        good, first = key
        rows = ", ".join(r["row"] for r in regs if (r["good_sha"], r["first_sha"]) == key)
        lines += ["", f"### Commits that can have raised {rows}", ""]
        commits = ranges.get(key)
        if good is None:
            lines.append(f"The kept history ({HISTORY_POINTS} points) has no value at or under the ratchet; the rise "
                         f"is at or before {link(first)}.")
        elif commits is None:
            lines.append(f"The range {good[:12]}..{first[:12]} could not be listed (see the run log).")
        else:
            lines.append(f"{len(commits)} commit(s) in {good[:12]}..{first[:12]} (first parent, oldest first):")
            lines.append("")
            for c, subject in commits[:RANGE_COMMITS_SHOWN]:
                lines.append(f"- {link(c)} {subject}")
            if len(commits) > RANGE_COMMITS_SHOWN:
                lines.append(f"- ... and {len(commits) - RANGE_COMMITS_SHOWN} more")
    if run_url:
        lines += ["", f"Last checked by [this run]({run_url})."]
    return "\n".join(lines) + "\n"


# ---------- GitHub ----------

def gh_request(path, method="GET", body=None, timeout=30):
    api = os.environ.get("GITHUB_API_URL", "https://api.github.com")
    url = path if path.startswith("http") else f"{api}{path}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers={
        "Authorization": f"Bearer {os.environ['GH_TOKEN']}", "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "cmux-perf-cron-arch"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        payload = r.read()
    return json.loads(payload) if payload else {}


def own_issue(issue):
    """This report's own issue: its title, opened by the workflow's bot, ISSUE_MARK in its body, not a pull
    request. A person's issue with the same title is never edited, commented on or closed."""
    return (isinstance(issue, dict) and issue.get("title") == ISSUE_TITLE and "pull_request" not in issue
            and (issue.get("user") or {}).get("login") == ISSUE_AUTHOR and ISSUE_MARK in (issue.get("body") or ""))


def find_issue(repo, number=None):
    if isinstance(number, int) and number > 0:
        try:
            issue = gh_request(f"/repos/{repo}/issues/{number}")
            if own_issue(issue):
                return issue
        except urllib.error.HTTPError:
            pass
    q = urllib.parse.quote(f'repo:{repo} is:issue in:title "{ISSUE_TITLE}" author:app/github-actions')
    items = gh_request(f"/search/issues?q={q}&sort=created&order=desc&per_page=10").get("items", [])
    items = [i for i in items if own_issue(i)]
    return items[0] if items else None


def keep_issue(repo, state, regs, body, summary, run_url, dry_run):
    """Open, update, reopen or close the one issue. Returns a line for the log."""
    issue = find_issue(repo, state.get(ISSUE_KEY))
    number = issue["number"] if issue else None
    is_open = bool(issue) and issue.get("state") == "open"
    suffix = f" ([run]({run_url}))." if run_url else "."
    if not regs:
        if not is_open:
            return "no issue needed"
        if dry_run:
            return f"would close issue #{number}"
        gh_request(f"/repos/{repo}/issues/{number}/comments", "POST",
                   {"body": f"Recovered: every architecture row is at or under its ratchet value. {summary}{suffix}"})
        gh_request(f"/repos/{repo}/issues/{number}", "PATCH", {"state": "closed", "state_reason": "completed"})
        return f"closed issue #{number}"
    if dry_run:
        return f"would {'open an issue' if not issue else ('update' if is_open else 'reopen') + f' issue #{number}'}"
    if not issue:
        created = gh_request(f"/repos/{repo}/issues", "POST", {"title": ISSUE_TITLE, "body": body})
        state[ISSUE_KEY] = created["number"]
        return f"opened issue #{created['number']}"
    state[ISSUE_KEY] = number
    gh_request(f"/repos/{repo}/issues/{number}", "PATCH", {"body": body, **({} if is_open else {"state": "open"})})
    if not is_open:
        gh_request(f"/repos/{repo}/issues/{number}/comments", "POST", {"body": f"Regressed again: {summary}{suffix}"})
    return f"{'updated' if is_open else 'reopened'} issue #{number}"


# ---------- main ----------

def run(o):
    started = time.monotonic()
    root = o.root
    sha = resolve_sha(root, o.sha)
    rows, packages, ratchet = measure(root, sha)
    ratchet_note = ""
    if ratchet is None:
        log(f"no {RATCHET_PATH} at {sha[:12]}: trend only, no regression check, the issue is left as it is")
    state, writable = load_state(o.state)
    history = add_point(history_of(state), sha, rows, now_iso())
    if ratchet is not None:
        missing = sorted(n for n in rows if n not in ratchet and rows[n])
        if missing:
            ratchet_note = (f"{len(missing)} nonzero row(s) have no ratchet value (not judged): "
                            + ", ".join(missing[:10]) + (" ..." if len(missing) > 10 else ""))
            log(ratchet_note)
    print(f"perf-cron-arch: architecture counts at {sha[:12]} ({len(rows)} rows, {len(history)} points kept)")
    for line in trend_table(history, ratchet):
        print(line)
    regs = over_rows(history, ratchet, packages) if ratchet is not None else []
    summary = (f"{sha[:12]}: {len(regs)} row(s) over the ratchet: " + ", ".join(f"{r['row']} {r['now']} > {r['ratchet']}"
               for r in regs[:8])) if regs else f"{sha[:12]}: every row at or under the ratchet"
    log(summary)
    if writable and not o.dry_run:
        state[STATE_KEY] = history
    if o.issue and ratchet is not None:
        repo = o.repo
        if not repo or (not o.dry_run and not os.environ.get("GH_TOKEN")):
            log("no repository or GH_TOKEN: the issue is not kept this run")
        else:
            ranges = {}
            for r in regs:
                key = (r["good_sha"], r["first_sha"])
                if r["good_sha"] and key not in ranges:
                    ranges[key] = range_commits(root, *key)
            body = issue_body(regs, sha, ratchet_note, ranges, o.run_url, repo)
            try:
                log(keep_issue(repo, state, regs, body, summary, o.run_url, o.dry_run))
            except (urllib.error.URLError, OSError, ValueError, KeyError) as error:
                log(f"cannot keep the issue: {error}")
    if writable and not o.dry_run:
        save_state(o.state, state)
    log(f"done in {time.monotonic() - started:.1f} s")


def default_run_url():
    server, repo, run_id = (os.environ.get(k) for k in ("GITHUB_SERVER_URL", "GITHUB_REPOSITORY", "GITHUB_RUN_ID"))
    return f"{server}/{repo}/actions/runs/{run_id}" if server and repo and run_id else ""


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--sha", required=True, help="the commit to count (the measured branch's tip)")
    ap.add_argument("--state", required=True, help=f"the perf cron's state JSON; this keeps `{STATE_KEY}` in it")
    ap.add_argument("--issue", action="store_true", help="open, update or close the regression issue")
    ap.add_argument("--dry-run", action="store_true", help="print only: no state write, no GitHub write")
    ap.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", ""), help="owner/name (GITHUB_REPOSITORY)")
    ap.add_argument("--run-url", default=default_run_url())
    ap.add_argument("--root", default=ROOT, help="the git checkout (default: this script's repository)")
    try:
        o = ap.parse_args(argv)
    except SystemExit as error:
        return 0 if error.code in (0, None) else (log("bad arguments; nothing done") or 0)
    try:
        run(o)
    except Exception as error:  # the job never fails on this report
        log(f"error, the report is skipped: {error!r}")
        traceback.print_exc(file=sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main())
