#!/usr/bin/env python3
"""Hot swap out: neutralize one piece of a first-red commit, not the whole commit, and drill down to it.

Leo, 2026-11-22 08:53Z: "the partial revert, not all the way back, but to individual pieces. that's the whole point.
if we can hot swap in, then we should be able to hot swap out. we should be able to neutralize and drill down into
individual pieces."

Hot swap in is a layer: `cmux customize use pr:N` puts a PR's web part over a running app, `hot-apply.py apply SHA`
hands the daemons a new build (cmuxterm-hq docs/design/cmux-next-hot-swap-layers.md). Hot swap out is the inverse on
the same boundaries: a commit splits into pieces (.github/change-classes.json piece_roots: a webviews feature folder, a
crate, a Swift module; any other file alone), and taking a piece out is the commit with only that piece's diff reversed.

  manifest SHA            the commit's pieces: id, class, how it swaps (file, live, build, never), files, and
                          live_apply.py's verdict per piece (what a running app could take without a build)
  out SHA --piece ID ...  [--onto REF] a commit on REF (default SHA itself) with those pieces of SHA reversed and
                          everything else kept; prints its sha. In a running app: `cmux app try <that sha>` (a
                          web or daemon piece swaps out live; `cmux app try undo` swaps it back in)

The post-merge batch (scripts/ci/post_merge_batch.py, .github/workflows/cmux-next-post-merge.yml) calls this when its
bisect names one first-red commit. When every piece is in a class .github/piece-swap.json lists (`drill`, `web-ui`, `rust-core`):
  1. suspects: only pieces the red suite's own paths read (the batch calls a suite only for those paths);
  2. drill down: one probe run of the red job per step at the commit with half the suspects swapped out; green means
     the bad piece is in the half that is out. log2(pieces) runs name the one piece;
  3. open a pull request that swaps that piece out of the branch tip (swapout/pr-N-SHA12-JOB, one per job and first
     red), tell the commit's PR once, and print the whole revert as the owner's fallback; it is never performed here.
Guards: never a take-back of a take-back (a revert or swap-out subject); at most max_per_hour swap-out PRs an hour (the
breaker); a class not listed, or a `never` class (migrations, signing), keeps today's whole revert pull request; the
repository variable NEXT_PIECE_SWAP=0 stops all of it (one switch).
"""

from __future__ import annotations

import argparse
import datetime as dt
import fnmatch
import hashlib
import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile
from dataclasses import asdict, dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CLASSES = ROOT / ".github" / "change-classes.json"
CONFIG = ROOT / ".github" / "piece-swap.json"
SWAPS = ("file", "live", "build", "never")
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
TAKE_BACK = re.compile(r'^(Revert "|revert[:(]|Swap out )', re.I)
OTHER = {"name": "other", "swap": "never", "paths": [], "why": "No class matches: nothing says how it comes out."}


def matches(path: str, pattern: str) -> bool:
    """post_merge_batch.Suite.reached's rule: fnmatch (* crosses /), and DIR/** is everything under DIR."""
    return fnmatch.fnmatchcase(path, pattern) or (pattern.endswith("/**") and path.startswith(pattern[:-2]))


class Classifier:
    def __init__(self, data: dict):
        self.classes = list(data.get("classes") or [])
        self.roots = [r.split("/") for r in data.get("piece_roots") or []]

    def classify(self, path: str) -> dict:
        for cls in self.classes:
            if any(matches(path, p) for p in cls.get("paths") or []):
                return cls
        return OTHER

    def piece_id(self, path: str) -> str:
        parts = path.split("/")
        for root in self.roots:
            if len(parts) > len(root) and all(r == "*" or r == p for r, p in zip(root, parts)):
                return "/".join(parts[: len(root)])
        return path


def load_classifier(path: Path = CLASSES) -> Classifier:
    return Classifier(json.loads(Path(path).read_text()))


def load_config(path: Path = CONFIG) -> dict:
    data = json.loads(Path(path).read_text())
    return {"classes": list(data.get("classes") or []), "max_per_hour": int(data.get("max_per_hour", 3)),
            "max_probes": int(data.get("max_probes", 4))}


@dataclass
class Piece:
    id: str
    cls: str
    swap: str
    files: list[str] = field(default_factory=list)


def split(files: list[str], classifier: Classifier) -> list[Piece]:
    """The pieces of a change, sorted by id. A piece is one class: a root holding files of two classes splits by class
    (the id gets the class after a #)."""
    pieces: dict[str, Piece] = {}
    for path in sorted(set(files)):
        cls = classifier.classify(path)
        pid = classifier.piece_id(path)
        if pid in pieces and pieces[pid].cls != cls["name"]:
            pid = f"{pid}#{cls['name']}"
        pieces.setdefault(pid, Piece(pid, cls["name"], cls["swap"])).files.append(path)
    return [pieces[k] for k in sorted(pieces)]


def decide(pieces: list[Piece], config: dict, env) -> tuple[bool, str]:
    """(swap pieces out, why). False keeps the existing whole revert pull request."""
    if str(env.get("NEXT_PIECE_SWAP", "")).strip() == "0":
        return False, "NEXT_PIECE_SWAP=0: hot swap out is off"
    if not pieces:
        return False, "the commit changes no file"
    enabled = set(config.get("classes") or [])
    off = sorted({p.cls for p in pieces if p.cls not in enabled})
    if off:
        return False, f"class {', '.join(off)} is not listed in .github/piece-swap.json"
    never = sorted({p.cls for p in pieces if p.swap == "never"})
    if never:
        return False, f"class {', '.join(never)} cannot be swapped out piece by piece"
    return True, f"{len(pieces)} piece(s), every class listed"


def suspects(pieces: list[Piece], suite_paths: list[str]) -> list[Piece]:
    """The pieces the red suite reads: a batch calls a suite only for its paths, so a piece outside them cannot have
    turned it red. A suite with no paths reads everything."""
    if not suite_paths:
        return list(pieces)
    return [p for p in pieces if any(matches(f, s) for f in p.files for s in suite_paths)]


def halve(candidates: list[str]) -> list[str]:
    """The pieces the next probe swaps out: the first half (at least one, never all)."""
    return list(candidates[: max(1, len(candidates) // 2)])


def narrow(candidates: list[str], out: list[str], conclusion: str) -> list[str] | None:
    """After a probe of the commit with `out` swapped out: green means the red left with them; red means it is in the
    rest. None: no verdict (cancelled, lost runner)."""
    if conclusion == "success":
        return [c for c in candidates if c in out]
    if conclusion == "failure":
        return [c for c in candidates if c not in out]
    return None


@dataclass
class State:
    """The drill-down's state, carried in the probe run's `pieces` input (a workflow input is a string)."""
    culprit: str
    candidates: list[str]
    out: list[str]
    probes: int = 0

    def dump(self) -> str:
        return json.dumps(asdict(self), separators=(",", ":"), sort_keys=True)

    @classmethod
    def parse(cls, text: str | None) -> "State | None":
        if not (text or "").strip():
            return None
        data = json.loads(text)
        if not isinstance(data, dict) or not SHA_RE.match(str(data.get("culprit") or "")):
            raise ValueError(f"bad piece state {text!r}")
        cand, out = data.get("candidates"), data.get("out")
        if not isinstance(cand, list) or not isinstance(out, list) or not cand or not set(out) <= set(cand):
            raise ValueError(f"bad piece state {text!r}")
        return cls(data["culprit"], [str(c) for c in cand], [str(o) for o in out], int(data.get("probes") or 0))


def is_take_back(subject: str) -> bool:
    return bool(TAKE_BACK.search(subject or ""))


def breaker_open(opened: list[dt.datetime], now: dt.datetime, max_per_hour: int) -> bool:
    return sum(1 for at in opened if dt.timedelta(0) <= now - at < dt.timedelta(hours=1)) >= max_per_hour


def slug(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")[:40] or "job"


def branch_name(culprit: str, job: str, pr: str) -> str:
    """One swap-out PR per (red job, first red commit)."""
    who = f"pr-{pr}-" if pr else ""
    return f"swapout/{who}{culprit[:12]}-{slug(job)}"


def probe_branch(culprit: str, out: list[str]) -> str:
    return f"swapout-probe/{culprit[:12]}-{hashlib.sha256(json.dumps(sorted(out)).encode()).hexdigest()[:10]}"


def neutralize_list(culprit: str, pieces: list[Piece]) -> str:
    """The pieces to neutralize as plain JSON (piece ids, each with its class, swap kind and files). One function, so a
    delivery format (the signed per-piece manifest of lane ship-without-update, hq docs/design/ship-without-update.md)
    re-serialises it rather than this tool keeping a second manifest."""
    return json.dumps({"culprit": culprit, "neutralize": [asdict(p) for p in pieces]}, sort_keys=True)


# webviews/src/<folder> -> the web bundle (cmux-tui/crates/cmux-web-pieces BUNDLES, lane ship-without-update) that ships it.
# A folder not named here (kit, ui, protocol: shared by every bundle) has no bundle piece of its own.
WEB_BUNDLE = {"agent-session": "agent-pane", "pages": "pages", "agent-activity": "agent-activity",
              "optchat-inspector": "inspector", "markdown-viewer": "webviews-app", "diff-viewer": "webviews-app"}


def web_piece_id(piece: Piece) -> str | None:
    """The piece's id in the signed web-pieces switch file: `<bundle>/<sub>` (pages/settings), the form the app
    matches by longest known prefix. None: not a web piece one bundle ships."""
    parts = piece.id.split("#")[0].split("/")
    if len(parts) < 3 or parts[:2] != ["webviews", "src"] or parts[2] not in WEB_BUNDLE:
        return None
    return "/".join([WEB_BUNDLE[parts[2]], *parts[3:4]])


def web_switches(pieces: list[Piece], reason: str) -> dict:
    """The `pieces` map of a cmux-web-pieces switch file (schema 1) that serves these pieces' last good bundle. The
    serial, channel, signature and publishing belong to ship-without-update's tool, which signs this map as is."""
    return {wid: {"serve": "last-good", "reason": reason} for wid in sorted({web_piece_id(p) for p in pieces} - {None})}


def from_web_bisect(report: dict, classifier: Classifier, cwd: Path | None = None) -> list[dict]:
    """The pieces of each culprit a web-bisect/2 report (cmux-next-web.yml web-bisect artifact) pins, and the ones
    its red test files sit under. Only verdict "culprit" with a pull request number counts. It finds no culprit
    itself: the bisect did."""
    out = []
    for verdict in report.get("verdicts") or []:
        culprit = verdict.get("culprit") or {}
        if verdict.get("verdict") != "culprit" or not culprit.get("pr") or not SHA_RE.match(str(culprit.get("sha") or "")):
            continue
        pieces = split(changed(culprit["sha"], cwd=cwd), classifier)
        test = str(verdict.get("file") or "")
        near = [p for p in pieces if test.startswith(p.id.split("#")[0].rsplit("/", 1)[0] + "/")]
        out.append({"file": test, "culprit": culprit["sha"], "pr": culprit["pr"], "green": verdict.get("green"),
                    "pieces": [p.id for p in pieces], "suspects": [p.id for p in (near or pieces)],
                    "web_switches": web_switches(near or pieces, f"cmux#{culprit['pr']} turned {test} red")})
    return out


def whole_revert_command(culprit: str, branch: str, parents: int = 1) -> str:
    mainline = " -m 1" if parents > 1 else ""
    return (f"git fetch origin {branch} && git switch -c revert/{culprit[:12]} origin/{branch} && "
            f"git revert --no-edit{mainline} {culprit} && git push -u origin HEAD && gh pr create --base {branch} --fill")


# ---------------------------------------------------------------------------- git


def git(*argv: str, cwd: Path | None = None, env: dict | None = None, input: str | None = None) -> str:
    done = subprocess.run(["git", *argv], cwd=cwd or ROOT, capture_output=True, text=True, env=env, input=input)
    if done.returncode:
        raise RuntimeError(f"git {' '.join(argv[:2])}: {(done.stderr or done.stdout).strip()[-400:]}")
    return done.stdout


def changed(culprit: str, cwd: Path | None = None) -> list[str]:
    """The commit's files against its first parent (a squash merge's one parent)."""
    out = git("diff", "--no-renames", "--name-only", f"{culprit}^1", culprit, cwd=cwd)
    return [line for line in out.splitlines() if line]


def parents(culprit: str, cwd: Path | None = None) -> int:
    return len(git("rev-list", "--parents", "-n1", culprit, cwd=cwd).split()) - 1


def swap_out_commit(onto: str, culprit: str, files: list[str], message: str, cwd: Path | None = None) -> str | None:
    """A commit on `onto` with the culprit's diff of `files` reversed, made in a private index (no worktree, no branch,
    no hook runs). None when the reverse does not apply to `onto` (a later commit changed those lines)."""
    if not files:
        return None
    patch = git("diff", "--binary", "--no-renames", "--full-index", culprit, f"{culprit}^1", "--", *files, cwd=cwd)
    if not patch.strip():
        return None
    with tempfile.TemporaryDirectory() as tmp:
        env = {**os.environ, "GIT_INDEX_FILE": str(Path(tmp) / "index")}
        git("read-tree", onto, cwd=cwd, env=env)
        try:
            git("apply", "--cached", "--3way", cwd=cwd, env=env, input=patch)
        except RuntimeError:
            return None
        if git("ls-files", "--unmerged", cwd=cwd, env=env).strip():
            return None
        tree = git("write-tree", cwd=cwd, env=env).strip()
    if tree == git("rev-parse", f"{onto}^{{tree}}", cwd=cwd).strip():
        return None
    return git("commit-tree", tree, "-p", onto, "-m", message, cwd=cwd, env=identity_env(cwd)).strip()


SWAP_IDENT = ("cmux piece swap", "41898282+github-actions[bot]@users.noreply.github.com")


def identity_env(cwd: Path | None = None) -> dict:
    """The environment for a commit: the caller's own identity when git has one (the revert job sets it), else
    SWAP_IDENT. The judge job rebuilds a probe's commit only to compare trees, on a runner with no user.name,
    and a commit that needs a configured name there is a swap-out that never happens (run 45046212800)."""
    env = dict(os.environ)
    for role in ("AUTHOR", "COMMITTER"):
        probe = subprocess.run(["git", "var", f"GIT_{role}_IDENT"], cwd=cwd or ROOT, capture_output=True, text=True, env=env)
        if probe.returncode:
            env[f"GIT_{role}_NAME"], env[f"GIT_{role}_EMAIL"] = SWAP_IDENT
    return env


def live_verdicts(culprit: str, pieces: list[Piece], cwd: Path | None = None) -> dict[str, str]:
    """scripts/cmux-next/live_apply.py's verdict for each piece's own diff: what a running app takes without a build."""
    spec = importlib.util.spec_from_file_location("live_apply", ROOT / "scripts" / "cmux-next" / "live_apply.py")
    if spec is None or spec.loader is None:
        return {}
    try:
        live = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(live)
        out = {}
        for piece in pieces:
            names = live.parse_name_status(git("diff", "--no-renames", "--name-status", f"{culprit}^1", culprit, "--", *piece.files, cwd=cwd))
            diffs = live.parse_diff(git("diff", "--no-renames", "-U0", f"{culprit}^1", culprit, "--", *piece.files, cwd=cwd))
            out[piece.id] = live.classify(names, diffs)["verdict"]
        return out
    except Exception as err:  # the verdict is advice; a parse change there never stops a manifest
        return {"_error": str(err)[:200]}


def manifest(culprit: str, classifier: Classifier, cwd: Path | None = None, live: bool = False) -> dict:
    pieces = split(changed(culprit, cwd=cwd), classifier)
    verdicts = live_verdicts(culprit, pieces, cwd=cwd) if live else {}
    subject = git("log", "-1", "--format=%s", culprit, cwd=cwd).strip()
    return {
        "culprit": culprit,
        "subject": subject,
        "parents": parents(culprit, cwd=cwd),
        "pieces": [{**asdict(p), **({"live_apply": verdicts[p.id]} if p.id in verdicts else {})} for p in pieces],
        **({"live_apply_error": verdicts["_error"]} if "_error" in verdicts else {}),
    }


# ---------------------------------------------------------------------------- CLI


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = parser.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("manifest")
    p.add_argument("sha")
    p.add_argument("--live", action="store_true", help="add live_apply.py's verdict per piece")
    p = sub.add_parser("out")
    p.add_argument("sha")
    p.add_argument("--piece", action="append", required=True)
    p.add_argument("--onto", default="")
    p = sub.add_parser("web-bisect", help="the pieces of each culprit in a web-bisect/2 report.json")
    p.add_argument("report")
    args = parser.parse_args(argv)
    classifier = load_classifier()
    if args.cmd == "web-bisect":
        print(json.dumps(from_web_bisect(json.loads(Path(args.report).read_text()), classifier), indent=2))
        return 0
    sha = git("rev-parse", args.sha).strip()
    if args.cmd == "manifest":
        print(json.dumps(manifest(sha, classifier, live=args.live), indent=2))
        return 0
    pieces = {p.id: p for p in split(changed(sha), classifier)}
    unknown = [i for i in args.piece if i not in pieces]
    if unknown:
        print(f"no such piece in {sha[:12]}: {', '.join(unknown)} (pieces: {', '.join(pieces)})", file=sys.stderr)
        return 2
    files = [f for i in args.piece for f in pieces[i].files]
    onto = git("rev-parse", args.onto or sha).strip()
    out = swap_out_commit(onto, sha, files, f"Swap out {', '.join(args.piece)} of {sha[:12]}")
    if not out:
        print(f"the pieces do not swap out cleanly onto {onto[:12]}", file=sys.stderr)
        return 3
    print(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
