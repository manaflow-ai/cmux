#!/usr/bin/env python3
"""A superseded cmux-tui artifacts push skips its builds and daemon tests.

On 2026-10-14 the owned Macs' side lane had ~285 queued jobs and 37% of the
queued cmux-tui artifacts runs were superseded: 61 cmux-tui-pin-* merge trees
of pull requests that had moved on, and 24 lane-branch pushes whose branch had
moved. They were cancelled by hand. The workflow group keeps them: a queued
run is already admitted, and GitHub replaces only a pending one.

This runs the workflow's own steps against a fake GitHub API and real commits:
tree-preflight's superseded check and the daemon-test job's re-check, then
tree-preflight's daemon policy and inspect steps with the verdict, and checks
the jobs that consume it. main, feat-cmux-next and next-batch/* runs, pull
request runs and dispatches are never superseded.
"""

import http.server
import json
import os
import stat
import subprocess
import sys
import tempfile
import threading

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORKFLOW = os.path.join(ROOT, ".github", "workflows", "cmux-tui-artifacts.yml")
REPO = "manaflow-ai/cmux"
KEY = "c" * 40
FAILURES = []


def _check(ok, message):
    print(("ok: " if ok else "FAIL: ") + message)
    if not ok:
        FAILURES.append(message)


def jobs():
    with open(WORKFLOW, encoding="utf-8") as handle:
        return yaml.safe_load(handle)["jobs"]


def step(job, step_id):
    found = [s for s in jobs()[job]["steps"] if s.get("id") == step_id]
    if len(found) != 1:
        raise SystemExit(f"FAIL: {job} has no step with id {step_id}")
    return found[0]


class FakeApi:
    """Serves ROUTES (path without query -> (status, body)) and logs requests."""

    def __init__(self):
        self.routes = {}
        self.requests = []
        api = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                api.requests.append(self.path)
                status, body = api.routes.get(self.path.split("?")[0], (404, {"message": "Not Found"}))
                data = json.dumps(body).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def log_message(self, *args):
                pass

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}"

    def reset(self, routes):
        self.routes = {f"/repos/{REPO}/{path}": value for path, value in routes.items()}
        self.requests = []


def git(repo, *args, env=None):
    base = ["git", "-C", repo, "-c", "user.name=t", "-c", "user.email=t@example.com"]
    return subprocess.run(base + list(args), check=True, capture_output=True, text=True, env=env).stdout.strip()


def make_commits(repo):
    subprocess.run(["git", "init", "-q", repo], check=True)
    git(repo, "commit", "-q", "--allow-empty", "-m", "base")
    base = git(repo, "rev-parse", "HEAD")
    git(repo, "commit", "-q", "--allow-empty", "-m", "lane head")
    head = git(repo, "rev-parse", "HEAD")
    tree = git(repo, "rev-parse", "HEAD^{tree}")
    merge = git(repo, "commit-tree", tree, "-p", base, "-p", head, "-m", f"Merge {head} into {base}")
    other = git(repo, "commit-tree", tree, "-p", base, "-p", head, "-m", "next-batch: stack 3 PRs")
    os.symlink(os.path.join(ROOT, "scripts"), os.path.join(repo, "scripts"))
    return base, head, merge, other


def run_check(api, repo, script, event, ref, sha, extra=None):
    output = os.path.join(repo, "github-output")
    open(output, "w").close()
    env = {"PATH": os.environ["PATH"], "HOME": repo, "GITHUB_OUTPUT": output,
           "GITHUB_API_URL": api.url, "GITHUB_REPOSITORY": REPO, "GH_TOKEN": "x",
           "EVENT_NAME": event, "REF": ref, "SHA": sha, "KEY": "", "RUN_ID": "100"}
    env.update(extra or {})
    result = subprocess.run(["bash", "-e", "-c", script], cwd=repo, env=env, capture_output=True, text=True, timeout=60)
    values = dict(line.split("=", 1) for line in open(output).read().splitlines() if "=" in line)
    if result.returncode != 0:
        return f"exit {result.returncode}: {result.stderr.strip()[-300:]}"
    return values.get("stale")


def commit(sha, parents, message):
    """GET commits/<sha>: the pin check reads parents and subject from here."""
    return (200, {"sha": sha, "parents": [{"sha": p} for p in parents], "commit": {"message": message}})


def shallow_clone(source, branch, into):
    """A depth-1 checkout of BRANCH, as actions/checkout leaves it: no parents."""
    subprocess.run(["git", "clone", "-q", "--depth", "1", "--branch", branch, f"file://{source}", into],
                   check=True, capture_output=True)
    os.symlink(os.path.join(ROOT, "scripts"), os.path.join(into, "scripts"))
    return into


def pull(number, head, state="open", repo=REPO, merged=False, base="feat-cmux-next"):
    return {"number": number, "state": state, "head": {"sha": head, "repo": {"full_name": repo}},
            "base": {"ref": base}, "merged_at": "2026-10-21T18:00:00Z" if merged else None}


def check_verdicts():
    preflight_step = step("tree-preflight", "stale")
    daemon_step = step("cmux-next-daemon-tests", "current")
    api = FakeApi()
    with tempfile.TemporaryDirectory() as repo:
        base, head, merge, other = make_commits(repo)
        newer = "d" * 40
        lane = "refs/heads/codex/some-lane"
        pin = f"refs/heads/cmux-tui-pin-{merge[:12]}"
        ref_path = "git/ref/heads/codex/some-lane"
        pulls_path = f"commits/{head}/pulls"
        deferred_path = "actions/artifacts"
        merge_path = f"commits/{merge}"
        merge_commit = {merge_path: commit(merge, [base, head], f"Merge {head} into {base}")}
        dispatch_path = "actions/workflows/cmux-next.yml/runs"
        no_dispatch = (200, {"total_count": 0, "workflow_runs": []})
        script = preflight_step["run"]
        cases = [
            ("a lane push whose branch moved is superseded", "push", lane, head,
             {ref_path: (200, {"object": {"sha": newer}})}, "true"),
            ("a lane push that is still the branch head runs", "push", lane, head,
             {ref_path: (200, {"object": {"sha": head}})}, "false"),
            ("a lane push of a deleted branch runs (fail open)", "push", lane, head, {}, "false"),
            ("a lane push runs when the API fails", "push", lane, head,
             {ref_path: (500, {"message": "boom"})}, "false"),
            ("a pin whose pull request has a newer head is superseded", "push", pin, merge,
             dict(merge_commit, **{pulls_path: (200, [pull(7, newer)])}), "true"),
            ("a pin of the pull request's current head runs", "push", pin, merge,
             dict(merge_commit, **{pulls_path: (200, [pull(7, head)])}), "false"),
            # Once the pull request merged, feat-cmux-next's push of it tests its own tree (2026-10-21: pin
            # daemon tests of merged pull requests held the side lane for hours).
            ("a pin of a merged pull request's final head is superseded", "push", pin, merge,
             dict(merge_commit, **{pulls_path: (200, [pull(7, head, state="closed", merged=True)])}), "true"),
            ("a pin of a pull request merged into another branch runs", "push", pin, merge,
             dict(merge_commit, **{pulls_path: (200, [pull(7, head, state="closed", merged=True, base="some-lane")])}),
             "false"),
            ("a pin of a merged fork pull request runs", "push", pin, merge,
             dict(merge_commit, **{pulls_path: (200, [pull(7, head, state="closed", merged=True, repo="someone/cmux")])}),
             "false"),
            ("a pin of a pull request closed without merging runs", "push", pin, merge,
             dict(merge_commit, **{pulls_path: (200, [pull(7, head, state="closed")])}), "false"),
            ("a pin whose head is still open in another pull request runs", "push", pin, merge,
             dict(merge_commit, **{pulls_path: (200, [pull(7, head, state="closed", merged=True), pull(8, head)])}),
             "false"),
            ("a pin of a commit no pull request has runs", "push", pin, merge,
             dict(merge_commit, **{pulls_path: (200, [])}), "false"),
            ("a pin of a non-merge commit (pin-cmux-tui.sh) runs", "push", f"refs/heads/cmux-tui-pin-{head[:12]}", head,
             {f"commits/{head}": commit(head, [base], "lane head"), pulls_path: (200, [pull(7, newer)])}, "false"),
            ("a pin of a merge that is not GitHub's pull request merge (next_batch.py) runs", "push",
             f"refs/heads/cmux-tui-pin-{other[:12]}", other,
             {f"commits/{other}": commit(other, [base, head], "next-batch: stack 3 PRs"),
              pulls_path: (200, [pull(7, newer)])}, "false"),
            ("a pin runs when the API fails", "push", pin, merge, dict(merge_commit, **{pulls_path: (502, {})}), "false"),
            ("a pin runs when its commit lookup fails", "push", pin, merge,
             {merge_path: (502, {}), pulls_path: (200, [pull(7, newer)])}, "false"),
            ("a feat-cmux-next push is never superseded here", "push", "refs/heads/feat-cmux-next", head,
             {"git/ref/heads/feat-cmux-next": (200, {"object": {"sha": newer}})}, "false"),
            ("a main push is never superseded here", "push", "refs/heads/main", head,
             {"git/ref/heads/main": (200, {"object": {"sha": newer}})}, "false"),
            ("a next-batch push is never superseded here", "push", "refs/heads/next-batch/abc", head,
             {"git/ref/heads/next-batch/abc": (200, {"object": {"sha": newer}})}, "false"),
            ("a dispatch is never superseded", "workflow_dispatch", lane, head,
             {ref_path: (200, {"object": {"sha": newer}})}, "false"),
            ("a pull request run is never superseded here", "pull_request_target", lane, head,
             {ref_path: (200, {"object": {"sha": newer}})}, "false"),
            # cp/, lane/ and perf/ agent branches publish only a head an open pull request has (2026-10-26).
            ("a lane/ head no open pull request has is superseded", "push", "refs/heads/lane/x", head,
             {pulls_path: (200, []), dispatch_path: no_dispatch,
              "git/ref/heads/lane/x": (200, {"object": {"sha": head}})}, "true"),
            ("a cp/ head whose only pull request closed is superseded", "push", "refs/heads/cp/x", head,
             {pulls_path: (200, [pull(7, head, state="closed")]), dispatch_path: no_dispatch,
              "git/ref/heads/cp/x": (200, {"object": {"sha": head}})}, "true"),
            ("a perf/ head of a fork's pull request is superseded", "push", "refs/heads/perf/x", head,
             {pulls_path: (200, [pull(7, head, repo="someone/cmux")]), dispatch_path: no_dispatch,
              "git/ref/heads/perf/x": (200, {"object": {"sha": head}})}, "true"),
            # A cmux-next dispatch on the branch (#22303) probes this exact tree with no base fallback.
            ("a lane/ head a cmux-next dispatch asked for runs", "push", "refs/heads/lane/x", head,
             {pulls_path: (200, []), dispatch_path: (200, {"total_count": 1, "workflow_runs": [{"id": 9}]}),
              "git/ref/heads/lane/x": (200, {"object": {"sha": head}})}, "false"),
            ("a lane/ push runs when the dispatch lookup fails", "push", "refs/heads/lane/x", head,
             {pulls_path: (200, []), dispatch_path: (502, {})}, "false"),
            ("a lane/ head an open pull request has runs", "push", "refs/heads/lane/x", head,
             {pulls_path: (200, [pull(7, head)]), "git/ref/heads/lane/x": (200, {"object": {"sha": head}})}, "false"),
            ("a lane/ head of an open pull request is still superseded once the branch moved", "push",
             "refs/heads/lane/x", head,
             {pulls_path: (200, [pull(7, head)]), "git/ref/heads/lane/x": (200, {"object": {"sha": newer}})}, "true"),
            ("a lane/ push runs when the pull request lookup fails", "push", "refs/heads/lane/x", head,
             {pulls_path: (502, {})}, "false"),
            ("an other agent branch keeps its own rule", "push", lane, head,
             {pulls_path: (200, []), ref_path: (200, {"object": {"sha": head}})}, "false"),
        ]
        for why, event, ref, sha, routes, want in cases:
            api.reset(routes)
            got = run_check(api, repo, script, event, ref, sha)
            _check(got == want, f"tree-preflight: {why} ({got!r}, want {want!r})")
            if ref in ("refs/heads/feat-cmux-next", "refs/heads/main") or event != "push":
                _check(api.requests == [], f"tree-preflight: {why} without asking the API ({api.requests})")

        # actions/checkout fetches depth 1 in both jobs, so the pin commit is a
        # shallow boundary and git shows it without parents (run 38608893139
        # kept a superseded pin that way). The verdict must come from the API.
        git(repo, "branch", "pin", merge)
        git(repo, "branch", "batch", other)
        with tempfile.TemporaryDirectory() as tmp:
            shallow = shallow_clone(repo, "pin", os.path.join(tmp, "pin"))
            _check(git(shallow, "log", "-1", "--format=%P", merge) == "",
                   "the shallow checkout shows the pin commit without parents")
            api.reset(dict(merge_commit, **{pulls_path: (200, [pull(7, newer)])}))
            got = run_check(api, shallow, script, "push", pin, merge)
            _check(got == "true", f"tree-preflight: a superseded pin in a depth-1 checkout is superseded ({got!r}, want 'true')")
            api.reset(dict(merge_commit, **{pulls_path: (200, [pull(7, newer)]),
                                            deferred_path: (200, {"artifacts": []})}))
            got = run_check(api, shallow, daemon_step["run"], "push", pin, merge, {"KEY": KEY, "RUN_ID": "100"})
            _check(got == "true", f"daemon tests: a superseded pin in a depth-1 checkout skips ({got!r}, want 'true')")
            batch = shallow_clone(repo, "batch", os.path.join(tmp, "batch"))
            api.reset({f"commits/{other}": commit(other, [base, head], "next-batch: stack 3 PRs"),
                       pulls_path: (200, [pull(7, newer)])})
            got = run_check(api, batch, script, "push", f"refs/heads/cmux-tui-pin-{other[:12]}", other)
            _check(got == "false", f"tree-preflight: a depth-1 pin whose API subject is not a pull request merge runs ({got!r})")

        # The daemon-test job re-checks when it gets a Mac, with the run's key.
        moved = dict(merge_commit, **{pulls_path: (200, [pull(7, newer)])})
        other_run = {"artifacts": [{"expired": False, "workflow_run": {"id": 200}}]}
        own_run = {"artifacts": [{"expired": False, "workflow_run": {"id": 100}}]}
        daemon_cases = [
            ("the daemon tests of a superseded pin skip", dict(moved, **{deferred_path: (200, {"artifacts": []})}), "true"),
            ("the daemon tests run when another run deferred the key to this one",
             dict(moved, **{deferred_path: (200, other_run)}), "false"),
            ("this run's own deferral marker does not keep it", dict(moved, **{deferred_path: (200, own_run)}), "true"),
            ("the daemon tests run when the deferral lookup fails", dict(moved, **{deferred_path: (500, {})}), "false"),
            ("the daemon tests of a current pin run", dict(merge_commit, **{pulls_path: (200, [pull(7, head)])}), "false"),
            ("the daemon tests of a merged pull request's pin skip",
             dict(merge_commit, **{pulls_path: (200, [pull(7, head, state="closed", merged=True)]),
                                   deferred_path: (200, {"artifacts": []})}), "true"),
        ]
        for why, routes, want in daemon_cases:
            api.reset(routes)
            got = run_check(api, repo, daemon_step["run"], "push", pin, merge, {"KEY": KEY, "RUN_ID": "100"})
            _check(got == want, f"daemon tests: {why} ({got!r}, want {want!r})")
        api.reset({ref_path: (200, {"object": {"sha": newer}})})
        got = run_check(api, repo, daemon_step["run"], "pull_request_target", lane, head, {"KEY": KEY})
        _check(got == "false" and api.requests == [], f"daemon tests: a pull request run is never superseded ({got!r})")
        # A lane/ head that asks for the daemon tests keeps its run without a pull request.
        git(repo, "commit", "-q", "--allow-empty", "-m", "opt in\n\nCmux-Daemon-Tests: run")
        opted = git(repo, "rev-parse", "HEAD")
        api.reset({f"commits/{opted}/pulls": (200, []), "git/ref/heads/lane/x": (200, {"object": {"sha": opted}})})
        got = run_check(api, repo, script, "push", "refs/heads/lane/x", opted)
        _check(got == "false", f"tree-preflight: a lane/ head with Cmux-Daemon-Tests: run keeps its run ({got!r})")
        _check(not any("/pulls" in r for r in api.requests),
               f"tree-preflight: an opted-in lane/ head asks no pull request lookup ({api.requests})")

        # With CMUX_TUI_REF_REMOTE (the workflow sets it) a branch head is read
        # over git, never GET git/ref, and a moved cp/, lane/ or perf/ branch is
        # superseded before any API lookup.
        for name in ("preflight", "daemon tests"):
            job, step_id = ("tree-preflight", "stale") if name == "preflight" else ("cmux-next-daemon-tests", "current")
            want = "${{ github.server_url }}/${{ github.repository }}.git"
            _check(step(job, step_id).get("env", {}).get("CMUX_TUI_REF_REMOTE") == want,
                   f"{name}: the superseded check reads branch heads over git")
        with tempfile.TemporaryDirectory() as tmp:
            remote = os.path.join(tmp, "remote.git")
            subprocess.run(["git", "init", "-q", "--bare", remote], check=True)
            git(repo, "push", "-q", remote, f"{head}:refs/heads/lane/moved", f"{head}:refs/heads/lane/current",
                f"{head}:refs/heads/codex/current", f"{base}:refs/heads/codex/moved")
            git(remote, "update-ref", "refs/heads/lane/moved", base)
            over_git = {"CMUX_TUI_REF_REMOTE": f"file://{remote}"}
            git_cases = [
                ("a moved lane/ branch is superseded with no API call", "refs/heads/lane/moved", {}, "true", []),
                ("a current lane/ head with an open pull request runs, asking only the pull request",
                 "refs/heads/lane/current", {pulls_path: (200, [pull(7, head)])}, "false", [pulls_path]),
                ("a current lane/ head no pull request has is still superseded", "refs/heads/lane/current",
                 {pulls_path: (200, []), dispatch_path: no_dispatch}, "true", [pulls_path, dispatch_path]),
                ("a deleted lane/ branch still asks its pull requests", "refs/heads/lane/gone",
                 {pulls_path: (200, []), dispatch_path: no_dispatch}, "true", [pulls_path, dispatch_path]),
                ("an other branch at its head runs with no API call", "refs/heads/codex/current", {}, "false", []),
                ("an other branch that moved is superseded with no API call", "refs/heads/codex/moved", {}, "true", []),
                ("a deleted other branch keeps its run", "refs/heads/codex/gone", {}, "false", []),
            ]
            for why, ref, routes, want, asked in git_cases:
                api.reset(routes)
                got = run_check(api, repo, script, "push", ref, head, over_git)
                _check(got == want, f"over git: {why} ({got!r}, want {want!r})")
                paths = [r.split("?")[0].removeprefix(f"/repos/{REPO}/") for r in api.requests]
                _check(paths == asked, f"over git: {why} asks exactly {asked} ({paths})")
            api.reset({})
            got = run_check(api, repo, script, "push", "refs/heads/codex/current", head,
                            {"CMUX_TUI_REF_REMOTE": f"file://{tmp}/missing.git"})
            _check(got == "false", f"over git: an unreadable remote keeps the run ({got!r})")
    api.server.shutdown()


FAKE_CURL = r"""#!/usr/bin/env python3
import sys
url = next(a for a in sys.argv[1:] if a.startswith("http"))
if "/actions/" in url:
    print("{}")
    sys.exit(0)
sys.exit(22)
"""


def check_preflight_consumers():
    # daemon-policy: a superseded push runs no daemon tests, even on a testing ref.
    policy = step("tree-preflight", "daemon-policy")
    _check(str(policy.get("env", {}).get("STALE")) == "${{ steps.stale.outputs.stale }}",
           "daemon-policy reads the superseded verdict")
    with tempfile.TemporaryDirectory() as tmp:
        subprocess.run(["git", "init", "-q", tmp], check=True)
        git(tmp, "commit", "-q", "--allow-empty", "-m", "x\n\nCmux-Daemon-Tests: run")
        for stale, ref, want in (("true", "refs/heads/cmux-tui-pin-0123456789ab", "false"),
                                 ("true", "refs/heads/codex/lane", "false"),
                                 ("false", "refs/heads/cmux-tui-pin-0123456789ab", "true"),
                                 ("false", "refs/heads/codex/lane", "true")):
            output = os.path.join(tmp, "out")
            open(output, "w").close()
            env = {"PATH": os.environ["PATH"], "HOME": tmp, "GITHUB_OUTPUT": output,
                   "EVENT_NAME": "push", "REF": ref, "STALE": stale}
            subprocess.run(["bash", "-e", "-c", policy["run"]], cwd=tmp, env=env, check=True, capture_output=True)
            got = dict(l.split("=", 1) for l in open(output).read().splitlines()).get("daemon_tests")
            _check(got == want, f"daemon-policy with stale={stale} on {ref} -> daemon_tests {got!r}, want {want!r}")

    # inspect: a superseded push neither claims its tree key nor builds.
    inspect = step("tree-preflight", "inspect")
    _check(str(inspect.get("env", {}).get("STALE")) == "${{ steps.stale.outputs.stale }}",
           "inspect reads the superseded verdict")
    sha = git(ROOT, "rev-parse", "HEAD")
    for stale in ("true", "false"):
        with tempfile.TemporaryDirectory() as tmp:
            bin_dir = os.path.join(tmp, "bin")
            os.makedirs(bin_dir)
            curl = os.path.join(bin_dir, "curl")
            with open(curl, "w") as handle:
                handle.write(FAKE_CURL)
            os.chmod(curl, os.stat(curl).st_mode | stat.S_IXUSR)
            output = os.path.join(tmp, "out")
            open(output, "w").close()
            env = {k: v for k, v in os.environ.items() if not k.startswith("ACTIONS_ID_TOKEN")}
            env.update(PATH=f"{bin_dir}:{os.environ['PATH']}", EVENT_NAME="push", REF="refs/heads/codex/lane",
                       SHA=sha, SOURCE_COMMIT=sha, HEAD_REPOSITORY=REPO, REPOSITORY=REPO,
                       SERVER_URL="https://github.invalid", API_URL="https://api.github.invalid", RUN_ID="5",
                       GITHUB_RUN_ID="5", GH_TOKEN="x", GITHUB_OUTPUT=output, RUNNER_TEMP=tmp, STALE=stale)
            result = subprocess.run(["bash", "-e", "-c", inspect["run"]], cwd=ROOT, env=env,
                                    capture_output=True, text=True, timeout=120)
            out = dict(l.split("=", 1) for l in open(output).read().splitlines() if "=" in l)
            claimed = "tree claim:" in result.stderr or "tree-claim authority" in result.stdout
            want_macos = "false" if stale == "true" else "true"
            _check(result.returncode == 0 and out.get("run_macos") == want_macos,
                   f"inspect with stale={stale}: run_macos {out.get('run_macos')!r}, want {want_macos!r} "
                   f"({result.returncode}, {result.stderr.strip()[-200:]})")
            _check(claimed == (stale != "true"),
                   f"inspect with stale={stale}: {'claims' if claimed else 'does not claim'} the tree key")
            _check(out.get("owner_run_id", "") == "", f"inspect with stale={stale} elects no other owner")


def check_wiring():
    all_jobs = jobs()
    preflight = all_jobs["tree-preflight"]
    names = [s.get("id") for s in preflight["steps"]]
    _check(names.index("stale") < names.index("daemon-policy") < names.index("inspect"),
           "tree-preflight decides superseded before the daemon policy and the claim")
    _check(preflight["permissions"].get("pull-requests") == "read",
           "tree-preflight can read a pin's pull request")
    _check(preflight["outputs"].get("stale") == "${{ steps.stale.outputs.stale }}", "tree-preflight exports stale")
    _check("needs.tree-preflight.outputs.stale != 'true'" in str(all_jobs["tree-owner-wait"].get("if", "")),
           "a superseded push skips tree-owner-wait")
    # A cp/, lane/ or perf/ run may turn out superseded and then hands nothing off, so the same-commit
    # election never makes one the owner another run waits for.
    inspect_run = str(step("tree-preflight", "inspect")["run"])
    election = inspect_run[inspect_run.index("same_sha_json="):]
    _check('[[ "$candidate_branch" == cp/* || "$candidate_branch" == lane/* || "$candidate_branch" == perf/* ]] && continue'
           in election, "the same-commit election never elects a cp/, lane/ or perf/ run")

    owner_wait = all_jobs["tree-owner-wait"]
    owner_steps = {s.get("id"): s for s in owner_wait["steps"]}
    _check("read-token" in owner_steps, "owner-wait keeps its bounded status read on the routing App")
    expected_token = "${{ steps.read-token.outputs.token || github.token }}"
    _check(owner_steps["wait"]["env"]["GH_TOKEN"] == expected_token,
           "owner-wait falls back to github.token only when the routing token cannot be minted")
    recheck = next(s for s in owner_wait["steps"] if s.get("id") == "recheck")
    _check(recheck["env"]["GH_TOKEN"] == expected_token,
           "owner hand-off recheck stays off the shared workflow-token budget")
    _check("environment" in owner_wait and owner_wait["environment"] == "ci-routing-agent",
           "owner-wait's protected routing token stays in its environment")
    for name in ("darwin-fallback-plan", "cmux-next-daemon-tests"):
        _check("environment" not in all_jobs[name], f"{name} has no unused routing environment")

    daemon = all_jobs["cmux-next-daemon-tests"]
    steps = daemon["steps"]
    index = next(i for i, s in enumerate(steps) if s.get("id") == "current")
    # The re-check uses the workflow token directly; the routing App is reserved
    # for runner placement and must not spend its Actions quota here.
    before = [s.get("id") or str(s.get("uses", "")).split("@")[0] for s in steps[:index]]
    _check(before == ["actions/checkout"], "the daemon tests re-check immediately after checkout")
    current = steps[index]
    _check(str(current.get("if")) == "github.event_name == 'push'", "only push runs re-check")
    for later in steps[index + 1:]:
        _check("steps.current.outputs.stale != 'true'" in str(later.get("if", "")),
               f"daemon-test step {later.get('name') or later.get('id') or later.get('uses')} is skipped when superseded")
    _check(daemon["permissions"].get("pull-requests") == "read" and daemon["permissions"].get("actions") == "read",
           "the daemon-test job can read pull requests and deferral artifacts")
    _check(daemon["outputs"].get("superseded") == "${{ steps.current.outputs.stale }}",
           "the daemon-test job exports superseded")
    _check(daemon["outputs"].get("key") == "${{ steps.key.outputs.key }}",
           "a skipped key step leaves the key empty, so nothing publishes or marks the tree tested")

    notify = all_jobs["notify-unpublished-tree"]
    report = next(s for s in notify["steps"] if str(s.get("name", "")).startswith("Report the unpublished tree"))
    _check("needs.cmux-next-daemon-tests.outputs.superseded != 'true'" in str(report.get("if", "")),
           "a superseded run does not report its tree as failed to cmux-next")
    hand = next(s for s in notify["steps"] if str(s.get("name", "")).startswith("Hand the key"))
    _check("superseded" not in str(hand.get("if", "")), "a superseded owner still hands its key to a deferred run")


def main():
    check_verdicts()
    check_preflight_consumers()
    check_wiring()
    if FAILURES:
        print(f"{len(FAILURES)} failure(s)")
        sys.exit(1)
    print("PASS: superseded lane and pin pushes skip their builds and daemon tests; promotion refs keep theirs")


if __name__ == "__main__":
    main()
