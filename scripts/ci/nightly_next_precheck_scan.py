#!/usr/bin/env python3
"""Which recent feat-cmux-next commits pass the nightly-next precheck, read once a tick.

The nightly-next tick ("Request nightly-next promotion on main" in nightly-next-tick.yml) walks
first-parent commits newest-first and runs each commit's own request-nightly-next.sh. That script
searches for the commit's cmux-tui tree, and for an older published tree when its own is missing
(older-tree-for-tip.sh, a CDN walk over about 80 commits), before it reads the precheck: the build
fleet's Release compile verdict. A commit the fleet has not compiled yet was refused only after that
search. Tick 45821041380 (2026-11-26 12:38Z) took 82-101 s per refused commit, refused 15
("not prechecked yet" or "cannot resolve a published cmux-tui tree"), spent its 900 s walk budget
and promoted nothing, while an older commit was promotable.

This reads the same verdicts first, for the whole walk at once (one GET each, about 60 ms), and
answers per commit, newest first:

  <sha> ask <reason>    the precheck passes (or cannot be read), so its request runs
  <sha> skip <reason>   the commit's request-nightly-next.sh would refuse it on the precheck
  <sha> stop <reason>   nightly-next already contains it: the walk ends there, as the script's
                        "already on nightly-next" ends it

A commit whose app is the published one's (the script's app_unchanged, checked before its precheck)
is asked: its script answers "already on nightly-next" and the walk ends, as before.

It mirrors precheck() in scripts/cmux-next/request-nightly-next.sh (on feat-cmux-next): the commit's
own verdict (pass, fail, superseded and covered by the first later checked tip that passed), else
the nearest first-parent ancestor with a pass or fail verdict, within CMUX_NIGHTLY_NEXT_PRECHECK_DEPTH
(30), standing for it when the app is the same (scripts/ci/nightly_build_inputs.py and the cmux-tui
tree key). A skip is only ever a commit the script refuses too, so no safety check moves: the
script still runs every check on each asked commit (tree published and verified, never behind
nightly-next, strings, marker). Any doubt asks: a commit whose script has no precheck, a service
that does not answer (the script promotes unprechecked then), or a failure of this scan (the tick
then asks every commit, as before).

The pass and fail verdicts it reads go into the script's own per-run cache
(RUNNER_TEMP/nightly-next-precheck-RUN-ATTEMPT/<sha>), so the asked commits' prechecks read nothing
again.
"""
from __future__ import annotations

import argparse
import contextlib
import io
import json
import os
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

DEFAULT_RESULTS = "https://gh-events.cmux.com/compile-checks/v1"
SCRIPT = "scripts/cmux-next/request-nightly-next.sh"
# The compile-results CDN rejects urllib's and curl's default user agents; the script sends this one.
USER_AGENT = "cmux-ci-fleet-compile-result/1"


def git(*args: str, cwd: Path, stdin: str | None = None) -> subprocess.CompletedProcess:
    return subprocess.run(["git", *args], cwd=cwd, input=stdin, capture_output=True, text=True)


def parse_verdict(status: int, body: bytes, sha: str, repo: str) -> str:
    """fleet_verdict's answer: pass, fail, pending, superseded, none or down."""
    if status == 404:
        return "none"
    if status in (429, 503):
        return "pending"
    if status != 200:
        return "down"
    try:
        record = json.loads(body)
    except ValueError:
        return "none"
    if (
        not isinstance(record, dict)
        or record.get("sha") != sha
        or record.get("repo") != repo
        or record.get("recipe_version") != 2
        or record.get("configuration") != "release-onone"
    ):
        return "none"
    state = record.get("state")
    if state in ("pass", "fail"):
        return state
    if state in ("queued", "running", "deferred", "", None):
        return "pending"
    if state == "superseded":
        return "superseded"
    return "none"


class Scan:
    def __init__(self, workspace: Path, repo: str, results: str, depth: int, cache: Path | None):
        self.workspace = workspace
        self.repo = repo
        self.results = results.rstrip("/")
        self.depth = depth
        self.cache = cache
        self.verdicts: dict[str, str] = {}
        self.keys: dict[str, str | None] = {}
        self.has_precheck: dict[str, bool] = {}
        self.classifier = None
        # HEAD's first-parent chain, newest first, once (set by main): a walked commit's
        # ancestors and later tips are slices of it, not a git call each.
        self.chain: list[str] = []
        self.position: dict[str, int] = {}

    def read_verdict(self, sha: str) -> str:
        if self.cache is not None:
            kept = self.cache / sha
            try:
                word = kept.read_text(encoding="utf-8").strip()
                if word in ("pass", "fail"):
                    return word
            except OSError:
                pass
        url = f"{self.results}/{sha}?repo={urllib.parse.quote(self.repo, safe='')}"
        request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
        try:
            with urllib.request.urlopen(request, timeout=20) as response:
                word = parse_verdict(response.status, response.read(), sha, self.repo)
        except urllib.error.HTTPError as error:
            word = parse_verdict(error.code, b"", sha, self.repo)
        except (urllib.error.URLError, OSError, ValueError):
            word = "down"
        if self.cache is not None and word in ("pass", "fail"):
            try:
                tmp = self.cache / f"{sha}.{os.getpid()}"
                tmp.write_text(word + "\n", encoding="utf-8")
                tmp.replace(self.cache / sha)
            except OSError:
                pass
        return word

    def prefetch(self, shas: list[str]) -> None:
        todo = [sha for sha in dict.fromkeys(shas) if sha not in self.verdicts]
        with ThreadPoolExecutor(max_workers=4) as pool:
            for sha, word in zip(todo, pool.map(self.read_verdict, todo)):
                self.verdicts[sha] = word
        # A busy or failed answer is read once more, one at a time: a burst refused is not a verdict,
        # and a commit passed over on one costs the tick its promotion.
        for sha in todo:
            if self.verdicts[sha] in ("pending", "down"):
                self.verdicts[sha] = self.read_verdict(sha)

    def verdict(self, sha: str) -> str:
        if sha not in self.verdicts:
            self.verdicts[sha] = self.read_verdict(sha)
        return self.verdicts[sha]

    def tree_key(self, sha: str) -> str | None:
        if sha not in self.keys:
            out = subprocess.run(
                [sys.executable, str(self.workspace / "scripts/ci/cmux_tui_tree_key.py"), "--version", "v2", sha],
                cwd=self.workspace, capture_output=True, text=True,
            )
            key = out.stdout.strip()
            self.keys[sha] = key if out.returncode == 0 and len(key) == 40 else None
        return self.keys[sha]

    def same_app(self, base: str, sha: str) -> bool:
        """same_app <base> <sha> of the script: nothing that reaches the app changed."""
        on_chain = base in self.position and sha in self.position and self.position[base] > self.position[sha]
        if not on_chain and git("merge-base", "--is-ancestor", base, sha, cwd=self.workspace).returncode != 0:
            return False
        classifier = self.workspace / "scripts/ci/nightly_build_inputs.py"
        if not classifier.is_file():
            return False
        diff = git("diff", "--no-renames", "--name-only", base, sha, cwd=self.workspace)
        if diff.returncode != 0:
            return False
        if not diff.stdout.strip():
            return True
        if self.inputs_changed([line for line in diff.stdout.splitlines() if line.strip()]):
            return False
        key_base, key_sha = self.tree_key(base), self.tree_key(sha)
        return key_base is not None and key_base == key_sha

    def inputs_changed(self, paths: list[str]) -> bool:
        """scripts/ci/nightly_build_inputs.py's answer, in this process: its start-up (about 0.4 s)
        once per commit was most of a 120-commit scan. Any error counts as changed."""
        if self.classifier is None:
            try:
                sys.path.insert(0, str(self.workspace / "scripts/ci"))
                import nightly_build_inputs  # noqa: PLC0415 - the checkout's own copy

                self.classifier = nightly_build_inputs.build_inputs_changed
            except Exception:  # noqa: BLE001 - an unreadable classifier never skips a commit
                self.classifier = False
        if self.classifier is False:
            return True
        try:
            with contextlib.redirect_stdout(sys.stderr), contextlib.redirect_stderr(io.StringIO()):
                changed, _ = self.classifier(paths, self.workspace)
        except Exception:  # noqa: BLE001
            return True
        return bool(changed)

    def script_has_precheck(self, sha: str) -> bool:
        if sha not in self.has_precheck:
            shown = git("show", f"{sha}:{SCRIPT}", cwd=self.workspace)
            self.has_precheck[sha] = shown.returncode == 0 and "fleet_verdict" in shown.stdout
        return self.has_precheck[sha]

    def app_unchanged(self, sha: str, published: str, promoted: str) -> bool:
        """app_unchanged <sha> of the script, which answers before its precheck."""
        if not published or published == sha or not self.commit_known(published):
            return False
        if not self.same_app(published, sha):
            return False
        if promoted and promoted != published and git(
            "merge-base", "--is-ancestor", promoted, published, cwd=self.workspace
        ).returncode != 0:
            return self.commit_known(promoted) and self.same_app(promoted, sha)
        return True

    def commit_known(self, sha: str) -> bool:
        return git("cat-file", "-e", f"{sha}^{{commit}}", cwd=self.workspace).returncode == 0

    def decide(self, sha: str, tip: str, published: str = "", promoted: str = "") -> tuple[str, str]:
        if not self.script_has_precheck(sha):
            return "ask", "its request-nightly-next.sh has no precheck"
        if self.app_unchanged(sha, published, promoted):
            return "ask", "nothing that reaches the app changed since the published nightly-next"
        word = self.verdict(sha)
        if word == "pass":
            return "ask", "the build fleet compiled it in Release"
        if word == "fail":
            return "skip", "precheck red: the build fleet's Release compile of it failed"
        if word == "down":
            return "ask", "the compile results service did not answer (the script promotes it unprechecked)"
        if word == "superseded":
            if sha in self.position and self.chain and self.chain[0] == tip:
                newer_tips = self.chain[: self.position[sha]][::-1]
            else:
                newer_tips = git(
                    "rev-list", "--first-parent", "--ancestry-path", "--reverse", f"{sha}..{tip}", cwd=self.workspace
                ).stdout.split()
            for newer in newer_tips[: self.depth]:
                covering = self.verdict(newer)
                if covering == "pass":
                    return "ask", f"its push was superseded by {newer[:12]}, whose Release compile passed"
                if covering in ("fail", "pending", "down"):
                    break
        at = self.position.get(sha)
        if at is not None and len(self.chain) >= at + 1 + self.depth:
            ancestors = self.chain[at + 1 : at + 1 + self.depth]
        else:
            ancestors = git("rev-list", "--first-parent", "-n", str(self.depth), f"{sha}^", cwd=self.workspace).stdout.split()
        for ancestor in ancestors:
            nearest = self.verdict(ancestor)
            if nearest not in ("pass", "fail"):
                continue
            if not self.same_app(ancestor, sha):
                return "skip", (
                    f"not prechecked yet: no Release compile verdict for it yet "
                    f"(the nearest one, {ancestor[:12]}, compiled another app)"
                )
            if nearest == "pass":
                return "ask", f"the build fleet compiled {ancestor[:12]} in Release, and nothing that reaches the app changed since"
            return "skip", f"precheck red: the build fleet's Release compile of {ancestor[:12]} failed, and nothing that reaches the app changed since"
        return "skip", "not prechecked yet: no Release compile verdict for it or the ancestors read yet"


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--workspace", default=".", help="the feat-cmux-next checkout the tick walks (its HEAD is the walk's start)")
    parser.add_argument("--commits", type=int, default=120, help="first-parent commits the walk covers")
    parser.add_argument("--promoted", default="", help="nightly-next's commit, when it is in this history")
    parser.add_argument("--published", default="", help="the commit the nightly-next tag points at (its feed's last publish)")
    args = parser.parse_args(argv)
    workspace = Path(args.workspace).resolve()
    depth_raw = os.environ.get("CMUX_NIGHTLY_NEXT_PRECHECK_DEPTH", "30")
    depth = int(depth_raw) if depth_raw.isdigit() else 30
    results = os.environ.get("CMUX_NIGHTLY_NEXT_PRECHECK_RESULTS") or DEFAULT_RESULTS
    cache = None
    if os.environ.get("GITHUB_RUN_ID"):
        base = os.environ.get("RUNNER_TEMP") or os.environ.get("TMPDIR") or "/tmp"
        cache = Path(base) / f"nightly-next-precheck-{os.environ['GITHUB_RUN_ID']}-{os.environ.get('GITHUB_RUN_ATTEMPT') or '1'}"
        try:
            cache.mkdir(parents=True, exist_ok=True)
        except OSError:
            cache = None
    tip_read = git("rev-parse", "HEAD", cwd=workspace)
    walk = git("rev-list", "--first-parent", "-n", str(args.commits), "HEAD", cwd=workspace)
    if tip_read.returncode != 0 or walk.returncode != 0:
        print("error: could not read the walk's history", file=sys.stderr)
        return 1
    tip = tip_read.stdout.strip()
    shas = walk.stdout.split()
    scan = Scan(workspace, args.repo, results, depth, cache)
    # Every verdict the walk can need, in parallel: the walk and depth ancestors past its end.
    more = git("rev-list", "--first-parent", "-n", str(args.commits + depth), "HEAD", cwd=workspace)
    if more.returncode == 0:
        scan.chain = more.stdout.split()
        scan.position = {commit: i for i, commit in enumerate(scan.chain)}
    scan.prefetch(scan.chain or shas)
    promoted = args.promoted if len(args.promoted) == 40 else ""
    published = args.published if len(args.published) == 40 else ""
    for sha in shas:
        if promoted and git("merge-base", "--is-ancestor", sha, promoted, cwd=workspace).returncode == 0:
            print(f"{sha} stop it is already on nightly-next ({promoted[:12]})")
            break
        verdict, reason = scan.decide(sha, tip, published, promoted)
        print(f"{sha} {verdict} {reason}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
