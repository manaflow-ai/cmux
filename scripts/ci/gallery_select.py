#!/usr/bin/env python3
"""Pick, describe and report the gallery states gallery-advisory.yml renders for a pull request.

The advisory renders a capped sample of the gallery states a change touches, before and after.
Which states fill the cap decides whether the receipt shows the change at all: a pull request
that edits a shared stylesheet touches every agent-pane entry, and the first states in file order
are then unrelated to it. touched.ts ranks the touched entries (own source, a gallery file that
names the changed component, importers by hops, the same folder, a host stylesheet, a broad
change); `select` keeps that order. A `Gallery: id, id` line in the pull request body (entry ids,
or `entry/variant`) replaces the ranking.

  select   --touched T --head-all H --base-all B [--cap 16] --out-dir D   (PR_BODY in the env)
           -> D/head.json, D/base.json (the cases each side renders), D/selection.json
  entries  --touched T                                                   (PR_BODY in the env)
           -> the comma list of entries the manifests need (touched plus the override)
  review   --selection S --outcomes O --pr N --head-sha S --base-sha S --repo R --run-id N --out F
           -> gallery-review.json, the machine-readable receipt (schema cmux.gallery-review.v1)
  section  --review F --out F     the PR status comment's `gallery` section
  stale    --current F --head S   a `gallery` section for a head that moved, or nothing

`review` and `section` run in the trusted comment job on data the pull request's code wrote, so
they keep only states the selection named and ids and file names that are plain.
"""
from __future__ import annotations

import argparse
import datetime
import json
import math
import os
import re
import sys
from pathlib import Path

CAP = 16
SCHEMA = "cmux.gallery-review.v1"
ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")
OVERRIDE_ID = re.compile(rf"{ID.pattern}(?:/{ID.pattern})?")
KEY = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*\.png")
PATH = re.compile(r"[A-Za-z0-9._/-]+")
SHA = re.compile(r"[0-9a-f]{40}")
OVERRIDE_LINE = re.compile(r"^[ \t]*gallery:[ \t]*(?P<ids>.+)$", re.I | re.M)
HEAD_MARK = re.compile(r"<!-- gallery-head: (?P<sha>[0-9a-f]{40}) -->")
STALE = "**Stale**"
SHOWN_IN_SECTION = 40


def override_ids(body: str | None) -> list[str]:
    """The ids on the first `Gallery:` line of a pull request body; anything not plain is dropped."""
    match = OVERRIDE_LINE.search(body or "")
    if not match:
        return []
    out: list[str] = []
    for raw in re.split(r"[,\s]+", match["ids"]):
        token = raw.strip("`'\"")
        if OVERRIDE_ID.fullmatch(token) and token not in out:
            out.append(token)
    return out


def manifest_entries(touched: dict, body: str | None) -> list[str]:
    """The entries the manifests must list: every touched one and every one the override names."""
    return sorted(set(touched.get("entries", [])) | {i.split("/", 1)[0] for i in override_ids(body)})


def state_of(case: dict) -> tuple[str, str]:
    params = case.get("params", {})
    return str(params.get("entry", case.get("id", ""))), str(params.get("variant", ""))


def select(touched: dict, head_all: list[dict], base_all: list[dict], *, body: str | None,
           cap: int = CAP) -> tuple[list[dict], list[dict], dict]:
    """The head cases, base cases and selection record for the first `cap` states in rank order."""
    head_states = {state_of(c) for c in head_all}
    base_states = {state_of(c) for c in base_all}
    # Every state, head order first, then those only the base has (the ones the PR removes).
    ordered: list[tuple[str, str]] = []
    for case in head_all + base_all:
        if state_of(case) not in ordered:
            ordered.append(state_of(case))
    # Within an entry, the states the PR adds or removes come first (a stable sort).
    ordered.sort(key=lambda state: (state in head_states) == (state in base_states))
    requested = override_ids(body)
    override, ignored = [], []
    picks: list[tuple[tuple[str, str], dict]] = []
    for wanted in requested:
        entry, _, variant = wanted.partition("/")
        matched = [state for state in ordered if state[0] == entry and (not variant or state[1] == variant)]
        (override if matched else ignored).append(wanted)
        for state in matched:
            if state not in [p[0] for p in picks]:
                picks.append((state, {"why": "pr-body", "file": "", "distance": 0}))
    # A `Gallery:` line that names no state (prose, a typo) falls back to the ranking.
    if not picks:
        for row in touched.get("ranked", []):
            for state in ordered:
                if state[0] == row.get("id") and state not in [p[0] for p in picks]:
                    picks.append((state, {"why": str(row.get("why", "")), "file": str(row.get("file", "")),
                                          "distance": int(row.get("distance", 0))}))
    # No entry takes more than half the cap while another touched entry waits: the
    # first pass takes up to that many states of each entry in rank order, then
    # the rest fills what is left. An entry with many variants (agent-pane.subagents
    # has 16) otherwise hides every other entry the change reaches. An override is
    # taken as written.
    if requested and override:
        shown = picks[:cap]
    else:
        share, taken, first, rest = max(cap // 2, 1), {}, [], []
        for pick in picks:
            entry = pick[0][0]
            (first if taken.get(entry, 0) < share else rest).append(pick)
            taken[entry] = taken.get(entry, 0) + 1
        chosen_picks = (first + rest)[:cap]
        shown = [pick for pick in picks if pick in chosen_picks]
    chosen = {state for state, _ in shown}
    order = {state: index for index, (state, _) in enumerate(shown)}
    head = sorted((c for c in head_all if state_of(c) in chosen), key=lambda c: order[state_of(c)])
    base = sorted((c for c in base_all if state_of(c) in chosen), key=lambda c: order[state_of(c)])
    states = [{
        "state": f"{entry}/{variant}", "entry": entry, "variant": variant, "selected_by": why,
        "status_hint": "new" if (entry, variant) not in base_states else
        "removed" if (entry, variant) not in head_states else "existing",
    } for (entry, variant), why in shown]
    selection = {"states": states, "more": len(picks) - len(shown), "cap": cap, "override": override,
                 "override_ignored": ignored, "touched": len(touched.get("entries", [])), "all": bool(touched.get("all"))}
    return head, base, selection


def review(selection: dict, outcomes: list[dict], *, pr: int, head_sha: str, base_sha: str, repo: str,
           run_id: int, cases: list[dict] | None = None) -> dict:
    """The machine-readable receipt: each rendered image, its diff and the change that picked it.

    `cases` (the rendered head and base manifests) give each case's color scheme."""
    scheme = {str(c.get("id")): str(c.get("params", {}).get("colorScheme", "")) for c in cases or []}
    artifact = f"gallery-advisory-{pr}-{head_sha}"
    rank = {s["state"]: (i, s) for i, s in enumerate(selection.get("states", []))
            if OVERRIDE_ID.fullmatch(str(s.get("state", ""))) and "/" in str(s.get("state", ""))}
    images = []
    for position, outcome in enumerate(outcomes):
        state = f"{outcome.get('entry')}/{outcome.get('variant')}"
        key = str(outcome.get("key", ""))
        if state not in rank or not KEY.fullmatch(key):
            continue
        status = str(outcome.get("status", ""))
        picked = rank[state][1].get("selected_by", {})
        file = str(picked.get("file", ""))
        images.append({
            "state": state, "entry": state.split("/", 1)[0], "variant": state.split("/", 1)[1],
            "theme": str(outcome.get("theme", "")), "scheme": scheme.get(str(outcome.get("id", "")), ""),
            "engine": str(outcome.get("engine", "")), "status": status,
            "diff_percent": round(float(outcome.get("ratio", 0)) * 100, 4),
            "base_image": f"base/{key}" if status not in ("new", "broken") else None,
            "head_image": f"head/{key}" if status not in ("removed",) else None,
            "before_after": f"diff/thumbs/{key}" if outcome.get("thumb") else None,
            "selected_by": {"why": str(picked.get("why", "")), "file": file if PATH.fullmatch(file) else "",
                            "distance": int(picked.get("distance", 0))},
            "_order": (rank[state][0], position),
        })
    images.sort(key=lambda image: image.pop("_order"))
    return {
        "schema": SCHEMA, "repo": repo, "pr": pr, "head_sha": head_sha, "base_sha": base_sha, "run_id": run_id,
        "artifact": artifact,
        "artifact_api": f"https://api.github.com/repos/{repo}/actions/artifacts?name={artifact}",
        "download": f"gh run download {run_id} -R {repo} -n {artifact}",
        "paths": "image paths are relative to the artifact root",
        "states": [s["state"] for s in selection.get("states", []) if s["state"] in rank],
        "more": int(selection.get("more", 0)), "override": [i for i in selection.get("override", [])
                                                          if OVERRIDE_ID.fullmatch(str(i))],
        "images": images,
    }


SOURCE = "linux-fallback"
SOURCE_LABEL = "linux · fallback fonts · Chromium (component)"
RANK_REASON = {"own": "own-source", "pr-body": "override", "host-stylesheet": "rest", "everything": "rest"}


def visual_manifest(doc: dict, *, generated_at: str) -> dict:
    """The team feed's shape (cmux.visual-manifest.v1) of a review document.

    Gallery images are not published to the public pr-media branch (#21400), so `url` is None and
    `artifact_path` names the file inside the run's artifact (`doc["download"]` fetches it).
    """
    def side(path: str | None, sha: str) -> dict | None:
        return {"url": None, "sha": sha, "artifact_path": path} if path else None

    states = []
    for image in doc["images"]:
        picked = image["selected_by"]
        reason = f"imports:{picked['distance']}" if picked["why"] == "imports" else \
            RANK_REASON.get(picked["why"], picked["why"])
        states.append({
            "id": image["state"], "title": image["state"],
            "theme": image["theme"] if image["theme"] in ("dark", "light") else theme_scheme(image),
            # Headless Chromium on Linux with the runner's fallback fonts, not macOS WebKit.
            "source": SOURCE, "changed": image["status"] != "unchanged", "status": image["status"],
            "diff_percent": image["diff_percent"], "rank_reason": reason, "rank_file": picked["file"],
            "before": side(image["base_image"], doc["base_sha"]), "after": side(image["head_image"], doc["head_sha"]),
            "before_after": side(image["before_after"], doc["head_sha"]),
        })
    return {"schema": "cmux.visual-manifest.v1", "repo": doc["repo"], "pr": doc["pr"], "head": doc["head_sha"],
            "base": doc["base_sha"], "producer": "gallery-advisory",
            "run_url": f"https://github.com/{doc['repo']}/actions/runs/{doc['run_id']}",
            "artifact": doc["artifact"], "download": doc["download"],
            "generated_at": generated_at, "more": doc["more"], "states": states}


def previews(doc: dict) -> dict:
    """HQ's preview tool shape (cmux.pr-previews.v1, tools/previews in cmuxterm-hq)."""
    return {"schema": "cmux.pr-previews.v1", "head_sha": doc["head_sha"], "base_sha": doc["base_sha"],
            "states": [{
                "id": image["state"], "source": SOURCE, "kind": "story", "label": SOURCE_LABEL,
                "status": image["status"] if image["status"] in ("changed", "new", "removed", "broken", "unchanged")
                else "changed",
                "caption": f"{image['state']} ({image.get('scheme') or image['theme']}), "
                           f"{image['diff_percent']:.3g}% changed; picked by {image['selected_by']['why']}"
                           + (f" {image['selected_by']['file']}" if image["selected_by"]["file"] else ""),
                "before": image["base_image"], "after": image["head_image"],
            } for image in doc["images"]]}


def theme_scheme(image: dict) -> str:
    return image.get("scheme", "") if image.get("scheme") in ("dark", "light") else ""


STATUSES = ("changed", "new", "removed", "broken", "nondeterministic", "unchanged")


def plain(value: object, pattern: re.Pattern = PATH) -> str:
    text = str(value or "")
    return text if pattern.fullmatch(text) else ""


def clean(doc: dict) -> dict:
    """A review document reduced to plain values: the comment job reads one the PR's code wrote."""
    images = []
    for image in doc.get("images", []) if isinstance(doc.get("images"), list) else []:
        if not isinstance(image, dict) or not OVERRIDE_ID.fullmatch(str(image.get("state", ""))):
            continue
        picked = image.get("selected_by") if isinstance(image.get("selected_by"), dict) else {}
        try:
            diff, distance = float(image.get("diff_percent", 0)), int(picked.get("distance", 0))
            if not math.isfinite(diff):
                diff = 0.0
        except (TypeError, ValueError, OverflowError):
            diff, distance = 0.0, 0
        images.append({
            "state": image["state"], "theme": re.sub(r"[^A-Za-z0-9 ._-]", "", str(image.get("theme", "")))[:40],
            "status": image.get("status") if image.get("status") in STATUSES else "unknown",
            "diff_percent": diff,
            "selected_by": {"why": plain(picked.get("why"), ID), "file": plain(picked.get("file")), "distance": distance},
        })
    try:
        more = int(doc.get("more", 0))
    except (TypeError, ValueError, OverflowError):
        more = 0
    return {
        "head_sha": plain(doc.get("head_sha"), SHA), "download": str(doc.get("download", "")).replace("`", ""),
        "states": [s for s in doc.get("states", []) if OVERRIDE_ID.fullmatch(str(s))] if isinstance(doc.get("states"), list) else [],
        "more": more, "override": bool(doc.get("override")), "images": images,
    }


def section(doc: dict) -> str:
    """The `gallery` section of the PR status comment: what was rendered, why, and how to fetch it."""
    doc = clean(doc)
    head = doc["head_sha"]
    changed = [i for i in doc["images"] if i["status"] in ("changed", "new", "removed", "broken")]
    lines = [
        f"<!-- gallery-head: {head} -->" if head else "",
        f"Gallery before/after for `{head[:7]}`: {len(doc['states'])} states rendered, "
        f"{len(changed)} images differ"
        + (f", {doc['more']} more touched states not rendered" if doc["more"] else "")
        + (" (picked by the `Gallery:` line in the PR body)" if doc["override"] else "")
        + ". Images are in the run's artifact, not on this public PR; the independent review of this head "
          "reads them on its own, so the PR needs no hand-made screenshots of these states.",
        "",
        f"`{doc['download']}` (then read `gallery-review.json`)",
        "",
        "<details><summary>States</summary>",
        "",
        "| State | Theme | Status | Diff | Picked by |",
        "| --- | --- | --- | --- | --- |",
    ]
    for image in doc["images"][:SHOWN_IN_SECTION]:
        picked = image["selected_by"]
        why = picked["why"] + (f" `{Path(picked['file']).name}`" if picked["file"] else "") + \
            (f" ({picked['distance']} hops)" if picked["distance"] else "")
        lines.append(f"| `{image['state']}` | {image['theme'].replace('|', ' ')} | {image['status']} | "
                     f"{image['diff_percent']:.3g}% | {why} |")
    if len(doc["images"]) > SHOWN_IN_SECTION:
        lines.append(f"| {len(doc['images']) - SHOWN_IN_SECTION} more images in gallery-review.json | | | | |")
    lines += ["", "</details>", "",
              "<sub>Pick other states with a `Gallery: entry.id, entry.id/variant` line in the PR body.</sub>"]
    return "\n".join(line for i, line in enumerate(lines) if line or i) + "\n"


def stale(current: str | None, head: str) -> str | None:
    """The section marked stale when it shows another head; None when it is current or absent."""
    if not current:
        return None
    mark = HEAD_MARK.search(current)
    if not mark or mark["sha"] == head:
        return None
    body = current.split("\n", 1)[1] if current.startswith(STALE) else current
    return f"{STALE}: these images are of `{mark['sha'][:7]}`; the head is now `{head[:7]}` and a new capture is running.\n{body}"


def read_json(path: str):
    return json.loads(Path(path).read_text())


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    sub = parser.add_subparsers(dest="command", required=True)
    s = sub.add_parser("select")
    s.add_argument("--touched", required=True)
    s.add_argument("--head-all", required=True)
    s.add_argument("--base-all", required=True)
    s.add_argument("--cap", type=int, default=CAP)
    s.add_argument("--out-dir", required=True)
    e = sub.add_parser("entries")
    e.add_argument("--touched", required=True)
    r = sub.add_parser("review")
    r.add_argument("--selection", required=True)
    r.add_argument("--outcomes", required=True)
    r.add_argument("--pr", type=int, required=True)
    r.add_argument("--head-sha", required=True)
    r.add_argument("--base-sha", required=True)
    r.add_argument("--repo", required=True)
    r.add_argument("--run-id", type=int, required=True)
    r.add_argument("--cases", nargs="*", default=[], help="the rendered manifests, for each case's color scheme")
    r.add_argument("--out", required=True)
    r.add_argument("--visual-out", help="also write the feed's cmux.visual-manifest.v1 here")
    r.add_argument("--previews-out", help="also write HQ's cmux.pr-previews.v1 here")
    c = sub.add_parser("section")
    c.add_argument("--review", required=True)
    c.add_argument("--out", required=True)
    t = sub.add_parser("stale")
    t.add_argument("--current", required=True)
    t.add_argument("--head", required=True)
    args = parser.parse_args(argv)
    body = os.environ.get("PR_BODY", "")
    if args.command == "select":
        head, base, selection = select(read_json(args.touched), read_json(args.head_all), read_json(args.base_all),
                                       body=body, cap=args.cap)
        out = Path(args.out_dir)
        for name, data in (("head.json", head), ("base.json", base), ("selection.json", selection)):
            (out / name).write_text(json.dumps(data, indent=2) + "\n")
        print(f"gallery: rendering {len(selection['states'])} states, {selection['more']} more touched")
    elif args.command == "entries":
        print(",".join(manifest_entries(read_json(args.touched), body)))
    elif args.command == "review":
        for name in ("head_sha", "base_sha"):
            if not SHA.fullmatch(getattr(args, name)):
                parser.error(f"--{name.replace('_', '-')} must be a full SHA")
        doc = review(read_json(args.selection), read_json(args.outcomes), pr=args.pr, head_sha=args.head_sha,
                     base_sha=args.base_sha, repo=args.repo, run_id=args.run_id,
                     cases=[c for path in args.cases for c in read_json(path)])
        Path(args.out).write_text(json.dumps(doc, indent=2) + "\n")
        if args.visual_out:
            now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            Path(args.visual_out).write_text(json.dumps(visual_manifest(doc, generated_at=now), indent=2) + "\n")
        if args.previews_out:
            Path(args.previews_out).write_text(json.dumps(previews(doc), indent=2) + "\n")
    elif args.command == "section":
        Path(args.out).write_text(section(read_json(args.review)))
    else:
        current = Path(args.current).read_text() if Path(args.current).exists() else None
        text = stale(current, args.head)
        if text is not None:
            sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
