#!/usr/bin/env python3
"""package_deps_heal.py: after a feat-cmux-next push, turn an undeclared local import into a fix pull request.

    scripts/cmux-next/package_deps_heal.py plan --out DIR [--repo .] [--head HEAD] [--github-repo OWNER/REPO]
                                               [--run-url URL]
    scripts/cmux-next/package_deps_heal.py open --out DIR [--repo .] [--remote origin] [--base feat-cmux-next]

A push that skips the pre-push hook (a direct push, --no-verify) can add `import X` to a target that does not
declare X in Packages/macOS/CmuxNext/Package.swift. CI's "Package dependency lists sorted" step then goes red on
every pull request after it (2026-10-29: a63986a4 and e875485c, repaired by hand in #27173 and #27219).

`plan` runs check-package-dependency-lists.py's checks on the checkout. Green: it prints `red=false` and changes
nothing. Red: it declares each undeclared import (--fix-imports, marked lists put back in order) in the working
tree, finds the commit that brought each import in, and writes the pull request to DIR: `branch`
(autofix/package-deps-<digest of what it repairs>, so a later push with the same gap finds the same branch and
opens no second pull request), `title`, `body.md` (it names the offending commits), `commit-message` and `labels`.
It prints `red`, `fixable` and `branch` lines for $GITHUB_OUTPUT. A red it cannot repair from Package.swift alone
(a stale IMPORT_BASELINE line, alone or beside a fixable import) is `fixable=false`: nothing is opened.

`open` commits the planned tree on that branch, pushes the branch (never feat-cmux-next) and opens the pull
request with `gh`, unless one is already open from that branch. cmux-next-package-deps-heal.yml runs both.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
MANIFEST = "Packages/macOS/CmuxNext/Package.swift"
BASE = "feat-cmux-next"
LABELS = ("risk:low",)
CHECK_STEP = "Package dependency lists sorted"
BRANCH_PREFIX = "autofix/package-deps-"


def load_check():
    spec = importlib.util.spec_from_file_location("check_package_dependency_lists",
                                                  HERE / "check-package-dependency-lists.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def git(repo: Path, *args: str, check: bool = True) -> str:
    return subprocess.run(["git", "-C", str(repo), *args], text=True, capture_output=True, check=check).stdout


def target_folder(check, text: str, target: str) -> str:
    kind, _, path = check.manifest_targets(text)[target]
    return str(Path(MANIFEST).parent / (path or (("Tests" if kind == "testTarget" else "Sources") + "/" + target)))


def offender(repo: Path, head: str, folder: str, module: str) -> tuple[str, str] | None:
    """(sha, subject) of the newest commit at or before HEAD that added an `import MODULE` line under FOLDER."""
    # POSIX classes, not \s, \w or \b: git -G uses the platform's regex, and macOS's (a mini runs this
    # check now) has none of those GNU extensions, so the pattern matched nothing there.
    pattern = (rf"^[[:space:]]*(@[[:alnum:]_]+(\([^)]*\))?[[:space:]]+)*"
               rf"((public|package|internal|private|fileprivate)[[:space:]]+)?import[[:space:]]+{module}([^[:alnum:]_]|$)")
    out = git(repo, "log", "-1", "--format=%H%x09%s", "-G", pattern, head, "--", folder).strip()
    if not out:
        return None
    sha, _, subject = out.partition("\t")
    return sha, subject


def branch_for(missing: list[tuple[str, str]], sorting: list[str]) -> str:
    """The branch for a gap: its missing imports when there are any, so a later push that only sorts the lists finds
    the same branch (review of 1f94c38c); otherwise the sorting problems."""
    repairs = [f"{t}: {m}" for t, m in missing] or [f"sort: {p}" for p in sorting]
    return BRANCH_PREFIX + hashlib.sha256("\n".join(sorted(repairs)).encode()).hexdigest()[:12]


def title_for(missing: list[tuple[str, str]]) -> str:
    if not missing:
        return "fix(cmux-next): put Package.swift's sorted dependency lists back in order"
    if len(missing) == 1:
        target, module = missing[0]
        return f"fix(cmux-next): {target} declares {module}, which it imports"
    return f"fix(cmux-next): declare {len(missing)} local imports Package.swift is missing"


def body_for(missing, sorting, offenders, github_repo: str, run_url: str) -> str:
    def commit_link(sha: str) -> str:
        return f"[`{sha[:10]}`](https://github.com/{github_repo}/commit/{sha})" if github_repo else f"`{sha[:10]}`"

    lines = ["## Summary", "",
             f"CI's \"{CHECK_STEP}\" step is red on {BASE}, so it is red on every pull request. The change "
             "reached the branch without the pre-push hook, which refuses it.", ""]
    if missing:
        lines += [f"A target imports another local target that its `dependencies` in `{MANIFEST}` do not declare "
                  "(an incremental build then keeps objects compiled against the old interface):", "",
                  "| target | imports | brought in by |", "| --- | --- | --- |"]
        for target, module in missing:
            found = offenders.get((target, module))
            by = f"{commit_link(found[0])} {found[1]}" if found else "not found in the history"
            lines.append(f"| `{target}` | `{module}` | {by} |")
        lines += ["", "This pull request declares each one, as `scripts/cmux-next/check-package-dependency-lists.py "
                  "--fix-imports` does: a sorted list gets the entry in order, any other list gets it before its "
                  "closing bracket.", ""]
    if sorting:
        lines += ["It also puts these sorted lists back in order (`--fix`):", ""] + [f"- {p}" for p in sorting] + [""]
    lines += ["Red fix: it lands on an independent review and a green check, like any other red fix. "
              "It changes only `Package.swift`.", ""]
    if run_url:
        lines += [f"Opened by {run_url}.", ""]
    lines += ["## Testing", "",
              "`python3 scripts/cmux-next/check-package-dependency-lists.py` finds nothing to repair on the fixed tree "
              "(checked before this pull request was opened).", "",
              "## Changelog", "", "none", ""]
    return "\n".join(lines)


def plan(repo: Path, head: str, out: Path, github_repo: str = "", run_url: str = "") -> dict[str, str]:
    check = load_check()
    manifest = repo / MANIFEST
    text = manifest.read_text(encoding="utf-8")
    sorting, fixed_text = check.check(text, fix=True)
    missing = [tuple(pair) for pair in check.missing_imports(fixed_text, manifest.parent)]
    other = [p for p in check.import_problems(text, manifest.parent) if "does not declare" not in p]
    if not missing and not sorting:
        return {"red": "true", "fixable": "false"} if other else {"red": "false"}
    offenders = {}
    for target, module in missing:
        found = offender(repo, head, target_folder(check, fixed_text, target), module)
        if found:
            offenders[(target, module)] = found
    for target, module in missing:
        try:
            fixed_text = check.add_dependency(fixed_text, target, module)
        except (check.FixError, check.ListError) as error:
            print(f"package-deps-heal: cannot declare {module} in {target}: {error}", file=sys.stderr)
            return {"red": "true", "fixable": "false"}
    # Every problem, a stale IMPORT_BASELINE line included: a pull request that leaves one is red itself (review of
    # 8e00c8ba).
    still = check.check(fixed_text, fix=False)[0] + check.import_problems(fixed_text, manifest.parent)
    if still:
        print("package-deps-heal: still red after the repair:\n  " + "\n  ".join(still), file=sys.stderr)
        return {"red": "true", "fixable": "false"}
    manifest.write_text(fixed_text, encoding="utf-8")
    branch = branch_for(missing, sorting)
    title = title_for(missing)
    shas = sorted({sha for sha, _ in offenders.values()})
    out.mkdir(parents=True, exist_ok=True)
    (out / "branch").write_text(branch + "\n")
    (out / "title").write_text(title + "\n")
    (out / "body.md").write_text(body_for(missing, sorting, offenders, github_repo, run_url))
    (out / "commit-message").write_text(
        f"{title}\n\nCI's \"{CHECK_STEP}\" was red on {BASE}"
        + (f" after {', '.join(s[:10] for s in shas)}" if shas else "")
        + ". Made by scripts/cmux-next/package_deps_heal.py (check-package-dependency-lists.py --fix-imports).\n")
    (out / "labels").write_text(",".join(LABELS) + "\n")
    return {"red": "true", "fixable": "true", "branch": branch}


def gh(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["gh", *args], text=True, capture_output=True)


def open_pr(repo: Path, out: Path, remote: str = "origin", base: str = BASE) -> str:
    """Commit, push the planned branch and open its pull request; returns its URL, or what was found instead."""
    branch = (out / "branch").read_text().strip()
    if not branch.startswith(BRANCH_PREFIX):
        raise SystemExit(f"package-deps-heal: refusing to push {branch!r}: only {BRANCH_PREFIX}* branches")
    listed = gh("pr", "list", "--head", branch, "--state", "open", "--json", "url", "--limit", "1")
    if listed.returncode == 0 and json.loads(listed.stdout or "[]"):
        return f"already open: {json.loads(listed.stdout)[0]['url']}"
    git(repo, "checkout", "-q", "-B", branch)
    git(repo, "add", "--", MANIFEST)
    git(repo, "commit", "-q", "-F", str(out / "commit-message"))
    # A plain push: a branch someone else already pushed is left alone (the open pull request above, or a closed one
    # a person decided against), never overwritten.
    pushed = subprocess.run(["git", "-C", str(repo), "push", "-q", remote, f"HEAD:refs/heads/{branch}"],
                            text=True, capture_output=True)
    if pushed.returncode != 0:
        # An earlier run pushed the branch. A pull request ever opened from it (a closed one is a person's decision)
        # leaves it alone; none means that run's `gh pr create` failed, so this run opens it (review of 1f94c38c).
        ever = gh("pr", "list", "--head", branch, "--state", "all", "--json", "url", "--limit", "1")
        if ever.returncode != 0 or json.loads(ever.stdout or "[]"):
            found = json.loads(ever.stdout)[0]["url"] if ever.returncode == 0 else ever.stderr.strip()[-200:]
            return f"not pushed: {branch} exists on {remote} ({found})"
    created = gh("pr", "create", "--base", base, "--head", branch, "--title", (out / "title").read_text().strip(),
                 "--body-file", str(out / "body.md"), "--label", (out / "labels").read_text().strip())
    if created.returncode != 0:
        raise SystemExit(f"package-deps-heal: pushed {branch} but could not open its pull request: {created.stderr}")
    return created.stdout.strip()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="op", required=True)
    p = sub.add_parser("plan")
    p.add_argument("--repo", type=Path, default=Path("."))
    p.add_argument("--head", default="HEAD")
    p.add_argument("--out", type=Path, required=True)
    p.add_argument("--github-repo", default="")
    p.add_argument("--run-url", default="")
    o = sub.add_parser("open")
    o.add_argument("--repo", type=Path, default=Path("."))
    o.add_argument("--out", type=Path, required=True)
    o.add_argument("--remote", default="origin")
    o.add_argument("--base", default=BASE)
    args = parser.parse_args(argv)
    if args.op == "plan":
        for key, value in plan(args.repo.resolve(), args.head, args.out, args.github_repo, args.run_url).items():
            print(f"{key}={value}")
    else:
        print(open_pr(args.repo.resolve(), args.out, args.remote, args.base))
    return 0


if __name__ == "__main__":
    sys.exit(main())
