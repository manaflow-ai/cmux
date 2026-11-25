#!/usr/bin/env python3
"""fixit-handoff: a base or nightly type check that fixit-compile could not fix is reverted, not left for a fix agent.

    fixit_handoff.py signal [--dir DIR]                     `nofix=true|false` for $GITHUB_OUTPUT (the red's record)
    fixit_handoff.py find --red SHA --check web|webviews    the culprit, and whether its revert on the tip is green
    fixit_handoff.py land --culprit SHA --tip SHA --clear true|false ...   push the revert, or open its pull request

Leo, 2026-11-22: "should've been caught and fixed faster. hell, maybe even should've been automatic. how are our fixit
type things for lint errors and random bullshit?" and, at 06:01Z: "if the fix is clear i think you guys should be able
to unilaterally push commits directly." #49052 broke the webview type check on feat-cmux-next; fixit-compile saw the
error from 02:10Z in the nightly, logged "the red is left for a fix agent", and nothing picked it up until a human
pushed the fix at 05:06Z.

fixit_compile.py now writes a record (FIXIT_HANDOFF_OUT, else $RUNNER_TEMP/fixit-handoff) when a type check fails with
no machine fix. `signal` reads it in the job that ran the check; a separate job with only actions: write dispatches
.github/workflows/fixit-handoff.yml on feat-cmux-next (the nightly, the post-merge batch's web suite). There:

  find  (read-only job) the tip first: green means someone fixed it, and nothing happens. Otherwise, from the red
        commit back along feat-cmux-next's first parents, the type check at 1, 2, 4, ... commits back until one is
        green (at most --max-back), then a bisect between: the culprit is the first red commit after the last green.
        Then the culprit's revert on the tip, checked again. `clear` = one commit (not a merge), the revert applies
        cleanly and the type check is green with it.
  land  (the job with the routing App's token) commits the same revert on the same tip. Clear, not a teammate's
        (post_merge_batch.TEAMMATES) and FIXIT_HANDOFF not `pr`: a plain push to the branch (never forced, never
        retried another way). A refused push (a ruleset, a moved tip) is quoted in the summary with the rulesets
        that cover the branch, and the revert goes to its own pull request instead. Not clear, or a teammate's: the
        revert's own pull request (revert/pr-N, the post-merge batch's name, so the two never open two), held with
        TEAMMATE_HOLD for a teammate, for next-autoland to land pinned. A revert that conflicts opens nothing.

FIXIT_HANDOFF=0 (repository variable vars.FIXIT_HANDOFF) turns the whole hand-off off; `pr` keeps it but never pushes
to the branch directly.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import post_merge_batch as pmb  # noqa: E402

BRANCH = "feat-cmux-next"
WORKFLOW = "fixit-handoff.yml"
# The type check each check name runs in a probe worktree, from the directory named: (directory, setup, check).
# The setup (an install: a probe commit can change the lockfile; webviews also writes its gitignored page strings,
# as fast_gate_webviews_checks) is kept apart from the check, so a download that fails is never read as a red type
# check: a setup that fails twice stops the search with no culprit (ProbeError).
CHECKS = {
    "webviews": ("webviews", "bun install --frozen-lockfile >/dev/null && "
                             "{ [ ! -f scripts/pages/gen-strings.mjs ] || bun scripts/pages/gen-strings.mjs --best-effort "
                             ">/dev/null 2>&1 || true; }",
                 "bun run typecheck"),
    "web": ("web", "bun install --frozen-lockfile >/dev/null", "bun run typecheck"),
}
MAX_BACK = 64
BOT = ("cmux fixit-handoff", "41898282+github-actions[bot]@users.noreply.github.com")
RULESET_REFUSAL = re.compile(r"GH0\d\d|rule violation|protected branch|ruleset", re.I)


def mode() -> str:
    """FIXIT_HANDOFF: 0 (off), pr (a pull request only), else on."""
    value = (os.environ.get("FIXIT_HANDOFF") or "").strip().lower()
    return "off" if value in {"0", "off", "false"} else "pr" if value == "pr" else "on"


def handoff_dir() -> Path | None:
    if os.environ.get("FIXIT_HANDOFF_OUT"):
        return Path(os.environ["FIXIT_HANDOFF_OUT"])
    if os.environ.get("RUNNER_TEMP"):
        return Path(os.environ["RUNNER_TEMP"]) / "fixit-handoff"
    return None


def git(*argv: str, cwd: Path) -> str:
    return pmb.git(*argv, cwd=cwd)


def say(text: str, summary_path: str | None = None) -> None:
    pmb.summary(summary_path, f"fixit-handoff: {text}")


# ---- find -----------------------------------------------------------------------------------------------------------

class ProbeError(RuntimeError):
    """A probe whose setup (the install) failed: no verdict on that commit, so no culprit is chosen."""


class Prober:
    """One worktree the type check runs in, moved from commit to commit (node_modules stays, ignored by git clean)."""

    def __init__(self, repo: Path, check_dir: str, command: str, setup: str = ""):
        self.repo, self.check_dir, self.command, self.setup = repo, check_dir, command, setup
        self.holder = Path(tempfile.mkdtemp(prefix="fixit-handoff-"))
        self.tree = self.holder / "tree"
        self.results: dict[str, bool] = {}
        self.log: list[str] = []

    def __enter__(self) -> "Prober":
        return self

    def __exit__(self, *_exc) -> None:
        subprocess.run(["git", "-C", str(self.repo), "worktree", "remove", "--force", str(self.tree)],
                       capture_output=True)
        shutil.rmtree(self.holder, ignore_errors=True)

    def _goto(self, sha: str) -> None:
        if not self.tree.exists():
            git("worktree", "add", "--quiet", "--detach", str(self.tree), sha, cwd=self.repo)
        else:
            git("checkout", "--quiet", "--force", "--detach", sha, cwd=self.tree)
            git("clean", "-fdq", cwd=self.tree)

    def run(self) -> bool:
        """True green, False a red type check. The setup runs first, twice at most; a setup that still fails raises
        ProbeError instead of counting as red (a failed download must not name a healthy commit the culprit)."""
        cwd = self.tree / self.check_dir
        if self.setup:
            for attempt in (1, 2):
                setup = subprocess.run(["bash", "-c", self.setup], cwd=cwd, capture_output=True, text=True)
                if setup.returncode == 0:
                    break
            else:
                head = git("rev-parse", "HEAD", cwd=self.tree).strip()
                tail = (setup.stderr + setup.stdout).strip()[-400:]
                raise ProbeError(f"the type check's setup failed twice at {head[:12]} (exit {setup.returncode}): "
                                 f"{tail}")
        out = subprocess.run(["bash", "-c", self.command], cwd=cwd, capture_output=True, text=True)
        return out.returncode == 0

    def green(self, sha: str) -> bool:
        if sha not in self.results:
            self._goto(sha)
            self.results[sha] = self.run()
            self.log.append(f"{sha[:12]} {'green' if self.results[sha] else 'red'}")
            print(f"fixit-handoff: type check at {sha[:12]}: {'green' if self.results[sha] else 'red'}", flush=True)
        return self.results[sha]

    def revert_green(self, tip: str, culprit: str) -> tuple[bool, bool]:
        """(applies, green): the culprit's revert committed on the tip, then the type check."""
        self._goto(tip)
        parents = git("rev-list", "--parents", "-n1", culprit, cwd=self.tree).split()[1:]
        mainline = ["-m", "1"] if len(parents) > 1 else []
        done = subprocess.run(["git", "-c", f"user.name={BOT[0]}", "-c", f"user.email={BOT[1]}", "revert", "--no-edit",
                               *mainline, culprit], cwd=self.tree, capture_output=True, text=True)
        if done.returncode:
            subprocess.run(["git", "revert", "--abort"], cwd=self.tree, capture_output=True)
            return False, False
        return True, self.run()


def find_culprit(prober: Prober, chain: list[str]) -> tuple[str, str] | None:
    """(good, culprit) along CHAIN (the red commit first, then its first parents, newest to oldest): the newest green
    found 1, 2, 4, ... back, then a bisect to the first red after it. None: nothing green within CHAIN."""
    red_at, step = 0, 1
    good_at = None
    while step < len(chain):
        if prober.green(chain[step]):
            good_at = step
            break
        red_at, step = step, step * 2
    if good_at is None:
        last = len(chain) - 1
        if last <= red_at or not prober.green(chain[last]):
            return None
        good_at = last
    # chain[red_at] is red, chain[good_at] green; narrow to adjacent.
    while good_at - red_at > 1:
        mid = (red_at + good_at) // 2
        if prober.green(chain[mid]):
            good_at = mid
        else:
            red_at = mid
    return chain[good_at], chain[red_at]


def pr_number(subject: str) -> str:
    match = pmb.PR_RE.search(subject)
    return match.group(1) if match else ""


def find(repo: Path, branch_tip: str, red: str, check: str, command: str | None, max_back: int,
         setup: str | None = None) -> dict:
    """The culprit (see find_culprit) and its revert's verdict. A probe that cannot run (ProbeError) names nothing."""
    check_dir, default_setup, default_cmd = CHECKS[check]
    if setup is None:
        setup = "" if command else default_setup  # a custom --check-cmd brings its own setup
    result = {"culprit": "", "good": "", "tip": branch_tip, "pr": "", "subject": "", "clear": "false",
              "verified": "false", "reason": ""}
    with Prober(repo, check_dir, command or default_cmd, setup) as prober:
        try:
            return _find(repo, branch_tip, red, check, max_back, prober, result)
        except ProbeError as err:
            result.update(culprit="", good="", pr="", subject="", clear="false", verified="false",
                          reason=f"a probe could not run, so no culprit is named: {err}",
                          probes=", ".join(prober.log))
            return result


def _find(repo: Path, branch_tip: str, red: str, check: str, max_back: int, prober: Prober, result: dict) -> dict:
    if prober.green(branch_tip):
        result["reason"] = f"the {check} type check is green at the tip {branch_tip[:12]}: already fixed"
        return result
    on_branch = subprocess.run(["git", "merge-base", "--is-ancestor", red, branch_tip], cwd=repo).returncode == 0
    start = red if on_branch else branch_tip
    if start != branch_tip and prober.green(start):
        start = branch_tip  # the reported red commit checks green here: start from the tip, which is red
    chain = git("rev-list", "--first-parent", f"--max-count={max_back + 1}", start, cwd=repo).split()
    found = find_culprit(prober, chain)
    if found is None:
        result["reason"] = f"no green {check} type check in the {len(chain) - 1} commits before {chain[0][:12]}"
        return result
    good, culprit = found
    subject = git("log", "-1", "--format=%s", culprit, cwd=repo).strip()
    parents = git("rev-list", "--parents", "-n1", culprit, cwd=repo).split()[1:]
    applies, green = prober.revert_green(branch_tip, culprit)
    result.update(culprit=culprit, good=good, pr=pr_number(subject), subject=subject,
                  verified="true" if green else "false")
    if len(parents) > 1:
        result["reason"] = f"{culprit[:12]} is a merge commit: not a one-commit revert"
    elif not applies:
        result["reason"] = f"reverting {culprit[:12]} conflicts with the tip {branch_tip[:12]}"
    elif not green:
        result["reason"] = f"the {check} type check is still red with {culprit[:12]} reverted on the tip"
    else:
        result["clear"] = "true"
        result["reason"] = (f"{culprit[:12]} is the first red commit after {good[:12]}; its revert on the tip "
                            f"{branch_tip[:12]} is green")
    result["applies"] = "true" if applies else "false"
    result["probes"] = ", ".join(prober.log)
    return result


def cmd_find(args: argparse.Namespace) -> int:
    repo = Path(args.repo_dir).resolve()
    tip = git("rev-parse", args.tip or "HEAD", cwd=repo).strip()
    red = git("rev-parse", args.red or tip, cwd=repo).strip()
    if mode() == "off":
        say("FIXIT_HANDOFF=0: off", args.summary)
        pmb.write_outputs(args.github_output, {"culprit": ""})
        return 0
    result = find(repo, tip, red, args.check, args.check_cmd, args.max_back)
    say(f"{args.check} type check red at {red[:12]}: {result['reason']}", args.summary)
    if result.get("probes"):
        say(f"probes: {result['probes']}", args.summary)
    pmb.write_outputs(args.github_output, {k: v for k, v in result.items() if k != "probes"})
    print(json.dumps(result, sort_keys=True))
    return 0


# ---- land -----------------------------------------------------------------------------------------------------------

def redact(text: str, token: str) -> str:
    text = re.sub(r"x-access-token:[^@\s]+@", "x-access-token:***@", text)
    return text.replace(token, "***") if token else text


def rulesets(repo: str, branch: str, api=pmb.gh_api) -> list[str]:
    """The rulesets that cover BRANCH, by name, with their rule types (best effort: a read that fails says so)."""
    try:
        rules = api(f"repos/{repo}/rules/branches/{branch}") or []
    except RuntimeError as err:
        return [f"(the branch's rules could not be read: {str(err)[-200:]})"]
    by_id: dict[int, list[str]] = {}
    for rule in rules:
        by_id.setdefault(rule.get("ruleset_id"), []).append(rule.get("type", "?"))
    names = []
    for rid, types in by_id.items():
        try:
            name = (api(f"repos/{repo}/rulesets/{rid}") or {}).get("name") or "?"
        except RuntimeError:
            name = "?"
        names.append(f"{name} (ruleset {rid}: {', '.join(sorted(set(types)))})")
    return names


def direct_push(push_url: str, branch: str, cwd: Path, run=subprocess.run) -> tuple[bool, str]:
    """One plain push of HEAD to the branch: never forced, never retried."""
    out = run(["git", "push", "--porcelain", push_url, f"HEAD:refs/heads/{branch}"], cwd=cwd, capture_output=True,
              text=True)
    return out.returncode == 0, (out.stderr + out.stdout).strip()


def revert_body(args: argparse.Namespace, author: str, who: str, pushed_refusal: str) -> str:
    land = (f"This revert is {author}'s to land or close; no agent lands it." if author else
            "The base-break rule restores the base first: next-autoland lands this pinned; reland the change with "
            "its fix.")
    verified = (f"Its revert on the tip `{args.tip[:12]}` makes the {args.check} type check green."
                if args.verified == "true" else
                f"The {args.check} type check was not green with only this revert on the tip `{args.tip[:12]}` "
                f"({args.reason}); look before landing.")
    parts = ([pmb.TEAMMATE_HOLD.format(login=author)] if author else []) + [
        f"Reverts {who} (`{args.culprit}`): the {args.check} type check went red on {args.branch} with it "
        f"(last green `{args.good[:12] or '?'}`), and fixit-compile found no machine fix ({args.origin or 'run unknown'}). "
        + verified,
        land + " If the red is not this change's, close this and say so.",
    ]
    if pushed_refusal:
        parts.append("The direct push of this revert to the branch was refused:\n\n```\n" + pushed_refusal + "\n```")
    parts.append("Opened by .github/workflows/fixit-handoff.yml (scripts/ci/oops/fixit_handoff.py land).")
    return "\n\n".join(parts)


def culprit_owner(repo: str, culprit: str, pr: str, api=pmb.gh_api) -> str:
    """The teammate whose change the culprit is ("" when it is nobody's on TEAMMATES), so their revert opens held.
    With a PR number, its author (post_merge_batch.merged_by_teammate). Without one (a commit pushed straight to the
    branch, no `(#N)`), the commit's own GitHub author and committer. A commit whose author cannot be read or has no
    GitHub login counts as a teammate's: a held revert costs a human glance, a pushed one can break the rule."""
    if pr:
        return pmb.merged_by_teammate(repo, pr, api=api)
    try:
        commit = api(f"repos/{repo}/commits/{culprit}") or {}
    except RuntimeError:
        return "the culprit's author (unread)"
    author = (commit.get("author") or {}).get("login") or ""
    committer = (commit.get("committer") or {}).get("login") or ""
    for login in (author, committer):
        if login in pmb.TEAMMATES:
            return login
    return "" if author else "the culprit's author (unknown)"


def land(args: argparse.Namespace, api=pmb.gh_api, push=direct_push, start=pmb.start_branch,
         push_branch=pmb.push_branch) -> dict:
    """Commit the revert on the tested tip, then push it or open its pull request. Returns what happened."""
    cwd = Path(args.repo_dir).resolve()
    out = {"action": "none", "url": "", "pushed": "", "refusal": ""}
    if mode() == "off" or not args.culprit:
        out["note"] = "off" if args.culprit else "no culprit"
        return out
    subject = git("log", "-1", "--format=%s", args.culprit, cwd=cwd).strip()
    pr = pr_number(subject)
    who = f"#{pr}" if pr else f"`{args.culprit[:12]}`"
    branch_name = f"revert/pr-{pr}" if pr else f"revert/fixit-{args.culprit[:12]}"
    owner = args.repo.split("/")[0]
    existing = api(f"repos/{args.repo}/pulls?state=open&head={owner}:{branch_name}") or []
    if existing:
        out.update(action="exists", url=existing[0].get("html_url", ""))
        return out
    git("checkout", "--quiet", "--force", "--detach", args.tip, cwd=cwd)
    parents = git("rev-list", "--parents", "-n1", args.culprit, cwd=cwd).split()[1:]
    mainline = ["-m", "1"] if len(parents) > 1 else []
    done = subprocess.run(["git", "-c", f"user.name={BOT[0]}", "-c", f"user.email={BOT[1]}", "revert", "--no-edit",
                           *mainline, args.culprit], cwd=cwd, capture_output=True, text=True)
    if done.returncode:
        subprocess.run(["git", "revert", "--abort"], cwd=cwd, capture_output=True)
        out.update(action="conflict", note=f"reverting {args.culprit[:12]} conflicts with {args.tip[:12]}")
        return out
    message = git("log", "-1", "--format=%B", "HEAD", cwd=cwd).rstrip()
    message += (f"\n\nfixit-handoff: the {args.check} type check went red on {args.branch} at {who}; fixit-compile found "
                f"no machine fix. {args.reason}. {args.origin}".rstrip())
    git("-c", f"user.name={BOT[0]}", "-c", f"user.email={BOT[1]}", "commit", "--quiet", "--amend", "-m", message,
        cwd=cwd)
    author = culprit_owner(args.repo, args.culprit, pr, api=api)
    refusal = ""
    if args.clear == "true" and not author and mode() == "on":
        ok, text = push(args.push_url, args.branch, cwd)
        text = redact(text, os.environ.get("PUSH_TOKEN", ""))
        if ok:
            out.update(action="pushed", pushed=git("rev-parse", "HEAD", cwd=cwd).strip())
            return out
        refusal = text[-3000:]
        if RULESET_REFUSAL.search(text):
            names = rulesets(args.repo, args.branch, api=api)
            refusal += "\n\nRulesets on " + args.branch + ": " + ("; ".join(names) or "none read")
        out["refusal"] = refusal
    title = f'Revert "{subject}" (fixit-handoff: {args.check} type check red on {args.branch})'
    start(args.repo, branch_name, args.tip)
    push_branch(args.push_url, f"+HEAD:refs/heads/{branch_name}")
    created = api(f"repos/{args.repo}/pulls", method="POST",
                  fields={"head": branch_name, "base": args.branch, "title": title,
                          "body": revert_body(args, author, who, refusal)}) or {}
    out.update(action="held" if author else "pr", url=created.get("html_url", ""), author=author)
    return out


def cmd_land(args: argparse.Namespace) -> int:
    out = land(args)
    action = out["action"]
    if action == "pushed":
        say(f"pushed the revert of `{args.culprit[:12]}` to {args.branch} directly: `{out['pushed'][:12]}` "
            f"({args.reason})", args.summary)
    elif action in {"pr", "held"}:
        if out["refusal"]:
            say(f"the direct push to {args.branch} was refused:\n\n```\n{out['refusal']}\n```", args.summary)
        say(f"revert pull request{' (held: ' + out.get('author', '') + ')' if action == 'held' else ''}: {out['url']}",
            args.summary)
    elif action == "exists":
        say(f"a revert pull request is already open: {out['url']}", args.summary)
    else:
        say(f"nothing pushed or opened: {out.get('note', action)}", args.summary)
    pmb.write_outputs(args.github_output, {k: str(v) for k, v in out.items() if k != "refusal"})
    return 0


# ---- signal ---------------------------------------------------------------------------------------------------------

def cmd_signal(args: argparse.Namespace) -> int:
    where = Path(args.dir) if args.dir else handoff_dir()
    records = sorted(where.glob("*.json")) if where and where.is_dir() else []
    print(f"nofix={'true' if records else 'false'}")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("signal")
    p.add_argument("--dir")
    p.set_defaults(func=cmd_signal)

    def common(p: argparse.ArgumentParser) -> None:
        p.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", "manaflow-ai/cmux"))
        p.add_argument("--repo-dir", default=".")
        p.add_argument("--branch", default=BRANCH)
        p.add_argument("--check", choices=sorted(CHECKS), default="webviews")
        p.add_argument("--github-output", default=os.environ.get("GITHUB_OUTPUT"))
        p.add_argument("--summary", default=os.environ.get("GITHUB_STEP_SUMMARY"))

    p = sub.add_parser("find")
    common(p)
    p.add_argument("--red", default="")
    p.add_argument("--tip", default="")
    p.add_argument("--check-cmd", default=None, help="the type check (bash), run in the check's directory")
    p.add_argument("--max-back", type=int, default=MAX_BACK)
    p.set_defaults(func=cmd_find)

    p = sub.add_parser("land")
    common(p)
    p.add_argument("--culprit", default="")
    p.add_argument("--tip", required=True)
    p.add_argument("--good", default="")
    p.add_argument("--clear", default="false")
    p.add_argument("--verified", default="false")
    p.add_argument("--reason", default="")
    p.add_argument("--origin", default="")
    p.add_argument("--push-url", default="origin")
    p.set_defaults(func=cmd_land)

    args = parser.parse_args(argv)
    pmb.API_WAIT_BUDGET["seconds"] = 300.0
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
