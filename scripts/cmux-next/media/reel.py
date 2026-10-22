#!/usr/bin/env python3
"""Build a nightly reel of the cmux NEXT "after" clips for one build's pull requests.

    reel.py --build B [--notes-url URL | --notes FILE] --out DIR [--dry-run]
            [--repo manaflow-ai/cmux] [--clips FILE] [--tree FILE] [--heads FILE]
            [--allow-unsigned] [--allow-truncated] [--publish]

The pull requests come from the build's signed release notes (release-notes.py
`build`: each item is {title, author, pr}), in notes order, once each. Their
clips come from the `pr-media` branch, where publish.py uploads each tour at
<pr>/<sha8>/next-<tour>/tour.mp4 and capture_paths.py names the head capture
`<tour>-after`. One `git/trees` listing finds them all; a pull request with
several captures takes the one at its current head (one GraphQL query), and a
hand-posted <pr>/<name>.mp4 is used only when no tour clip exists.

Each clip gets a 1.5 s title card ("#N title") and is scaled to publish.py's
video profile, then all of them are joined into DIR/reel.mp4. DIR/reel.json and
a self-contained DIR/index.html list every pull request in the build, with its
clip or "no clip". `--dry-run` prints the plan and writes only reel.json.

Notes must verify against the content-signing key (a local --notes file needs
FILE.sig unless --allow-unsigned), and a truncated listing stops the build
unless --allow-truncated. `--publish` uploads index.html, reel.json and reel.mp4
to the pr-media branch at nightly-next/<build>/ (a folder the pr-media prune
keeps, unlike pull request folders) and prints their URLs. Downloads are limited to files-next.cmux.com (notes)
and the repo's pr-media branch on raw.githubusercontent.com (clips), with no
redirects.

`--clips FILE` (a JSON map of pr to a local path or pr-media URL) skips discovery;
`--tree FILE` and `--heads FILE` (a saved trees response, a map of pr to head
sha) stand in for the GitHub calls.
"""

from __future__ import annotations

import argparse
import html
import importlib.util
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
from typing import Any
import urllib.error
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[3]
NOTES_HOST = "https://files-next.cmux.com/"
NOTES_BASE = f"{NOTES_HOST}nightly-next/next/notes"
# The content-signing public key the nightly verifies notes with (.github/workflows/nightly.yml).
CONTENT_PUBLIC_KEY = "AnrDI4vqN4lFGX2IpzeWPZsa/Hk7yQMkVIKppFwAst4="
CARD_SECONDS = 1.5
CLIP_SECONDS = 60
TITLE_MAX = 60
# path_map.py's TOUR_ORDER: the first tour a pull request has is its clip.
TOUR_ORDER = ("new-tab", "agent-pane", "chief-settings", "glass", "core")
TOUR_AFTER = re.compile(r"(?P<pr>[0-9]+)/(?P<sha8>[0-9a-f]{8})/next-(?P<tour>[a-z0-9][a-z0-9-]*?)-after/tour\.mp4")
TOUR_PLAIN = re.compile(r"(?P<pr>[0-9]+)/(?P<sha8>[0-9a-f]{8})/next-(?P<tour>[a-z0-9][a-z0-9-]*)/tour\.mp4")
MANUAL = re.compile(r"(?P<pr>[0-9]+)/(?P<name>[A-Za-z0-9][A-Za-z0-9._-]*)\.mp4")
NO_CLIP = "no clip"
USER_AGENT = "cmux-reel/1"


def load_script(name: str, path: Path) -> Any:
    """A sibling script as a module (their file names are not importable)."""
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


publish = load_script("cmux_next_publish", Path(__file__).with_name("publish.py"))
pr_media = publish.load_pr_media()
release_notes = load_script("cmux_next_release_notes", ROOT / "scripts/cmux-next/release-notes.py")


# Notes


class NoRedirect(urllib.request.HTTPRedirectHandler):
    """A redirect could leave the allowed host, so none is followed."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise urllib.error.HTTPError(req.full_url, code, f"refused redirect to {newurl}", headers, fp)


def clip_prefix(repo: str) -> str:
    return f"https://raw.githubusercontent.com/{repo}/pr-media/"


def fetch(url: str, into: Path, prefix: str, limit: int = 30 * 1024 * 1024) -> Path:
    """Download url to into: only under prefix, no redirects, at most limit bytes."""
    parts = urllib.parse.urlparse(url)
    if not url.startswith(prefix) or parts.params or parts.query or parts.fragment \
            or ".." in urllib.parse.unquote(parts.path).split("/"):
        raise ValueError(f"refused URL (only {prefix}...): {url}")
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.build_opener(NoRedirect).open(request, timeout=60) as response:
        data = response.read(limit + 1)
    if len(data) > limit:
        raise ValueError(f"{url} is over {limit} bytes")
    into.write_bytes(data)
    return into


def load_notes(args: argparse.Namespace, scratch: Path) -> tuple[dict[str, Any], str]:
    """The build's notes and where they came from. Notes must carry a valid
    signature (FILE.sig next to a local file) unless --allow-unsigned."""
    if args.notes:
        source = str(args.notes)
        sig = Path(f"{args.notes}.sig")
        if sig.is_file():
            if not release_notes.verified(str(args.notes), args.public_key):
                raise SystemExit(f"{args.notes}: bad signature")
        elif args.allow_unsigned:
            print(f"note: {args.notes} has no .sig; using it unverified", file=sys.stderr)
        else:
            raise SystemExit(f"{args.notes}: no {sig.name} (pass --allow-unsigned to use it anyway)")
        path = args.notes
    else:
        source = args.notes_url or f"{NOTES_BASE}/{args.build}.json"
        path = fetch(source, scratch / "notes.json", NOTES_HOST)
        fetch(f"{source}.sig", scratch / "notes.json.sig", NOTES_HOST, 64 * 1024)
        if not release_notes.verified(str(path), args.public_key):
            raise SystemExit(f"{source}: bad signature")
    notes = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(notes, dict):
        raise SystemExit(f"{source}: not a notes object")
    if str(notes.get("build")) != args.build:
        raise SystemExit(f"{source} is build {notes.get('build')}, not {args.build}")
    return notes, source


def notes_prs(notes: dict[str, Any]) -> list[dict[str, Any]]:
    """Each pull request in the notes once, in notes order: {pr, title, author}.
    Older notes without items fall back to the "(#N)" suffix of each change."""
    items = notes.get("items")
    if not isinstance(items, list):
        items = [release_notes.change_item(c, "") for c in notes.get("changes", []) if isinstance(c, str)]
    seen, prs = set(), []
    for item in items:
        if not isinstance(item, dict):
            continue
        pr = item.get("pr")
        if not isinstance(pr, int) or isinstance(pr, bool) or pr <= 0 or pr in seen:
            continue
        seen.add(pr)
        prs.append({"pr": pr, "title": str(item.get("title") or ""), "author": str(item.get("author") or "")})
    return prs


# Discovery


def gh(args: list[str]) -> str:
    done = subprocess.run(["gh", *args], capture_output=True, text=True)
    if done.returncode != 0:
        raise RuntimeError(f"gh {' '.join(args[:2])}: {done.stderr.strip()}")
    return done.stdout


def load_tree(args: argparse.Namespace) -> dict[str, Any]:
    """The pr-media branch's full listing: one REST call, or --tree."""
    if args.tree:
        return json.loads(args.tree.read_text(encoding="utf-8"))
    return json.loads(gh(["api", f"repos/{args.repo}/git/trees/pr-media?recursive=1"]))


def load_heads(args: argparse.Namespace, prs: list[int]) -> dict[int, str]:
    """Each pull request's head sha: --heads, or one batched GraphQL query
    (only alongside a live tree listing). Empty when unavailable."""
    if args.heads:
        raw = json.loads(args.heads.read_text(encoding="utf-8"))
        return {int(pr): str(sha) for pr, sha in raw.items()}
    if args.tree or not prs:
        return {}
    owner, name = args.repo.split("/", 1)
    fields = " ".join(f"p{pr}: pullRequest(number: {pr}) {{ headRefOid }}" for pr in prs)
    query = f'query {{ repository(owner: "{owner}", name: "{name}") {{ {fields} }} }}'
    # A pull request that does not resolve fails the whole call, but stdout still
    # carries the ones that did.
    done = subprocess.run(["gh", "api", "graphql", "-f", f"query={query}"], capture_output=True, text=True)
    try:
        data = json.loads(done.stdout)
    except ValueError:
        print(f"warning: no head shas: {done.stderr.strip()[:300]}", file=sys.stderr)
        return {}
    if done.returncode != 0:
        print(f"warning: some head shas did not resolve: {done.stderr.strip()[:300]}", file=sys.stderr)
    if not isinstance(data, dict):
        return {}
    repo = (data.get("data") or {}).get("repository") or {}
    return {int(key[1:]): value["headRefOid"] for key, value in repo.items()
            if isinstance(value, dict) and value.get("headRefOid")}


def tour_rank(tour: str) -> tuple[int, str]:
    return (TOUR_ORDER.index(tour) if tour in TOUR_ORDER else len(TOUR_ORDER), tour)


def pick_clip(pr: int, paths: list[str], head: str | None) -> dict[str, Any] | None:
    """The clip for one pull request from the branch's paths, or None.

    A tour "after" clip wins, then a pre-before/after tour clip, then a hand-posted
    <pr>/<name>.mp4. Among captures at several heads, the one at the current head
    wins; without it the choice is deterministic (lexically last sha8, which is not
    necessarily the newest) and says so in "note"."""
    for kind, pattern in (("tour-after", TOUR_AFTER), ("tour", TOUR_PLAIN)):
        found = [m for m in (pattern.fullmatch(p) for p in paths) if m and int(m["pr"]) == pr]
        if kind == "tour":
            found = [m for m in found if not m["tour"].endswith("-before")]
        if not found:
            continue
        shas = sorted({m["sha8"] for m in found})
        note = ""
        if head and head[:8] in shas:
            sha8 = head[:8]
        else:
            sha8 = shas[-1]
            if len(shas) > 1:
                why = "head moved past every capture" if head else "head unknown"
                note = f"{len(shas)} captures, {why}; picked {sha8} by name, not by date"
        match = min((m for m in found if m["sha8"] == sha8), key=lambda m: tour_rank(m["tour"]))
        return {"path": match.group(0), "source": kind, "sha8": sha8, "tour": match["tour"], "note": note}
    manual = sorted((m for m in (MANUAL.fullmatch(p) for p in paths) if m and int(m["pr"]) == pr),
                    key=lambda m: ("after" in m["name"].lower(), m["name"]))
    if manual:
        note = f"{len(manual)} hand-posted clips; picked by name" if len(manual) > 1 else ""
        return {"path": manual[-1].group(0), "source": "manual", "sha8": "", "tour": "", "note": note}
    return None


def discover(args: argparse.Namespace, prs: list[dict[str, Any]]) -> tuple[dict[int, dict[str, Any]], bool]:
    """Clips by pull request from the pr-media listing, and whether it was truncated."""
    tree = load_tree(args)
    wanted = {entry["pr"] for entry in prs}
    paths: dict[int, list[str]] = {}
    for node in tree.get("tree") or []:
        path = node.get("path") if isinstance(node, dict) and node.get("type") == "blob" else None
        head = path.split("/", 1)[0] if isinstance(path, str) else ""
        if head.isdigit() and int(head) in wanted:
            paths.setdefault(int(head), []).append(path)
    truncated = bool(tree.get("truncated"))
    if truncated and not args.allow_truncated:
        raise SystemExit("the pr-media listing is truncated, so clips could be missed "
                         "(pass --allow-truncated to build from it anyway)")
    if truncated:
        print("warning: the pr-media listing was truncated; some clips may be missed", file=sys.stderr)
    heads = load_heads(args, sorted(paths))
    clips = {}
    for pr, found in paths.items():
        clip = pick_clip(pr, found, heads.get(pr))
        if clip:
            clip["url"] = pr_media.raw_url(args.repo, pr_media.BRANCH, clip["path"])
            clips[pr] = clip
    return clips, truncated


def given_clips(path: Path) -> dict[int, dict[str, Any]]:
    """--clips: {pr: local path or URL}."""
    raw = json.loads(path.read_text(encoding="utf-8"))
    return {int(pr): {"url": str(where), "source": "given", "sha8": "", "tour": "", "note": ""}
            for pr, where in raw.items()}


# Video


def card_text(pr: int, title: str) -> str:
    """The title card's one line: "#N title", control characters gone, long titles cut at a word."""
    text = " ".join("".join(ch if ch.isprintable() else " " for ch in title).split())
    if len(text) > TITLE_MAX:
        text = text[:TITLE_MAX - 1].rsplit(" ", 1)[0].rstrip(" ,.;:-") + "…"
    return f"#{pr}  {text}" if text else f"#{pr}"


def normalize_filter() -> str:
    width, height = publish.VIDEO_SIZE
    return (f"scale={width}:{height}:force_original_aspect_ratio=decrease,"
            f"pad={width}:{height}:(ow-iw)/2:(oh-ih)/2:color=white,setsar=1,"
            f"fps={publish.VIDEO_FPS},format=yuv420p")


ENCODE = ["-an", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-r", str(publish.VIDEO_FPS),
          "-video_track_timescale", "12800"]


def ffmpeg(argv: list[str], cwd: Path) -> None:
    done = subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-y", *argv],
                          cwd=cwd, capture_output=True, text=True, env=pr_media.tool_env())
    if done.returncode != 0:
        raise RuntimeError(done.stderr.strip()[-500:] or "ffmpeg failed")


def make_card(pr: int, title: str, work: Path) -> Path:
    """A CARD_SECONDS title card. The text goes through a file named relative to
    ffmpeg's working folder, so neither the title nor a path needs filter
    escaping, and expansion=none keeps "%{...}" in a title literal."""
    width, height = publish.VIDEO_SIZE
    (work / f"card-{pr}.txt").write_text(card_text(pr, title), encoding="utf-8")
    out = work / f"card-{pr}.mp4"
    source = ["-f", "lavfi", "-i", f"color=c=0x111111:s={width}x{height}:r={publish.VIDEO_FPS}:d={CARD_SECONDS}"]
    text = (f"drawtext=textfile=card-{pr}.txt:expansion=none:fontcolor=white:fontsize=40:"
            "x=(w-text_w)/2:y=(h-text_h)/2")
    try:
        ffmpeg([*source, "-vf", f"{text},format=yuv420p", *ENCODE, out.name], work)
    except RuntimeError as error:
        # An ffmpeg without drawtext or a font still gets a card, just a blank one.
        print(f"warning: blank card for #{pr}: {error}", file=sys.stderr)
        ffmpeg([*source, "-vf", "format=yuv420p", *ENCODE, out.name], work)
    return out


def local_clip(pr: int, where: str, work: Path, repo: str) -> Path:
    """A clip on disk: a given path as is, a pr-media URL downloaded into work."""
    if re.match(r"^[A-Za-z][A-Za-z0-9+.-]*:", where):
        return fetch(where, work / f"source-{pr}.mp4", clip_prefix(repo))
    path = Path(where)
    if not path.is_file():
        raise FileNotFoundError(where)
    return path.resolve()


def make_segment(pr: int, clip: Path, work: Path) -> Path:
    out = work / f"clip-{pr}.mp4"
    # The clip is untrusted: read it only as a local mp4/mov file, at most CLIP_SECONDS.
    ffmpeg(["-protocol_whitelist", "file", "-f", "mov", "-t", str(CLIP_SECONDS), "-i", str(clip),
            "-vf", normalize_filter(), *ENCODE, out.name], work)
    return out


def concat(segments: list[Path], out: Path, work: Path) -> None:
    """Join segments made with the same settings, without re-encoding."""
    (work / "list.txt").write_text("".join(f"file '{s.name}'\n" for s in segments), encoding="utf-8")
    ffmpeg(["-f", "concat", "-safe", "0", "-i", "list.txt", "-c", "copy",
            "-movflags", "+faststart", str(out.resolve())], work)


def build_reel(entries: list[dict[str, Any]], out: Path, repo: str) -> bool:
    """reel.mp4 from every entry with a clip; an entry whose clip fails gets "error"."""
    segments = []
    with tempfile.TemporaryDirectory() as scratch:
        work = Path(scratch)
        for entry in entries:
            if entry["clip"] == NO_CLIP:
                continue
            try:
                clip = make_segment(entry["pr"], local_clip(entry["pr"], entry["clip"], work, repo), work)
                segments += [make_card(entry["pr"], entry["title"], work), clip]
            except (OSError, ValueError, RuntimeError) as error:
                print(f"warning: #{entry['pr']}: {error}", file=sys.stderr)
                entry["error"] = str(error)[:300]
        if not segments:
            return False
        concat(segments, out / "reel.mp4", work)
    return True


# Output


def entries_for(prs: list[dict[str, Any]], clips: dict[int, dict[str, Any]]) -> list[dict[str, Any]]:
    entries = []
    for pr in prs:
        clip = clips.get(pr["pr"])
        entry = {**pr, "clip": clip["url"] if clip else NO_CLIP}
        if clip:
            entry.update({k: clip[k] for k in ("source", "sha8", "tour", "note") if clip.get(k)})
        entries.append(entry)
    return entries


def render_html(build: str, repo: str, entries: list[dict[str, Any]], reel: bool) -> str:
    """A self-contained page: the reel, then every pull request with its clip or "no clip"."""
    e = html.escape
    rows = []
    for entry in entries:
        link = f"https://github.com/{repo}/pull/{entry['pr']}"
        clip = entry["clip"]
        if clip == NO_CLIP:
            cell = NO_CLIP
        elif clip.startswith("https://"):
            cell = f'<a href="{e(clip, quote=True)}">clip</a>'
        else:
            cell = e(clip)
        if entry.get("error"):
            cell += f" (failed: {e(entry['error'][:120])})"
        rows.append(f'<tr><td><a href="{e(link, quote=True)}">#{entry["pr"]}</a></td>'
                    f'<td>{e(entry["title"])}</td><td>{e(entry["author"])}</td><td>{cell}</td></tr>')
    video = ('<video src="reel.mp4" controls playsinline width="1280"></video>' if reel
             else "<p>No clips for this build.</p>")
    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>cmux NEXT {e(build)}</title>
<style>
:root {{ color-scheme: light dark; --fg: #1d1d1f; --bg: #fff; --line: #ddd; }}
@media (prefers-color-scheme: dark) {{ :root {{ --fg: #f2f2f2; --bg: #161616; --line: #333; }} }}
body {{ font: 14px/1.4 -apple-system, system-ui, sans-serif; color: var(--fg); background: var(--bg);
       margin: 0 auto; padding: 16px; max-width: 1280px; }}
video {{ max-width: 100%; height: auto; background: #000; }}
table {{ border-collapse: collapse; width: 100%; }}
td, th {{ text-align: left; padding: 4px 8px; border-bottom: 1px solid var(--line); vertical-align: top; }}
a {{ color: inherit; }}
</style></head><body>
<h1>cmux NEXT {e(build)}</h1>
{video}
<table><thead><tr><th>PR</th><th>Title</th><th>Author</th><th>Clip</th></tr></thead>
<tbody>
{chr(10).join(rows)}
</tbody></table>
</body></html>
"""


def write_json(out: Path, args: argparse.Namespace, source: str, entries: list[dict[str, Any]],
               truncated: bool, reel: bool) -> None:
    report = {"version": 1, "build": args.build, "notes": source, "repo": args.repo,
              "reel": "reel.mp4" if reel else None, "dryRun": args.dry_run,
              "treeTruncated": truncated, "prs": entries}
    (out / "reel.json").write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--build", required=True)
    notes = parser.add_mutually_exclusive_group()
    notes.add_argument("--notes-url", help=f"default: {NOTES_BASE}/<build>.json")
    notes.add_argument("--notes", type=Path, help="a local notes file (checked when FILE.sig exists)")
    parser.add_argument("--public-key", default=CONTENT_PUBLIC_KEY, help="content-signing Ed25519 key, base64")
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--repo", default="manaflow-ai/cmux")
    parser.add_argument("--clips", type=Path, help="JSON map of pr to a local path or URL; skips discovery")
    parser.add_argument("--tree", type=Path, help="a saved git/trees response for pr-media")
    parser.add_argument("--heads", type=Path, help="JSON map of pr to head sha")
    parser.add_argument("--allow-unsigned", action="store_true", help="accept a --notes file with no .sig")
    parser.add_argument("--allow-truncated", action="store_true", help="build from a truncated pr-media listing")
    parser.add_argument("--dry-run", action="store_true", help="print the plan; write only reel.json")
    parser.add_argument("--publish", action="store_true", help="upload the reel and its page to pr-media")
    args = parser.parse_args(argv)
    if args.publish and args.dry_run:
        parser.error("--publish uploads a built reel; it cannot go with --dry-run")
    if not re.fullmatch(r"[0-9]+", args.build):
        raise SystemExit(f"--build must be digits, not {args.build!r}")

    if not args.dry_run and not shutil.which("ffmpeg"):
        raise SystemExit("ffmpeg is required (or pass --dry-run)")
    args.out.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as scratch:
        notes_doc, source = load_notes(args, Path(scratch))
    prs = notes_prs(notes_doc)
    truncated = False
    if args.clips:
        clips = given_clips(args.clips)
    else:
        clips, truncated = discover(args, prs)
    entries = entries_for(prs, clips)

    print(f"build {args.build}: {len(entries)} pull requests, {sum(e['clip'] != NO_CLIP for e in entries)} with clips")
    for entry in entries:
        note = f" ({entry['note']})" if entry.get("note") else ""
        print(f"  #{entry['pr']} {entry['title'][:70]}: {entry['clip']}{note}")
    reel = False if args.dry_run else build_reel(entries, args.out, args.repo)
    write_json(args.out, args, source, entries, truncated, reel)
    if not args.dry_run:
        (args.out / "index.html").write_text(render_html(args.build, args.repo, entries, reel), encoding="utf-8")
        print(args.out / ("reel.mp4" if reel else "index.html"))
    if args.publish:
        try:
            publish_build(args)
        except pr_media.MediaError as error:
            # A privacy refusal names paths and kinds only, never what it matched.
            raise SystemExit(f"the reel was not published: {error}") from None
    return 0


def publish_build(args: argparse.Namespace) -> None:
    """Upload the reel (when there is one), the report and the page to nightly-next/<build>/.

    The page goes last: a failed upload leaves no page linking a missing reel.
    All three pass scripts/pr-media.py's privacy check before the first upload;
    nightly-next/ is a bot's folder, so any private name refuses the lot.
    """
    files = [(f"nightly-next/{args.build}/{name}", args.out / name)
             for name in ("reel.mp4", "reel.json", "index.html") if (args.out / name).is_file()]
    pr_media.check_privacy(files, args.repo)
    for remote, local in files:
        pr_media.put_file(args.repo, pr_media.BRANCH, remote, local, f"cmux NEXT nightly reel for build {args.build}",
                          checked=True)
        print(pr_media.raw_url(args.repo, pr_media.BRANCH, remote))


if __name__ == "__main__":
    sys.exit(main())
