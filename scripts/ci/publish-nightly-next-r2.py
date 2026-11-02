#!/usr/bin/env python3
"""The cmux NEXT feed's critical path: this build's files to R2, then the feed.

Leo, 2026-10-26: "how are we even spending more than one minute on uploads?" The
GitHub release upload sat 13 to 18 minutes in secondary rate-limit backoff
(runs 40357982361, 40376320918) while the feed waited on it. The feed and its
downloads now live on R2 (files-next.cmux.com); the GitHub release copy is a
follow-up job that never holds the feed.

  upload --file F [--file ...]
      Writes each file to <prefix><name>, write-once, all at once (one thread
      per file), then reads each back from R2 and checks its size and SHA-256
      against the local file's, and checks the public base serves it at that size.
  rewrite --feed F --name N [--name ...]
      Points every enclosure <github-prefix><N> in F at <public-base>/<N>.
      --if-public rewrites only names the public base serves at the enclosure's
      length (the delta republish, which may carry older GitHub-only builds).
  write-feed --feed F [--same-build]
      Replaces <prefix><basename F> only while the live feed's newest build is
      below this feed's newest build, with If-Match on the bytes it read, so two
      runs never move the feed back (a lost race re-reads and decides again).
      --same-build (the delta republish): only while the live feed's newest
      build is this feed's. Either way the feed written keeps the live feed's
      newest earlier builds until it holds KEEP_BUILDS (2) builds, so a pull
      (nightly-next-rollback.yml) always has a published build to fall back
      to: every build on the live feed passed the publish gate, and a pulled
      one is no longer on it.

Environment: AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY (the nightly-next scoped
token), R2_ENDPOINT, NIGHTLY_NEXT_R2_BUCKET, NIGHTLY_NEXT_R2_PREFIX,
NIGHTLY_NEXT_FEED_BASE. Every key passes nightly-next-guard.py r2-key first.
"""
from __future__ import annotations

import argparse
import concurrent.futures
import datetime as dt
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET

HERE = Path(__file__).resolve().parent
UPLOADER = HERE / "upload-r2-object.py"
GUARD = HERE / "nightly-next-guard.py"
GITHUB_PREFIX = "https://github.com/manaflow-ai/cmux/releases/download/nightly-next/"
SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
CMUX_NS = "https://cmux.com/xml-namespaces/cmux"
FEED_PREFIXES = {b"sparkle": SPARKLE_NS.encode(), b"cmux": CMUX_NS.encode()}
RSS_OPEN = re.compile(rb"<rss\b[^>]*>")
IMMUTABLE_CACHE = "public, max-age=31536000, immutable"
FEED_CACHE = "no-cache, no-store, must-revalidate"
CONFLICT = 3
# The feed keeps this many builds: the new one and the newest earlier one, so a rollback can serve it.
KEEP_BUILDS = 2
ITEM = re.compile(rb"[ \t]*<item>.*?</item>[ \t]*\n?", re.S)
ITEM_VERSION = re.compile(rb"<sparkle:version>\s*(\d+)\s*</sparkle:version>")
ITEM_SOURCE = re.compile(rb"<cmux:sourceCommit(?:\s+[^>]*)?>\s*([0-9a-f]{7,40})\s*</cmux:sourceCommit>", re.I)
ITEM_CHANNEL = re.compile(rb"<sparkle:channel>\s*([^<]*?)\s*</sparkle:channel>")
NIGHTLY_CHANNELS = (None, b"cmux-next")  # what a Nightly-ring app is offered (untagged or cmux-next)
_sleep = time.sleep


def env(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise SystemExit(f"{name} is not set")
    return value


def public_base() -> str:
    return env("NIGHTLY_NEXT_FEED_BASE").rstrip("/") + "/"


def guard_key(key: str) -> None:
    subprocess.run([sys.executable, str(GUARD), "r2-key", env("NIGHTLY_NEXT_R2_BUCKET"), key], check=True)


def uploader_args(path: Path, key: str, cache: str, content_type: str) -> list[str]:
    return [sys.executable, str(UPLOADER), "--file", str(path), "--endpoint-url", env("R2_ENDPOINT"),
            "--bucket", env("NIGHTLY_NEXT_R2_BUCKET"), "--key", key,
            "--content-type", content_type, "--cache-control", cache]


def public_length(url: str, attempts: int = 5) -> int | None:
    """The Content-Length the public base serves for url, None on a 404 after retries."""
    for attempt in range(attempts):
        request = urllib.request.Request(url, method="HEAD", headers={"User-Agent": "cmux-nightly-next-r2/1"})
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return int(response.headers.get("Content-Length", "-1"))
        except (urllib.error.URLError, OSError, ValueError) as error:
            if attempt == attempts - 1:
                print(f"{url}: {error}", file=sys.stderr)
                return None
            _sleep(2 * (attempt + 1))
    return None


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def stored_digest(key: str) -> tuple[int, str]:
    """(size, SHA-256) of the object's bytes as R2 stores them, read back through the S3 API.

    Straight from R2, not the public base: a CDN read can trickle (files.cmux.com served a binary at
    4-35 KB/s), and upload-r2-object.py --download-to bounds each attempt and retries."""
    with tempfile.TemporaryDirectory(prefix="nightly-next-r2-readback-") as scratch:
        copy = Path(scratch) / "object"
        subprocess.run([sys.executable, str(UPLOADER), "--endpoint-url", env("R2_ENDPOINT"),
                        "--bucket", env("NIGHTLY_NEXT_R2_BUCKET"), "--key", key, "--download-to", str(copy)],
                       check=True)
        return copy.stat().st_size, file_sha256(copy)


def upload_one(path: Path) -> str:
    key = env("NIGHTLY_NEXT_R2_PREFIX") + path.name
    guard_key(key)
    started = time.monotonic()
    content_type = "application/x-apple-diskimage" if path.suffix == ".dmg" else "application/octet-stream"
    if path.suffix in (".json",):
        content_type = "application/json"
    elif path.suffix == ".txt":
        content_type = "text/plain; charset=utf-8"
    subprocess.run(uploader_args(path, key, IMMUTABLE_CACHE, content_type) + ["--write-once"], check=True)
    size, sha256 = path.stat().st_size, file_sha256(path)
    # The stored bytes, not only a length: an object of the right length with other bytes (stale or
    # corrupt) must not pass the readback.
    stored = stored_digest(key)
    if stored != (size, sha256):
        raise RuntimeError(f"s3://{env('NIGHTLY_NEXT_R2_BUCKET')}/{key} holds {stored[0]} bytes with SHA-256 "
                           f"{stored[1]}, expected {size} bytes with SHA-256 {sha256}")
    url = public_base() + path.name
    served = public_length(url)
    if served != size:
        raise RuntimeError(f"{url} serves {served} bytes, expected {size}")
    return f"{path.name}: {size} bytes, SHA-256 {sha256}, in {time.monotonic() - started:.1f} s, live at {url}"


def upload(files: list[Path]) -> int:
    missing = [str(f) for f in files if not f.is_file()]
    if missing:
        raise SystemExit(f"missing: {', '.join(missing)}")
    started = time.monotonic()
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(files)) as pool:
        futures = {pool.submit(upload_one, f): f for f in files}
        failed = []
        for future in concurrent.futures.as_completed(futures):
            try:
                print(future.result(), flush=True)
            except Exception as error:  # report every failure, not only the first
                failed.append(f"{futures[future].name}: {error}")
    if failed:
        print("\n".join(failed), file=sys.stderr)
        return 1
    print(f"{len(files)} files on R2 in {time.monotonic() - started:.1f} s")
    return 0


ENCLOSURE_URL = re.compile(r'(url=")([^"]+)(")')


def rewrite(feed: Path, names: set[str], if_public: bool) -> int:
    text = feed.read_text(encoding="utf-8")
    base = public_base()
    lengths = {}
    if if_public:
        # Each enclosure's declared length, to check the public copy against.
        root = ET.fromstring(text)
        for element in root.iter("enclosure"):
            url = element.get("url") or ""
            if url.startswith(GITHUB_PREFIX):
                lengths[url[len(GITHUB_PREFIX):]] = element.get("length")
    changed = []

    def replace(match: re.Match) -> str:
        url = match.group(2)
        if not url.startswith(GITHUB_PREFIX):
            return match.group(0)
        name = url[len(GITHUB_PREFIX):]
        if "/" in name or not name.startswith("cmux-nightly-next-macos-"):
            return match.group(0)
        if names and name not in names:
            return match.group(0)
        if if_public:
            served = public_length(base + name, attempts=1)
            if served is None or str(served) != str(lengths.get(name)):
                return match.group(0)
        changed.append(name)
        return f"{match.group(1)}{base}{name}{match.group(3)}"

    text = ENCLOSURE_URL.sub(replace, text)
    feed.write_text(text, encoding="utf-8")
    for name in changed:
        print(f"{feed.name}: {name} -> {base}{name}")
    if names and not if_public and not set(names) <= set(changed):
        print(f"{feed.name}: no GitHub enclosure for {sorted(set(names) - set(changed))}", file=sys.stderr)
        return 1
    return 0


def newest_build(xml: bytes) -> int:
    # The live feed may predate bind_feed_prefixes (11-01: an unbound cmux: prefix).
    root = ET.fromstring(bind_feed_prefixes(xml))
    builds = [0]
    for element in root.iter():
        if element.tag == f"{{{SPARKLE_NS}}}version" and (element.text or "").strip().isdigit():
            builds.append(int(element.text.strip()))
        value = element.get(f"{{{SPARKLE_NS}}}version")
        if value and value.isdigit():
            builds.append(int(value))
    return max(builds)


def item_builds(xml: bytes) -> list[tuple[re.Match, int]]:
    found = []
    for match in ITEM.finditer(xml):
        version = ITEM_VERSION.search(match.group(0))
        if version is not None:
            found.append((match, int(version.group(1))))
    return found


def item_source(xml: bytes, build: int) -> str | None:
    """The source commit attached to the item's build, if the feed has one."""
    for match, item_build in item_builds(xml):
        if item_build != build:
            continue
        source = ITEM_SOURCE.search(match.group(0))
        return source.group(1).decode("ascii").lower() if source else None
    return None


def add_source(xml: bytes, source_sha: str) -> bytes:
    """Attach the authenticated build source so later writers can order by source."""
    if not re.fullmatch(r"[0-9a-f]{40}", source_sha):
        raise ValueError(f"invalid source SHA {source_sha!r}")
    build = newest_build(xml)
    matches = [(match, value) for match, value in item_builds(xml) if value == build]
    if len(matches) != 1:
        raise ValueError(f"feed must have exactly one newest item for source {source_sha}")
    match, _ = matches[0]
    item = match.group(0)
    source_line = ('            <cmux:sourceCommit xmlns:cmux="https://cmux.com/xml-namespaces/cmux">'
                   f"{source_sha}</cmux:sourceCommit>\n").encode()
    if ITEM_SOURCE.search(item):
        item = ITEM_SOURCE.sub(source_line.strip(), item, count=1)
    else:
        item = item.replace(b"</item>", source_line + b"        </item>", 1)
    return bind_feed_prefixes(xml[:match.start()] + item + xml[match.end():])


def bind_feed_prefixes(xml: bytes) -> bytes:
    """Declare on the <rss> root every feed prefix (sparkle:, cmux:) the feed uses.

    Items are copied between feeds as bytes. An item that relied on its old feed's
    root declaration (a bare <cmux:sourceCommit>) has an unbound prefix in a feed
    whose root lacks it, and no XML parser reads that feed. An inline declaration
    on some other item does not bind it, so the check is on the root tag alone.
    """
    root = RSS_OPEN.search(xml)
    if root is None:
        return xml
    opening = root.group(0)
    for prefix, uri in FEED_PREFIXES.items():
        used = re.search(rb"[<\s]" + prefix + rb":[A-Za-z_]", xml) is not None
        if used and re.search(rb"\sxmlns:" + prefix + rb"\s*=", opening) is None:
            opening = opening[:-1] + b" xmlns:" + prefix + b'="' + uri + b'">'
    return xml[:root.start()] + opening + xml[root.end():]


def source_order(live_source: str, candidate_source: str) -> bool:
    """Whether candidate_source is live_source or a descendant of it.

    The feed's build number is a run id, not a source ordering. GitHub's
    compare status is authenticated by the workflow token and is checked on
    every CAS read, so a late run of an older source cannot win by having a
    larger run id.
    """
    repository = os.environ.get("GITHUB_REPOSITORY", "").strip()
    if not repository or not os.environ.get("GH_TOKEN") and not os.environ.get("GITHUB_TOKEN"):
        raise RuntimeError("cannot compare nightly-next source commits without an authenticated GitHub token")
    result = subprocess.run(
        ["gh", "api", f"repos/{repository}/compare/{live_source}...{candidate_source}", "--jq", ".status"],
        check=False, capture_output=True, text=True,
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or "GitHub compare failed").strip()
        raise RuntimeError(f"could not compare live source {live_source} with candidate {candidate_source}: {detail}")
    status = result.stdout.strip().lower()
    if status not in {"ahead", "identical", "behind", "diverged"}:
        raise RuntimeError(f"GitHub compare returned unknown status {status!r}")
    return status in {"ahead", "identical"}


def signed_notes_source(build: int) -> str | None:
    """Read the exact live build's signed notes as a markerless-feed fallback."""
    base = os.environ.get("NIGHTLY_NEXT_FEED_BASE", "").strip().rstrip("/")
    public_key = os.environ.get("NIGHTLY_NEXT_CONTENT_PUBLIC_KEY", "").strip()
    if not base or not public_key:
        return None
    with tempfile.TemporaryDirectory(prefix="nightly-next-notes-") as scratch:
        notes = Path(scratch) / f"{build}.json"
        signature = Path(scratch) / f"{build}.json.sig"
        for path, suffix in ((notes, f"notes/{build}.json"), (signature, f"notes/{build}.json.sig")):
            request = urllib.request.Request(f"{base}/{suffix}", headers={"User-Agent": "cmux-nightly-next-r2/1"})
            try:
                with urllib.request.urlopen(request, timeout=30) as response:
                    path.write_bytes(response.read())
            except urllib.error.HTTPError as error:
                if error.code == 404:
                    return None
                raise RuntimeError(f"could not read signed notes for live build {build}: HTTP {error.code}") from error
            except (urllib.error.URLError, OSError) as error:
                raise RuntimeError(f"could not read signed notes for live build {build}: {error}") from error
        verifier = Path(os.environ.get("PUBLISH_TOOLING", "")) / "cmux-next/release-notes.py"
        if not verifier.is_file():
            verifier = HERE.parent / "cmux-next/release-notes.py"
        checked = subprocess.run(
            [sys.executable, str(verifier), "verify", "--public-key", public_key, str(notes)],
            check=False, capture_output=True, text=True,
        )
        if checked.returncode != 0:
            detail = (checked.stderr or checked.stdout or "signature verification failed").strip()
            raise RuntimeError(f"signed notes for live build {build} failed verification: {detail}")
        try:
            payload = json.loads(notes.read_text(encoding="utf-8"))
        except (OSError, ValueError) as error:
            raise RuntimeError(f"signed notes for live build {build} are not valid JSON: {error}") from error
        if str(payload.get("build", "")) != str(build):
            raise RuntimeError(f"signed notes identify build {payload.get('build')!r}, not live build {build}")
        source = str(payload.get("head", "")).strip().lower()
        if not re.fullmatch(r"[0-9a-f]{40}", source):
            raise RuntimeError(f"signed notes for live build {build} have no full source head")
        return source


def provenance_json(path: str, token: str) -> dict:
    """One bounded authenticated read; migration never waits on a quota reset."""
    request = urllib.request.Request("https://api.github.com/" + path, headers={
        "Authorization": "Bearer " + token, "Accept": "application/vnd.github+json",
        "User-Agent": "cmux-nightly-next-source/1",
    })
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            return json.load(response)
    except (urllib.error.URLError, OSError, ValueError) as error:
        raise RuntimeError(f"could not read compiled-source provenance: {type(error).__name__}") from error


def compiled_artifact_source(build: int) -> str | None:
    """Migrate markerless recovered feeds using their original compiler receipt.

    As in resume-unsigned-nightly.py, the dSYM artifact name records the resolved
    source; the workflow head may be ahead of it. Only authenticated metadata
    from that build's successful protected producer attempt is accepted.
    """
    repository = os.environ.get("GITHUB_REPOSITORY", "")
    token = os.environ.get("NIGHTLY_NEXT_PROVENANCE_TOKEN", "")
    encoded = str(build)
    if repository != "manaflow-ai/cmux" or not token or len(encoded) <= 2 or int(encoded[-2:]) < 1:
        return None
    run_id, attempt = int(encoded[:-2]), int(encoded[-2:])
    prefix = f"repos/{repository}/actions/runs/{run_id}"
    run = provenance_json(f"{prefix}/attempts/{attempt}", token)
    job_list = provenance_json(f"{prefix}/attempts/{attempt}/jobs?per_page=100", token)
    artifact_list = provenance_json(f"{prefix}/artifacts?per_page=100", token)
    if job_list.get("total_count", 101) > 100 or artifact_list.get("total_count", 101) > 100:
        raise RuntimeError("compiled-source lookup exceeds its bounded metadata page")
    identity = run.get("repository", {})
    if not (run.get("id") == run_id and run.get("run_attempt") == attempt and
            identity.get("full_name") == repository and isinstance(identity.get("id"), int) and
            run.get("head_repository", {}).get("full_name") == repository and
            run.get("path") == ".github/workflows/nightly.yml" and
            run.get("head_branch") == "nightly-next" and run.get("event") in {"push", "workflow_dispatch"}):
        raise RuntimeError("compiled-source run is not the exact protected nightly producer")
    jobs = [job for job in job_list.get("jobs", []) if job.get("name") == "build-nightly-app" and
            job.get("run_attempt") == attempt and job.get("conclusion") == "success"]
    if len(jobs) != 1 or not jobs[0].get("started_at") or not jobs[0].get("completed_at"):
        raise RuntimeError("compiled-source build has no unique successful producer attempt")
    job = jobs[0]
    sources = []
    for artifact in artifact_list.get("artifacts", []):
        name = re.fullmatch(r"nightly-next-dsyms-([0-9a-f]{40})", artifact.get("name", ""))
        if not name or artifact.get("expired") is not False or not (
                job["started_at"] <= artifact.get("created_at", "") <= job["completed_at"]):
            continue
        origin = artifact.get("workflow_run", {})
        if not (origin.get("id") == run_id and origin.get("head_sha") == run.get("head_sha") and
                origin.get("head_branch") == "nightly-next" and
                origin.get("repository_id") == origin.get("head_repository_id") == identity["id"] and
                isinstance(artifact.get("id"), int) and artifact["id"] > 0 and
                re.fullmatch(r"sha256:[0-9a-f]{64}", artifact.get("digest", ""))):
            raise RuntimeError("compiled-source artifact identity does not match its producer")
        sources.append(name.group(1))
    if len(sources) != 1:
        raise RuntimeError("compiled-source build has no unique unexpired source receipt")
    return sources[0]


def nightly_item(item: bytes) -> bool:
    channel = ITEM_CHANNEL.search(item)
    return (channel.group(1) if channel else None) in NIGHTLY_CHANNELS


def keep_earlier_builds(ours: bytes, live: bytes, keep: int = KEEP_BUILDS) -> bytes:
    """OURS, holding a Nightly-ring item (untagged or cmux-next) for each of the KEEP - 1 newest builds
    below OURS' newest that either feed offers Nightly apps, taken from the live feed when OURS lacks it.

    Counting over both feeds means a feed combined from an older read (a lost race) still takes a
    build that landed meanwhile. A Dev-tagged (cmux-next-dev) item never counts: a Nightly app rejects
    it, so it could not serve a rollback. Where OURS has a wanted build only as Dev items (a promotion
    raced this write), those items give way to the live feed's Nightly item. Kept items are the live
    feed's bytes, after OURS' last item."""
    mine = item_builds(ours)
    if not mine:
        return ours
    newest = max(build for _, build in mine)
    nightly_mine = {build for match, build in mine if nightly_item(match.group(0))}
    theirs = [(match, build) for match, build in item_builds(live) if nightly_item(match.group(0))]
    earlier = {build for build in nightly_mine if build < newest} | {build for _, build in theirs if build < newest}
    wanted = set(sorted(earlier, reverse=True)[:keep - 1]) - nightly_mine
    added, taken = [], set()
    for match, build in sorted(theirs, key=lambda entry: entry[1], reverse=True):
        if build in wanted and build not in taken:
            item = match.group(0)
            added.append(item if item.endswith(b"\n") else item + b"\n")
            taken.add(build)
    if not added:
        return ours
    kept, cursor = [], 0
    for match, build in mine:
        kept.append(ours[cursor:match.start()])
        if build not in taken:  # a Dev item of a build whose Nightly item is added gives way to it
            kept.append(match.group(0))
        cursor = match.end()
    end = len(b"".join(kept))
    kept.append(ours[cursor:])
    body = b"".join(kept)
    return body[:end] + b"".join(added) + body[end:]


def _uploader_module():
    spec = importlib.util.spec_from_file_location("upload_r2_object", UPLOADER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def read_live(key: str) -> bytes | None:
    """The feed object's bytes through the S3 API (not the cached public URL), None when absent."""
    module = _uploader_module()
    args = argparse.Namespace(endpoint_url=env("R2_ENDPOINT"), bucket=env("NIGHTLY_NEXT_R2_BUCKET"), key=key,
                              cache_control=FEED_CACHE, content_type="application/xml")
    amz_date = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    request = module._build_signed_request(args, b"", amz_date, method="GET")
    try:
        with module._open_signed_request(request, timeout=60) as response:
            return response.read()
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None
        raise


def write_feed(feed: Path, github_output: str | None, same_build: bool = False, attempts: int = 5,
               source_sha: str | None = None) -> int:
    key = env("NIGHTLY_NEXT_R2_PREFIX") + feed.name
    guard_key(key)
    original = bind_feed_prefixes(feed.read_bytes())
    if source_sha:
        original = add_source(original, source_sha.lower())
    ours = newest_build(original)
    for _ in range(attempts):
        live = read_live(key)
        if live is None and same_build:
            print(f"{feed.name}: no live feed to revise; left as it is")
            return 0
        if live is not None:
            theirs = newest_build(live)
            if not same_build and theirs == ours and source_sha:
                live_source = item_source(live, theirs) or signed_notes_source(theirs) or compiled_artifact_source(theirs)
                if live_source == source_sha.lower():
                    # The CAS may have succeeded before a later handoff failed.
                    # Retry metadata publication from the bytes already accepted.
                    feed.write_bytes(live)
                    if github_output:
                        with open(github_output, "a", encoding="utf-8") as out:
                            out.write("feed_written=false\nfeed_current=true\n")
                    print(f"{feed.name}: this exact build and source are already live; reusing the live feed")
                    return 0
            if (theirs != ours) if same_build else (theirs >= ours):
                print(f"{feed.name}: the live feed serves build {theirs}, this feed's newest is {ours}; "
                      "left as it is")
                if github_output:
                    with open(github_output, "a", encoding="utf-8") as out:
                        out.write("feed_written=false\npublication_refused=true\n")
                return 0
            if source_sha and not same_build:
                live_source = item_source(live, theirs)
                if live_source is None:
                    live_source = signed_notes_source(theirs) or compiled_artifact_source(theirs)
                if live_source is None:
                    raise RuntimeError(
                        f"{feed.name}: live build {theirs} has no source metadata and no verified signed "
                        "notes head or compiled-source receipt; refusing an unsafe overwrite"
                    )
                if not source_order(live_source, source_sha.lower()):
                    print(f"{feed.name}: live source {live_source} is newer than candidate source {source_sha}; left it as is")
                    if github_output:
                        with open(github_output, "a", encoding="utf-8") as out:
                            out.write("feed_written=false\npublication_refused=true\n")
                    return 0
            mode = ["--replace-sha256", hashlib.sha256(live).hexdigest(), "--conflict-exit-code", str(CONFLICT)]
            merged = keep_earlier_builds(original, live)
            # Delta artifacts predate the source marker added by the initial CAS.
            # Keep the live item's provenance when revising that exact build.
            if same_build:
                live_source = item_source(live, ours) or item_source(merged, ours)
                if live_source:
                    merged = add_source(merged, live_source)
            merged = bind_feed_prefixes(merged)
            if merged != original:
                kept = sorted({b for _, b in item_builds(merged)} - {b for _, b in item_builds(original)}, reverse=True)
                print(f"{feed.name}: keeps the live feed's build {', '.join(map(str, kept))} beside {ours}, "
                      "for a rollback to serve")
            feed.write_bytes(merged)
        else:
            feed.write_bytes(original)
            mode = ["--write-once", "--conflict-exit-code", str(CONFLICT)]
        try:  # never publish a feed an XML reader refuses
            ET.fromstring(feed.read_bytes())
        except ET.ParseError as error:
            raise RuntimeError(f"{feed.name}: refusing to publish a feed that does not parse: {error}") from error
        result = subprocess.run(uploader_args(feed, key, FEED_CACHE, "application/xml") + mode)
        if result.returncode == 0:
            print(f"{feed.name}: build {ours} is live at {public_base()}{feed.name}")
            if github_output:
                with open(github_output, "a", encoding="utf-8") as out:
                    out.write("feed_written=true\nfeed_current=true\n")
            return 0
        if result.returncode != CONFLICT:
            return result.returncode
        print(f"{feed.name}: another run wrote the feed meanwhile; reading it again", flush=True)
    print(f"{feed.name}: the feed kept changing under {attempts} attempts", file=sys.stderr)
    return 1


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    up = sub.add_parser("upload")
    up.add_argument("--file", action="append", type=Path, required=True)
    rw = sub.add_parser("rewrite")
    rw.add_argument("--feed", type=Path, required=True)
    rw.add_argument("--name", action="append", default=[])
    rw.add_argument("--if-public", action="store_true")
    wf = sub.add_parser("write-feed")
    wf.add_argument("--feed", type=Path, required=True)
    wf.add_argument("--github-output")
    wf.add_argument("--same-build", action="store_true")
    wf.add_argument("--source-sha", help="full source commit for this feed's newest item")
    args = parser.parse_args(argv)
    if args.command == "upload":
        return upload(args.file)
    if args.command == "rewrite":
        if not args.name and not args.if_public:
            parser.error("rewrite needs --name or --if-public")
        return rewrite(args.feed, set(args.name), args.if_public)
    return write_feed(args.feed, args.github_output, args.same_build, source_sha=args.source_sha)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
