#!/usr/bin/env python3
"""The base autofix's Mac exports, taken from the cmux-next generated-files job that already built them.

Every feat-cmux-next push whose generated files are checked on their own job runs cmux-next.yml's
generated-files job, which builds the CmuxNext package and its tests on a Mac.
cmux-next-base-autofix.yml's action-exports job built the same package on another Mac for the same
push, only to regenerate the action exports (plans/cmux-next/action-surfaces.json, actions.md,
links.json) and the settings exports (settings-exports.txt). Now the generated-files job of a push
also regenerates them on its own build (base-autofix-exports-pack.sh) and uploads them as one pack,
and the base autofix takes that pack instead of building again. Its Mac job runs only when there is
no pack (cmuxterm-hq#5424, "one compile per base tree").

A pack is keyed by the git tree of the commit it was made at (NAME_PREFIX + tree id): the same tree
is the same sources, generators and Xcode pin, so the same fresh exports. Like the Mac job, which
regenerated on the newest tip, the autofix takes the pack of the newest commit between its own and
the branch tip that has one, and reports that commit as where the exports were made (made_at), which
base-autofix-land.sh already judges.

  key [REV]               print the pack's artifact name for a commit (default HEAD)
  manifest ...            write manifest.json for a pack directory (the producer)
  lookup ...              find, verify and unpack a pack for the autofix (the consumer), waiting a
                          bounded time for this push's generated-files job to make one

The base tier path is for cmuxterm-hq#5424 fix 1, which moves generated files and daemon tests off
each push into a `cmux-next base tier · <sha>` dispatch (cmux-next-base-tier-kick.yml). Until a tree
has that kick, no run carries that name and `lookup` never waits for one: every pack comes from push
runs, as here. Once it lands, the same code takes the base tier run's pack with no further change.

`lookup` only takes a pack from this repository's own push runs of cmux-next.yml on feat-cmux-next
whose head is the pack's commit (only their generated-files or folded daemon-test job makes one, after every regeneration
rewrote every export; the job itself may still be red for a stale export, which is what the autofix
repairs), and only when every file matches the SHA-256 its manifest records. Every problem is a miss
with a reason, and the Mac job regenerates as before.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path

SCHEMA = "cmux-next-base-autofix-exports/v1"
# Part of the artifact name: bump it to drop every recorded pack (a change to how a pack is made).
RECIPE = "v1"
NAME_PREFIX = f"cmux-next-base-exports-{RECIPE}-"
WORKFLOW_PATH = ".github/workflows/cmux-next.yml"
WORKFLOW_FILE = "cmux-next.yml"
BRANCH = "feat-cmux-next"
# The jobs that pack: generated-files, or daemon-test on a push whose generated files it checks on its
# own build (path_route's generated_host, CMUX_NEXT_FOLD_GENERATED). Either uploads the pack in this step.
GENERATED_JOB = "cmux-next generated files"
DAEMON_JOB = "cmux-next daemon tests"
UPLOAD_STEP = "Upload the exports for the base autofix"
ACTION_EXPORTS = ("plans/cmux-next/action-surfaces.json", "plans/cmux-next/actions.md", "plans/cmux-next/links.json")
OID = re.compile(r"^[0-9a-f]{40}$")
MAX_JSON_BYTES = 8 * 1024**2
MAX_PACK_BYTES = 64 * 1024**2
# cmux-next.yml's base tier dispatch (cmux-next-base-tier-kick.yml): a feat-cmux-next push leaves its
# generated files and daemon tests to one such run on the tip at most every 15 minutes, named after the
# commit it tests (a same-tree rerun keeps the name; its head is the newer tip).
BASE_TIER_TITLE = re.compile(r"^cmux-next base tier · ([0-9a-f]{40})$")
BASE_TIER_KICK = ".github/workflows/cmux-next-base-tier-kick.yml"
# Commits between the run's own and the tip whose packs the first look takes (newest first), besides its own.
NEWER_CANDIDATES = 8
# How far back the tip's first-parent history is read to find the run's commit.
HISTORY_DEPTH = 80
# The newest cmux-next.yml runs on the branch read a poll (about an hour of pushes and dispatches),
# and the unfinished ones among them whose jobs are read.
RUNS_LISTED = 50
RUNS_WATCHED = 4


class Miss(Exception):
    """No pack can be used; the message is the reason."""


def settings_exports(root: Path) -> list[str]:
    text = (root / "scripts/cmux-next/settings-exports.txt").read_text(encoding="utf-8")
    listed = [line.split("#", 1)[0].strip() for line in text.splitlines()]
    return [path for path in listed if path]


def exports(root: Path) -> list[str]:
    """Every file a pack holds: the action exports, then the settings exports."""
    return [*ACTION_EXPORTS, *settings_exports(root)]


def pack_name(tree: str) -> str:
    if not OID.match(tree):
        raise Miss(f"{tree!r} is not a tree id")
    return NAME_PREFIX + tree


def git(root: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(root), *args], check=True, capture_output=True, text=True).stdout.strip()


def tree_of(root: Path, rev: str) -> str:
    return git(root, "rev-parse", f"{rev}^{{tree}}")


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def write_manifest(root: Path, pack: Path, sha: str, env: dict[str, str]) -> dict:
    """manifest.json for the pack at `pack` (every export at its repository path), made at `sha`."""
    files = {}
    for rel in exports(root):
        path = pack / rel
        if not path.is_file():
            raise SystemExit(f"manifest: the pack has no {rel}")
        files[rel] = sha256(path.read_bytes())
    manifest = {
        "schema": SCHEMA, "source_sha": sha, "tree": tree_of(root, sha), "files": files,
        "run_id": int(env["GITHUB_RUN_ID"]), "run_attempt": int(env.get("GITHUB_RUN_ATTEMPT", "1")),
        "recorded_at": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
    }
    (pack / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    return manifest


class Api:
    """The GitHub REST calls the lookup makes. Tests replace it."""

    def __init__(self, token: str, repo: str, base: str, deadline: float):
        self.token, self.repo, self.base, self.deadline = token, repo, base.rstrip("/"), deadline

    def left(self) -> float:
        return self.deadline - time.monotonic()

    def sleep(self, seconds: float) -> None:
        time.sleep(max(0.0, min(seconds, self.left())))

    def json(self, path: str) -> dict:
        request = urllib.request.Request(f"{self.base}/repos/{self.repo}/{path}", headers={
            "Authorization": f"Bearer {self.token}", "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28"})
        try:
            with urllib.request.urlopen(request, timeout=20) as response:
                body = response.read(MAX_JSON_BYTES + 1)
        except (OSError, urllib.error.URLError) as error:
            raise Miss(f"GET {path.split('?')[0]} failed: {error}") from error
        if len(body) > MAX_JSON_BYTES:
            raise Miss(f"GET {path.split('?')[0]} answered over {MAX_JSON_BYTES} bytes")
        try:
            return json.loads(body.decode())
        except ValueError as error:
            raise Miss(f"GET {path.split('?')[0]} answered no JSON: {error}") from error

    def download(self, url: str, dest: Path) -> None:
        # curl, not urllib: the artifact URL redirects to blob storage, which refuses the GitHub
        # token; curl sends a -H header only to the first host. The header goes on stdin, never argv.
        command = ["curl", "-fsSL", "--retry", "2", "--connect-timeout", "10", "--max-time", "120",
                   "--max-filesize", str(MAX_PACK_BYTES), "-H", "@-", "-o", str(dest), url]
        try:
            result = subprocess.run(command, input=f"Authorization: Bearer {self.token}\n", text=True,
                                    capture_output=True, timeout=130)
        except (OSError, subprocess.TimeoutExpired) as error:
            raise Miss(f"download failed: {error}") from error
        if result.returncode != 0:
            raise Miss(f"download failed (curl {result.returncode}): {result.stderr.strip()[:200]}")


def trusted_packs(artifacts: list[dict], tree: str, repository_id: str) -> list[dict]:
    """Unexpired packs of `tree` from this repository's own runs on feat-cmux-next, newest first."""
    packs = []
    for item in artifacts:
        run = item.get("workflow_run") or {}
        if item.get("name") != pack_name(tree) or item.get("expired"):
            continue
        if str(run.get("repository_id")) != repository_id or str(run.get("head_repository_id")) != repository_id:
            continue
        if run.get("head_branch") != BRANCH or not run.get("id"):
            continue
        packs.append(item)
    return sorted(packs, key=lambda item: item.get("created_at") or "", reverse=True)


def check_run(run: dict, repo: str) -> str:
    """The commit a pack of this run was made at, when the run is this repository's own cmux-next.yml
    on feat-cmux-next: a push (its head), or a base tier dispatch (the commit its name gives). Merged
    code only: a pull request or any other dispatch is a Miss."""
    if run.get("path") != WORKFLOW_PATH or run.get("head_branch") != BRANCH:
        raise Miss(f"run {run.get('id')} is {run.get('path')} on {run.get('head_branch')}, not {WORKFLOW_PATH} on {BRANCH}")
    if (run.get("repository") or {}).get("full_name") != repo or (run.get("head_repository") or {}).get("full_name") != repo:
        raise Miss(f"run {run.get('id')} is not this repository's own")
    if run.get("event") == "push":
        commit = str(run.get("head_sha") or "")
    elif run.get("event") == "workflow_dispatch":
        title = BASE_TIER_TITLE.match(str(run.get("display_title") or ""))
        if not title:
            raise Miss(f"run {run.get('id')} is a dispatch but not a base tier run")
        commit = title.group(1)
    else:
        raise Miss(f"run {run.get('id')} is a {run.get('event')} run, not a push or a base tier dispatch")
    if not OID.match(commit):
        raise Miss(f"run {run.get('id')} names no commit")
    return commit


def unpack_verified(bundle: Path, tree: str, run: dict, commit: str, names: list[str], into: Path) -> dict:
    """Extract a downloaded pack into `into`, checking its manifest and every file's SHA-256."""
    try:
        with zipfile.ZipFile(bundle) as archive:
            manifest = json.loads(archive.read("manifest.json").decode())
            if manifest.get("schema") != SCHEMA:
                raise Miss(f"pack schema {manifest.get('schema')!r} is not {SCHEMA}")
            if manifest.get("tree") != tree:
                raise Miss("the pack's manifest names another tree")
            if manifest.get("run_id") != run.get("id"):
                raise Miss("the pack's manifest names another run than the one that uploaded it")
            if not OID.match(str(manifest.get("source_sha", ""))) or manifest.get("source_sha") != commit:
                raise Miss("the pack's commit is not the commit of the run that uploaded it")
            files = manifest.get("files")
            if not isinstance(files, dict) or sorted(files) != sorted(names):
                raise Miss("the pack does not hold exactly the exports this checkout lists")
            staged = {}
            for rel in names:
                data = archive.read(rel)
                if sha256(data) != files[rel]:
                    raise Miss(f"{rel} does not match the pack's digest (corrupt or replaced)")
                staged[rel] = data
    except KeyError as error:
        raise Miss(f"the pack has no {error}") from error
    except (zipfile.BadZipFile, ValueError, OSError) as error:
        raise Miss(f"the pack is not a readable zip: {error}") from error
    # Written only once every file checked out: a bad pack leaves nothing behind.
    for rel, data in staged.items():
        dest = into / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(data)
    return manifest


def take_pack(api: Api, tree: str, env: dict[str, str], names: list[str], into: Path, reasons: list[str]) -> dict | None:
    """The newest usable pack of `tree` unpacked into `into`, or None (the reasons appended)."""
    query = urllib.parse.urlencode({"name": pack_name(tree), "per_page": 10})
    packs = trusted_packs(api.json(f"actions/artifacts?{query}").get("artifacts", []), tree, env["GITHUB_REPOSITORY_ID"])
    with tempfile.TemporaryDirectory(prefix="cmux-base-exports-") as scratch:
        for item in packs[:2]:
            run_id = (item.get("workflow_run") or {}).get("id")
            try:
                run = api.json(f"actions/runs/{int(run_id)}")
                commit = check_run(run, env["GITHUB_REPOSITORY"])
                bundle = Path(scratch) / f"pack-{item.get('id')}.zip"
                api.download(item["archive_download_url"], bundle)
                return unpack_verified(bundle, tree, run, commit, names, into)
            except (Miss, KeyError, TypeError, ValueError) as why:
                reasons.append(f"tree {tree[:12]} run {run_id}: {why}")
    return None


def job_pending(jobs: list[dict]) -> str:
    """'' when no job of an unfinished run can still upload a pack, else what is still running. A pack
    is uploaded mid-job (daemon-test runs its tests after it), so a job whose upload step finished
    counts as done. A job not listed yet may still run (jobs list once their needs finish)."""
    def state(name: str) -> str:
        found = [job for job in jobs if job.get("name") == name]
        if not found:
            return "absent"
        job = found[0]
        if job.get("status") == "completed":
            return "skipped" if job.get("conclusion") in ("skipped", None) else "done"
        steps = [step for step in job.get("steps") or [] if step.get("name") == UPLOAD_STEP]
        return "done" if any(step.get("status") == "completed" for step in steps) else job.get("status") or "queued"

    generated, daemon = state(GENERATED_JOB), state(DAEMON_JOB)
    # Only one of them packs a run (path_route's generated_host): one that finished packing ends the wait.
    if "done" in (generated, daemon):
        return ""
    for name, value in ((GENERATED_JOB, generated), (DAEMON_JOB, daemon)):
        if value == "absent":
            return f"its {name} job is not listed yet"
        if value != "skipped":
            return f"its {name} job is {value}"
    return ""


def window_of(history: list[tuple[str, str]], sha: str, tree: str) -> dict[str, str]:
    """commit -> tree of `sha` and every newer commit on the tip's first-parent line (newest first)."""
    shas = [commit for commit, _ in history]
    if sha not in shas:
        return {sha: tree}
    return dict(history[:shas.index(sha) + 1])


def producers(api: Api, window: dict[str, str], repo: str) -> list[tuple[dict, str]]:
    """(run, commit) of the newest cmux-next.yml runs on the branch whose packs would be made at a
    commit in `window`: pushes, and base tier dispatches (cmux-next-base-tier-kick.yml)."""
    query = urllib.parse.urlencode({"branch": BRANCH, "per_page": RUNS_LISTED})
    found = []
    for run in api.json(f"actions/workflows/{WORKFLOW_FILE}/runs?{query}").get("workflow_runs", []):
        try:
            commit = check_run(run, repo)
        except Miss:
            continue
        if commit in window:
            found.append((run, commit))
    return found


def candidates(history: list[tuple[str, str]], sha: str, tree: str) -> list[tuple[str, str]]:
    """(commit, tree) to look up, newest first: up to NEWER_CANDIDATES commits after `sha` on the
    tip's first-parent line, then `sha` itself. A `sha` the history does not reach (the tip moved on
    a long way, or history could not be read) gives only `sha`."""
    shas = [commit for commit, _ in history]
    if sha not in shas:
        return [(sha, tree)]
    newer = history[:shas.index(sha)]
    return [*newer[:NEWER_CANDIDATES], (sha, tree)]


def sweep(api: Api, history: list[tuple[str, str]], sha: str, tree: str, env: dict[str, str], names: list[str],
          into: Path, reasons: list[str]) -> dict | None:
    for commit, commit_tree in candidates(history, sha, tree):
        manifest = take_pack(api, commit_tree, env, names, into, reasons)
        if manifest:
            return {"hit": "true", "made_at": commit, "source_run_id": str(manifest["run_id"]),
                    "source_sha": manifest["source_sha"]}
    return None


def lookup(api: Api, read_history, sha: str, tree: str, env: dict[str, str], names: list[str], into: Path,
           poll: float, first_run_grace: float, expect_base_tier: bool = False) -> dict[str, str]:
    """Take the newest pack at or after `sha`. While a cmux-next run on `sha` or a newer commit can
    still make one (this push's own, a newer push, or the base tier run that covers it), wait, take the
    pack of each producer as its upload finishes, and give up at the deadline. With `expect_base_tier`
    (pushes leave the generated files to the base tier) it also waits for that run to be dispatched."""
    if not OID.match(sha) or not OID.match(tree):
        raise Miss(f"no commit ({sha!r}) or tree ({tree!r})")
    if not env.get("GITHUB_REPOSITORY_ID", "").strip() or not env.get("GITHUB_REPOSITORY"):
        raise Miss("GITHUB_REPOSITORY_ID is not set, so no pack can be trusted")
    repo = env["GITHUB_REPOSITORY"]
    budget = api.left()
    reasons: list[str] = []
    hit = sweep(api, read_history(), sha, tree, env, names, into, reasons)
    # A pack is looked up at most twice once its producer is done (an upload can list a moment late).
    tried: dict[str, int] = {}
    while not hit:
        window = window_of(read_history(), sha, tree)
        runs = producers(api, window, repo)
        pending, ready = [], []
        watched = 0
        for run, commit in runs:
            if run.get("status") == "completed":
                ready.append(commit)
                continue
            if watched >= RUNS_WATCHED:
                pending.append(f"run {run.get('id')} at {commit[:12]} is {run.get('status')}")
                continue
            watched += 1
            jobs = api.json(f"actions/runs/{int(run['id'])}/jobs?filter=latest&per_page=100").get("jobs", [])
            why = job_pending(jobs)
            if why:
                pending.append(f"run {run['id']} at {commit[:12]}: {why}")
            else:
                ready.append(commit)
        # Each producer's pack is looked up once, as soon as nothing more can come of it (newest first).
        for commit in [c for c in window if c in ready and tried.get(window[c], 0) < 2]:
            tried[window[commit]] = tried.get(window[commit], 0) + 1
            manifest = take_pack(api, window[commit], env, names, into, reasons)
            if manifest:
                hit = {"hit": "true", "made_at": commit, "source_run_id": str(manifest["run_id"]),
                       "source_sha": manifest["source_sha"]}
                break
        if hit:
            break
        if not pending and expect_base_tier and not any(BASE_TIER_TITLE.match(str(run.get("display_title") or ""))
                                                        for run, _ in runs):
            pending = ["no base tier run on this commit or a newer one yet (the kick starts one within 15 minutes of a landing)"]
        # cmux-next.yml's push run of this commit starts within seconds of this workflow's; until it
        # lists, give it a grace before reading "no run" as "no pack coming".
        if not pending and not runs and budget - api.left() < first_run_grace:
            pending = ["no cmux-next run of this commit is listed yet"]
        if pending:
            if api.left() <= poll:
                raise Miss("; ".join([f"no pack within the wait ({pending[0]})", *reasons[-4:]]))
            api.sleep(poll)
            continue
        # Nothing can upload any more: one last look, at the tip as it is now.
        reasons = []
        hit = sweep(api, read_history(), sha, tree, env, names, into, reasons)
        if not hit:
            raise Miss("; ".join(["no pack for this commit or a newer one, and none is coming", *reasons[-4:]]))
    return hit


def remote_history(remote: str, branch: str, scratch: Path) -> list[tuple[str, str]]:
    """(commit, tree) of the branch tip's first-parent line, newest first; [] when it cannot be read."""
    bare = scratch / "history.git"
    try:
        subprocess.run(["git", "init", "-q", "--bare", str(bare)], check=True, capture_output=True)
        subprocess.run(["git", "-C", str(bare), "fetch", "-q", "--no-tags", "--filter=tree:0", f"--depth={HISTORY_DEPTH}",
                        remote, f"+refs/heads/{branch}:refs/heads/tip"], check=True, capture_output=True, timeout=120)
        out = git(bare, "log", "--first-parent", f"-n{HISTORY_DEPTH}", "--format=%H %T", "refs/heads/tip")
    except (OSError, subprocess.SubprocessError):
        return []
    finally:
        shutil.rmtree(bare, ignore_errors=True)
    return [tuple(line.split()) for line in out.splitlines() if len(line.split()) == 2]


def changed_exports(root: Path, staged: Path, names: list[str], into: Path) -> list[str]:
    """Copy the packed exports that differ from the checkout's HEAD into `into`, at their repository
    paths (the action-exports artifact's layout), and return their paths."""
    changed = []
    for rel in names:
        committed = subprocess.run(["git", "-C", str(root), "cat-file", "blob", f"HEAD:{rel}"], capture_output=True)
        if committed.returncode == 0 and committed.stdout == (staged / rel).read_bytes():
            continue
        dest = into / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(staged / rel, dest)
        changed.append(rel)
    return changed


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    k = sub.add_parser("key", help="print the pack's artifact name for a commit")
    k.add_argument("rev", nargs="?", default="HEAD")
    m = sub.add_parser("manifest", help="write manifest.json into a pack directory")
    m.add_argument("--pack", required=True)
    m.add_argument("--sha", required=True)
    f = sub.add_parser("lookup", help="print hit=, reason=, exports= and made_at= for $GITHUB_OUTPUT")
    f.add_argument("--out", required=True, help="the action-exports directory: changed exports at their paths")
    f.add_argument("--wait", type=float, default=2700, help="seconds to wait for a pack at or after this commit")
    f.add_argument("--poll", type=float, default=90)
    f.add_argument("--first-run-grace", type=float, default=180)
    f.add_argument("--base-tier", choices=("auto", "off"), default="auto",
                   help="auto: wait for the base tier run when the checkout has its kick (off: vars.CMUX_NEXT_BASE_TIER_COALESCE is 0)")
    f.add_argument("--skip", default="", help="a reason not to look (switched off)")
    f.add_argument("--summary", default=os.environ.get("GITHUB_STEP_SUMMARY"))
    args = parser.parse_args(argv)
    env = dict(os.environ)
    root = Path(git(Path.cwd(), "rev-parse", "--show-toplevel"))
    if args.command == "key":
        print(pack_name(tree_of(root, args.rev)))
        return 0
    if args.command == "manifest":
        write_manifest(root, Path(args.pack), args.sha, env)
        print(f"pack={pack_name(tree_of(root, args.sha))}")
        return 0
    outputs: dict[str, str]
    try:
        if args.skip:
            raise Miss(args.skip)
        sha, tree = git(root, "rev-parse", "HEAD"), tree_of(root, "HEAD")
        api = Api(env.get("GH_TOKEN") or "", env.get("GITHUB_REPOSITORY", ""),
                  env.get("GITHUB_API_URL", "https://api.github.com"), time.monotonic() + args.wait)
        if not api.token:
            raise Miss("no read token (GH_TOKEN, the route App's): not waiting on the shared GITHUB_TOKEN budget")
        remote = f"{env.get('GITHUB_SERVER_URL', 'https://github.com')}/{env.get('GITHUB_REPOSITORY', '')}"
        names = exports(root)
        with tempfile.TemporaryDirectory(prefix="cmux-base-exports-staged-") as scratch:
            staged = Path(scratch) / "staged"
            expect_base_tier = args.base_tier == "auto" and (root / BASE_TIER_KICK).is_file()
            outputs = lookup(api, lambda: remote_history(remote, BRANCH, Path(scratch)), sha, tree, env, names,
                             staged, args.poll, args.first_run_grace, expect_base_tier)
            changed = changed_exports(root, staged, names, Path(args.out))
        outputs["exports"] = "true" if changed else "false"
        for rel in changed:
            print(f"regenerated: {rel}", file=sys.stderr)
    except Miss as why:
        outputs = {"hit": "false", "reason": " ".join(str(why).split())[:500]}
    except Exception as error:  # noqa: BLE001 - a lookup bug must never fail the run: the Mac job regenerates
        outputs = {"hit": "false", "reason": f"lookup error: {type(error).__name__}: {error}"[:500]}
    if args.summary:
        server, repo = env.get("GITHUB_SERVER_URL", "https://github.com"), env.get("GITHUB_REPOSITORY", "")
        if outputs.get("hit") == "true":
            line = (f"Swift exports: **taken** from {server}/{repo}/actions/runs/{outputs['source_run_id']} "
                    f"(made at `{outputs['made_at'][:12]}`); "
                    f"{'some differ from this commit' if outputs['exports'] == 'true' else 'all current'}. No Mac job.")
        else:
            line = f"Swift exports: no pack ({outputs.get('reason')}); the Mac job regenerates them."
        try:
            with open(args.summary, "a", encoding="utf-8") as stream:
                stream.write(line + "\n")
        except OSError:
            pass
    for name, value in outputs.items():
        print(f"{name}={value}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
