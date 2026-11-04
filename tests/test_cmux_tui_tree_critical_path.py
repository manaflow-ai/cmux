#!/usr/bin/env python3
"""A feat-cmux-next push reaches a promotable cmux-tui tree in few runner queues.

nightly-next promotes only a commit with a tree-commit marker
(scripts/cmux-next/tree-commit-marker.sh), and every feat-cmux-next commit
changes cmux-tui, so each one builds its own tree. On 2026-10-28 that took
62-95 minutes from push to marker (runs 40781398367, 40775754399,
40774963755), and most of it was not work: every job in the chain waited
for its own Blacksmith runner, 1-15 minutes each, across eight jobs:
tree-preflight, tree-owner-wait, select binary targets, the target builds,
build-ok, publish, publish-tree and mark-tree-commits.

Three of them did nothing a job before or after could not do:
- tree-owner-wait, for a run that already owns its key (the claim granted it
  or no other owner exists), only printed "this run owns the key". The
  preflight now says so itself (owns_key) and the job is skipped.
- build-ok only checked the build and macOS fallback results; publish and
  sentry-dsyms read them directly.
- mark-tree-commits wrote the commit's marker one queue after publish-tree;
  publish-tree now writes this commit's marker once the tree is verified,
  and mark-tree-commits still walks the window behind it.
And the nightly-next tick, which promotes, ran only when the whole run ended
(after Windows, the daemon tests and the macOS cross checks); publish-tree now
asks it as soon as the marker is written.

This test pins each of those, runs tree-preflight's own inspect step for the
owns_key decision, and fails when a job is added back on the path from the
push to this commit's marker: at most PATH_BUDGET runner queues.
"""

import os
import re
import stat
import subprocess
import sys
import tempfile

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORKFLOW = os.path.join(ROOT, ".github", "workflows", "cmux-tui-artifacts.yml")
KEY = "8729cadfd262d8c13cad8f8ad5d7d54ca4984e01"
# tree-preflight, select binary targets, the target builds, publish,
# publish-tree. A reusable workflow call counts as its two serial jobs.
PATH_BUDGET = 5
FAILURES = []


def _check(ok, message):
    print(("ok: " if ok else "FAIL: ") + message)
    if not ok:
        FAILURES.append(message)


def jobs():
    with open(WORKFLOW, encoding="utf-8") as handle:
        return yaml.safe_load(handle)["jobs"]


def needs(job):
    value = job.get("needs", [])
    return [value] if isinstance(value, str) else list(value)


def evaluate(expression, values, cancelled=False):
    """GitHub's expression subset these `if`s use; an unknown context reads ''."""
    text = str(expression).strip()
    if text.startswith("${{") and text.endswith("}}"):
        text = text[3:-2]
    strings = []

    def keep(match):
        strings.append(match.group(0))
        return f"__S{len(strings) - 1}__"

    text = re.sub(r"'[^']*'", keep, text)
    text = re.sub(r"\b(?:github|needs|inputs|vars|steps|env)(?:\.[A-Za-z0-9_-]+)+",
                  lambda m: f"C({m.group(0)!r})", text)
    text = text.replace("&&", " and ").replace("||", " or ")
    text = re.sub(r"!(?!=)", " not ", text)
    text = text.replace("startsWith(", "starts_with(").replace("contains(", "contains_(")
    for index, literal in enumerate(strings):
        text = text.replace(f"__S{index}__", literal)
    scope = {
        "C": lambda path: values.get(path, ""),
        "starts_with": lambda value, prefix: str(value).startswith(prefix),
        "contains_": lambda haystack, needle: needle in haystack,
        "cancelled": lambda: cancelled,
        "always": lambda: True,
    }
    has_status = re.search(r"\b(?:always|cancelled|success|failure)\(", text)

    def success():
        return all(values.get(f"needs.{n}.result") == "success" for n in values.get("__needs__", []))

    scope["success"] = success
    result = bool(eval(" ".join(text.split()), {"__builtins__": {}}, scope))
    return result if has_status else (success() and result)


def simulate(all_jobs, base):
    """Which jobs run for these preflight outputs, every job that runs succeeding."""
    values = dict(base)
    results = {}
    pending = dict(all_jobs)
    while pending:
        progressed = False
        for name, job in list(pending.items()):
            if any(n not in results for n in needs(job)):
                continue
            values["__needs__"] = needs(job)
            if name == "tree-preflight":
                ran = True
            else:
                ran = evaluate(job.get("if", "true"), values) if "if" in job else all(
                    results[n] == "success" for n in needs(job))
            results[name] = "success" if ran else "skipped"
            values[f"needs.{name}.result"] = results[name]
            del pending[name]
            progressed = True
        if not progressed:
            raise SystemExit(f"FAIL: cycle or unknown need among {sorted(pending)}")
    return results


def queues(job):
    """Serial runner queues a job costs: a reusable call is select-targets then the builds."""
    return 2 if "uses" in job else 1


def longest_path(all_jobs, results, target):
    memo = {}

    def depth(name):
        if name not in memo:
            ran = [n for n in needs(all_jobs[name]) if results.get(n) == "success"]
            memo[name] = queues(all_jobs[name]) + max((depth(n) for n in ran), default=0)
        return memo[name]

    return depth(target)


FAKE_CURL = r"""#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
url = next(a for a in args if a.startswith("http"))
out = args[args.index("-o") + 1] if "-o" in args else None
def emit(body):
    if out and out != "/dev/null":
        open(out, "w").write(body)
    else:
        sys.stdout.write(body)
if "audience=cmux-ci-tree-claim" in url:
    emit(json.dumps({"value": "oidc"}))
    sys.exit(0)
if url.endswith("/tree-claim"):
    owner = os.environ["FAKE_CLAIM_OWNER"]
    emit(json.dumps({"owner_run_id": int(owner), "granted": owner == os.environ["RUN_ID"]}))
    if "-w" in args:
        sys.stdout.write("200")
    sys.exit(0)
url = url.split("?")[0]
if "/actions/" in url:
    emit("{}")
    sys.exit(0)
name = url.rsplit("/", 1)[1]
if os.environ.get("FAKE_PUBLISHED") != "1":
    sys.exit(22)
if name == "daemon-tests.json" and os.environ.get("FAKE_MARKER") != "1":
    sys.exit(22)
key = url.split("/tree/")[1].split("/")[0] if "/tree/" in url else ""
names = ["cmux-tui-aarch64-apple-darwin", "cmux-tui-app-host-aarch64-apple-darwin", "cmux-tui-cloud-server-aarch64-apple-darwin"]
if name == "completion.json":
    emit(json.dumps({"key": key, "binaries": {n: "a" * 64 for n in names}}))
elif name == "source.json":
    emit(json.dumps({"daemonTests": "separate", "run": ""}))
elif name.endswith(".sha256"):
    emit("a" * 64 + "  x\n")
"""


def inspect_script():
    steps = jobs()["tree-preflight"]["steps"]
    return next(s["run"] for s in steps if s.get("id") == "inspect")


def preflight(ref="refs/heads/feat-cmux-next", **fake):
    sha = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True, text=True, check=True).stdout.strip()
    with tempfile.TemporaryDirectory() as tmp:
        bin_dir = os.path.join(tmp, "bin")
        os.makedirs(bin_dir)
        curl = os.path.join(bin_dir, "curl")
        with open(curl, "w") as handle:
            handle.write(FAKE_CURL)
        os.chmod(curl, os.stat(curl).st_mode | stat.S_IXUSR)
        output = os.path.join(tmp, "out")
        open(output, "w").close()
        env = dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}", EVENT_NAME="push", REF=ref, SHA=sha,
                   SOURCE_COMMIT=sha, REPOSITORY="manaflow-ai/cmux", SERVER_URL="https://github.invalid",
                   API_URL="https://api.github.invalid", RUN_ID="5", GITHUB_RUN_ID="5", GH_TOKEN="x",
                   GITHUB_OUTPUT=output, RUNNER_TEMP=tmp, ELECTION_DEADLINE_SECONDS="5",
                   ACTIONS_ID_TOKEN_REQUEST_URL="https://token.invalid/?x=1",
                   ACTIONS_ID_TOKEN_REQUEST_TOKEN="t", FAKE_CLAIM_OWNER="5", STALE="false",
                   GIT_TERMINAL_PROMPT="0")
        env.update(fake)
        result = subprocess.run(["bash", "-e", "-c", inspect_script()], cwd=ROOT, env=env,
                                capture_output=True, text=True, timeout=180)
        outputs = dict(line.split("=", 1) for line in open(output).read().splitlines() if "=" in line)
        return result, outputs


def preflight_values(**outputs):
    base = {"key": KEY, "legacy_key": KEY, "run_macos": "true", "tree_ready": "false", "daemon_tests": "true",
            "daemon_tested": "true", "daemon_marker": "false", "stale": "false", "superseded": "false",
            "owner_run_id": "", "owns_key": "true", "darwin_builder": "linux"}
    base.update(outputs)
    values = {f"needs.tree-preflight.outputs.{k}": v for k, v in base.items()}
    values.update({"github.event_name": "push", "github.ref": "refs/heads/feat-cmux-next",
                   "github.repository": "manaflow-ai/cmux", "github.repository_owner": "manaflow-ai",
                   "needs.tree-preflight.result": "success",
                   "needs.cmux-next-daemon-tests.outputs.key": KEY})
    return values


def main():
    all_jobs = jobs()

    # 1. tree-preflight's own decision.
    result, out = preflight()
    _check(result.returncode == 0 and out.get("owns_key") == "true" and out.get("owner_run_id") == "",
           f"a push whose claim names this run owns its key ({result.returncode}, {out.get('owns_key')}, "
           f"{out.get('owner_run_id')!r}, {result.stderr.strip()[-300:]})")
    result, out = preflight(FAKE_CLAIM_OWNER="3")
    _check(result.returncode == 0 and out.get("owns_key") == "false" and out.get("owner_run_id") == "3",
           f"a push whose key another run claimed asks tree-owner-wait ({out.get('owns_key')}, {out.get('owner_run_id')!r})")
    result, out = preflight(FAKE_PUBLISHED="1")
    _check(result.returncode == 0 and out.get("daemon_tested") == "false" and out.get("owns_key") == "false",
           f"a published tree without its daemon-tests marker still goes to tree-owner-wait to be tested "
           f"({out.get('daemon_tested')}, {out.get('owns_key')})")
    result, out = preflight(FAKE_PUBLISHED="1", FAKE_MARKER="1")
    _check(result.returncode == 0 and out.get("owns_key") == "true" and out.get("run_macos") == "false",
           f"a published, tested tree needs no owner check and builds nothing ({out.get('owns_key')}, {out.get('run_macos')})")
    result, out = preflight(STALE="true")
    _check(result.returncode == 0 and out.get("owns_key") == "false",
           f"a superseded push never owns its key ({out.get('owns_key')})")
    result, out = preflight(ref="refs/heads/main")
    _check(result.returncode == 0 and out.get("owns_key") == "true",
           f"a main push owns its build ({out.get('owns_key')})")

    # 2. The jobs that read tree-owner-wait's takeover start without it when the preflight owns the key,
    # and wait for it otherwise.
    owner_wait = all_jobs["tree-owner-wait"]
    owns = preflight_values()
    _check(not evaluate(owner_wait["if"], dict(owns, __needs__=needs(owner_wait))),
           "tree-owner-wait is skipped for a run that owns its key")
    deferring = preflight_values(owns_key="false", owner_run_id="3")
    _check(evaluate(owner_wait["if"], dict(deferring, __needs__=needs(owner_wait))),
           "tree-owner-wait runs when another run owns the key")
    # build-windows runs only on a dispatch with include_windows; no push builds Windows.
    windows = all_jobs["build-windows"]
    _check(not evaluate(windows["if"], dict(owns, **{"needs.tree-owner-wait.result": "skipped",
                                                    "inputs.include_windows": True, "__needs__": needs(windows)})),
           "build-windows never runs on a push")
    _check(not evaluate(windows["if"], dict(owns, **{"github.event_name": "workflow_dispatch",
                                                    "needs.tree-owner-wait.result": "skipped",
                                                    "inputs.include_windows": False, "__needs__": needs(windows)})),
           "build-windows does not run on a dispatch without include_windows")
    windows_dispatch = {"github.event_name": "workflow_dispatch", "inputs.include_windows": True}
    for name in ("build", "build-windows", "cmux-next-daemon-tests"):
        job = all_jobs[name]
        extra = windows_dispatch if name == "build-windows" else {}
        skipped = dict(owns, **extra, **{"needs.tree-owner-wait.result": "skipped", "__needs__": needs(job)})
        _check(evaluate(job["if"], skipped), f"{name} starts without tree-owner-wait when the run owns its key")
        for takeover, result, expected in (("true", "success", True), ("false", "success", False), ("", "failure", False)):
            values = dict(deferring, **extra, **{"needs.tree-owner-wait.result": result,
                                        "needs.tree-owner-wait.outputs.takeover": takeover, "__needs__": needs(job)})
            _check(evaluate(job["if"], values) == expected,
                   f"{name} with tree-owner-wait {result}, takeover {takeover or '-'}: {'runs' if expected else 'skipped'}")
        _check(not evaluate(job["if"], dict(skipped, **{"needs.tree-preflight.result": "failure",
                                                        "needs.tree-preflight.outputs.run_macos": ""})),
               f"{name} never runs after a failed tree-preflight")
    for name, job in all_jobs.items():
        if "tree-owner-wait" in needs(job) and "needs.tree-owner-wait.outputs.takeover == 'true'" in str(job.get("if", "")):
            _check("needs.tree-preflight.outputs.owns_key == 'true'" in str(job["if"]),
                   f"{name} reads takeover as tree-owner-wait's or the preflight's owns_key")

    # 3. No build-ok hop: publish reads the build results itself.
    _check("build-ok" not in all_jobs, "no build-ok job between the build and publish")
    publish = all_jobs["publish"]
    base = dict(owns, **{"__needs__": needs(publish), "needs.build-darwin-fallback.result": "skipped",
                         "needs.darwin-fallback-plan.result": "skipped"})
    for build, fallback, recovered, expected in (("success", "skipped", "", True), ("failure", "success", "false", True),
                                                 ("failure", "skipped", "true", True), ("failure", "failure", "false", False),
                                                 ("failure", "skipped", "", False), ("skipped", "skipped", "", False)):
        values = dict(base, **{"needs.build.result": build, "needs.build-darwin-fallback.result": fallback,
                               "needs.darwin-fallback-plan.outputs.recovered": recovered})
        _check(evaluate(publish["if"], values) == expected,
               f"publish with build {build}, fallback {fallback}, recovered {recovered or '-'}: {'runs' if expected else 'skipped'}")
        _check(evaluate(all_jobs["sentry-dsyms"]["if"], values) == expected,
               f"sentry-dsyms with build {build}, fallback {fallback}: {'runs' if expected else 'skipped'}")

    # 4. publish-tree writes this commit's marker on feat-cmux-next, and only on its first (unix) pass.
    tree_steps = all_jobs["publish-tree"]["steps"]
    marks = [s for s in tree_steps if "tree-commit-marker.sh write" in str(s.get("run", ""))]
    _check(len(marks) == 1, f"publish-tree writes the tree-commit marker ({len(marks)} steps)")
    if marks:
        mark = marks[0]
        _check(mark.get("continue-on-error") is True, "a failed marker write in publish-tree never fails the publish")
        _check(tree_steps.index(mark) > next(i for i, s in enumerate(tree_steps) if s.get("name") == "Verify the tree publication"),
               "the marker is written after the tree publication is verified")
        for ref, event, publish_pass, expected in (("refs/heads/feat-cmux-next", "push", "unix", True),
                                                   ("refs/heads/feat-cmux-next", "workflow_dispatch", "unix", True),
                                                   ("refs/heads/feat-cmux-next", "push", "windows", False),
                                                   ("refs/heads/main", "push", "unix", False),
                                                   ("refs/heads/codex/lane", "push", "unix", False)):
            values = {"github.ref": ref, "github.event_name": event, "github.repository": "manaflow-ai/cmux",
                      "env.CMUX_TUI_PUBLISH_PASS": publish_pass, "__needs__": []}
            _check(evaluate(mark["if"], values) == expected,
                   f"{event} {ref} ({publish_pass} pass): {'writes' if expected else 'no'} marker in publish-tree")
    _check("mark-tree-commits" in all_jobs, "mark-tree-commits still marks the window and backfills")
    asks = [s for s in tree_steps if "nightly-next-tick.yml" in str(s.get("run", ""))]
    _check(len(asks) == 1 and marks and tree_steps.index(asks[0]) > tree_steps.index(marks[0])
           and asks[0].get("continue-on-error") is True and "--ref main" in asks[0]["run"],
           "publish-tree asks main's nightly-next tick once this commit is marked, never failing the publish")
    if asks:
        for ref, publish_pass, expected in (("refs/heads/feat-cmux-next", "unix", True),
                                            ("refs/heads/feat-cmux-next", "windows", False),
                                            ("refs/heads/main", "unix", False)):
            values = {"github.ref": ref, "github.event_name": "push", "github.repository": "manaflow-ai/cmux",
                      "env.CMUX_TUI_PUBLISH_PASS": publish_pass, "__needs__": []}
            _check(evaluate(asks[0]["if"], values) == expected,
                   f"{ref} ({publish_pass} pass): {'asks' if expected else 'does not ask'} the tick")

    # 5. The whole path, simulated: a feat-cmux-next push that owns a new key.
    results = simulate(all_jobs, owns)
    ran = sorted(n for n, r in results.items() if r == "success")
    for name in ("tree-preflight", "build", "publish", "publish-tree", "mark-tree-commits"):
        _check(results.get(name) == "success", f"{name} runs for a feat-cmux-next push that owns a new key ({ran})")
    _check(results.get("tree-owner-wait") == "skipped", "tree-owner-wait does not run on that push")
    path = longest_path(all_jobs, results, "publish-tree")
    _check(path <= PATH_BUDGET,
           f"push to this commit's tree-commit marker: {path} runner queues (budget {PATH_BUDGET}); "
           "fold a new job into one on the path instead of adding a queue")

    if FAILURES:
        print(f"{len(FAILURES)} failure(s)")
        return 1
    print(f"PASS: a feat-cmux-next push reaches its tree-commit marker in {path} runner queues")
    return 0


if __name__ == "__main__":
    sys.exit(main())
