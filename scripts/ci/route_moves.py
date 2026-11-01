#!/usr/bin/env python3
"""Move jobs already queued on a label a routing variable left: the record and the runs-on check.

Coordinator, 2026-11-01, on about 2,000 cmux runs left queued on blacksmith-32vcpu-ubuntu-2404 after
LINUX_RUNNER moved off it: "Better: make it a queue-janitor action that does this automatically when the
route changes, so nobody re-runs by hand next time."

GitHub binds a job's label when it creates the job, from the variables its run started with. Pointing
LINUX_RUNNER or a RUNNER_POOLS member at another label moves new runs only; a job already queued on the old
label stays there until a re-run evaluates its runs-on again. Two halves:

- runner_pools.py records every move it makes in RUNNER_POOLS' `_moved` (record_moves()): a list of
  {"variable", "from", "to", "at"}, `variable` being a mirrored variable's name (LINUX_RUNNER) or
  RUNNER_POOLS.<pool>. An entry lasts MOVE_TTL, a later move from the same label replaces it, and one whose
  old label is the variable's value again (it moved back) is dropped. At most MAX_MOVES are kept.
- the queue janitor reads that value from its own job's env (`vars.RUNNER_POOLS`: no API read and no new
  token) and, for each move, treats a job as lost (queue_janitor.route_lost(), category e) when it is queued
  with no runner on exactly the old label, in a run created before the move, and its runs-on, read from the
  workflow file at the run's head (WorkflowFiles, over git, the API only as a fallback), takes its label from
  that variable: evaluated with the old value it gives the old label, and with the values the janitor's job
  started with it gives another one (qualifies()). Anything it cannot evaluate (an input, a picker's output,
  a variable not handed in) is left alone, never guessed.
"""

from __future__ import annotations

import base64
import dataclasses
import datetime as dt
import json
import os
import re
import subprocess
import tempfile
import time
import urllib.parse
from collections.abc import Callable, Iterable, Mapping, Sequence
from typing import Any

UTC = dt.timezone.utc
MOVED_KEY = "_moved"
# A move older than this moves nothing: GitHub drops a job queued 24 hours, and a re-run is wanted within hours.
MOVE_TTL = dt.timedelta(hours=6)
MAX_MOVES = 16
POOLS_VARIABLE = "RUNNER_POOLS"
# The variables the janitor's job hands in by name (ci-queue-janitor.yml): the routing variables a runs-on
# reads beside a moved one. A runs-on reading any other variable is not evaluated.
VALUE_VARIABLES = ("LINUX_RUNNER", "RUNNER_POOLS", "CI_CLOUD_OVERFLOW_SAVED")
LABEL = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
VARIABLE_NAME = re.compile(r"^(?:[A-Z][A-Z0-9_]*|RUNNER_POOLS\.[a-z][a-z0-9_]*)$")


def iso(moment: dt.datetime) -> str:
    return moment.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_time(value: object) -> dt.datetime | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        moment = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    return moment if moment.tzinfo is not None else None


@dataclasses.dataclass(frozen=True)
class Move:
    variable: str  # "LINUX_RUNNER" or "RUNNER_POOLS.<pool>"
    old: str
    new: str
    at: dt.datetime

    def line(self) -> str:
        return f"{self.variable} `{self.old}` -> `{self.new}` at {iso(self.at)}"


def valid_entry(entry: object) -> bool:
    return (isinstance(entry, Mapping) and isinstance(entry.get("variable"), str)
            and bool(VARIABLE_NAME.match(entry["variable"]))
            and all(isinstance(entry.get(key), str) and LABEL.match(entry[key]) for key in ("from", "to"))
            and entry["from"] != entry["to"] and parse_time(entry.get("at")) is not None)


def parse_moves(entries: object, *, now: dt.datetime | None = None) -> list[Move]:
    """The valid moves of a `_moved` list, within MOVE_TTL of `now` when given."""
    found = []
    for entry in entries if isinstance(entries, list) else ():
        if not valid_entry(entry):
            continue
        at = parse_time(entry["at"])
        assert at is not None
        if now is not None and not (dt.timedelta(minutes=-5) <= now - at <= MOVE_TTL):
            continue
        found.append(Move(entry["variable"], entry["from"], entry["to"], at))
    return found


def moves_in(raw_pools: str | None, *, now: dt.datetime) -> tuple[list[Move], str]:
    """(the live moves RUNNER_POOLS' `_moved` records, why there are none)."""
    if not (raw_pools or "").strip():
        return [], f"{POOLS_VARIABLE} was not handed in"
    try:
        value = json.loads(str(raw_pools))
    except ValueError:
        return [], f"{POOLS_VARIABLE} is not JSON"
    if not isinstance(value, dict):
        return [], f"{POOLS_VARIABLE} is not a JSON object"
    found = parse_moves(value.get(MOVED_KEY), now=now)
    return found, "" if found else f"no move recorded in the last {MOVE_TTL}"


def record_moves(previous: object, changes: Iterable[tuple[str, str | None, str]], *,
                 current: Mapping[str, str], now: dt.datetime) -> list[dict[str, str]]:
    """The next `_moved` list: `previous` (a `_moved` list) less what expired or moved back, plus `changes`.

    `changes` are (variable, old label, new label) for this pass's writes; an unset or equal old label records
    nothing. `current` maps each variable to its value after this pass: an entry whose old label is that value
    again is dropped, since its jobs are where the route points."""
    kept: list[dict[str, str]] = []
    for entry in previous if isinstance(previous, list) else ():
        if not valid_entry(entry):
            continue
        at = parse_time(entry["at"])
        assert at is not None
        if not (dt.timedelta(minutes=-5) <= now - at <= MOVE_TTL):
            continue
        if current.get(entry["variable"]) == entry["from"]:
            continue
        kept.append({key: entry[key] for key in ("variable", "from", "to", "at")})
    for variable, old, new in changes:
        old = (old or "").strip()
        if not old or old == new or not LABEL.match(old) or not LABEL.match(new or ""):
            continue
        kept = [entry for entry in kept if not (entry["variable"] == variable and entry["from"] == old)]
        kept.append({"variable": variable, "from": old, "to": new, "at": iso(now)})
    return kept[-MAX_MOVES:]


def with_value(values: Mapping[str, str], variable: str, label: str) -> dict[str, str] | None:
    """`values` with `variable` (a name or RUNNER_POOLS.<pool>) set to `label`; None when that cannot be done."""
    out = dict(values)
    name, _, pool = variable.partition(".")
    if not pool:
        out[name] = label
        return out
    try:
        doc = json.loads(values.get(name) or "")
    except ValueError:
        return None
    if not isinstance(doc, dict):
        return None
    doc[pool] = label
    out[name] = json.dumps(doc)
    return out


# --- runs-on evaluation -------------------------------------------------------------------------------------
UNKNOWN = object()
EXPRESSION = re.compile(r"\$\{\{(.*?)\}\}", re.DOTALL)
_LITERAL = re.compile(r"'((?:[^']|'')*)'", re.DOTALL)
_CALL = re.compile(r"^(startsWith|endsWith|contains|fromJSON)\((.*)\)$", re.IGNORECASE | re.DOTALL)
_MEMBER = re.compile(r"^fromJSON\((.*)\)\.([A-Za-z0-9_]+)$", re.IGNORECASE | re.DOTALL)
_VARIABLE = re.compile(r"^vars\.([A-Za-z0-9_]+)$")


def split_top(text: str, operator: str) -> list[str]:
    """`text` split on `operator` outside parentheses and quotes."""
    parts, depth, quoted, start, index = [], 0, False, 0, 0
    while index < len(text):
        char = text[index]
        if char == "'":
            quoted = not quoted
        elif not quoted and char == "(":
            depth += 1
        elif not quoted and char == ")":
            depth -= 1
        elif not quoted and depth == 0 and text.startswith(operator, index):
            parts.append(text[start:index])
            index += len(operator)
            start = index
            continue
        index += 1
    parts.append(text[start:])
    return parts


def _unwrap(text: str) -> str:
    text = text.strip()
    while text.startswith("(") and text.endswith(")"):
        depth, quoted, closes_early = 0, False, False
        for index, char in enumerate(text):
            if char == "'":
                quoted = not quoted
            elif not quoted and char == "(":
                depth += 1
            elif not quoted and char == ")":
                depth -= 1
                if depth == 0 and index != len(text) - 1:
                    closes_early = True
                    break
        if closes_early:
            break
        text = text[1:-1].strip()
    return text


def _truthy(value: Any) -> bool:
    return value is not None and value is not False and value != "" and value != 0


def _text(value: Any) -> str | None:
    if value is None:
        return ""
    return value if isinstance(value, str) else None


def evaluate(expression: str, values: Mapping[str, str], context: Mapping[str, str]) -> Any:
    """A GitHub expression's value with these variables and this run's context, or UNKNOWN when it reads
    anything else (an input, a picker's output, a matrix value, a variable not handed in)."""
    text = _unwrap(expression)
    for operator in ("||", "&&"):
        parts = split_top(text, operator)
        if len(parts) > 1:
            value: Any = None
            for part in parts:
                value = evaluate(part, values, context)
                if value is UNKNOWN:
                    return UNKNOWN
                if _truthy(value) == (operator == "||"):
                    return value
            return value
    for operator in ("!=", "=="):
        parts = split_top(text, operator)
        if len(parts) == 2:
            left, right = (evaluate(part, values, context) for part in parts)
            if left is UNKNOWN or right is UNKNOWN:
                return UNKNOWN
            if not (isinstance(left, (str, bool, type(None))) and isinstance(right, (str, bool, type(None)))):
                return UNKNOWN
            same = str("" if left is None else left).lower() == str("" if right is None else right).lower()
            return same == (operator == "==")
    if text.startswith("!") and not text.startswith("!="):
        value = evaluate(text[1:], values, context)
        return UNKNOWN if value is UNKNOWN else not _truthy(value)
    literal = _LITERAL.fullmatch(text)
    if literal:
        return literal.group(1).replace("''", "'")
    if text in ("true", "false"):
        return text == "true"
    if text == "null":
        return None
    member = _MEMBER.fullmatch(text)
    if member:
        doc = _from_json(evaluate(member.group(1), values, context))
        if doc is UNKNOWN or not isinstance(doc, dict):
            return UNKNOWN  # GitHub fails the job; nothing to move to
        value = doc.get(member.group(2))
        return value if isinstance(value, str) else UNKNOWN
    variable = _VARIABLE.fullmatch(text)
    if variable:
        return values[variable.group(1)] if variable.group(1) in values else UNKNOWN
    if text in context:
        return context[text]
    call = _CALL.fullmatch(text)
    if call:
        name = call.group(1).lower()
        args = split_top(call.group(2), ",")
        if name == "fromjson":
            return _from_json(evaluate(args[0], values, context)) if len(args) == 1 else UNKNOWN
        if len(args) != 2:
            return UNKNOWN
        left, right = (evaluate(arg, values, context) for arg in args)
        if left is UNKNOWN or right is UNKNOWN:
            return UNKNOWN
        if name == "contains" and isinstance(left, list):
            needle = _text(right)
            if needle is None:
                return UNKNOWN
            return any(isinstance(item, str) and item.lower() == needle.lower() for item in left)
        left, right = _text(left), _text(right)
        if left is None or right is None:
            return UNKNOWN
        left, right = left.lower(), right.lower()
        if name == "startswith":
            return left.startswith(right)
        if name == "endswith":
            return left.endswith(right)
        return right in left
    return UNKNOWN


def _from_json(value: Any) -> Any:
    if not isinstance(value, str):
        return UNKNOWN
    try:
        return json.loads(value)
    except ValueError:
        return UNKNOWN


def run_context(run: Mapping[str, Any], repo: str) -> dict[str, str]:
    """What a runs-on may read about the run, as a re-run sees it."""
    head_repo = str(((run.get("head_repository") or {}).get("full_name")) or "")
    context = {"github.repository_owner": repo.split("/", 1)[0], "github.repository": repo,
               "github.event_name": str(run.get("event") or "")}
    if run.get("event") in ("pull_request", "pull_request_target"):
        context["github.event.pull_request.head.repo.full_name"] = head_repo
    return context


def qualifies(runs_on: str | None, move: Move, values: Mapping[str, str],
              context: Mapping[str, str]) -> tuple[str | None, str]:
    """(the label a re-run takes, why) when this runs-on took `move.old` from the moved variable, else (None, why).

    The runs-on must be one `${{ }}` expression and nothing else. With the moved variable at its old value it
    must give the old label (so that label came from the route, not a literal), and with `values`, the values
    a re-run reads, another label (so a re-run moves it)."""
    if runs_on is None:
        return None, "its job's runs-on could not be read at the run's head"
    expressions = EXPRESSION.findall(runs_on)
    if len(expressions) != 1 or EXPRESSION.sub("", runs_on).strip():
        return None, "its runs-on is not one expression"
    before = with_value(values, move.variable, move.old)
    if before is None:
        return None, f"{move.variable.split('.')[0]} was not handed in as JSON"
    then = evaluate(expressions[0], before, context)
    if then is UNKNOWN:
        return None, "its runs-on reads something this sweep cannot evaluate; left alone"
    if not isinstance(then, str) or then.lower() != move.old.lower():
        return None, f"its runs-on does not take `{move.old}` from {move.variable}"
    now = evaluate(expressions[0], values, context)
    if not isinstance(now, str) or not now or now is UNKNOWN:
        return None, "its runs-on gives no label with today's values"
    if now.lower() == move.old.lower():
        return None, f"a re-run would land on `{move.old}` again"
    return now, f"{move.variable} moved `{move.old}` -> `{move.new}` at {iso(move.at)}; a re-run lands on `{now}`"


# --- finding the job in its workflow ------------------------------------------------------------------------
REUSABLE = re.compile(r"^\./\.github/workflows/[A-Za-z0-9._-]+\.ya?ml$")
_MATRIX_SUFFIX = re.compile(r"\s*\(.*\)\s*$", re.DOTALL)


def _load(text: str) -> Mapping[str, Any] | None:
    try:
        import yaml  # noqa: PLC0415 - only this pass needs it; without it nothing moves
    except ImportError:
        return None
    try:
        doc = yaml.load(text, Loader=yaml.BaseLoader)
    except yaml.YAMLError:
        return None
    return doc if isinstance(doc, dict) else None


def yaml_available() -> bool:
    try:
        import yaml  # noqa: F401, PLC0415
    except ImportError:
        return False
    return True


def _name_pattern(template: str) -> re.Pattern[str]:
    parts = re.split(r"\$\{\{.*?\}\}", template, flags=re.DOTALL)
    return re.compile(".+?".join(re.escape(part) for part in parts), re.DOTALL)


def find_job(text: str, name: str) -> tuple[Mapping[str, Any], str] | None:
    """(the workflow job, the rest of the API's job name) for the job the API calls `name`: the job itself
    (rest ""), or a reusable workflow's caller (rest: the callee's part after " / "). None unless exactly
    one job matches; a name spelled out wins over a templated one."""
    doc = _load(text)
    jobs = doc.get("jobs") if doc else None
    if not isinstance(jobs, dict):
        return None
    exact, templated = [], []
    for job_id, job in jobs.items():
        if not isinstance(job, dict):
            continue
        template = str(job.get("name") or job_id)
        reusable = isinstance(job.get("uses"), str)
        head, sep, rest = name.partition(" / ") if reusable else (name, "", "")
        if reusable and not sep:
            continue
        bare = _MATRIX_SUFFIX.sub("", head)
        if head == template or bare == template:
            exact.append((job, rest))
        elif "${{" in template and (_name_pattern(template).fullmatch(head) or _name_pattern(template).fullmatch(bare)):
            templated.append((job, rest))
    found = exact or templated
    return found[0] if len(found) == 1 else None


def runs_on_text(job: Mapping[str, Any]) -> str | None:
    value = job.get("runs-on")
    return value if isinstance(value, str) else None


def runs_on_of(read: Callable[[str], str | None], path: str, name: str, depth: int = 0) -> str | None:
    """The runs-on text of the job the API names `name` in the workflow at `path` (read(path): the file at the
    run's head), following local reusable-workflow calls two deep; None when it cannot be found."""
    text = read(path)
    found = find_job(text, name) if text is not None else None
    if found is None:
        return None
    job, rest = found
    if not rest:
        return runs_on_text(job)
    uses = str(job.get("uses") or "")
    if depth >= 2 or not REUSABLE.match(uses):
        return None
    return runs_on_of(read, uses[2:], rest, depth + 1)


def mentions(text: str | None, move: Move) -> bool:
    """Whether a workflow file names the moved variable at all (a cheap filter before listing a run's jobs)."""
    return bool(text) and re.search(rf"\bvars\.{re.escape(move.variable.split('.')[0])}\b", text or "") is not None


class WorkflowFiles:
    """Workflow files at a commit, read over git (no API budget), the API only when git cannot.

    git: one bare partial clone in a scratch directory; each commit is fetched once with its trees only
    (`--depth=1 --filter=blob:none`), and `git show` fetches the one blob it reads. The API: one contents
    read per file, through `api(path)` (the janitor's client, so its budget, retries and rate-limit stop
    apply). At most `max_reads` distinct (commit, file) reads a sweep, and none past `deadline`
    (time.monotonic()); a read past either is None, which moves nothing."""

    def __init__(self, repo: str, *, api: Callable[[str], Any] | None = None, max_reads: int = 40,
                 deadline: float | None = None, git: bool = True, git_url: str | None = None) -> None:
        self.repo = repo
        self.api = api
        self.max_reads = max_reads
        self.deadline = deadline
        self.git_url = git_url or f"https://github.com/{repo}.git"
        self.cache: dict[tuple[str, str], str | None] = {}
        self.fetched: dict[str, bool] = {}
        self.git_reads = 0
        self.api_reads = 0
        self.refused = 0
        self._scratch: str | None = None
        self._git = git

    def _run(self, *args: str, timeout: float) -> subprocess.CompletedProcess[str]:
        assert self._scratch is not None
        return subprocess.run(["git", "-C", self._scratch, *args], capture_output=True, text=True,
                              timeout=timeout, check=False,
                              env={**os.environ, "GIT_TERMINAL_PROMPT": "0"})

    def _git_ready(self) -> bool:
        if not self._git:
            return False
        if self._scratch is None:
            try:
                self._scratch = tempfile.mkdtemp(prefix="route-moves-git-")
                for args in (("init", "-q", "--bare"), ("config", "core.repositoryformatversion", "1"),
                             ("config", "extensions.partialClone", "origin"),
                             ("remote", "add", "origin", self.git_url),
                             ("config", "remote.origin.promisor", "true"),
                             ("config", "remote.origin.partialclonefilter", "blob:none")):
                    if self._run(*args, timeout=30).returncode != 0:
                        self._git = False
                        return False
            except (OSError, subprocess.SubprocessError):
                self._git = False
                return False
        return True

    def _git_read(self, sha: str, path: str) -> str | None:
        if not self._git_ready():
            return None
        try:
            if sha not in self.fetched:
                done = self._run("fetch", "-q", "--no-tags", "--depth=1", "--filter=blob:none", "origin", sha,
                                 timeout=90)
                self.fetched[sha] = done.returncode == 0
            if not self.fetched[sha]:
                return None
            shown = self._run("show", f"{sha}:{path}", timeout=60)
        except (OSError, subprocess.SubprocessError):
            return None
        return shown.stdout if shown.returncode == 0 else None

    def _api_read(self, sha: str, path: str) -> str | None:
        if self.api is None:
            return None
        query = urllib.parse.urlencode({"ref": sha})
        payload = self.api(f"/repos/{self.repo}/contents/{urllib.parse.quote(path)}?{query}")
        content = payload.get("content") if isinstance(payload, Mapping) else None
        if not isinstance(content, str) or payload.get("encoding") != "base64":
            return None
        return base64.b64decode(content).decode("utf-8", errors="replace")

    def read(self, sha: str, path: str) -> str | None:
        key = (sha, path)
        if key in self.cache:
            return self.cache[key]
        if not re.fullmatch(r"[0-9a-f]{40}", sha) or not REUSABLE.match(f"./{path}"):
            return None
        if len(self.cache) >= self.max_reads or (self.deadline is not None and time.monotonic() >= self.deadline):
            self.refused += 1
            return None
        text = self._git_read(sha, path)
        if text is not None:
            self.git_reads += 1
        else:
            # A rate limit propagates (the caller's client raises): the sweep stops before acting. Any other
            # refusal (a 404 for a file missing at that commit, a 5xx after retries, the sweep's deadline)
            # leaves this job alone instead of failing the whole sweep.
            try:
                text = self._api_read(sha, path)
            except Exception as error:  # noqa: BLE001 - only a rate limit may end the sweep
                if type(error).__name__ == "RateLimited":
                    raise
                text = None
            if text is not None:
                self.api_reads += 1
        self.cache[key] = text
        return text

    def line(self) -> str:
        return (f"{len(self.cache)} workflow file reads ({self.git_reads} over git, {self.api_reads} over the API"
                f"{f', {self.refused} past the cap' if self.refused else ''})")


def values_from(env: Mapping[str, str]) -> dict[str, str]:
    """The routing variables the janitor's job handed in (VALUE_VARIABLES); one not in `env` was not handed in."""
    return {name: str(env[name]) for name in VALUE_VARIABLES if name in env}


def summary(moves: Sequence[Move], why_none: str, lines: Sequence[str], files: WorkflowFiles | None,
            *, dry_run: bool, listings: int) -> str:
    if not moves:
        return f"\n_Route moves: none ({why_none})._\n"
    head = "\n### Route moves" + (" (dry run)" if dry_run else "") + "\n\n"
    body = "".join(f"- recorded: {move.line()}\n" for move in moves)
    body += "".join(f"- {line}\n" for line in lines) or "- no queued job on a label a route left\n"
    tail = f"\n_{listings} extra job listings for route moves"
    tail += f", {files.line()}" if files is not None else ""
    return head + body + tail + "._\n"
