"""Dedupe a finding against cmux issues and file it: one issue per bug, with the minimized repro and its frames.

Each issue carries a hidden `cmux-fuzz-signature: <digest>` marker. Before filing, the digest is searched in
open and closed issues; a match gets a comment instead of a second issue (a closed match is a regression: the
comment says so and reopens it). Issues are public, so nothing machine-specific goes in: no host or user names,
no fleet paths, only the build's commit, the steps and frames the fuzzer took of its own sandboxed app.
"""

from __future__ import annotations

import base64
import getpass
import json
import re
import socket
import subprocess
from pathlib import Path

from .actions import describe

REPO = "manaflow-ai/cmux"
MEDIA_BRANCH = "pr-media"
MARKER = "cmux-fuzz-signature"
MAX_FRAMES = 10
MAX_LISTED_STEPS = 40
BODY_LIMIT = 60000  # GitHub refuses bodies over 65536 characters
# Paths and names that say which machine ran it. Frames come from an app whose shell and file explorer sit in
# a neutral sandbox; text is scrubbed here.
_PRIVATE = [
    (re.compile(r"/Users/Shared/[^\s\"']*"), "<fuzz dir>"),
    (re.compile(r"/(?:private/)?tmp/cmux-fuzz[^\s\"']*"), "<sandbox>"),
    (re.compile(r"/Users/[^/\s\"']+"), "~"),
    (re.compile(r"\b[\w-]*mac-mini[\w.-]*\b", re.I), "<host>"),
    (re.compile(r"\bcmux(?:\d+s?|-[\w-]*(?:mini|lawrence)[\w.-]*)\b", re.I), "<host>"),
    (re.compile(r"\b[\w-]*\.local\b"), "<host>"),
]


def _local_names() -> list[str]:
    """This machine's host and user names and home, which may sit in a copied finding's text."""
    names = {str(Path.home())}
    with _quiet():
        host = socket.gethostname()
        names.update({host, host.split(".")[0]})
    with _quiet():
        names.add(getpass.getuser())
    # Never a name the issue needs: the repository, the product, the marker (a mini's user is `cmux`).
    keep = f"{REPO} {MARKER} {MEDIA_BRANCH} cmux"
    return sorted((n for n in names if n and len(n) >= 3 and n.lower() not in keep.lower()), key=len, reverse=True)


class _quiet:
    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return exc[0] is not None and issubclass(exc[0], Exception)


def scrub(text: str, extra: list[str] | None = None) -> str:
    for pattern, repl in _PRIVATE:
        text = pattern.sub(repl, text)
    for name in [*(extra or []), *_local_names()]:
        text = re.sub(rf"(?<![\w-]){re.escape(name)}(?![\w-])", "<redacted>", text)
    return text


def _gh(args: list[str], *, stdin: str | None = None) -> str:
    return subprocess.run(["gh", *args], input=stdin, check=True, capture_output=True, text=True).stdout


def find_existing(digest: str, repo: str = REPO) -> dict | None:
    """The issue whose body carries this digest's marker (search is fuzzy, so the body is checked)."""
    out = _gh(["issue", "list", "--repo", repo, "--state", "all", "--limit", "10", "--search",
               f'"{MARKER}: {digest}" in:body', "--json", "number,state,stateReason,url,title,body"])
    for hit in json.loads(out or "[]"):
        if f"{MARKER}: {digest}" in (hit.get("body") or ""):
            return hit
    return None


def already_reported(number: int, sha: str, repo: str = REPO) -> bool:
    """Whether the issue (body or a comment) already names this build, so another mini's copy adds nothing."""
    out = _gh(["issue", "view", str(number), "--repo", repo, "--json", "body,comments"])
    data = json.loads(out or "{}")
    texts = [data.get("body") or "", *((c.get("body") or "") for c in data.get("comments") or [])]
    return bool(sha) and any(sha[:12] in text for text in texts)


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


def upload(frames: list[Path], folder: str, repo: str = REPO) -> list[str]:
    """Put the frames on the media branch under fuzz/<folder>/ (one folder per finding, so frames of two
    repros never mix) and return their raw URLs. A frame already there (an earlier, interrupted filing of this
    same finding) is reused; a concurrent commit to the branch (409) is retried."""
    urls = []
    for frame in frames:
        path = f"fuzz/{folder}/{frame.name}"
        payload = json.dumps({"message": f"fuzz {folder}: {frame.name}", "branch": MEDIA_BRANCH,
                              "content": base64.b64encode(frame.read_bytes()).decode()})
        for attempt in range(3):
            try:
                _gh(["api", "-X", "PUT", f"repos/{repo}/contents/{path}", "--input", "-"], stdin=payload)
                break
            except subprocess.CalledProcessError as error:
                text = (error.stderr or "") + (error.stdout or "")
                if "HTTP 422" in text and "sha" in text:  # the same path exists: this finding's own frame
                    break
                if "HTTP 409" not in text or attempt == 2:
                    raise
        urls.append(f"https://raw.githubusercontent.com/{repo}/{MEDIA_BRANCH}/{path}")
    return urls


def issue_title(finding: dict, redact: list[str] | None = None) -> str:
    return scrub(f"[fuzz] {finding['signature']['title']}", redact)[:120]


def issue_body(finding: dict, frame_urls: list[str], maybe_related: list[dict],
               redact: list[str] | None = None) -> str:
    sig = finding["signature"]
    steps = finding.get("repro_steps") or []
    sha = finding.get("sha") or ""
    lines = [
        f"The UI fuzzer broke a cmux DEV build of `main` at [{sha[:12]}](https://github.com/{REPO}/commit/{sha}) "
        f"in {len(steps)} step(s). The fuzzer drives the app through its control socket and synthesized "
        "pointer input on a Mac nobody is using, checks it after every step, and minimizes each failure.",
        "",
        f"**What broke:** {scrub(finding.get('detail') or sig['title'], redact)}",
        "",
        "## Steps",
        "",
    ]
    listed = list(enumerate(steps, start=1))
    if len(listed) > MAX_LISTED_STEPS:
        head, tail = listed[: MAX_LISTED_STEPS // 2], listed[-MAX_LISTED_STEPS // 2:]
        lines += [f"{n}. {describe(step)}" for n, step in head]
        lines += [f"{len(steps) - len(head) - len(tail)} more steps (in repro.json)"]
        listed = tail
    lines += [f"{n}. {describe(step)}" for n, step in listed]
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
              json.dumps({"kind": "cmux-fuzz-repro", "version": 1, "signature": sig, "steps": steps}),
              "```", "", "</details>"]
    if maybe_related:
        lines += ["", "Possibly related: " + ", ".join(f"{i['url']}" for i in maybe_related)]
    lines += ["", f"Signature `{sig['key'][:200]}` (seed {finding.get('seed')}, session "
                  f"{finding.get('session_seed')}).", "", f"<!-- {MARKER}: {sig['digest']} -->"]
    body = scrub("\n".join(lines), redact)  # one pass over everything, the repro JSON and signature included
    if len(body) > BODY_LIMIT:
        body = body[: BODY_LIMIT - 200] + f"\n\n(truncated)\n\n<!-- {MARKER}: {sig['digest']} -->"
    return body


def file_or_comment(finding_dir: Path, *, file: bool, repo: str = REPO, redact: list[str] | None = None) -> dict:
    """File the finding in FINDING_DIR, or comment on its issue. REDACT: more names to keep out (the host the
    finding came from, when the collector knows it)."""
    finding = json.loads((finding_dir / "finding.json").read_text())
    digest = finding["signature"]["digest"]
    sha = finding.get("sha") or ""
    existing = find_existing(digest, repo)
    if existing:
        if already_reported(existing["number"], sha, repo):
            return {"action": "already reported", "url": existing["url"]}
        closed = existing["state"] != "OPEN"
        wont_fix = closed and existing.get("stateReason") == "NOT_PLANNED"
        note = ("Seen again" if not closed else
                "Seen again after the issue was closed as not planned" if wont_fix else
                "This came back after the issue was closed")
        comment = scrub(f"{note} on `main` at {sha[:12]} (seed {finding.get('seed')}, "
                        f"{len(finding.get('repro_steps') or [])} step repro).", redact)
        if file:
            _gh(["issue", "comment", str(existing["number"]), "--repo", repo, "--body-file", "-"], stdin=comment)
            if closed and not wont_fix:
                _gh(["issue", "reopen", str(existing["number"]), "--repo", repo])
        return {"action": "commented" if file else "would comment", "url": existing["url"], "body": comment}
    title = issue_title(finding, redact)
    maybe = related(finding["signature"]["title"], repo)
    frames = frames_for(finding_dir)
    folder = f"{digest}/{finding.get('session_seed') or finding.get('seed')}"
    urls = upload(frames, folder, repo) if file else [f"<{f.name}>" for f in frames]
    body = issue_body(finding, urls, maybe, redact)
    if not file:
        return {"action": "would file", "title": title, "related": maybe, "body": body}
    url = _gh(["issue", "create", "--repo", repo, "--title", title, "--body-file", "-"], stdin=body).strip()
    return {"action": "filed", "url": url, "title": title}
