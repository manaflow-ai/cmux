#!/usr/bin/env python3
"""Architecture count trend and regression issue for the scheduled perf cron (Linux report step).

perf-cron.py's `report` subcommand calls run_report() in process when a measurement finishes (PL-perf-cron's file;
the hook is below). The command line does the same for one state file, for a manual run:

  perf-cron-arch-report.py --sha SHA --kind tip --state STATE_JSON [--issue] [--dry-run]

1. Counts every architecture row at SHA with that commit's own scripts/cmux-next/arch_counts.py, always in a
   subprocess (code of the measured commit never runs in this process, and its environment has no token). The
   contract, owned by the ratchet-file slice: arch_counts.py is one self-contained file (standard library imports
   only; it is the only script exported from the commit, and it runs under `python3 -I`), and
   `arch_counts.py --repo ROOT --rev SHA --json` prints one JSON object of the plans/cmux-next/arch-ratchet.json
   shape (`method` "arch_counts", `method_version`, `measured_sha`, `rows` {id: {title, ratchet}}, `totals`
   {id: n}, `packages` {package: {id: n}}). It reads the commit from git objects and parses Package.swift itself,
   so the report runner needs no swift and no working tree. Any other output is an error (nothing is kept, the
   issue is left as it is).
2. The report checkout is shallow (depth 1), sparse and blobless, and SHA need not be its HEAD: before counting,
   this fetches SHA's commit when it is missing (one fetch, depth 1, no blobs) and then every blob the count reads
   (PREFETCH_PATHS) in ONE fetch from the promisor remote, so git never fetches the blobs one by one. The promisor
   remote is the one with `remote.<name>.promisor` true (what a current git and actions/checkout's init + fetch
   --filter write), else `extensions.partialClone` (an older git).
   The 'is it there' probes use GIT_NO_LAZY_FETCH (git 2.44+); with an older git, nothing is probed in a
   partial clone and both fetches run unconditionally.
3. Reads plans/cmux-next/arch-ratchet.json at SHA (the ratchet: a ratcheted row's total only goes down). The limit
   of a row is the file's total; the cron does not apply `exceptions` allowances. A push that an exception entry
   let raise a row leaves the tip over the file's total until someone runs `arch-ratchet.py --update`: the issue
   lists the row's exception entries and says to run --update when one of them accepted the rise.
4. Keeps the last HISTORY_POINTS points under the state's key `arch_history` (the other keys are left as they
   are). Only a tip measurement (`kind` "tip") adds a point. A tip older than the last point (GitHub compare
   "behind") adds nothing and changes nothing; so does a run that cannot tell the order this time (no token, a
   network error). A tip that is neither (feat-cmux-next was rewritten: "diverged", or the last point's commit is
   gone) starts a new trend: the kept points that are not its ancestors are dropped, and the log and the issue
   body say so.
5. Prints one trend table: row, ratchet value, the last TREND_VALUES values, now, and an arrow.
6. With --issue: when a ratcheted row is over its ratchet value, opens or updates the one issue ISSUE_TITLE
   (ISSUE_MARK in its body, opened by the workflow's bot); it names each row, the packages that rose, the first
   sha where the row was seen higher and the commits in the range. It closes the issue only when EVERY ratcheted
   row was judged and is at or under the ratchet. A run that cannot judge every row (a ratcheted row missing from
   the counts, no row in common, a method version that differs from the ratchet file's, a ratchet file of another
   shape) names the rows it could not judge, puts them in an open issue's body and never closes it.

The whole report has one deadline (REPORT_SECONDS): every git subprocess, the count and every GitHub request get
the time that is left, and the report stops when it runs out. run_report() catches every error (also SystemExit
and the deadline; not KeyboardInterrupt), prints it and leaves the state as it was; the command line exits 0.
--dry-run prints the table and the issue action and writes nothing (no state, no GitHub). Tests:
scripts/cmux-next/tests/test_perf_cron_arch_report.py (GitHub faked, git real in temporary repositories, also a
shallow, sparse, blobless clone made both by git clone and the way actions/checkout makes it; run them yourself, no
CI job runs them).

Hook (PL-perf-cron's files; send to session cmux-b6 after this file and the ratchet-file slice, which adds
arch_counts.py and arch-ratchet.json, are on feat-cmux-next). Three edits, not one line:
- .github/workflows/cmux-next-perf-budgets.yml, job `report`, the checkout's sparse-checkout list: add
  `scripts/cmux-next/perf-cron-arch-report.py`.
- perf-cron.py: a helper next to load_budgets_module:
      def load_sibling(name):
          spec = importlib.util.spec_from_file_location(name.replace("-", "_")[:-3], os.path.join(HERE, name))
          mod = importlib.util.module_from_spec(spec)
          spec.loader.exec_module(mod)
          return mod
- perf-cron.py cmd_report: inside `if cur and not cur["parts_todo"] and (changed or o.finish):` (where `changed`
  is already set True), keep `finished = cur`; after the existing `json.dump(state, ...)` of state.json AND after
  write_outputs (so the perf state and outputs.changed=true are written before the report starts, and a kill
  during the report loses nothing of perf-cron's own work), add:
      if finished and load_sibling("perf-cron-arch-report.py").run_report(
              state, finished["sha"], finished["kind"], root=ROOT, repo=o.repo, run_url=o.run_url, issue=o.issues):
          json.dump(state, open(os.path.join(o.dir, "state.json"), "w"), indent=1)
  (`finished = None` before the `if`.) run_report changes only state["arch_history"] and state["arch_issue"],
  returns True only when it changed them, never raises, and ends within REPORT_SECONDS (well inside the job's
  `timeout-minutes: 10`), so the second dump stores the arch point and "Save the state" uploads it.
"""
import argparse, datetime, json, os, re, subprocess, sys, tempfile, time, traceback
import urllib.error, urllib.parse, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
RATCHET_PATH = "plans/cmux-next/arch-ratchet.json"
COUNTS_DIR = "scripts/cmux-next"
COUNTS_SCRIPT = f"{COUNTS_DIR}/arch_counts.py"
COUNTS_METHOD = "arch_counts"
# What the count reads at SHA (arch_counts.py: the CmuxNext sources, Package.swift, the layer map) plus what this
# script reads (the ratchet file, the count script). All their blobs are fetched in one go before the count.
# (path, suffix, recursive); suffix None: exactly this file.
PREFETCH_PATHS = (("Packages/macOS/CmuxNext/Sources", ".swift", True),
                  ("Packages/macOS/CmuxNext/Package.swift", None, False),
                  ("plans/cmux-next", ".json", False),
                  (COUNTS_SCRIPT, None, False))
STATE_KEY = "arch_history"
ISSUE_KEY = "arch_issue"
HISTORY_POINTS = 20
TREND_VALUES = 5
BRANCH = "feat-cmux-next"
TIP_KIND = "tip"
ISSUE_TITLE = "cmux-next architecture count regression"
ISSUE_MARK = "<!-- cmux-next-arch-ratchet -->"
# The issue is this report's own only when the bot opened it and its body carries ISSUE_MARK.
ISSUE_AUTHOR = "github-actions[bot]"
RANGE_COMMITS_SHOWN = 40
DEEPEN_STEP = 500
DEEPEN_ROUNDS = 4
# One deadline for the whole report: under a third of the report job's `timeout-minutes: 10`, so perf-cron's own
# steps keep the rest. A full run on the real tree (shallow, blobless checkout) took 11 s.
REPORT_SECONDS = 180
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
# The count runs code of the measured commit: it gets no credential of the job.
SECRET_ENV = re.compile(r"TOKEN|SECRET|PASSWORD|^ACTIONS_RUNTIME|^ACTIONS_ID_TOKEN|^ACTIONS_CACHE")


def log(msg):
    print(f"perf-cron-arch: {msg}", flush=True)


def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


class CountError(Exception):
    """The counts at SHA could not be taken or do not follow the arch_counts contract."""


class ReportTimeout(TimeoutError):
    """The report's deadline ran out (an OSError, like a timed-out request, so every step that already treats a
    failed request or fetch as 'not this run' does so here too)."""


class Deadline:
    """One deadline for the whole report. Every subprocess and request takes its timeout from left(), so the report
    as a whole ends by the deadline; left() raises ReportTimeout once it has passed."""

    def __init__(self, seconds, clock=time.monotonic):
        self.clock = clock
        self.end = clock() + seconds

    def left(self):
        remaining = self.end - self.clock()
        if remaining <= 0:
            raise ReportTimeout(f"the report's deadline ({REPORT_SECONDS} s by default) ran out")
        return remaining


# ---------- git ----------

def run(dl, args, **kw):
    """subprocess.run with the time left as its timeout (TimeoutExpired when the deadline passes during it)."""
    return subprocess.run(args, timeout=dl.left(), **kw)


def git(dl, root, *args, check=True, env=None):
    return run(dl, ["git", "-C", root, *args], capture_output=True, text=True, check=check, env=env).stdout.strip()


def no_lazy_env():
    """git that answers 'missing' for an object the clone does not have, instead of fetching it on its own."""
    return {**os.environ, "GIT_NO_LAZY_FETCH": "1"}


def probes_never_fetch(dl):
    """True when this git honors GIT_NO_LAZY_FETCH (2.44 and later). An older git fetches a missing object while
    it is only asked whether it has it (a missing commit: its whole history), so then nothing is probed in a
    partial clone: the fetches below run unconditionally (cheap when the objects are already there)."""
    found = re.search(r"(\d+)\.(\d+)", run(dl, ["git", "--version"], capture_output=True, text=True).stdout)
    return bool(found) and (int(found.group(1)), int(found.group(2))) >= (2, 44)


def can_probe(dl, root):
    return not promisor_remote(dl, root) or probes_never_fetch(dl)


def have_object(dl, root, spec):
    return run(dl, ["git", "-C", root, "cat-file", "-e", spec], capture_output=True, env=no_lazy_env()).returncode == 0


def is_shallow(dl, root):
    return git(dl, root, "rev-parse", "--is-shallow-repository", check=False) == "true"


def promisor_remote(dl, root):
    """The partial clone's promisor remote, or None. A current git, and the `git fetch --filter=blob:none` that
    actions/checkout runs in a fresh `git init`, mark it with `remote.<name>.promisor` true; an older git wrote
    `extensions.partialClone` instead."""
    marked = git(dl, root, "config", "--type=bool", "--get-regexp", r"^remote\..*\.promisor$", check=False)
    for line in marked.splitlines():
        key, _, value = line.partition(" ")
        if value == "true" and key.startswith("remote.") and key.endswith(".promisor"):
            return key[len("remote."):-len(".promisor")]
    return git(dl, root, "config", "--get", "extensions.partialClone", check=False) or None


def ensure_commit(dl, root, sha):
    """Fetch SHA's commit and trees (no blobs) when the clone lacks it: the report checkout has only its own HEAD."""
    if not SHA_RE.match(sha) or (can_probe(dl, root) and have_object(dl, root, f"{sha}^{{commit}}")):
        return
    promisor = promisor_remote(dl, root)
    args = ["fetch", "--no-tags", "--no-write-fetch-head"]
    if is_shallow(dl, root):
        args.append("--depth=1")
    if promisor:
        args.append("--filter=blob:none")
    log(f"fetching {sha[:12]} (not in the checkout)")
    git(dl, root, *args, promisor or "origin", sha)


def resolve_sha(dl, root, sha):
    full = git(dl, root, "rev-parse", "--verify", "--end-of-options", f"{sha}^{{commit}}", env=no_lazy_env())
    if not SHA_RE.match(full):
        raise ValueError(f"{sha!r} is not a commit")
    return full


def wanted(path):
    for prefix, suffix, recursive in PREFETCH_PATHS:
        if suffix is None:
            if path == prefix:
                return True
            continue
        rest = path[len(prefix) + 1:] if path.startswith(prefix + "/") else None
        if rest and rest.endswith(suffix) and (recursive or "/" not in rest):
            return True
    return False


def list_blobs(dl, root, sha):
    """[(oid, path)] of the PREFETCH_PATHS blobs at sha (trees only: no blob is read)."""
    listing = run(dl, ["git", "-C", root, "ls-tree", "-r", "-z", sha, "--", *(p for p, _, _ in PREFETCH_PATHS)],
                  capture_output=True, check=True, env=no_lazy_env()).stdout
    files = []
    for entry in listing.split(b"\0"):
        if not entry:
            continue
        meta, _, path = entry.partition(b"\t")
        mode, kind, oid = meta.split()
        name = path.decode(errors="surrogateescape")
        if kind == b"blob" and mode != b"120000" and wanted(name):
            files.append((oid.decode(), name))
    return files


def prefetch_blobs(dl, root, files):
    """In a partial clone, fetch every listed blob in ONE fetch (the command git itself runs for a lazy fetch, with
    all the oids at once). Without this, each blob the count reads is a fetch of its own: thousands of round trips.
    Returns the number of oids asked for (0: not a partial clone, nothing to do)."""
    remote = promisor_remote(dl, root)
    if not remote or not files:
        return 0
    oids = sorted({oid for oid, _ in files})
    if probes_never_fetch(dl):
        check = run(dl, ["git", "-C", root, "cat-file", "--batch-check=%(objectname) %(objecttype)"],
                    input="".join(f"{oid}\n" for oid in oids), capture_output=True, text=True, check=True,
                    env=no_lazy_env()).stdout
        oids = sorted({line.split()[0] for line in check.splitlines() if line.endswith(" missing")})
    if not oids:
        return 0
    started = time.monotonic()
    run(dl, ["git", "-C", root, "-c", "fetch.negotiationAlgorithm=noop", "fetch", remote, "--no-tags",
             "--no-write-fetch-head", "--recurse-submodules=no", "--filter=blob:none", "--stdin"],
        input="".join(f"{oid}\n" for oid in oids), capture_output=True, text=True, check=True)
    log(f"fetched {len(oids)} blob(s) in one fetch, {time.monotonic() - started:.1f} s")
    return len(oids)


def export_file(dl, root, oid, name, dest):
    """Write one blob into dest/name."""
    blob = run(dl, ["git", "-C", root, "cat-file", "blob", oid], capture_output=True, check=True).stdout
    target = os.path.join(dest, name)
    os.makedirs(os.path.dirname(target), exist_ok=True)
    with open(target, "wb") as f:
        f.write(blob)


def file_at(dl, root, sha, path):
    """The text of path at sha, or None when the commit has no such file."""
    proc = run(dl, ["git", "-C", root, "show", f"{sha}:{path}"], capture_output=True, text=True)
    return proc.stdout if proc.returncode == 0 else None


def ancestor_code(dl, root, old, new):
    """git merge-base --is-ancestor old new: 0 yes, 1 no, other: cannot tell (an object is missing)."""
    return run(dl, ["git", "-C", root, "merge-base", "--is-ancestor", "--end-of-options", old, new],
               capture_output=True, env=no_lazy_env()).returncode


def is_ancestor(dl, root, good, bad):
    """True: good is an ancestor of bad. False: not known in this (shallow) clone yet. None: complete and not."""
    if ancestor_code(dl, root, good, bad) == 0:
        return True
    return False if is_shallow(dl, root) else None


def range_commits(dl, root, good, bad):
    """[(sha, subject)] of the first-parent commits in good..bad (bad included), oldest first, or None (printed)
    when the range cannot be listed. The report's checkout is shallow: it is deepened first when needed."""
    try:
        for rounds in range(DEEPEN_ROUNDS + 1):
            have = is_ancestor(dl, root, good, bad)
            if have:
                break
            if have is None or rounds == DEEPEN_ROUNDS:
                log(f"cannot list {good[:12]}..{bad[:12]}: {good[:12]} is not a known ancestor of {bad[:12]}")
                return None
            git(dl, root, "fetch", "--no-tags", "--filter=blob:none", f"--deepen={DEEPEN_STEP}", "origin", BRANCH)
        out = git(dl, root, "log", "--first-parent", "--reverse", "--format=%H%x09%s", f"{good}..{bad}")
    except (subprocess.SubprocessError, OSError) as error:
        log(f"cannot list {good[:12]}..{bad[:12]}: {error}")
        return None
    return [tuple(line.split("\t", 1)) if "\t" in line else (line, "") for line in out.splitlines() if line]


AHEAD, BEHIND, DIVERGED, GONE = "ahead", "behind", "diverged", "gone"


def order(dl, root, repo, old, new):
    """How the tip new stands to the kept point old: AHEAD (new is old or descends from it), BEHIND (new is an
    ancestor of old: an older commit), DIVERGED (neither: the branch was rewritten), GONE (old no longer exists)
    or None (cannot tell this run). A complete clone that has old answers with git; otherwise (a shallow clone
    cannot say 'not', and lacks old) it asks the GitHub compare API."""
    if old == new:
        return AHEAD
    if not is_shallow(dl, root) and can_probe(dl, root) and have_object(dl, root, f"{old}^{{commit}}"):
        if ancestor_code(dl, root, old, new) == 0:
            return AHEAD
        return BEHIND if ancestor_code(dl, root, new, old) == 0 else DIVERGED
    if not repo or not os.environ.get("GH_TOKEN"):
        log(f"cannot order {new[:12]} against {old[:12]}: no repository or GH_TOKEN for the GitHub compare API")
        return None
    try:
        status = gh_request(f"/repos/{repo}/compare/{old}...{new}", timeout=dl.left()).get("status")
    except urllib.error.HTTPError as error:
        if error.code != 404:
            log(f"cannot compare {old[:12]}...{new[:12]} on GitHub: {error}")
            return None
        # 404: one side is unknown. new is the tip just measured, so when GitHub has it, old is the one gone.
        try:
            gh_request(f"/repos/{repo}/commits/{new}", timeout=dl.left())
        except (urllib.error.URLError, OSError, ValueError, KeyError) as again:
            log(f"cannot compare {old[:12]}...{new[:12]} on GitHub ({error}), and {new[:12]} is not found: {again}")
            return None
        return GONE
    except (urllib.error.URLError, OSError, ValueError, KeyError) as error:
        log(f"cannot compare {old[:12]}...{new[:12]} on GitHub: {error}")
        return None
    return {"ahead": AHEAD, "identical": AHEAD, "behind": BEHIND, "diverged": DIVERGED}.get(status)


def trend_base(dl, root, repo, history, sha):
    """(the kept points the point for sha extends, a note when the trend restarts), or (None, None): sha adds no
    point this run (older than the last point, or the order cannot be told now). When feat-cmux-next was
    rewritten (the last point DIVERGED from sha or is GONE), the trend restarts at the newest kept point that is
    an ancestor of sha: the points after it are dropped. The kept points are a tip-ordered chain (each one
    descends from the one before), so every point before that one is an ancestor of sha too."""
    if not history or history[-1]["sha"] == sha:
        return history, None
    last = history[-1]["sha"]
    first = order(dl, root, repo, last, sha)
    if first == AHEAD:
        return history, None
    if first == BEHIND:
        log(f"{sha[:12]} is older than the last point {last[:12]}: no point, the issue is left as it is")
        return None, None
    if first is None:
        log(f"the order of {sha[:12]} against the last point {last[:12]} is not known this run: no point, the "
            "issue is left as it is")
        return None, None
    keep = 0
    for i in range(len(history) - 2, -1, -1):
        rel = order(dl, root, repo, history[i]["sha"], sha)
        if rel is None:
            log(f"the order of {sha[:12]} against the kept point {history[i]['sha'][:12]} is not known this run: "
                "no point, the issue is left as it is")
            return None, None
        if rel == AHEAD:
            keep = i + 1
            break
    dropped = history[keep:]
    why = "is gone" if first == GONE else "is not an ancestor of it"
    note = (f"the trend restarts at {sha[:12]} (feat-cmux-next was rewritten): the last point {last[:12]} {why}, so "
            f"{len(dropped)} point(s) from {dropped[0]['sha'][:12]} on are dropped and {keep} kept")
    log(note)
    return history[:keep], note


# ---------- the counts contract ----------

def is_count(value):
    return isinstance(value, int) and not isinstance(value, bool) and value >= 0


def checked_record(value, what):
    """The arch_counts record (the arch-ratchet.json shape) reduced to what this report uses, or CountError naming
    the first thing that does not follow the contract."""
    def bad(why):
        raise CountError(f"{what} does not follow the {COUNTS_METHOD} contract: {why}")
    if not isinstance(value, dict):
        bad("not a JSON object")
    if value.get("method") != COUNTS_METHOD:
        bad(f"method is {value.get('method')!r}, not {COUNTS_METHOD!r}")
    version = value.get("method_version")
    if not is_count(version):
        bad(f"method_version is {version!r}")
    rows, totals, packages = value.get("rows"), value.get("totals"), value.get("packages")
    if not isinstance(rows, dict) or not rows:
        bad("no rows object")
    ratcheted = set()
    for name, meta in rows.items():
        if not isinstance(meta, dict) or not isinstance(meta.get("ratchet"), bool):
            bad(f"row {name!r} has no boolean ratchet")
        if meta["ratchet"]:
            ratcheted.add(name)
    if not isinstance(totals, dict) or not all(isinstance(k, str) and is_count(v) for k, v in totals.items()):
        bad("totals is not {row: count}")
    if not isinstance(packages, dict) or not all(
            isinstance(p, dict) and all(isinstance(k, str) and is_count(v) for k, v in p.items())
            for p in packages.values()):
        bad("packages is not {package: {row: count}}")
    return {"method_version": version, "rows": set(rows), "ratcheted": ratcheted, "totals": dict(totals),
            "packages": {pkg: dict(p) for pkg, p in packages.items()}, "measured_sha": value.get("measured_sha"),
            "exceptions": [e for e in value.get("exceptions") or [] if isinstance(e, dict)]}


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
    return None


def count_env():
    return {k: v for k, v in os.environ.items() if not SECRET_ENV.search(k)}


def counts_at(dl, root, sha):
    """The checked counts record at sha, from sha's own arch_counts.py run in a subprocess."""
    files = list_blobs(dl, root, sha)
    prefetch_blobs(dl, root, files)
    script = next((oid for oid, name in files if name == COUNTS_SCRIPT), None)
    if script is None:
        raise CountError(f"{COUNTS_SCRIPT} is not in the commit (the ratchet-file slice has not landed there)")
    with tempfile.TemporaryDirectory(prefix="arch-report-") as tree:
        export_file(dl, root, script, COUNTS_SCRIPT, tree)
        # -I: the contract makes arch_counts.py self-contained (standard library only), so neither its directory
        # nor PYTHON* nor the user site is on the path.
        try:
            proc = run(dl, [sys.executable, "-I", os.path.join(tree, COUNTS_SCRIPT), "--repo", root, "--rev", sha,
                            "--json"], cwd=tree, capture_output=True, text=True, env=count_env())
        except subprocess.TimeoutExpired as error:
            raise CountError(f"{COUNTS_SCRIPT} at {sha[:12]} ran past the report's deadline ({error.timeout:.0f} s "
                             "left when it started)") from None
    value = last_json_object(proc.stdout)
    if proc.returncode != 0 or value is None:
        raise CountError(f"{COUNTS_SCRIPT} --json at {sha[:12]} gave no counts (exit {proc.returncode}): "
                         f"{(proc.stderr or proc.stdout).strip()[-300:]}")
    record = checked_record(value, f"{COUNTS_SCRIPT} --json at {sha[:12]}")
    if record["measured_sha"] != sha:
        raise CountError(f"{COUNTS_SCRIPT} counted {record['measured_sha']!r}, not {sha}")
    return record


def ratchet_at(dl, root, sha):
    """(record, None), (None, why it cannot judge) or (None, None) when the commit has no ratchet file."""
    raw = file_at(dl, root, sha, RATCHET_PATH)
    if raw is None:
        return None, None
    try:
        return checked_record(json.loads(raw), f"{RATCHET_PATH} at {sha[:12]}"), None
    except ValueError as error:
        return None, f"{RATCHET_PATH} at {sha[:12]} is not JSON ({error})"
    except CountError as error:
        return None, str(error)


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
    return [p for p in hist if isinstance(p, dict) and isinstance(p.get("sha"), str) and isinstance(p.get("totals"), dict)
            and is_count(p.get("method_version"))] if isinstance(hist, list) else []


def add_point(history, sha, record, at):
    """The history with this point last (a point for the same sha replaces it), capped at HISTORY_POINTS."""
    point = {"sha": sha, "at": at, "method_version": record["method_version"], "totals": dict(record["totals"]),
             "packages": {k: dict(v) for k, v in record["packages"].items()}}
    return ([p for p in history if p["sha"] != sha] + [point])[-HISTORY_POINTS:]


def save_state(path, state):
    tmp = f"{path}.arch-tmp"
    with open(tmp, "w") as f:
        json.dump(state, f, indent=1)
    os.replace(tmp, path)


# ---------- the judgement, the trend and the regressions ----------

def judgement(counts, ratchet, ratchet_problem):
    """{'limits': {row: ratchet total} of the rows judged this run, 'unjudged': [why, ...]}. Every ratcheted row
    of the ratchet file that this run cannot compare is named, so a renamed or dropped row never leaves the
    judgement silently, and the issue is never closed on such a run."""
    if ratchet is None:
        return {"limits": {}, "unjudged": [ratchet_problem] if ratchet_problem else []}
    unjudged = []
    if ratchet["method_version"] != counts["method_version"]:
        return {"limits": {}, "unjudged": [
            f"the counts are method v{counts['method_version']}, the ratchet file v{ratchet['method_version']}: "
            "no row is compared until the ratchet file is rewritten with the same method"]}
    if not ratchet["ratcheted"]:
        unjudged.append(f"{RATCHET_PATH} ratchets no row")
    no_total = sorted(n for n in ratchet["ratcheted"] if n not in ratchet["totals"])
    if no_total:
        unjudged.append(f"ratcheted row(s) with no total in {RATCHET_PATH}: " + ", ".join(no_total))
    missing = sorted(n for n in ratchet["ratcheted"] if n in ratchet["totals"] and n not in counts["totals"])
    if missing:
        unjudged.append(f"ratcheted row(s) missing from the counts (renamed or dropped?): " + ", ".join(missing))
    limits = {n: ratchet["totals"][n] for n in ratchet["ratcheted"] if n in ratchet["totals"] and n in counts["totals"]}
    if not limits and ratchet["ratcheted"]:
        unjudged.append("no ratcheted row of the ratchet file is in the counts")
    return {"limits": limits, "unjudged": unjudged}


def arrow(prev, now):
    if prev is None:
        return "new"
    return "↑" if now > prev else "↓" if now < prev else "="


def comparable(history):
    """The points before now that were counted with now's method (another method's numbers are not a trend)."""
    version = history[-1]["method_version"]
    return [p for p in history[:-1] if p["method_version"] == version]


def trend_table(history, limits, ratchet):
    """The table's lines. history ends with the point for now. Rows that are 0 everywhere are left out."""
    now = history[-1]["totals"]
    before = comparable(history)
    names = sorted(set(now) | set(limits) | (ratchet["ratcheted"] if ratchet else set()))
    lines = ["| row | ratchet | last values | now | |", "|---|---:|---|---:|---|"]
    shown = 0
    for name in names:
        past = [p["totals"].get(name) for p in before[-TREND_VALUES:]]
        limit = limits.get(name)
        value = now.get(name)
        if not value and not limit and not any(past) and value is not None:
            continue
        values = " ".join("-" if v is None else str(v) for v in past) or "-"
        if value is None:
            mark, value = "not counted", "-"
        else:
            prev = next((v for v in reversed(past) if v is not None), None)
            mark = arrow(prev, value) + (" OVER" if limit is not None and value > limit else "")
        lines.append(f"| {name} | {'-' if limit is None else limit} | {values} | {value} | {mark} |")
        shown += 1
    if not shown:
        lines.append("| (every row is 0) | | | | |")
    return lines


def over_rows(history, limits, ratchet):
    """One entry per judged row over its ratchet value now: the packages that rose over the ratchet file's package
    counts, the first sha of the current run of points over the ratchet (where the row was first seen higher) and
    the last point at or under it before that run (None when the history does not reach one)."""
    out = []
    point = history[-1]
    before = comparable(history)
    for name in sorted(limits):
        limit, value = limits[name], point["totals"][name]
        if value <= limit:
            continue
        first, good = point, None
        for p in reversed(before):
            v = p["totals"].get(name)
            if v is not None and v > limit:
                first = p
                continue
            good = p if v is not None else None  # a point without the row is no known good value
            break
        rose = sorted((pkg, ratchet["packages"].get(pkg, {}).get(name, 0), counts.get(name, 0))
                      for pkg, counts in point["packages"].items()
                      if counts.get(name, 0) > ratchet["packages"].get(pkg, {}).get(name, 0))
        out.append({"row": name, "packages": ", ".join(f"{pkg} {a}→{b}" for pkg, a, b in rose) or "-",
                    "ratchet": limit, "now": value, "first_sha": first["sha"], "first_at": first.get("at"),
                    "first_value": first["totals"][name], "good_sha": good["sha"] if good else None,
                    "good_value": good["totals"].get(name) if good else None,
                    "exceptions": [e for e in ratchet["exceptions"] if e.get("row") == name]})
    return out


def issue_body(regs, sha, notes, ranges, run_url, repo, trend_note=None):
    def link(s):
        return f"[`{s[:12]}`](https://github.com/{repo}/commit/{s})" if repo else f"`{s[:12]}`"
    lines = [ISSUE_MARK, ""]
    if regs:
        lines += [f"An architecture count is over its ratchet value in `{RATCHET_PATH}` at {link(sha)}. The limit is "
                  "the file's total: this report does not apply `exceptions` allowances. A count only goes down: move "
                  "the new code to the pattern the rule asks for (inject from the composition root, a seam adapter, a "
                  "targeted observer, the domain package). Renaming a pattern to dodge the count is the same debt. "
                  "When a dated `exceptions` entry accepted the rise (a row's entries are listed below), run "
                  "`scripts/cmux-next/arch-ratchet.py --update` so the file records the new total; the issue closes "
                  "on the first tip after that lands.", ""]
    else:
        lines += [f"No judged row is over its ratchet value at {link(sha)}, but the run could not judge every row, so "
                  "this issue stays open until a run judges them all.", ""]
    if trend_note:
        lines += [f"Trend: {trend_note}.", ""]
    for note in notes:
        lines += [f"Not judged: {note}", ""]
    if regs:
        lines += ["| row | packages that rose | ratchet | now | first seen higher | last at or under |",
                  "|---|---|---:|---:|---|---|"]
    for r in regs:
        good = f"{link(r['good_sha'])} ({r['good_value']})" if r["good_sha"] else "before the kept history"
        lines.append(f"| {r['row']} | {r['packages']} | {r['ratchet']} | {r['now']} | {link(r['first_sha'])} "
                     f"({r['first_value']}, {r.get('first_at') or '?'}) | {good} |")
    for r in regs:
        if not r["exceptions"]:
            continue
        entries = "; ".join(json.dumps(e, sort_keys=True) for e in r["exceptions"])
        allowed = sum(e["allow"] for e in r["exceptions"] if is_count(e.get("allow")))
        rise = r["now"] - r["ratchet"]
        if allowed >= rise:
            lines.append(f"\n`{r['row']}`: the rise (+{rise}) is within its exception entries (+{allowed}): {entries}. "
                         "If they accepted it, run `scripts/cmux-next/arch-ratchet.py --update` to record it.")
        else:
            lines.append(f"\n`{r['row']}`: its exception entries allow +{allowed}, less than the rise (+{rise}): "
                         f"{entries}. The rest needs the fix (or a new dated entry).")
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


def find_issue(gh, repo, number=None):
    if isinstance(number, int) and number > 0:
        try:
            issue = gh(f"/repos/{repo}/issues/{number}")
            if own_issue(issue):
                return issue
        except urllib.error.HTTPError:
            pass
    q = urllib.parse.quote(f'repo:{repo} is:issue in:title "{ISSUE_TITLE}" author:app/github-actions')
    items = gh(f"/search/issues?q={q}&sort=created&order=desc&per_page=10").get("items", [])
    items = [i for i in items if own_issue(i)]
    return items[0] if items else None


def keep_issue(dl, repo, state, regs, all_judged, body, summary, run_url, dry_run):
    """Open, update, reopen or close the one issue (state[ISSUE_KEY] holds its number). Returns a line for the log.
    It closes only when every ratcheted row was judged and none is over. Every request gets the time left."""
    def gh(path, method="GET", body=None):
        return gh_request(path, method, body, timeout=dl.left())
    issue = find_issue(gh, repo, state.get(ISSUE_KEY))
    number = issue["number"] if issue else None
    is_open = bool(issue) and issue.get("state") == "open"
    suffix = f" ([run]({run_url}))." if run_url else "."
    if not regs and not all_judged:
        if not is_open:
            return "cannot judge every row; no open issue to note it in"
        if dry_run:
            return f"would leave issue #{number} open and note the rows not judged"
        state[ISSUE_KEY] = number
        gh(f"/repos/{repo}/issues/{number}", "PATCH", {"body": body})
        return f"left issue #{number} open: not every row could be judged"
    if not regs:
        if not is_open:
            return "no issue needed"
        if dry_run:
            return f"would close issue #{number}"
        gh(f"/repos/{repo}/issues/{number}/comments", "POST",
                   {"body": f"Recovered: every architecture row is at or under its ratchet value. {summary}{suffix}"})
        gh(f"/repos/{repo}/issues/{number}", "PATCH", {"state": "closed", "state_reason": "completed"})
        return f"closed issue #{number}"
    if dry_run:
        return f"would {'open an issue' if not issue else ('update' if is_open else 'reopen') + f' issue #{number}'}"
    if not issue:
        created = gh(f"/repos/{repo}/issues", "POST", {"title": ISSUE_TITLE, "body": body})
        state[ISSUE_KEY] = created["number"]
        return f"opened issue #{created['number']}"
    state[ISSUE_KEY] = number
    gh(f"/repos/{repo}/issues/{number}", "PATCH", {"body": body, **({} if is_open else {"state": "open"})})
    if not is_open:
        gh(f"/repos/{repo}/issues/{number}/comments", "POST", {"body": f"Regressed again: {summary}{suffix}"})
    return f"{'updated' if is_open else 'reopened'} issue #{number}"


# ---------- the report ----------

def _report(dl, state, sha, kind, root, repo, run_url, issue, dry_run):
    """The report on a copy of the two keys it owns: ({STATE_KEY: ..., ISSUE_KEY: ...} to store, or None)."""
    started = time.monotonic()
    if kind != TIP_KIND:
        log(f"{kind} measurement of {str(sha)[:12]}: not a tip, no architecture point (the trend follows the tip)")
        return None
    ensure_commit(dl, root, sha)
    sha = resolve_sha(dl, root, sha)
    history, trend_note = trend_base(dl, root, repo, history_of(state), sha)
    if history is None:
        return None
    counts = counts_at(dl, root, sha)
    ratchet, ratchet_problem = ratchet_at(dl, root, sha)
    if ratchet is None and ratchet_problem is None:
        log(f"no {RATCHET_PATH} at {sha[:12]}: trend only, no regression check, the issue is left as it is")
    judged = judgement(counts, ratchet, ratchet_problem)
    limits, notes = judged["limits"], list(judged["unjudged"])
    for note in notes:
        log(f"not judged: {note}")
    if ratchet is not None:
        extra = sorted(n for n, v in counts["totals"].items() if v and n not in ratchet["rows"])
        if extra:
            log(f"{len(extra)} nonzero counted row(s) the ratchet file does not know (trend only): " + ", ".join(extra))
    history = add_point(history, sha, counts, now_iso())
    print(f"perf-cron-arch: architecture counts at {sha[:12]} ({len(counts['totals'])} rows, {len(history)} points kept)")
    for line in trend_table(history, limits, ratchet):
        print(line)
    regs = over_rows(history, limits, ratchet) if limits else []
    all_judged = ratchet is not None and not notes
    summary = (f"{sha[:12]}: {len(regs)} row(s) over the ratchet: " + ", ".join(f"{r['row']} {r['now']} > {r['ratchet']}"
               for r in regs[:8])) if regs else (f"{sha[:12]}: every row at or under the ratchet" if all_judged else
                                                 f"{sha[:12]}: no judged row over the ratchet; {len(notes)} problem(s) "
                                                 "kept it from judging every row")
    log(summary)
    owned = {ISSUE_KEY: state.get(ISSUE_KEY)}
    if issue and (ratchet is not None or ratchet_problem):
        if not repo or (not dry_run and not os.environ.get("GH_TOKEN")):
            log("no repository or GH_TOKEN: the issue is not kept this run")
        else:
            ranges = {}
            for r in regs:
                key = (r["good_sha"], r["first_sha"])
                if r["good_sha"] and key not in ranges:
                    ranges[key] = range_commits(dl, root, *key)
            body = issue_body(regs, sha, notes, ranges, run_url, repo, trend_note)
            try:
                log(keep_issue(dl, repo, owned, regs, all_judged, body, summary, run_url, dry_run))
            except (urllib.error.URLError, OSError, ValueError, KeyError) as error:
                # A ReportTimeout is an OSError too: the point is kept, the issue is kept by the next run.
                log(f"cannot keep the issue: {error}")
    log(f"done in {time.monotonic() - started:.1f} s")
    return {STATE_KEY: history, ISSUE_KEY: owned[ISSUE_KEY]}


def run_report(state, sha, kind, *, root=ROOT, repo="", run_url="", issue=False, dry_run=False, deadline=None):
    """Count the architecture rows at sha and keep the trend and the issue in state (perf-cron's state dict).

    Changes only state[STATE_KEY] and state[ISSUE_KEY], and only when the whole report ran (not with dry_run).
    Returns True when it changed them. Ends by deadline (a Deadline; default REPORT_SECONDS from now). Never raises
    (also not for a SystemExit from the measured commit's code, or the deadline), except KeyboardInterrupt: an
    error is printed and the state is left as it was."""
    try:
        dl = deadline or Deadline(REPORT_SECONDS)
        owned = _report(dl, state, sha, kind, root, repo, run_url, issue, dry_run)
    except KeyboardInterrupt:
        raise
    except BaseException as error:  # the perf cron's job never fails on this report
        log(f"error, the report is skipped: {error!r}")
        traceback.print_exc(file=sys.stdout)
        return False
    if owned is None or dry_run:
        return False
    changed = False
    for key, value in owned.items():
        if value is None and key not in state:
            continue
        if state.get(key) != value:
            state[key] = value
            changed = True
    return changed


def default_run_url():
    server, repo, run_id = (os.environ.get(k) for k in ("GITHUB_SERVER_URL", "GITHUB_REPOSITORY", "GITHUB_RUN_ID"))
    return f"{server}/{repo}/actions/runs/{run_id}" if server and repo and run_id else ""


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--sha", required=True, help="the commit to count (a finished measurement's sha)")
    ap.add_argument("--kind", required=True, help=f"the measurement's kind; only {TIP_KIND!r} adds a point")
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
    state, writable = load_state(o.state)
    changed = run_report(state, o.sha, o.kind, root=o.root, repo=o.repo, run_url=o.run_url, issue=o.issue,
                         dry_run=o.dry_run)
    if changed and writable:
        try:
            save_state(o.state, state)
        except OSError as error:
            log(f"cannot write the state {o.state}: {error}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
