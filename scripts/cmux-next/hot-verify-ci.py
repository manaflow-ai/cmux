#!/usr/bin/env python3
"""The CI side of hot-verify (.github/workflows/cmux-next-hot-verify.yml): look first, then test.

Leo, 2026-11-15: "front load that. Just screenshot it, take a video, touch it, interact with it, click around
with it, and then push it through the various testing instead of the other way around." And: "maybe the code
doesn't even need to be compiled". A pull request whose change the engine (scripts/cmux-next/hot-verify.py) can
put onto a running NEXT nightly with no build is looked at on a fleet Mac minutes after the push, and the PR gets
one comment with what it looks like.

    hot-verify-ci.py verdict PLAN_OUTPUT            the engine's `plan` output -> GITHUB_OUTPUT lines
    hot-verify-ci.py hq-ref VERSION_JSON            the controller's /v1/version -> the HQ main commit, or nothing
    hot-verify-ci.py queue-bound STATUS_JSON        the controller's /v1/status -> seconds a look waits for a Mac
    hot-verify-ci.py pack --pr N --head SHA --nonce NONCE [--video]
                                                    the fleet step's inputs as z-chunks, one per line
    hot-verify-ci.py nightly-commit FEED_XML        the NEXT feed -> the CMUXCommit of the nightly a look copies, or nothing
    LOOK_RESULT=JSON hot-verify-ci.py result --pr N --head SHA
                                                    the build fleet controller's look_result -> state, step, url
                                                    (the signed out.tar link, or empty) and reason lines
    hot-verify-ci.py unpack OUT_TAR DIR             the step's out.tar into DIR (data only: no links, no ..)
    hot-verify-ci.py stage DIR --pr N --head SHA --stage STAGE --text TEXT
                                                    check the receipt names HEAD; copy the media into STAGE under
                                                    their pr-media names; TEXT = every line the worker read
    hot-verify-ci.py render DIR --pr N --head SHA --stage-json FILE [--uploaded] [--repo R] [--run-url URL]
                     [--gallery] [--event-at EPOCH] the PR comment's Markdown (--uploaded: stage's files are on
                                                    pr-media, an mp4 with its gif)
    hot-verify-ci.py post BODY --pr N --head SHA [--repo R]
                                                    edit our earlier marker comment in place, else post one;
                                                    nothing when the PR moved past HEAD

Every file under DIR is data from a fleet worker: names are checked before use, nothing in it runs, and the
comment carries no worker or host name. The marker (first line of the comment, cmuxterm-hq's NOW metric counts
it) comes from the engine's receipt.json and must name the head this run tested:

    <!-- cmux-hot-verify sha=<PR head 40> app=<CMUXCommit> layers=<web,rust,customize> source=<worktree|pr> -->
"""
from __future__ import annotations

import argparse
import base64
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import time
import urllib.parse
import zlib
from pathlib import Path

REPO = "manaflow-ai/cmux"
MEDIA_BRANCH = "pr-media"
RAW_HOST = "https://raw.githubusercontent.com"
BOT = "github-actions[bot]"
SHA = re.compile(r"[0-9a-f]{40}")
MARKER_PREFIX = "<!-- cmux-hot-verify "
MARKER = re.compile(r"<!-- cmux-hot-verify sha=([0-9a-f]{40}) app=(\S+) layers=([a-z,]+) source=(worktree|pr) -->")
# The layers a look puts onto a running copy with no build (hot-verify.py plan). "daemon" is the same Rust layer.
LOOK_LAYERS = {"web": "web", "rust": "rust", "daemon": "rust", "customize": "customize"}
# pr-capture step_args (cmuxterm-hq build-fleet/pr-capture): zlib 9, base64url without padding, "z" chunks.
CHUNK_PREFIX = "z"
CHUNK_CHARS = 2000
MAX_CHUNKS = 16
MEDIA_SUFFIXES = (".png", ".mp4")
MAX_SHOTS = 24
OUT_MAX_BYTES = 600 * 1024 * 1024
THEMES = ("light", "dark")


class Refused(Exception):
    """A step result this side will not publish (the message says why, with no file content in it)."""


# ---------------------------------------------------------------- plan


def verdict(text: str) -> dict:
    """The engine's plan (`--json`, or its text form) -> {eligible, layers, needs_build, reason}."""
    plan: dict = {}
    try:
        loaded = json.loads(text)
        plan = loaded if isinstance(loaded, dict) else {}
    except ValueError:
        for line in text.splitlines():
            key, _, value = line.partition(":")
            key, value = key.strip(), value.strip()
            if key == "layers":
                plan["layers"] = [] if value in ("", "none") else [v.strip() for v in value.split(",") if v.strip()]
            elif key == "needs_build":
                plan["needs_build"] = value.lower() == "true"
    if "needs_build" not in plan:
        return {"eligible": False, "layers": [], "needs_build": False,
                "reason": "the engine's plan said nothing about needs_build"}
    raw = plan.get("layers") or []
    layers = sorted({LOOK_LAYERS.get(str(layer), str(layer)) for layer in raw}) if isinstance(raw, list) else []
    needs_build = plan.get("needs_build") is True
    other = [layer for layer in layers if layer not in LOOK_LAYERS.values()]
    if needs_build:
        reason = "this change needs a build; the build path (pr-capture, the gallery, the dev build) covers it"
    elif not layers:
        reason = "nothing in the app changes (docs, CI, tests, scripts): nothing to look at"
    elif other:
        reason = f"layers {', '.join(other)} are not ones a look can apply"
    else:
        reason = f"looks without a build: {', '.join(layers)}"
    return {"eligible": not needs_build and bool(layers) and not other, "layers": layers,
            "needs_build": needs_build, "reason": reason}


def output_lines(found: dict) -> str:
    return "".join(f"{key}={' '.join(str(value).split())}\n" for key, value in (
        ("eligible", "true" if found["eligible"] else "false"), ("layers", ",".join(found["layers"])),
        ("needs_build", "true" if found["needs_build"] else "false"), ("reason", found["reason"])))


def hq_ref(text: str) -> str:
    """The HQ main commit the controller runs (`commit`, from hq#11359), or "" when it names none."""
    try:
        data = json.loads(text)
    except ValueError:
        return ""
    if not isinstance(data, dict):
        return ""
    for key in ("commit", "hq_commit", "commit_full"):
        value = str(data.get(key) or "").strip().lower()
        if SHA.fullmatch(value):
            return value
    return ""


def pack(inputs: dict) -> list[str]:
    """INPUTS as the fleet step's arguments (the same packing as pr-capture's step_args)."""
    packed = base64.urlsafe_b64encode(zlib.compress(json.dumps(inputs, separators=(",", ":")).encode(), 9))
    text = packed.decode().rstrip("=")
    chunks = [CHUNK_PREFIX + text[i:i + CHUNK_CHARS] for i in range(0, len(text), CHUNK_CHARS)]
    if len(chunks) > MAX_CHUNKS:
        raise Refused(f"the step's inputs pack to {len(chunks)} arguments, more than {MAX_CHUNKS}")
    return chunks


def step_inputs(pr: int, head: str, nonce: str, video: bool, nightly: str = "latest") -> dict:
    if pr <= 0 or not SHA.fullmatch(head) or not re.fullmatch(r"hv-[A-Za-z0-9-]{1,80}", nonce):
        raise Refused("pr, a 40-hex head and an hv- nonce are required")
    return {"mode": "hot-verify", "schema": 1, "pr": pr, "head": head, "look": True, "video": video,
            "state": None, "nightly": nightly, "nonce": nonce}


# ---------------------------------------------------------------- the step's result


def unpack(tar_path: Path, into: Path) -> Path:
    """OUT_TAR's regular files into INTO (no links, no absolute or .. names); the folder holding receipt.json."""
    into.mkdir(parents=True, exist_ok=True)
    total = 0
    with tarfile.open(tar_path) as archive:
        for member in archive.getmembers():
            name = member.name
            parts = Path(name).parts
            if member.isdir():
                continue
            if not member.isfile() or name.startswith("/") or ".." in parts or not parts:
                raise Refused(f"out.tar holds an entry this side does not unpack: {name[:80]!r}")
            total += member.size
            if total > OUT_MAX_BYTES:
                raise Refused("out.tar is larger than a look's result can be")
            target = into.joinpath(*parts)
            target.parent.mkdir(parents=True, exist_ok=True)
            source = archive.extractfile(member)
            if source is None:
                continue
            with source, target.open("wb") as sink:
                shutil.copyfileobj(source, sink)
    found = sorted(into.rglob("receipt.json"), key=lambda p: len(p.parts))
    step = sorted(into.rglob("step.json"), key=lambda p: len(p.parts))
    return (found or step or [into / "receipt.json"])[0].parent


def read_json(path: Path) -> dict:
    try:
        data = json.loads(path.read_text())
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def worker_stop(step: dict) -> str:
    """Why the worker stopped with no receipt, from its step.json (cmuxterm-hq hot_verify_run.py: worker, error,
    phases), so the run log names the cause, not only that the receipt has no marker (runs 43779426587 and
    43758485104, 2026-11-16, each a different cause)."""
    phases = step.get("phases") if isinstance(step.get("phases"), dict) else {}
    spent = ", ".join(f"{name} {secs}s" for name, secs in phases.items() if isinstance(secs, (int, float)))
    error = " ".join(str(step.get("error")).split())[:500]
    return (f"the look stopped on {str(step.get('worker') or 'the worker')[:80]} with no receipt: {error}"
            + (f" (phases: {spent})" if spent else ""))


def check_marker(receipt: dict, head: str) -> re.Match:
    marker = str(receipt.get("marker") or "")
    found = MARKER.fullmatch(marker)
    if not found:
        raise Refused("the receipt has no hot-verify marker")
    if found.group(1) != head:
        raise Refused(f"the receipt's marker names {found.group(1)[:12]}, not the head {head[:12]}")
    return found


def media_name(head: str, rel: str) -> str:
    """The pr-media file name for a look's file: hv-<head12>-<rel with / as ->, one safe name per file."""
    flat = re.sub(r"[^A-Za-z0-9._-]+", "-", rel.replace("/", "-")).strip("-.")
    return f"hv-{head[:12]}-{flat}"


def look_media(out: Path) -> list[str]:
    """The look's shots and video, relative to OUT, in a fixed order (before/after first)."""
    files = [p for p in out.rglob("*") if p.is_file() and not p.is_symlink() and p.suffix in MEDIA_SUFFIXES]
    rels = sorted(str(p.relative_to(out)) for p in files)
    order = {f"{side}/{theme}.png": n for n, (side, theme) in
             enumerate((s, t) for s in ("before", "after") for t in THEMES)}
    return sorted(rels, key=lambda rel: (order.get(rel, len(order)), rel))


def text_lines(texts: dict, rels: list[str]) -> tuple[list[str], list[str]]:
    """(every line the worker read in RELS, the files whose text it did not read): the privacy check's input."""
    lines, unread = [], []
    for rel in rels:
        seen = texts.get(rel)
        got = seen.get("text") if isinstance(seen, dict) else None
        if not isinstance(got, list) or not all(isinstance(line, str) for line in got):
            unread.append(rel)
            continue
        lines.extend(got)
    return lines, unread


def stage(out: Path, pr: int, head: str, staging: Path, text_path: Path) -> dict:
    """Check the result, copy its media into STAGING under pr-media names, write every line read to TEXT_PATH.

    A file whose text the worker did not read is withheld (the privacy check could not judge it), and so is one
    the worker's own reader flagged."""
    receipt = read_json(out / "receipt.json")
    step = read_json(out / "step.json")
    if step.get("needs_build") or receipt.get("plan", {}).get("needs_build"):
        return {"needs_build": True, "staged": [], "withheld": []}
    if not receipt.get("marker") and step.get("error"):
        raise Refused(worker_stop(step))
    check_marker(receipt, head)
    if step and str(step.get("head") or head) != head:
        raise Refused("step.json names another head")
    texts = read_json(out / "text.json")
    rels = look_media(out)
    flagged = [rel for rel in rels if isinstance(texts.get(rel), dict) and texts[rel].get("privacy")]
    lines, unread = text_lines(texts, [rel for rel in rels if rel not in flagged])
    withheld = [f"{rel} (private text)" for rel in flagged] + [f"{rel} (its text was not read)" for rel in unread]
    keep = [rel for rel in rels if rel not in flagged and rel not in unread]
    shots = [rel for rel in keep if rel.endswith(".png")]
    if len(shots) > MAX_SHOTS:
        withheld += [f"{rel} (more than {MAX_SHOTS} shots)" for rel in shots[MAX_SHOTS:]]
        keep = [rel for rel in keep if rel not in shots[MAX_SHOTS:]]
    staging.mkdir(parents=True, exist_ok=True)
    staged = []
    for rel in keep:
        name = media_name(head, rel)
        shutil.copyfile(out / rel, staging / name)
        staged.append({"rel": rel, "name": name})
    text_path.parent.mkdir(parents=True, exist_ok=True)
    text_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    plan = {"needs_build": False, "staged": staged, "withheld": withheld}
    (staging.parent / "stage.json").write_text(json.dumps(plan, indent=2) + "\n")
    return plan


# ---------------------------------------------------------------- the comment


def uploaded_names(staged: dict) -> list[str]:
    """The names pr-media.py put on the branch for STAGED: each file, and the gif it makes from an mp4."""
    names = []
    for item in staged.get("staged") or []:
        name = str(item.get("name") or "") if isinstance(item, dict) else ""
        if name:
            names.append(name)
            if name.endswith(".mp4"):
                names.append(name[:-4] + ".gif")
    return names


def raw_url(repo: str, pr: int, name: str) -> str:
    return f"{RAW_HOST}/{repo}/{MEDIA_BRANCH}/{urllib.parse.quote(f'{pr}/{name}')}"


def seconds(value) -> str:
    return f"{value:g}" if isinstance(value, (int, float)) and not isinstance(value, bool) else "?"


def phases_text(receipt: dict, step: dict) -> str:
    shown = []
    for key in ("push_to_first_shot_s", "edit_to_visible_s"):
        if isinstance(receipt.get(key), (int, float)):
            shown.append(f"{key[:-2].replace('_', ' ')} {seconds(receipt[key])} s")
    engine = receipt.get("phases") if isinstance(receipt.get("phases"), dict) else {}
    if engine:
        shown.append("look (" + ", ".join(f"{k} {seconds(v)}" for k, v in engine.items()
                                          if isinstance(v, (int, float))) + ")")
    worker = step.get("phases") if isinstance(step.get("phases"), dict) else {}
    if worker:
        shown.append("fleet step (" + ", ".join(f"{k} {seconds(v)}" for k, v in worker.items()
                                                if isinstance(v, (int, float))) + ")")
    return " · ".join(shown) or "none recorded"


def render(out: Path, pr: int, head: str, repo: str = REPO, uploaded: list[str] | None = None,
           run_url: str = "", gallery: bool = False, event_at: float | None = None,
           withheld: list[str] | None = None, now: float | None = None) -> str:
    """The PR comment: the marker first, the app build and the tested version, before/after, video, timings."""
    receipt = read_json(out / "receipt.json")
    step = read_json(out / "step.json")
    found = check_marker(receipt, head)
    marker = found.group(0)
    layers = found.group(3)
    nightly = step.get("nightly") if isinstance(step.get("nightly"), dict) else {}
    app = receipt.get("app") if isinstance(receipt.get("app"), dict) else {}
    commit = str(nightly.get("commit") or app.get("commit") or found.group(2))
    build = str(nightly.get("build") or app.get("version") or "?")
    names = set(uploaded or [])
    url = {rel: raw_url(repo, pr, media_name(head, rel)) for rel in look_media(out) if media_name(head, rel) in names}
    lines = [marker,
             f"**First look: app** · hot-verified with no build · layers: {layers.replace(',', ', ')}",
             "",
             f"- Tested version: PR head `{head}`",
             f"- App build: NEXT nightly {build} (CMUXCommit `{commit[:12]}`), a copy on a fleet Mac with the "
             "change applied live",
             ""]
    grid = [f"{side}/{theme}.png" for side in ("before", "after") for theme in THEMES]
    if any(rel in url for rel in grid):
        lines += ["| | light | dark |", "|---|---|---|"]
        for side in ("before", "after"):
            cells = [f"![{side} {theme}]({url[f'{side}/{theme}.png']})" if f"{side}/{theme}.png" in url else "-"
                     for theme in THEMES]
            lines.append(f"| {side} | {cells[0]} | {cells[1]} |")
        lines.append("")
    others = [rel for rel in url if rel not in grid]
    shots = [f"![{rel}]({url[rel]})" for rel in others if rel.endswith(".png")]
    if shots:
        lines += ["Click-through:", "", *shots, ""]
    videos = [rel for rel in others if rel.endswith(".mp4")]
    for rel in videos:
        mp4 = media_name(head, rel)
        gif = Path(mp4).with_suffix(".gif").name
        if gif in names:
            lines += [f"![{rel}]({raw_url(repo, pr, gif)})", ""]
        lines += [f"Video: [{rel}]({url[rel]})", ""]
    if not url:
        lines += ["No shots were published from this look.", ""]
    steps = receipt.get("steps")
    if isinstance(steps, dict) and isinstance(steps.get("steps"), list):
        done = [s for s in steps["steps"] if isinstance(s, dict)]
        lines.append(f"Click-through steps: {sum(1 for s in done if s.get('ok'))} of {len(done)} ok")
    errors = [" ".join(str(e).split())[:200] for e in (receipt.get("errors") or []) if e][:3]
    if errors or step.get("error"):
        lines.append("Look errors: " + "; ".join(errors or [" ".join(str(step['error']).split())[:200]]))
    if withheld:
        lines.append(f"Withheld by the privacy check: {len(withheld)} file(s)")
    timing = f"Wall seconds: {phases_text(receipt, step)}"
    if event_at and now:
        timing += f" · push to this comment {round(now - event_at)} s"
    lines += [timing, ""]
    if gallery:
        lines += ["The gallery advisory run still checks the rendered states later; this look is the app itself.",
                  ""]
    tail = f"`cmux-ci hot-verify {pr} --look` repeats it"
    if run_url:
        tail = f"[run]({run_url}) · " + tail
    lines.append(f"<sub>{tail} · nothing was built for this look</sub>")
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------- posting


# A look that finished is posted even when the job's token is out of quota (run 43790108433, cmux#44086,
# 2026-11-16: "API rate limit exceeded for installation" threw the finished look away): a call refused for its
# rate limit waits for the reset GitHub's rate_limit endpoint names (which costs no quota) and is tried again, for
# at most QUOTA_WAIT_SECONDS in all (the publish job's timeout-minutes leaves room for it).
QUOTA_WAIT_SECONDS = 1800
QUOTA_RETRY_SECONDS = 60  # a secondary limit, or the reset unreadable: try again after this
RATE_LIMITED = re.compile(r"rate limit", re.IGNORECASE)


def quota_wait() -> float:
    """Seconds until the core quota resets, plus 5; QUOTA_RETRY_SECONDS when quota remains (a secondary limit)."""
    done = subprocess.run(["gh", "api", "rate_limit", "--jq", ".resources.core | \"\\(.remaining) \\(.reset)\""],
                          capture_output=True, text=True, timeout=60)
    try:
        remaining, reset = (int(part) for part in done.stdout.split())
    except ValueError:
        return QUOTA_RETRY_SECONDS
    return max(5.0, reset - time.time() + 5) if remaining == 0 else QUOTA_RETRY_SECONDS


def gh(*args: str, body: str | None = None) -> str:
    waited = 0.0
    while True:
        done = subprocess.run(["gh", *args], input=body, capture_output=True, text=True, timeout=120)
        if done.returncode == 0:
            return done.stdout
        why = (done.stderr or "").strip()[:300]
        what = f"gh {args[0]} {args[1] if len(args) > 1 else ''}"
        wait = quota_wait() if RATE_LIMITED.search(why) else None
        if wait is None or waited + wait > QUOTA_WAIT_SECONDS:
            raise Refused(f"{what} failed: {why}" + (f" (after {int(waited)}s waiting for quota)" if waited else ""))
        print(f"hot-verify-ci: {what} is out of quota; trying again in {int(wait)}s", file=sys.stderr)
        time.sleep(wait)
        waited += wait


def our_comment(listing: str, login: str = BOT) -> int | None:
    """The newest of LOGIN's comments whose first line starts with the marker prefix (JSON lines of id/login/head)."""
    found = None
    for line in listing.splitlines():
        try:
            item = json.loads(line)
        except ValueError:
            continue
        if isinstance(item, dict) and item.get("login") == login \
                and str(item.get("head") or "").startswith(MARKER_PREFIX):
            found = int(item["id"])
    return found


COMMENT_PAGES = 30  # 100 comments a page, one bounded call each (never gh api's paginate flag)


def comment_listing(pr: int, repo: str = REPO) -> str:
    """The PR's comments as JSON lines of id/login/head, read one page of 100 per call, at most COMMENT_PAGES."""
    lines: list[str] = []
    for page in range(1, COMMENT_PAGES + 1):
        chunk = gh("api", f"repos/{repo}/issues/{pr}/comments?per_page=100&page={page}",
                   "--jq", '.[] | {id: .id, login: .user.login, head: .body[0:40]}')
        got = [line for line in chunk.splitlines() if line.strip()]
        lines += got
        if len(got) < 100:
            return "\n".join(lines)
    raise Refused(f"#{pr} has more than {COMMENT_PAGES * 100} comments")


def post(body: str, pr: int, head: str, repo: str = REPO) -> str:
    # A look at a merged PR's merge commit (cmux-next-hot-verify.yml after the merge) posts too: the PR names that
    # commit as its merge_commit_sha. Any other head the PR is not at is an older look's.
    live, _, merge = gh("api", f"repos/{repo}/pulls/{pr}", "--jq",
                        '.head.sha + " " + (if .merged_at then (.merge_commit_sha // "") else "" end)').strip().partition(" ")
    if head not in (live, merge.strip()):
        return f"#{pr} moved to {live[:12]}; its own run comments"
    listing = comment_listing(pr, repo)
    existing = our_comment(listing)
    payload = json.dumps({"body": body})
    if existing is not None:
        gh("api", "-X", "PATCH", f"repos/{repo}/issues/comments/{existing}", "--input", "-", body=payload)
        return f"edited comment {existing}"
    gh("api", "-X", "POST", f"repos/{repo}/issues/{pr}/comments", "--input", "-", body=payload)
    return "posted a comment"


# ---------------------------------------------------------------- main


QUEUE_FLOOR, QUEUE_CAP = 1800, 10800


def queue_bound(text: str, step_class: str = "light") -> int:
    """How long a look waits for a Mac: the controller's reported p90 queue wait for the class (/v1/status
    `step_queue_wait_p90_seconds`), rounded up, between 30 min and 3 h; 30 min when it reports none."""
    try:
        data = json.loads(text)
        value = float(data["step_queue_wait_p90_seconds"][step_class])
    except (ValueError, TypeError, KeyError, OverflowError):
        return QUEUE_FLOOR
    if not value >= QUEUE_FLOOR:  # NaN, -inf and short waits
        return QUEUE_FLOOR
    return int(max(QUEUE_FLOOR, min(QUEUE_CAP, -(-value // 1))))  # clamped before int(): inf stays out of it


# ---------------------------------------------------------------- the nightly and the controller's result

PICKER = Path(__file__).resolve().parents[1] / "ci" / "nightly_next_launch_smoke.py"
SOURCE_COMMIT = re.compile(r"<cmux:sourceCommit>\s*([0-9a-f]{40})\s*</cmux:sourceCommit>")


def nightly_commit(feed: str, picker: Path = PICKER) -> str:
    """The CMUXCommit of the nightly a fleet look copies: the NEXT feed's item cmux's own pick() chooses (the item
    the worker's hot_verify_run.py takes), its cmux:sourceCommit; "" when the feed or the item names none."""
    try:
        spec = importlib.util.spec_from_file_location("hot_verify_nightly_pick", picker)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        build = module.pick(feed)[0]
    except (OSError, ValueError, AttributeError, ImportError, SyntaxError):
        return ""
    for item in module.ITEM.findall(feed):
        version = module.VERSION.search(item)
        if version and int(version.group(1)) == build:
            found = SOURCE_COMMIT.search(item)
            return found.group(1) if found else ""
    return ""


RESULT_STATES = ("done", "failed", "cancelled", "unsubmitted")


def look_result(text: str, pr: int, head: str) -> dict:
    """The controller's look_result (cmuxterm-hq build-fleet/cmd/controller/hot_verify_look.go) for PR at HEAD:
    {state, step, url (the signed out.tar GET, or ""), reason}. Refused when it names another PR or head."""
    try:
        data = json.loads(text)
    except ValueError:
        raise Refused("look_result is not JSON") from None
    if not isinstance(data, dict) or data.get("pr") != pr or data.get("head") != head:
        raise Refused("look_result names another pull request or head")
    state = data.get("state")
    if state not in RESULT_STATES:
        raise Refused(f"look_result has no known state: {str(state)[:40]!r}")
    url = str(data.get("artifact_url") or "")
    if url and not url.startswith("https://"):
        raise Refused("look_result's out.tar link is not https")
    step = str(data.get("step_id") or "")
    step = step if re.fullmatch(r"[0-9a-f]{1,64}", step) else ""
    code = data.get("exit_code")
    reason = " ".join(str(data.get("error") or "").split())[:300]
    waited = data.get("queued_s")
    return {"state": state, "step": step, "url": url,
            "reason": f"step {step or 'none'} {state}" + (f" (exit {code})" if isinstance(code, int) else "")
                      + (f" after {waited} s in the queue" if isinstance(waited, int) and waited > 0 else "")
                      + (f": {reason}" if reason else "")}


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    sub = ap.add_subparsers(dest="command", required=True)
    p = sub.add_parser("verdict")
    p.add_argument("plan", type=Path)
    p = sub.add_parser("queue-bound")
    p.add_argument("status", type=Path)
    p = sub.add_parser("hq-ref")
    p.add_argument("version", type=Path)
    p = sub.add_parser("pack")
    p.add_argument("--pr", type=int, required=True)
    p.add_argument("--head", required=True)
    p.add_argument("--nonce", required=True)
    p.add_argument("--video", action="store_true")
    p = sub.add_parser("unpack")
    p.add_argument("tar", type=Path)
    p.add_argument("dir", type=Path)
    p = sub.add_parser("nightly-commit")
    p.add_argument("feed", type=Path)
    p = sub.add_parser("result")
    p.add_argument("--pr", type=int, required=True)
    p.add_argument("--head", required=True)
    for name in ("stage", "render", "post"):
        p = sub.add_parser(name)
        p.add_argument("path", type=Path)
        p.add_argument("--pr", type=int, required=True)
        p.add_argument("--head", required=True)
        p.add_argument("--repo", default=REPO)
        if name == "stage":
            p.add_argument("--stage", type=Path, required=True)
            p.add_argument("--text", type=Path, required=True)
        if name == "render":
            p.add_argument("--run-url", default="")
            p.add_argument("--gallery", action="store_true")
            p.add_argument("--event-at", type=float)
            p.add_argument("--uploaded", action="store_true")
            p.add_argument("--stage-json", type=Path, required=True)
    a = ap.parse_args(argv)
    try:
        if a.command == "verdict":
            text = a.plan.read_text(errors="replace") if a.plan.is_file() else ""
            print(output_lines(verdict(text)), end="")
        elif a.command == "queue-bound":
            print(queue_bound(a.status.read_text(errors="replace") if a.status.is_file() else ""))
        elif a.command == "hq-ref":
            print(hq_ref(a.version.read_text(errors="replace") if a.version.is_file() else ""))
        elif a.command == "pack":
            print("\n".join(pack(step_inputs(a.pr, a.head, a.nonce, a.video))))
        elif a.command == "unpack":
            print(unpack(a.tar, a.dir))
        elif a.command == "nightly-commit":
            print(nightly_commit(a.feed.read_text(errors="replace") if a.feed.is_file() else ""))
        elif a.command == "result":
            found = look_result(os.environ.get("LOOK_RESULT", ""), a.pr, a.head)
            print("".join(f"{key}={found[key]}\n" for key in ("state", "step", "url", "reason")), end="")
        elif a.command == "stage":
            print(json.dumps(stage(a.path, a.pr, a.head, a.stage, a.text)))
        elif a.command == "render":
            staged = read_json(a.stage_json)
            withheld = staged.get("withheld")
            print(render(a.path, a.pr, a.head, a.repo, uploaded_names(staged) if a.uploaded else [], a.run_url,
                         a.gallery, a.event_at, withheld if isinstance(withheld, list) else None, time.time()), end="")
        elif a.command == "post":
            print(post(a.path.read_text(), a.pr, a.head, a.repo))
    except Refused as error:
        print(f"hot-verify-ci: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
