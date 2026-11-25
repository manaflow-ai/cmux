#!/usr/bin/env python3
"""Diff this nightly's desktop visual-gate stills against the previous nightly's.

The visual gate (docs/ci/nightly-next-visual-gate.md) captures <state>/light.png and
<state>/dark.png for every file in scripts/cmux-next/visual-gate/states/ and uploads them as
nightly-next-visual-gate-<build_short_sha>. This script pairs this run's stills with the newest
earlier nightly.yml run that still kept that artifact, by `<state>/<light|dark>`, and writes one
markdown section: changed, new and removed states, each with the `Visual-change: <state glob or *>:
<why>` line that justifies it or "unjustified". The lines come from the commits between the two
builds: each commit message and, because a squash merge keeps the pull request's commit list but
not its body, each commit's pull request body (at most PR_BODY_CAP of them).

It warns and never fails: a missing baseline, a timeout, a download error or an image it cannot
read is reported and exits 0. Pixel comparison, the line format and its parsing are
ios_gate_screen_diff.py's, imported.

    desktop_visual_diff.py --head-root "$RUNNER_TEMP/visual-gate" --head-sha "$BUILD_SHA" \
        --fetch-baseline --repo manaflow-ai/cmux --out "$GITHUB_STEP_SUMMARY"

Tests pass --baseline-root and --messages instead (tests/test_desktop_visual_diff.py).
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
import time
import urllib.parse
import zipfile
from dataclasses import dataclass
from pathlib import Path

# The workflow runs this script with -I, which leaves its own directory off sys.path.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import deadline_http  # noqa: E402
from ios_gate_screen_diff import (  # noqa: E402
    CHANGED_RATIO,
    CHANNEL_TOLERANCE,
    _api,
    _download,
    diff_images,
    justifications,
    justify,
)

WORKFLOW_FILE = "nightly.yml"
ARTIFACT_PREFIX = "nightly-next-visual-gate-"
MODES = ("light", "dark")
TITLE = "### Desktop states vs the previous nightly"
# Nightly runs read when looking for a baseline: the artifact keeps 3 days.
RUNS_TO_SCAN = 20
# Artifact pages read per run (100 each): a nightly run uploads many.
ARTIFACT_PAGES = 3
# Listing runs and their artifacts, together.
LISTING_BUDGET_S = 90
# The baseline artifact's download.
DOWNLOAD_BUDGET_S = 120
# The compare call and every pull request body lookup, together.
MESSAGES_BUDGET_S = 60
# Commits whose pull request body is read; the rest count on their commit message alone.
PR_BODY_CAP = 40
# Pixel comparison stops this many seconds in; the rest compare by bytes. The step's timeout is 480 s.
TIME_BUDGET_S = 180


# --- States ----------------------------------------------------------------

def load_states(root: Path | None) -> dict[str, Path]:
    """`<state>/<mode>` -> still, for every <state>/light.png and <state>/dark.png under root.

    download-artifact may nest the tree one level down, so the state directories are the ones
    holding a light.png or dark.png, wherever they sit."""
    if root is None or not root.is_dir():
        return {}
    stills: dict[str, Path] = {}
    for mode in MODES:
        for path in sorted(root.rglob(f"{mode}.png")):
            if path.is_file():
                stills.setdefault(f"{path.parent.name}/{mode}", path)
    return stills


def why_for(key: str, lines: list[tuple[str, str]]) -> str | None:
    """A line names `<state>`, `<state>/<mode>`, a glob of either, or `*`."""
    state = key.split("/", 1)[0]
    return justify("", key, lines) or justify("", state, lines)


@dataclass
class Row:
    key: str
    kind: str  # changed, new, removed
    ratio: float | None
    box: tuple[int, int, int, int] | None
    note: str
    why: str | None


def compare(head_root: Path | None, base_root: Path | None, lines: list[tuple[str, str]],
            deadline: float = float("inf")) -> tuple[list[Row], int, float]:
    """Rows for the stills that differ, how many matched unchanged, and the largest unchanged ratio."""
    head = load_states(head_root)
    base = load_states(base_root)
    rows: list[Row] = []
    unchanged = 0
    largest_same = 0.0
    for key in sorted(set(head) | set(base)):
        if key not in base:
            rows.append(Row(key, "new", None, None, "", why_for(key, lines)))
            continue
        if key not in head:
            rows.append(Row(key, "removed", None, None, "", why_for(key, lines)))
            continue
        base_bytes, head_bytes = base[key].read_bytes(), head[key].read_bytes()
        if time.monotonic() > deadline and base_bytes != head_bytes:
            rows.append(Row(key, "changed", None, None, "files differ; not measured (time budget)",
                            why_for(key, lines)))
            continue
        result = diff_images(base_bytes, head_bytes)
        if result.ratio > CHANGED_RATIO:
            rows.append(Row(key, "changed", result.ratio, result.box, result.note, why_for(key, lines)))
        else:
            unchanged += 1
            largest_same = max(largest_same, result.ratio)
    return rows, unchanged, largest_same


# --- Baseline and messages -------------------------------------------------

@dataclass
class Baseline:
    directory: Path | None
    run_id: int | None = None
    run_url: str = ""
    sha: str = ""  # the build's short SHA, from the artifact's name
    problem: str = ""


def _extract_stills(archive_path: Path, dest: Path) -> Path | None:
    """Only <state>/<light|dark>.png members, by base name: nothing escapes dest."""
    wrote = False
    with zipfile.ZipFile(archive_path) as archive:
        for member in archive.infolist():
            parts = Path(member.filename).parts
            if member.is_dir() or len(parts) < 2 or parts[-1] not in {f"{m}.png" for m in MODES}:
                continue
            state = Path(parts[-2]).name
            if not state or state.startswith(".") or state in {"..", "."}:
                continue
            out = dest / state
            out.mkdir(parents=True, exist_ok=True)
            (out / parts[-1]).write_bytes(archive.read(member))
            wrote = True
    return dest if wrote else None


def fetch_baseline(repo: str, dest: Path, token: str, this_run: str,
                   api: str = "https://api.github.com") -> Baseline:
    """The stills of the newest nightly.yml run before this one that kept nightly-next-visual-gate-*."""
    listings = deadline_http.Deadline(LISTING_BUDGET_S)
    query = urllib.parse.urlencode({"status": "completed", "per_page": RUNS_TO_SCAN})
    try:
        runs = json.loads(_api(f"{api}/repos/{repo}/actions/workflows/{WORKFLOW_FILE}/runs?{query}",
                               token, listings))
    except Exception as error:  # noqa: BLE001 - warn only
        return Baseline(None, problem=f"listing {WORKFLOW_FILE} runs failed: {error}")
    current = int(this_run) if str(this_run).isdigit() else None
    found: tuple[dict, dict] | None = None
    for run in runs.get("workflow_runs") or []:
        run_id = run.get("id")
        if current is not None and isinstance(run_id, int) and run_id >= current:
            continue
        for page in range(1, ARTIFACT_PAGES + 1):
            try:
                url = f"{api}/repos/{repo}/actions/runs/{run_id}/artifacts?per_page=100&page={page}"
                listing = json.loads(_api(url, token, listings))
            except deadline_http.RequestTimeout as error:
                return Baseline(None, problem=f"listing nightly artifacts ran out of time: {error}")
            except Exception:  # noqa: BLE001 - skip that run
                break
            artifacts = listing.get("artifacts") or []
            match = next((a for a in artifacts if str(a.get("name", "")).startswith(ARTIFACT_PREFIX)
                          and not a.get("expired")), None)
            if match:
                found = (run, match)
                break
            if len(artifacts) < 100:
                break
        if found:
            break
    if not found:
        return Baseline(None, problem=(f"no earlier {WORKFLOW_FILE} run among the newest {RUNS_TO_SCAN} kept "
                                       f"{ARTIFACT_PREFIX}* (it keeps 3 days)"))
    run, artifact = found
    baseline = Baseline(None, run_id=run.get("id"), run_url=run.get("html_url") or "",
                        sha=str(artifact.get("name", ""))[len(ARTIFACT_PREFIX):])
    try:
        # A self-hosted Mac reuses RUNNER_TEMP's neighbours: an older run's stills must not mix in.
        shutil.rmtree(dest / "states", ignore_errors=True)
        archive = _download(f"{api}/repos/{repo}/actions/artifacts/{artifact['id']}/zip", token,
                            deadline_http.Deadline(DOWNLOAD_BUDGET_S), dest / "baseline.zip")
        baseline.directory = _extract_stills(archive, dest / "states")
        archive.unlink()
        if baseline.directory is None:
            baseline.problem = f"run {baseline.run_id}'s artifact has no <state>/light.png or dark.png"
    except Exception as error:  # noqa: BLE001 - warn only
        baseline.problem = f"downloading run {baseline.run_id}'s artifact failed: {error}"
    return baseline


def fetch_messages(repo: str, base: str, head: str, token: str,
                   api: str = "https://api.github.com") -> tuple[list[str], str]:
    """The commit messages between base and head and their pull requests' bodies, and a note on what
    was not read. A squash merge's message is the PR title and its commit list, not its body."""
    deadline = deadline_http.Deadline(MESSAGES_BUDGET_S)
    texts: list[str] = []
    try:
        compared = json.loads(_api(f"{api}/repos/{repo}/compare/{urllib.parse.quote(base)}..."
                                   f"{urllib.parse.quote(head)}?per_page=250", token, deadline))
    except Exception as error:  # noqa: BLE001 - warn only
        return [], f"reading the commits {base}...{head} failed: {error}"
    commits = compared.get("commits") or []
    notes: list[str] = []
    total = int(compared.get("total_commits") or len(commits))
    if total > len(commits):
        notes.append(f"only {len(commits)} of {total} commits were read")
    for commit in commits:
        texts.append(str((commit.get("commit") or {}).get("message") or ""))
    seen: set[int] = set()
    read = 0
    for commit in commits[-PR_BODY_CAP:]:
        try:
            pulls = json.loads(_api(f"{api}/repos/{repo}/commits/{commit.get('sha')}/pulls", token, deadline))
        except deadline_http.RequestTimeout:
            notes.append(f"pull request bodies read for {read} of {min(len(commits), PR_BODY_CAP)} commits "
                         "(time budget)")
            break
        except Exception:  # noqa: BLE001 - that commit counts on its message alone
            continue
        read += 1
        for pull in pulls if isinstance(pulls, list) else []:
            number = pull.get("number")
            if isinstance(number, int) and number not in seen:
                seen.add(number)
                texts.append(str(pull.get("body") or ""))
    if len(commits) > PR_BODY_CAP:
        notes.append(f"pull request bodies of the newest {PR_BODY_CAP} of {len(commits)} commits were read")
    return texts, "; ".join(notes)


def all_justifications(texts: list[str]) -> list[tuple[str, str]]:
    lines: list[tuple[str, str]] = []
    for text in texts:
        lines += justifications(text)
    return lines


# --- Report ----------------------------------------------------------------

def _pct(ratio: float | None) -> str:
    return "" if ratio is None else f"{ratio * 100:.2f}%"


def render(rows: list[Row], unchanged: int, largest_same: float, baseline: Baseline, head_found: bool,
           head_sha: str, messages_note: str) -> str:
    out = ["", TITLE, ""]
    if not head_found:
        out.append("This run captured no states (the capture step was skipped or failed); not compared.")
        out.append("")
        return "\n".join(out)
    if baseline.directory is None:
        out.append(f"No baseline: {baseline.problem or 'none given'}; not compared.")
        out.append("")
        return "\n".join(out)
    if baseline.run_id:
        out.append(f"Baseline: nightly run [{baseline.run_id}]({baseline.run_url}) at `{baseline.sha}`; this "
                   f"build `{head_sha[:8]}`; {unchanged} stills unchanged.")
    else:
        out.append(f"Baseline: {baseline.directory}; {unchanged} stills unchanged.")
    if messages_note:
        out.append(f"Visual-change lines: {messages_note}.")
    out.append("")
    out.append(f"A still is changed when over {CHANGED_RATIO * 100:.1f}% of its pixels move by more than "
               f"{CHANNEL_TOLERANCE}/255 in a channel; the largest unchanged still moved {_pct(largest_same)}.")
    out.append("")
    unjustified = [row for row in rows if row.why is None]
    if not rows:
        out.append("No desktop state differs from the previous nightly.")
    elif unjustified:
        out.append(f"**{len(unjustified)} desktop stills differ from the previous nightly with no Visual-change "
                   "line: is each wanted?**")
        out.append("")
        out.append("Justify one with a commit or pull request body line `Visual-change: <state glob or *>: <why>`.")
    else:
        out.append(f"{len(rows)} desktop stills differ from the previous nightly, each with a Visual-change line.")
    if rows:
        out += ["", "| State | Change | Pixels | Region | Justification |", "|---|---|---|---|---|"]
        for row in sorted(rows, key=lambda r: (r.why is not None, r.kind, r.key)):
            region = f"{row.box[2]}x{row.box[3]} at {row.box[0]},{row.box[1]}" if row.box else row.note
            verdict = "unjustified" if row.why is None else f"justified: {row.why}".replace("|", "\\|")
            out.append(f"| `{row.key}` | {row.kind} | {_pct(row.ratio)} | {region} | {verdict} |")
    out.append("")
    return "\n".join(out)


def warning(rows: list[Row]) -> str:
    """One workflow command line when any still differs with no justification, else ""."""
    unjustified = [row.key for row in rows if row.why is None]
    if not unjustified:
        return ""
    shown = ", ".join(unjustified[:8]) + (f" and {len(unjustified) - 8} more" if len(unjustified) > 8 else "")
    return (f"::warning title=Desktop states changed::{len(unjustified)} desktop stills differ from the previous "
            f"nightly with no Visual-change line: {shown}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--head-root", type=Path, required=True, help="this run's capture directory")
    parser.add_argument("--head-sha", default=os.environ.get("BUILD_SHA", ""))
    parser.add_argument("--baseline-root", type=Path, help="the baseline's <state>/<mode>.png, already on disk")
    parser.add_argument("--baseline-sha", default="", help="with --baseline-root: its build SHA")
    parser.add_argument("--fetch-baseline", action="store_true", help="download the previous nightly's")
    parser.add_argument("--messages", type=Path,
                        help="a JSON list of commit messages and PR bodies (default: read from GitHub)")
    parser.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", ""))
    parser.add_argument("--work", type=Path, default=Path("desktop-visual-baseline"))
    parser.add_argument("--out", type=Path, required=True, help="appended to (the step summary)")
    args = parser.parse_args(argv)

    started = time.monotonic()
    rows: list[Row] = []
    try:
        head_found = bool(load_states(args.head_root))
        token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN") or ""
        if not head_found:
            baseline = Baseline(None, problem="nothing to compare")
        elif args.fetch_baseline:
            if not token or not args.repo:
                baseline = Baseline(None, problem="no GitHub token or repository to read it with")
            else:
                baseline = fetch_baseline(args.repo, args.work, token, os.environ.get("GITHUB_RUN_ID", ""))
        else:
            baseline = Baseline(args.baseline_root if load_states(args.baseline_root) else None,
                                sha=args.baseline_sha, problem="" if load_states(args.baseline_root)
                                else "the baseline has no <state>/light.png or dark.png")
        unchanged, largest_same, note = 0, 0.0, ""
        if head_found and baseline.directory is not None:
            if args.messages is not None:
                texts = json.loads(args.messages.read_text())
            elif token and args.repo and baseline.sha and args.head_sha:
                texts, note = fetch_messages(args.repo, baseline.sha, args.head_sha, token)
            else:
                texts, note = [], "no commits read (no token, repository or SHA)"
            rows, unchanged, largest_same = compare(args.head_root, baseline.directory,
                                                    all_justifications([str(t) for t in texts]),
                                                    started + TIME_BUDGET_S)
        text = render(rows, unchanged, largest_same, baseline, head_found, args.head_sha, note)
        text += f"\n<sub>Compared in {time.monotonic() - started:.0f} s by scripts/ci/desktop_visual_diff.py.</sub>\n"
    except Exception as error:  # noqa: BLE001 - warn only, never fail the job
        rows = []
        text = f"\n{TITLE}\n\nThe desktop state diff could not run: {error!r}\n"
    try:
        with args.out.open("a") as out:
            out.write(text)
    except OSError as error:
        print(f"could not write {args.out}: {error}", file=sys.stderr)
        print(text)
    line = warning(rows)
    if line:
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
