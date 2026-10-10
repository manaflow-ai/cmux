#!/usr/bin/env python3
"""Publish real cmux showcase media where a PR reader can see it.

The command moves captures out of the private screenshot archive and into the
public ``pr-media`` branch, replaces one marked Showcase section in the PR
body (including a merged PR), links the live gallery, and posts macOS-facing
media to the existing Austin review feed.

Examples::

    scripts/showcase-publish.py --pr 19049 \
        --capture-root ~/Projects/cmux-app-screenshots-worktrees/showcase-d0d \
        --from-body
    scripts/showcase-publish.py --pr 19049 captures/*.png motion.mp4
    scripts/showcase-publish.py --pr 19049 captures/ --dry-run --no-feed

``--from-body`` reads the PR's existing capture links. Private
``cmux-app-screenshots`` links are resolved under ``--capture-root``; already
public media links are retained. A missing private capture is an error rather
than a private URL being copied into the public Showcase section.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.parse
from pathlib import Path

REPO = "manaflow-ai/cmux"
MEDIA_SUFFIXES = {".gif", ".jpeg", ".jpg", ".mp4", ".mov", ".png"}
PRIVATE_RE = re.compile(
    r"https://github\.com/manaflow-ai/cmux-app-screenshots/(?:blob|tree)/main/([^\s)]+)"
)
PUBLIC_RE = re.compile(
    r"https?://[^\s)]+(?:\.gif|\.jpe?g|\.mp4|\.mov|\.png)(?:\?[^\s)]*)?",
    re.IGNORECASE,
)
MARKER_RE = re.compile(r"\n?<!-- cmux-showcase:start -->.*?<!-- cmux-showcase:end -->\n?", re.DOTALL)


def load_pr_media() -> object:
    path = Path(__file__).with_name("pr-media.py")
    spec = importlib.util.spec_from_file_location("cmux_pr_media", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def run(command: list[str], *, input_text: str | None = None) -> str:
    done = subprocess.run(command, input=input_text, capture_output=True, text=True)
    if done.returncode:
        detail = (done.stderr or done.stdout).strip()
        raise RuntimeError(f"{' '.join(command[:3])}: {detail}")
    return done.stdout


def pr_body(pr: int) -> str:
    return run(["gh", "pr", "view", str(pr), "--repo", REPO, "--json", "body", "--jq", ".body"])


def collect_local(path: Path) -> list[Path]:
    if not path.exists():
        raise RuntimeError(f"capture path does not exist: {path}")
    paths = [path] if path.is_file() else sorted(p for p in path.rglob("*") if p.is_file())
    media = [p for p in paths if p.suffix.lower() in MEDIA_SUFFIXES]
    if not media:
        raise RuntimeError(f"no stills, strips, gifs or video under {path}")
    return media


def private_sources(body: str, root: Path) -> list[Path]:
    """Collect private media once, pruning nested capture links first."""
    candidates: list[Path] = []
    seen_candidates: set[Path] = set()
    root_resolved = root.resolve()
    for match in PRIVATE_RE.finditer(body):
        relative = Path(urllib.parse.unquote(match.group(1)))
        candidate = (root / relative).resolve()
        try:
            candidate.relative_to(root_resolved)
        except ValueError as exc:
            raise RuntimeError(f"capture link escapes capture root: {relative}") from exc
        if candidate not in seen_candidates:
            seen_candidates.add(candidate)
            candidates.append(candidate)

    def nested(candidate: Path, other: Path) -> bool:
        if candidate == other:
            return False
        try:
            candidate.relative_to(other)
        except ValueError:
            return False
        return other.is_dir()

    roots = [candidate for candidate in candidates
             if not any(nested(candidate, other) for other in candidates)]
    found: list[Path] = []
    seen: set[Path] = set()
    for candidate in roots:
        for path in collect_local(candidate):
            if path not in seen:
                seen.add(path)
                found.append(path)
    return found


def public_sources(body: str) -> list[str]:
    seen: set[str] = set()
    out: list[str] = []
    for url in PUBLIC_RE.findall(body):
        url = url.rstrip(".,")
        if "cmux-app-screenshots" in url:
            continue
        if url not in seen:
            seen.add(url)
            out.append(url)
    return out


def local_markdown(pr: int, files: list[Path], *, dry_run: bool, gif_fps: int, gif_width: int) -> str:
    """Upload through the existing public media publisher and return its Markdown."""
    if not files:
        return ""
    with tempfile.TemporaryDirectory(prefix=f"showcase-{pr}-") as scratch:
        staged: list[str] = []
        used: set[str] = set()
        for index, source in enumerate(files, 1):
            name = source.name
            if name in used:
                name = f"{index:02d}-{name}"
            used.add(name)
            target = Path(scratch) / name
            target.symlink_to(source.resolve())
            staged.append(str(target))
        pm = load_pr_media()
        uploads = pm.plan([Path(path) for path in staged], None, True)
        if dry_run:
            return pm.markdown(uploads, pr)
        command = [sys.executable, str(Path(__file__).with_name("pr-media.py")),
                   "--pr", str(pr), "--force", "--gif-fps", str(gif_fps),
                   "--gif-width", str(gif_width), *staged]
        output = run(command)
        lines = output.splitlines()
        start = next((i for i, line in enumerate(lines) if line.startswith(("![", "["))), None)
        if start is None:
            raise RuntimeError("pr-media uploaded media but printed no Markdown")
        return "\n".join(lines[start:]).strip() + "\n"


def media_urls(markdown: str, public: list[str]) -> tuple[list[str], list[str]]:
    urls = re.findall(r"https?://[^)\s>]+", markdown) + public
    deduped: list[str] = []
    seen: set[str] = set()
    for url in urls:
        url = url.rstrip(".,")
        if url not in seen:
            seen.add(url)
            deduped.append(url)
    stills = [u for u in deduped if Path(urllib.parse.urlparse(u).path).suffix.lower() in {".gif", ".jpeg", ".jpg", ".png"}]
    videos = [u for u in deduped if Path(urllib.parse.urlparse(u).path).suffix.lower() in {".mp4", ".mov"}]
    return stills, videos


def public_markdown(urls: list[str]) -> str:
    """Render reused public media with image syntax only for inline types."""
    lines: list[str] = []
    for url in urls:
        suffix = Path(urllib.parse.urlparse(url).path).suffix.lower()
        if suffix in {".gif", ".jpeg", ".jpg", ".png"}:
            lines.append(f"![showcase]({url})")
        else:
            lines.append(f"[Full quality media]({url})")
    return "\n".join(lines)


def showcase_section(markdown: str, live_url: str) -> str:
    body = markdown.strip()
    lines = ["<!-- cmux-showcase:start -->", "## Showcase", ""]
    if body:
        lines.extend([body, ""])
    lines.extend([f"[Open the live gallery]({live_url})", "", "<!-- cmux-showcase:end -->"])
    return "\n".join(lines)


def update_body(pr: int, body: str, section: str, *, dry_run: bool) -> str:
    updated = MARKER_RE.sub("", body).rstrip()
    # Keep the repository's generated-by trailer as the final line. GitHub
    # renders it as attribution, and moving it below Showcase makes reruns
    # change unrelated prose at the end of the PR body.
    trailer = "🤖 Generated with [Claude Code](https://claude.com/claude-code)"
    if updated.endswith(trailer):
        updated = f"{updated[:-len(trailer)].rstrip()}\n\n{section}\n\n{trailer}\n"
    else:
        updated = f"{updated}\n\n{section}\n"
    if not dry_run:
        run(["gh", "pr", "edit", str(pr), "--repo", REPO, "--body-file", "-"], input_text=updated)
    return updated


def post_feed(pr: int, stills: list[str], videos: list[str], live_url: str, app: str, *, dry_run: bool) -> None:
    if dry_run:
        print(f"feed: {len(stills)} stills, {len(videos)} video, app={app}")
        return
    body = {"pr": f"https://github.com/{REPO}/pull/{pr}", "app": app,
            "preview": live_url, "stills": stills, "video": videos[0] if videos else "",
            "by": os.environ.get("CMUX_LANE", "showcase-publish")}
    feed_path = os.environ.get("CMUX_FEED_POST", "~/.local/bin/feed-post")
    feed_url = os.environ.get("CMUX_FEED_URL", "").rstrip("/")
    if feed_url:
        command = ["curl", "-sS", "--connect-timeout", "10", "--max-time", "60",
                   "-X", "POST", "-H", "Content-Type: application/json",
                   "--data-binary", "@-", "-w", "\n%{http_code}", feed_url + "/api/posts"]
        done = subprocess.run(command, input=json.dumps(body), capture_output=True, text=True)
    else:
        remote = "curl -sS --connect-timeout 10 --max-time 60 -X POST -H 'Content-Type: application/json' --data-binary @- -w '\\n%{http_code}' http://127.0.0.1:18791/api/posts"
        done = subprocess.run(["ssh", "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=15",
                               "-o", "ServerAliveCountMax=3", os.environ.get("CMUX_FEED_SSH", "cmux-lawrence"), remote],
                              input=json.dumps(body), capture_output=True, text=True)
    if done.returncode:
        raise RuntimeError(f"feed-post: {(done.stderr or done.stdout).strip()}")
    response, _, status = done.stdout.rpartition("\n")
    if not status.startswith("2"):
        raise RuntimeError(f"feed-post returned HTTP {status or 'unknown'}: {response[-400:]}")
    print(response.strip())


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("media_pos", nargs="*", type=Path, help="local stills, strips, gifs or video")
    parser.add_argument("--media", action="append", type=Path, default=[], help="local still, strip, gif or video (repeatable)")
    parser.add_argument("--pr", type=int, required=True)
    parser.add_argument("--capture-root", type=Path, help="local cmux-app-screenshots checkout")
    parser.add_argument("--from-body", action="store_true", help="reuse media links already in the PR body")
    parser.add_argument("--live-url", default="https://cmux-lawrences-mac-mini.tail137216.ts.net:18796/live/")
    parser.add_argument("--gif-fps", type=int, default=10)
    parser.add_argument("--gif-width", type=int, default=900)
    parser.add_argument("--app", choices=("next", "classic", "ios", "infra"), default="next")
    parser.add_argument("--no-feed", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.pr <= 0:
        raise SystemExit("--pr must be positive")
    body = pr_body(args.pr)
    args.media = [*args.media_pos, *args.media]
    public = public_sources(body) if args.from_body else []
    files: list[Path] = []
    for entry in args.media:
        files.extend(collect_local(entry))
    if args.from_body:
        private_links = list(PRIVATE_RE.finditer(body))
        # Once a prior run has published the captures, the body contains both
        # the old private references and the public Showcase URLs. Reuse the
        # public set on an idempotent rerun; a private-only body still requires
        # an explicit checkout so a private URL is never copied blindly.
        has_published_showcase = "<!-- cmux-showcase:start -->" in body and bool(public)
        if private_links and not args.capture_root and not has_published_showcase:
            raise SystemExit("--from-body requires --capture-root for private capture links")
        if args.capture_root:
            files.extend(private_sources(body, args.capture_root))
    deduped_files: list[Path] = []
    seen_files: set[Path] = set()
    for path in files:
        resolved = path.resolve()
        if resolved not in seen_files:
            seen_files.add(resolved)
            deduped_files.append(resolved)
    uploaded = local_markdown(args.pr, deduped_files, dry_run=args.dry_run,
                              gif_fps=args.gif_fps, gif_width=args.gif_width)
    existing_public = public_markdown(public)
    media_markdown = "\n".join(part for part in (uploaded.strip(), existing_public) if part)
    feed_markdown = media_markdown
    stills, videos = media_urls(feed_markdown, [])
    if not media_markdown and not public:
        raise SystemExit("no public or local showcase media found")
    section = showcase_section(media_markdown, args.live_url)
    updated = update_body(args.pr, body, section, dry_run=args.dry_run)
    if args.dry_run:
        print(updated)
    if not args.no_feed:
        post_feed(args.pr, stills, videos, args.live_url, args.app, dry_run=args.dry_run)
    print(f"showcase: PR #{args.pr}, {len(stills)} stills, {len(videos)} video, gallery={args.live_url}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, OSError) as exc:
        print(f"showcase-publish: {exc}", file=sys.stderr)
        raise SystemExit(1)
