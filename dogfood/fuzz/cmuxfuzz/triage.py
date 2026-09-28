"""Dedupe a finding against cmux issues and file it: one issue per bug, with the minimized repro and its frames.

Each issue carries a hidden `cmux-fuzz-signature: <digest>` marker. Before filing, the digest is searched in
open and closed issues; a match gets a comment instead of a second issue (a closed match is a regression: the
comment says so and reopens it). Issues are public, so nothing machine-specific goes in: no host or user names,
no fleet paths, only the build's commit, the steps and frames the fuzzer took of its own sandboxed app.
"""

from __future__ import annotations

import base64
import json
import re
import subprocess
from pathlib import Path

from .actions import describe

REPO = "manaflow-ai/cmux"
MEDIA_BRANCH = "pr-media"
MARKER = "cmux-fuzz-signature"
MAX_FRAMES = 10
# Paths and names that say which machine ran it. Frames come from an app whose shell and file explorer sit in
# a neutral sandbox; text is scrubbed here.
_PRIVATE = [
    (re.compile(r"/Users/Shared/[^\s\"']*"), "<fuzz dir>"),
    (re.compile(r"/(?:private/)?tmp/cmux-fuzz[^\s\"']*"), "<sandbox>"),
    (re.compile(r"/Users/[^/\s\"']+"), "~"),
    (re.compile(r"\b[\w-]*mac-mini[\w.-]*\b", re.I), "<host>"),
    (re.compile(r"\b[\w-]*\.local\b"), "<host>"),
]


def scrub(text: str) -> str:
    for pattern, repl in _PRIVATE:
        text = pattern.sub(repl, text)
    return text


def _gh(args: list[str], *, stdin: str | None = None) -> str:
    return subprocess.run(["gh", *args], input=stdin, check=True, capture_output=True, text=True).stdout


def find_existing(digest: str, repo: str = REPO) -> dict | None:
    out = _gh(["issue", "list", "--repo", repo, "--state", "all", "--limit", "5", "--search",
               f'"{MARKER}: {digest}" in:body', "--json", "number,state,url,title"])
    hits = json.loads(out or "[]")
    return hits[0] if hits else None


def related(title: str, repo: str = REPO) -> list[dict]:
    """Open issues whose text shares the finding's words: possible duplicates filed by hand."""
    words = [w for w in re.findall(r"[A-Za-z][A-Za-z-]{3,}", title) if w.lower() not in {
        "layout", "invariant", "broken", "crash", "error", "logged", "main", "thread", "hang"}][:4]
    if not words:
        return []
    out = _gh(["issue", "list", "--repo", repo, "--state", "open", "--limit", "5", "--search", " ".join(words),
               "--json", "number,url,title"])
    return json.loads(out or "[]")


def frames_for(finding_dir: Path) -> list[Path]:
    """The repro replay's frames (before the first step, then after each), trimmed to MAX_FRAMES."""
    frames = sorted((finding_dir / "repro" / "frames").glob("step-*.png"))
    if not frames:
        frames = sorted((finding_dir / "frames").glob("step-*.png"))
    if len(frames) > MAX_FRAMES:
        frames = frames[:2] + frames[-(MAX_FRAMES - 2):]
    return frames


def upload(frames: list[Path], digest: str, repo: str = REPO) -> list[str]:
    """Put the frames on the media branch (fuzz/<digest>/...) and return their raw URLs."""
    urls = []
    for frame in frames:
        path = f"fuzz/{digest}/{frame.name}"
        payload = json.dumps({"message": f"fuzz {digest}: {frame.name}", "branch": MEDIA_BRANCH,
                              "content": base64.b64encode(frame.read_bytes()).decode()})
        try:
            _gh(["api", "-X", "PUT", f"repos/{repo}/contents/{path}", "--input", "-"], stdin=payload)
        except subprocess.CalledProcessError as error:
            if "sha" not in (error.stderr or ""):  # already there from an earlier run: reuse it
                raise
        urls.append(f"https://raw.githubusercontent.com/{repo}/{MEDIA_BRANCH}/{path}")
    return urls


def issue_title(finding: dict) -> str:
    return scrub(f"[fuzz] {finding['signature']['title']}")[:120]


def issue_body(finding: dict, frame_urls: list[str], maybe_related: list[dict]) -> str:
    sig = finding["signature"]
    steps = finding.get("repro_steps") or []
    sha = finding.get("sha") or ""
    lines = [
        f"The UI fuzzer broke a cmux DEV build of `main` at [{sha[:12]}](https://github.com/{REPO}/commit/{sha}) "
        f"in {len(steps)} step(s). The fuzzer drives the app through its control socket and synthesized "
        "pointer input on a Mac nobody is using, checks it after every step, and minimizes each failure.",
        "",
        f"**What broke:** {scrub(finding.get('detail') or sig['title'])}",
        "",
        "## Steps",
        "",
    ]
    lines += [f"{n}. {scrub(describe(step))}" for n, step in enumerate(steps, start=1)]
    lines += ["", f"The fresh app starts with one workspace, one terminal and a {1440}x{900} window."]
    replayed = finding.get("repro_replayed")
    lines += ["", "The minimized steps " + ("failed the same way again on a clean replay." if replayed
                                              else "did not fail again on the clean replay (flaky).")]
    if finding.get("minimize_exhausted"):
        lines += ["Minimization ran out of budget, so a shorter repro may exist."]
    if frame_urls:
        lines += ["", "## Frames", "", "Before the first step, then after each step of the replay:", ""]
        lines += [f"![{url.rsplit('/', 1)[-1]}]({url})" for url in frame_urls]
    lines += ["", "## Replay", "", "```bash",
              "scripts/fuzz replay repro.json --app \"<path to a cmux DEV build>.app\"", "```", "",
              "<details><summary>repro.json</summary>", "", "```json",
              json.dumps({"kind": "cmux-fuzz-repro", "version": 1, "signature": sig, "steps": steps}, indent=1),
              "```", "", "</details>"]
    if maybe_related:
        lines += ["", "Possibly related: " + ", ".join(f"{i['url']}" for i in maybe_related)]
    lines += ["", f"Signature `{scrub(sig['key'])[:200]}` (seed {finding.get('seed')}, session "
                  f"{finding.get('session_seed')}).", "", f"<!-- {MARKER}: {sig['digest']} -->"]
    return "\n".join(lines)


def file_or_comment(finding_dir: Path, *, file: bool, repo: str = REPO) -> dict:
    finding = json.loads((finding_dir / "finding.json").read_text())
    digest = finding["signature"]["digest"]
    existing = find_existing(digest, repo)
    if existing:
        note = ("Seen again" if existing["state"] == "OPEN"
                else "This came back after the issue was closed")
        comment = scrub(f"{note} on `main` at {finding.get('sha', '')[:12]} (seed {finding.get('seed')}, "
                        f"{len(finding.get('repro_steps') or [])} step repro).")
        if file:
            _gh(["issue", "comment", str(existing["number"]), "--repo", repo, "--body-file", "-"], stdin=comment)
            if existing["state"] != "OPEN":
                _gh(["issue", "reopen", str(existing["number"]), "--repo", repo])
        return {"action": "commented" if file else "would comment", "url": existing["url"], "body": comment}
    title = issue_title(finding)
    maybe = related(finding["signature"]["title"], repo)
    frames = frames_for(finding_dir)
    urls = upload(frames, digest, repo) if file else [f"<{f.name}>" for f in frames]
    body = issue_body(finding, urls, maybe)
    if not file:
        return {"action": "would file", "title": title, "related": maybe, "body": body}
    url = _gh(["issue", "create", "--repo", repo, "--title", title, "--body-file", "-"], stdin=body).strip()
    return {"action": "filed", "url": url, "title": title}
