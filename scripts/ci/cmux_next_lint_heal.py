#!/usr/bin/env python3
"""A red `web lint (fast)` on a feat-cmux-next push gets a fix or a revert pull request within minutes, unasked.

Leo, 2026-11-22, after a webview type error (#49052's `foldsPrompt`, 01:27Z) kept the NEXT nightly red for
hours: "should've been caught and fixed faster. hell, maybe even should've been automatic. how are our fixit type
things for lint errors and random bullshit?"

`web lint (fast)` (cmux-next-web-lint.yml) lints only what each push brought (event.before..sha): the webviews
check (Oxfmt, Oxlint, the type check, the source checks) of the packages the push touched. So its red shows once,
on the culprit's own push, and the next push that touches nothing there is green again: a base red that no later
verdict repeats, which nobody chased (base-red-watch's push pass confirms a red only on its second red run). This
acts on that one red, while it still names its commit:

  judge   in the workflow's `heal` job, after the lint step itself failed (a red Hook tests step never gets here):
          1. culprit: each first-parent commit of the range, oldest first, is linted over its own change
             (`web_lint_prepush.py --base C^ --head C`); the first red one is the culprit. None red: the push's red
             did not repeat (a flake), and nothing opens.
          2. still red: the culprit's change, linted at the branch's tip now. Its reds gone: fixed already; nothing opens.
          3. autofix: the lint's own fixers (`--fix`: Oxfmt, Oxlint --fix, the generators) on the tip. If they
             clear it: the patch is the fix (action=autofix).
          4. revert: the culprit reverted on the tip, linted the same way. Clears it: action=revert. Red, or the revert
             conflicts: nothing opens; the summary says why (the red is not the culprit's alone).
          "Clears" means the culprit's own reds (its diagnostics, else its failed pieces) are gone and no red is
          added that the tip did not already have; other commits' reds still at the tip are theirs.
  open    in the workflow's `heal-open` job, with the routing App's token and no repository code run but this file
          and git: commits the autofix patch, or the culprit's revert, on the tip. The fix is clear (judge verified
          it clears the culprit's own reds at the tip and adds none), so with --direct it is pushed straight to the branch (Leo, 06:01Z: "if the
          fix is clear i think you guys should be able to unilaterally push commits directly."). When that push is
          refused (a ruleset, a tip that moved), the summary keeps GitHub's words and it opens a pull request
          instead, which next-autoland lands at its exact head once its CI is green (cmuxterm-hq
          tools/fleet-reconcilers/next_autoland.py). A core teammate's culprit never goes direct: it opens held
          (post_merge_batch's TEAMMATE_HOLD), and no agent lands it.

Kill switches: the repository variable NEXT_LINT_HEAL=0 skips the heal job; NEXT_LINT_HEAL_DIRECT=0 opens a pull
request every time instead of the direct push.

Usage:
  cmux_next_lint_heal.py judge --before SHA --sha SHA [--tip REF] [--patch FILE] [--github-output F] [--summary F]
  cmux_next_lint_heal.py open --action autofix|revert --culprit SHA --good SHA [--patch FILE] [--dry-run]
  cmux_next_lint_heal.py judge ... --dry-run    judge, then print the pull request `open` would make
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

sys.path.insert(0, str(Path(__file__).resolve().parent))
from post_merge_batch import (  # noqa: E402
    PR_RE,
    SHA_RE,
    TEAMMATE_HOLD,
    TEAMMATES,
    first_parent_range,
    gh_api,
    push_branch,
    start_branch,
    summary,
    write_outputs,
)

ROOT = Path(__file__).resolve().parents[2]
JOB = "web lint (fast)"
BRANCH = "feat-cmux-next"
LINT = ROOT / "scripts" / "web_lint_prepush.py"
# A push run's range is one to a few commits; a dispatch may name a longer one (a nightly's red). Past this many
# commits the range is not searched: each probe is a lint run of minutes.
MAX_PROBES = 12
NOT_LINTED = "refused; nothing was linted"
AUTOFIX, REVERT, NONE = "autofix", "revert", "none"
BOT = ("cmux-next lint heal", "41898282+github-actions[bot]@users.noreply.github.com")

def git(*argv: str, cwd: Path | None = None, check: bool = True) -> str:
    out = subprocess.run(["git", *argv], cwd=cwd or ROOT, capture_output=True, text=True)
    if check and out.returncode:
        raise RuntimeError(f"git {' '.join(argv[:3])}: {(out.stderr or out.stdout).strip()[-400:]}")
    return out.stdout


# A diagnostic line of the webviews check (Oxlint and the type check print `x rule(code): message`; ESLint for web/
# prints `line:col  error  message  rule`), and web_lint_prepush's closing line naming the pieces that failed.
DIAGNOSTIC = re.compile(r"^\s*x (\S+\(\S+\): .+?)\s*$|^\s*\d+:\d+\s+error\s+(.+?)\s*$")
FAILED_PIECES = re.compile(r"web lint failed in [\d.]+s: (.+)$")


@dataclass(frozen=True)
class Lint:
    """One lint run: green, else the reds it printed (each diagnostic's text, with no line number, which moves; and
    `piece: <check>` for each check that failed)."""
    ok: bool
    reds: frozenset = frozenset()

    @classmethod
    def of(cls, run) -> "Lint":
        """A run_lint answer: a Lint, or a bare bool (a red with no detail)."""
        return run if isinstance(run, Lint) else cls(bool(run), frozenset() if run else frozenset({"red"}))

    def signature(self) -> frozenset:
        """What makes this red its own: its diagnostics, else (a source check prints its own way) its failed pieces."""
        found = frozenset(r for r in self.reds if not r.startswith("piece: "))
        return found or self.reds


def reds_of(text: str) -> frozenset:
    reds = set()
    for line in text.splitlines():
        if match := DIAGNOSTIC.match(line):
            reds.add(match.group(1) or match.group(2))
        elif match := FAILED_PIECES.search(line):
            reds.update(f"piece: {piece.strip()}" for piece in match.group(1).split(", "))
    return frozenset(reds)


def lint(base: str, head: str | None, repo: Path | None = None, fix: bool = False) -> Lint:
    """web_lint_prepush.py over base..head (head None: the working tree of repo, after its fixers). Its output goes to
    this job's log, so a red's errors are read there too."""
    argv = [sys.executable, str(LINT), "--repo", str(repo or ROOT), "--base", base]
    argv += ["--fix"] if fix else ["--head", head or "HEAD"]
    print(f"::group::lint {base[:12]}..{(head or 'working tree')[:12]}{' --fix' if fix else ''}", flush=True)
    try:
        done = subprocess.run(argv, cwd=repo or ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        sys.stdout.write(done.stdout)
    finally:
        print("::endgroup::", flush=True)
    refused = next((line for line in done.stdout.splitlines() if NOT_LINTED in line), "")
    if refused:
        raise NotLinted(refused)
    return Lint(done.returncode == 0, reds_of(done.stdout) if done.returncode else frozenset())


def clears(culprit: Lint, tip: Lint, after: Lint) -> bool:
    """A fix or revert is the culprit's answer when the culprit's own reds are gone and it brings no red the tip did
    not already have. Other commits' reds at the tip stay theirs: on the #49052 incident the tip also failed
    check:fixed-waits, check:design-tokens, check:type-scale and an Oxlint rule, none of them #49052's."""
    return after.ok or (not (culprit.signature() & after.reds) and after.reds <= tip.reds)


class NotLinted(RuntimeError):
    """web_lint_prepush.py refused and linted nothing (a sparse checkout, an unreadable range): no verdict, never a red.
    The first local run on the #49052 incident counted such refusals as reds and named a culprit it never linted."""


@dataclass
class Verdict:
    action: str
    reason: str
    culprit: str = ""
    good: str = ""
    patch: str = ""


def parent(sha: str) -> str:
    return git("rev-parse", f"{sha}^1").strip()


def tree_at(tip: str, work: Path) -> Path:
    path = Path(tempfile.mkdtemp(prefix="lint-heal-", dir=work))
    git("-c", "core.hooksPath=/dev/null", "worktree", "add", "--quiet", "--detach", str(path), tip)
    return path


def drop_tree(path: Path) -> None:
    git("worktree", "remove", "--force", str(path), check=False)


def revert_commit(tree: Path, culprit: str) -> bool:
    """Reverts culprit in tree (a worktree of the tip); False when it conflicts."""
    mainline = ["-m", "1"] if len(git("rev-list", "--parents", "-n1", culprit).split()) > 2 else []
    done = subprocess.run(["git", "-c", f"user.name={BOT[0]}", "-c", f"user.email={BOT[1]}", "revert", "--no-edit",
                           *mainline, culprit], cwd=tree, capture_output=True, text=True)
    if done.returncode:
        subprocess.run(["git", "revert", "--abort"], cwd=tree, capture_output=True)
        return False
    return True


def judge(before: str, sha: str, tip: str, *, run_lint: Callable = lint, work: Path | None = None) -> Verdict:
    try:
        return judge_range(before, sha, tip, run_lint=run_lint, work=work)
    except NotLinted as error:
        return Verdict(NONE, f"the lint could not run, so nothing is judged: {error}")


def judge_range(before: str, sha: str, tip: str, *, run_lint: Callable, work: Path | None) -> Verdict:
    commits = first_parent_range(before, sha, cwd=ROOT)
    if not commits:
        return Verdict(NONE, f"no first-parent commits in {before[:12]}..{sha[:12]}")
    if len(commits) > MAX_PROBES:
        return Verdict(NONE, f"{len(commits)} commits in {before[:12]}..{sha[:12]}, more than {MAX_PROBES} to probe")
    culprit, red = "", Lint(True)
    for commit in commits:
        red = Lint.of(run_lint(parent(commit), commit, None, False))
        if not red.ok:
            culprit = commit
            break
    if not culprit:
        return Verdict(NONE, f"no commit of {before[:12]}..{sha[:12]} is red linted alone: the push's red did not repeat")
    good = parent(culprit)
    at_tip = Lint.of(run_lint(good, tip, None, False))
    if at_tip.ok or not (red.signature() & at_tip.reds):
        return Verdict(NONE, f"`{culprit[:12]}`'s reds are gone at the tip `{tip[:12]}`: fixed already", culprit, good)
    work = work or Path(tempfile.mkdtemp(prefix="lint-heal-"))
    tree = tree_at(tip, work)
    try:
        if clears(red, at_tip, Lint.of(run_lint(good, None, tree, True))):
            patch = git("diff", "--binary", cwd=tree)
            if patch.strip():
                return Verdict(AUTOFIX, f"the lint's fixers clear `{culprit[:12]}`'s reds at the tip and add none", culprit, good, patch)
    finally:
        drop_tree(tree)
    tree = tree_at(tip, work)
    try:
        if not revert_commit(tree, culprit):
            return Verdict(NONE, f"reverting `{culprit[:12]}` conflicts with the tip `{tip[:12]}`; left to its owner",
                           culprit, good)
        reverted = git("rev-parse", "HEAD", cwd=tree).strip()
        if clears(red, at_tip, Lint.of(run_lint(good, reverted, None, False))):
            return Verdict(REVERT, f"`{culprit[:12]}` is the first red commit, and reverting it on the tip clears its "
                                   f"reds and adds none",
                           culprit, good)
        return Verdict(NONE, f"the tip stays red with `{culprit[:12]}` reverted: the red is not its alone", culprit, good)
    finally:
        drop_tree(tree)


# ---------------------------------------------------------------------------- the pull request


def culprit_owner(repo: str, culprit: str, pr: str, api=gh_api) -> str:
    """A core teammate's login when one wrote the culprit (its pull request, or a direct push's commit), else "".
    Unreadable counts as a teammate: a held revert costs a glance, an agent landing a teammate's revert breaks the
    rule."""
    try:
        if pr:
            login = ((api(f"repos/{repo}/pulls/{pr}") or {}).get("user") or {}).get("login") or ""
        else:
            login = ((api(f"repos/{repo}/commits/{culprit}") or {}).get("author") or {}).get("login") or ""
    except RuntimeError:
        return "the culprit's author (unread)"
    return login if login in TEAMMATES else ""


def pull_request(action: str, culprit: str, good: str, subject: str, *, owner: str, run_url: str, branch: str) -> dict:
    match = PR_RE.search(subject)
    pr = match.group(1) if match else ""
    who = f"#{pr}" if pr else f"`{culprit[:12]}` (a direct push)"
    seen = (f"`{JOB}` went red on {branch} at {who} (`{culprit}`; green at its parent `{good[:12]}`), "
            f"found by {run_url}.")
    if action == AUTOFIX:
        head = f"heal/web-lint-{culprit[:12]}"
        title = f"web lint fix for {who.split(' ')[0]} (`{JOB}` red on {branch})"
        body = [f"Fixes base red: cmux-next web lint / {JOB}. {seen}",
                "The lint's own fixers (`scripts/web_lint_prepush.py --fix`) clear that change's reds at the tip and add "
                "none; this is their patch, nothing else."]
    else:
        head = f"revert/pr-{pr}" if pr else f"revert/lint-{culprit[:12]}"
        title = f'Revert "{subject}" ({JOB} red on {branch})'
        body = [f"Reverts {who}: {seen}",
                "The lint's fixers cannot fix it (a type error is not mechanical), and reverting it clears its reds at "
                "the tip and adds none. The base-break rule restores the base first: land this, then reland the change with its fix."]
        if owner:
            body.insert(0, TEAMMATE_HOLD.format(login=owner))
    land = (f"This is {owner}'s to land or close; no agent lands it." if owner else
            "next-autoland lands it at its exact head once its CI is green; nothing here merges it.")
    body += [land + " If the red is not this change's, close this and say so.",
             "Opened by cmux-next-web-lint.yml heal (scripts/ci/cmux_next_lint_heal.py)."]
    return {"head": head, "base": branch, "title": title, "body": "\n\n".join(body), "pr": pr}


def push_once(push_url: str, refspec: str) -> None:
    """One push with GitHub's whole answer kept: a ruleset refusal names its rule ("GH013: Repository rule
    violations found ...") near the top, which post_merge_batch's 400-character tail drops."""
    done = subprocess.run(["git", "push", push_url, refspec], cwd=ROOT, capture_output=True, text=True)
    if done.returncode:
        lines = [line for line in (done.stderr or done.stdout).splitlines() if not line.startswith("hint:")]
        raise RuntimeError("\n".join(lines).replace(push_url, "<push url>")[:2000])


def push_direct(push_url: str, branch: str, run=push_once) -> tuple[bool, str]:
    """Pushes HEAD (the tip plus one fix or revert commit) straight to branch, never forced: a tip that moved since
    refuses it as a non-fast-forward. Leo, 2026-11-22 06:01Z: "if the fix is clear i think you guys should be able
    to unilaterally push commits directly." A refusal (a ruleset, a moved tip) is returned word for word and the
    caller opens the pull request instead; nothing retries the push another way."""
    try:
        run(push_url, f"HEAD:refs/heads/{branch}")
    except RuntimeError as error:
        return False, str(error)
    return True, ""


def cmd_judge(args: argparse.Namespace) -> int:
    for name in ("before", "sha"):
        if not SHA_RE.match(getattr(args, name)):
            raise SystemExit(f"--{name} must be 40 hex")
    tip = git("rev-parse", args.tip).strip()
    verdict = judge(args.before, args.sha, tip)
    if verdict.patch and args.patch:
        Path(args.patch).write_text(verdict.patch)
    summary(args.summary, f"### {JOB} heal: {verdict.action}\n\n{verdict.reason}.")
    write_outputs(args.github_output, {"action": verdict.action, "culprit": verdict.culprit, "good": verdict.good,
                                       "tip": tip})
    if args.dry_run and verdict.action != NONE:
        show(verdict.action, verdict.culprit, verdict.good, args)
    return 0


def show(action: str, culprit: str, good: str, args: argparse.Namespace) -> None:
    subject = git("log", "-1", "--format=%s", culprit).strip()
    pr = PR_RE.search(subject)
    owner = culprit_owner(args.repo, culprit, pr.group(1) if pr else "")
    made = pull_request(action, culprit, good, subject, owner=owner, run_url=args.run_url, branch=args.branch)
    print(f"Would open {args.repo} {made['head']} -> {made['base']}\ntitle: {made['title']}\n\n{made['body']}")


def cmd_open(args: argparse.Namespace) -> int:
    if not (SHA_RE.match(args.culprit) and SHA_RE.match(args.good)) or args.action not in (AUTOFIX, REVERT):
        raise SystemExit("open needs --action autofix|revert, --culprit and --good (40 hex)")
    if args.dry_run:
        show(args.action, args.culprit, args.good, args)
        return 0
    subject = git("log", "-1", "--format=%s", args.culprit).strip()
    match = PR_RE.search(subject)
    owner = culprit_owner(args.repo, args.culprit, match.group(1) if match else "")
    made = pull_request(args.action, args.culprit, args.good, subject, owner=owner, run_url=args.run_url,
                        branch=args.branch)
    open_ = gh_api(f"repos/{args.repo}/pulls?state=open&head={args.repo.split('/')[0]}:{made['head']}") or []
    if open_:
        summary(args.summary, f"Already open: {open_[0]['html_url']}")
        return 0
    git("checkout", "--quiet", "--detach", args.tip)
    if args.action == AUTOFIX:
        done = subprocess.run(["git", "apply", "--3way", args.patch], cwd=ROOT, capture_output=True, text=True)
        if done.returncode:
            summary(args.summary, f"The fix patch no longer applies at the tip: {done.stderr.strip()[-300:]}")
            return 0
        git("-c", f"user.name={BOT[0]}", "-c", f"user.email={BOT[1]}", "commit", "--quiet", "-am",
            f"web lint fix for {made['pr'] and '#' + made['pr'] or args.culprit[:12]}")
    elif not revert_commit(ROOT, args.culprit):
        summary(args.summary, f"Reverting `{args.culprit[:12]}` conflicts with the tip now; left to its owner.")
        return 0
    refused = ""
    if args.direct and not owner:
        pushed, refused = push_direct(args.push_url, args.branch)
        if pushed:
            sha = git("rev-parse", "HEAD").strip()
            summary(args.summary, f"Pushed `{sha[:12]}` straight to {args.branch} (a clear {args.action}, verified "
                                  f"green on the tip): {made['title']}")
            write_outputs(args.github_output, {"pushed": sha})
            return 0
        summary(args.summary, f"The direct push to {args.branch} was refused; opening a pull request instead. "
                              f"GitHub said:\n\n```\n{refused}\n```")
        write_outputs(args.github_output, {"direct_refused": refused.replace(chr(10), ' ')[:400]})
        made["body"] += f"\n\nA direct push to {args.branch} was tried first and refused: `{refused[:300]}`"
    start_branch(args.repo, made["head"], git("rev-parse", "HEAD^").strip())
    push_branch(args.push_url, f"+HEAD:refs/heads/{made['head']}")
    created = gh_api(f"repos/{args.repo}/pulls", method="POST",
                     fields={k: made[k] for k in ("head", "base", "title", "body")})
    summary(args.summary, f"Opened {created['html_url']}")
    write_outputs(args.github_output, {"url": created["html_url"]})
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = parser.add_subparsers(dest="cmd", required=True)
    server = os.environ.get("GITHUB_SERVER_URL", "https://github.com")
    repo = os.environ.get("GITHUB_REPOSITORY", "manaflow-ai/cmux")
    run_url = f"{server}/{repo}/actions/runs/{os.environ.get('GITHUB_RUN_ID', '')}"

    def common(p: argparse.ArgumentParser) -> None:
        p.add_argument("--repo", default=repo)
        p.add_argument("--branch", default=BRANCH)
        p.add_argument("--tip", default=f"origin/{BRANCH}")
        p.add_argument("--run-url", default=run_url)
        p.add_argument("--patch", default="")
        p.add_argument("--github-output", default=os.environ.get("GITHUB_OUTPUT"))
        p.add_argument("--summary", default=os.environ.get("GITHUB_STEP_SUMMARY"))
        p.add_argument("--dry-run", action="store_true", help="open nothing; print the pull request it would open")

    p = sub.add_parser("judge")
    common(p)
    p.add_argument("--before", required=True)
    p.add_argument("--sha", required=True)
    p.set_defaults(func=cmd_judge)

    p = sub.add_parser("open")
    common(p)
    p.add_argument("--action", required=True)
    p.add_argument("--culprit", required=True)
    p.add_argument("--good", required=True)
    p.add_argument("--push-url", default="origin")
    p.add_argument("--direct", action="store_true",
                   help="push a clear fix (not a teammate's culprit) straight to the branch; a refusal opens the PR")
    p.set_defaults(func=cmd_open)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
