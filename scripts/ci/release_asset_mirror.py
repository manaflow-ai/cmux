#!/usr/bin/env python3
"""A content-addressed mirror of the release downloads CI depends on.

2026-11-08 to 11-09: release downloads answered 503 and 504 for hours, and pull requests that were green
went red fetching the error-tracking CLI, the updater tools, prebuilt xcframeworks and FFI zips. A busy or
broken upstream should make a job slower, never make it fail. So every pinned release asset also lives in the public CI cache bucket, keyed by
its sha256, and readers try that copy first.

    release_asset_mirror.py fetch URL (--sha256 HEX | --from-index) --out PATH [--deadline SECONDS]
    release_asset_mirror.py fill [--ref REF ...] [--sources pins,deps,scan,lock]
    release_asset_mirror.py list [--ref REF ...] [--sources ...]

Layout under ${CMUX_RELEASE_MIRROR_URL:-${CI_CACHE_R2_PUBLIC_URL:-https://ci-cache.cmux.com}}, and the same
keys in the bucket:
    release-assets/v1/sha256/<64 hex>   the asset's bytes, written once
    release-assets/v1/url/<sha256 of the URL string>   "<64 hex>\\n", written after the object is verified
r2_cache_prune.py only prunes v1/*/objects/, so nothing here is ever pruned. Keep this prefix outside it:
a reader trusts that an indexed object stays.

fetch, per round: (1) the mirror object (with --from-index, the URL index first, then the object); (2) the
upstream URL; (3) for a github.com release download with a token in GH_TOKEN or GITHUB_TOKEN, the same
asset through the release-assets API (the token goes only to api.github.com). Rounds repeat with
exponential backoff (5 s doubling to 60 s, with jitter) until the deadline (default 900 s, or
CMUX_RELEASE_FETCH_DEADLINE), and only then fail. Every byte is checked against the sha256 before it lands
at --out. CMUX_RELEASE_MIRROR=off skips the mirror; CMUX_RELEASE_UPSTREAM=off skips the upstream and the
release API (the outage drill). Importable: fetch(url, sha256, out_path, deadline=None) returns the source that served it.

fill gathers (url, sha256) pairs and, for each one the bucket lacks, downloads it from upstream with the
same bounded retry, checks it, uploads it write-once (If-None-Match: *), reads it back, checks it again and
only then writes the URL index. Sources:
    pins   every literal .binaryTarget url/checksum in each Package.swift of the --ref trees (plus the
           GhosttyKit archive the tree's ghostty submodule and scripts/ghosttykit-checksums.txt pin)
    deps   literal binary targets in the Package.swift of every github.com pin in each Package.resolved
    scan   the newest release assets of our FFI and xcframework releases whose API digest is a sha256
    lock   scripts/ci/release-assets.lock, the tools scripts download
It exits non-zero only when a pinned pair (pins, deps, lock) fails for a reason other than the upstream
being unavailable; it never uploads unverified bytes. Writes use the bucket's S3 credentials through curl
--aws-sigv4, as r2-cache.sh save does: AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, CI_CACHE_R2_ENDPOINT,
CI_CACHE_R2_BUCKET. list prints what fill would mirror and writes nothing.

Stdlib only; run it as `python3 -I scripts/ci/release_asset_mirror.py`.
"""
from __future__ import annotations

import argparse
import concurrent.futures
import dataclasses
import hashlib
import http.client
import json
import os
import random
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LOCK_FILE = ROOT / "scripts" / "ci" / "release-assets.lock"
DEFAULT_MIRROR = "https://ci-cache.cmux.com"
PREFIX = "release-assets/v1"
DEFAULT_DEADLINE = 900.0
BACKOFF_START, BACKOFF_CAP = 5.0, 60.0
# urllib has one timeout for the connect and every read: no byte for this long is a stall.
CONNECT_TIMEOUT = 15
# A transfer that averages under this rate over a window is dropped and retried, so a crawling connection
# cannot hold a job until the deadline.
LOW_SPEED_BYTES_PER_SECOND = 32 * 1024
LOW_SPEED_WINDOW = 30.0
# Rounds in a row in which every upstream source answered for certain (404, or bytes with another sha256)
# end the wait early: retrying a missing asset or a wrong pin only delays the same failure.
DEFINITIVE_ROUNDS = 3
GITHUB_API = "https://api.github.com"
GITHUB_RELEASE_DOWNLOAD = re.compile(r"https://github\.com/([^/]+)/([^/]+)/releases/download/(.+)/([^/]+)")
SHA256_HEX = re.compile(r"[0-9a-f]{64}")
CHUNK = 1 << 20


def log(message: str) -> None:
    print(f"release-asset: {message}", file=sys.stderr, flush=True)


def mirror_base() -> str:
    return (os.environ.get("CMUX_RELEASE_MIRROR_URL") or os.environ.get("CI_CACHE_R2_PUBLIC_URL")
            or DEFAULT_MIRROR).rstrip("/")


def object_key(sha256: str) -> str:
    return f"{PREFIX}/sha256/{sha256}"


def index_key(url: str) -> str:
    return f"{PREFIX}/url/{hashlib.sha256(url.encode('utf-8')).hexdigest()}"


def asset_name(url: str) -> str:
    return urllib.parse.unquote(urllib.parse.urlsplit(url).path.rsplit("/", 1)[-1]) or url


def enabled(name: str) -> bool:
    return os.environ.get(name, "").strip().lower() not in ("off", "0", "false", "no")


class FetchError(RuntimeError):
    """fetch gave up. `kind` is "unavailable" (sources kept failing until the deadline), "definitive" (the
    upstream said for certain: no such asset, or other bytes), "no-index" or "config"."""

    def __init__(self, message: str, kind: str):
        super().__init__(message)
        self.kind = kind


class SourceFailed(Exception):
    def __init__(self, reason: str, definitive: bool = False):
        super().__init__(reason)
        self.reason, self.definitive = reason, definitive


def _open(request: urllib.request.Request, timeout: float = CONNECT_TIMEOUT):
    """The one network call; tests replace it."""
    return urllib.request.urlopen(request, timeout=timeout)  # noqa: S310


def _describe(error: BaseException) -> str:
    if isinstance(error, urllib.error.HTTPError):
        return f"HTTP {error.code}"
    if isinstance(error, urllib.error.URLError):
        return str(error.reason)
    return f"{type(error).__name__}: {error}" if str(error) else type(error).__name__


def _stream(request: urllib.request.Request, sink, limit: int | None = None) -> str:
    """Copy the response body into `sink`; return its sha256. Raises SourceFailed."""
    digest = hashlib.sha256()
    try:
        with _open(request) as response:
            total, window_start, window_bytes = 0, time.monotonic(), 0
            while True:
                chunk = response.read(CHUNK)
                if not chunk:
                    break
                digest.update(chunk)
                sink.write(chunk)
                total += len(chunk)
                if limit is not None and total > limit:
                    raise SourceFailed(f"larger than {limit} bytes")
                window_bytes += len(chunk)
                now = time.monotonic()
                if now - window_start >= LOW_SPEED_WINDOW:
                    if window_bytes < LOW_SPEED_BYTES_PER_SECOND * (now - window_start):
                        raise SourceFailed(f"stalled under {LOW_SPEED_BYTES_PER_SECOND // 1024} KiB/s")
                    window_start, window_bytes = now, 0
    except SourceFailed:
        raise
    except urllib.error.HTTPError as error:
        error.close()
        raise SourceFailed(_describe(error), definitive=error.code == 404) from None
    # http.client.HTTPException is not an OSError: IncompleteRead (a body cut short), BadStatusLine and
    # RemoteDisconnected-like failures must be a retryable miss, never an escape out of fetch or fill.
    except (OSError, ValueError, EOFError, http.client.HTTPException) as error:  # URLError, timeouts, resets
        raise SourceFailed(_describe(error)) from None
    return digest.hexdigest()


def _request(url: str, accept: str | None = None) -> urllib.request.Request:
    request = urllib.request.Request(url, headers={"User-Agent": "cmux-release-asset-mirror"})
    if accept:
        request.add_header("Accept", accept)
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if token and url.startswith(GITHUB_API + "/"):
        # Unredirected: the asset API redirects to a signed storage URL, which must not get the token.
        request.add_unredirected_header("Authorization", f"Bearer {token}")
    return request


def _read_small(url: str, accept: str | None = None, limit: int = 8 << 20) -> bytes:
    try:
        with _open(_request(url, accept)) as response:
            body = response.read(limit + 1)
    except urllib.error.HTTPError as error:
        error.close()
        raise SourceFailed(_describe(error), definitive=error.code == 404) from None
    except (OSError, ValueError, EOFError, http.client.HTTPException) as error:
        raise SourceFailed(_describe(error)) from None
    if len(body) > limit:
        raise SourceFailed(f"answer larger than {limit} bytes")
    return body


def read_index(url: str) -> str:
    """The sha256 the mirror's URL index records for `url`. Raises SourceFailed (definitive on a miss)."""
    text = _read_small(f"{mirror_base()}/{index_key(url)}", limit=256).decode("ascii", "replace").strip()
    if not SHA256_HEX.fullmatch(text):
        raise SourceFailed("URL index entry is not a sha256")
    return text


def api_asset_url(url: str) -> str | None:
    """The release-assets API URL of a github.com release download, or None when it is not one, there is no
    token, or the release has no asset of that name."""
    match = GITHUB_RELEASE_DOWNLOAD.fullmatch(url)
    if not match:
        return None
    owner, repo, tag, name = (urllib.parse.unquote(part) for part in match.groups())
    listing = _read_small(f"{GITHUB_API}/repos/{owner}/{repo}/releases/tags/{urllib.parse.quote(tag, safe='')}",
                          "application/vnd.github+json")
    try:
        assets = json.loads(listing).get("assets") or []
    except ValueError:
        raise SourceFailed("release listing is not JSON") from None
    asset = next((a for a in assets if a.get("name") == name), None)
    if asset is None:
        raise SourceFailed(f"release {owner}/{repo} {tag} has no asset {name}", definitive=True)
    return str(asset["url"])


def _land(request_or_url, sha256: str, out: Path, accept: str | None = None) -> None:
    """Download into a temporary file beside `out` and rename it there only if its sha256 matches."""
    request = request_or_url if isinstance(request_or_url, urllib.request.Request) else _request(request_or_url, accept)
    out.parent.mkdir(parents=True, exist_ok=True)
    handle = tempfile.NamedTemporaryFile(dir=out.parent, prefix=f".{out.name}.", suffix=".part", delete=False)
    try:
        with handle:
            got = _stream(request, handle)
        if got != sha256:
            raise SourceFailed(f"sha256 {got}, expected {sha256}", definitive=True)
        os.replace(handle.name, out)
    finally:
        if os.path.exists(handle.name):
            os.unlink(handle.name)


def fetch(url: str, sha256: str | None, out_path, deadline: float | None = None, *,
          mirror: bool | None = None, upstream: bool | None = None, also: tuple[str, ...] = (),
          sleep=time.sleep, clock=time.monotonic) -> str:
    """Put the asset at `url` into `out_path`, checked against `sha256` (None: the mirror's URL index names
    it). Returns the source that served it: "mirror", "upstream", "api" or "also". Raises FetchError.

    `also`: the caller's own pinned endpoints for the same bytes (a public release-assets API URL, which
    needs no token), tried in every round after the upstream URL. A caller's fallback must run during the
    wait, not after it: a job's time limit can end before the deadline does."""
    out = Path(out_path)
    name = asset_name(url)
    if sha256 is not None:
        sha256 = sha256.strip().lower()
        if not SHA256_HEX.fullmatch(sha256):
            raise FetchError(f"{sha256!r} is not a sha256\nnext: pass the 64 hex digits the pin names", "config")
    if deadline is None:
        deadline = float(os.environ.get("CMUX_RELEASE_FETCH_DEADLINE") or DEFAULT_DEADLINE)
    use_mirror = enabled("CMUX_RELEASE_MIRROR") if mirror is None else mirror
    use_upstream = enabled("CMUX_RELEASE_UPSTREAM") if upstream is None else upstream
    if not use_mirror and not use_upstream:
        raise FetchError(f"no source for {name}: CMUX_RELEASE_MIRROR and CMUX_RELEASE_UPSTREAM are both off\n"
                         "next: turn one of them back on", "config")
    if sha256 is None and not use_mirror:
        raise FetchError(f"--from-index needs the mirror, and CMUX_RELEASE_MIRROR is off\n"
                         "next: pass --sha256, or turn the mirror on", "config")
    has_token = bool(os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN"))
    started = clock()
    delay, rounds, definitive_rounds = BACKOFF_START, 0, 0
    last: dict[str, str] = {}

    def attempt(source: str, action) -> bool:
        began = clock()
        try:
            action()
        except SourceFailed as failure:
            last[source] = failure.reason
            verb = "miss" if source == "mirror" and failure.definitive else "failed"
            log(f"{source} {verb} {name} ({failure.reason}) {clock() - began:.1f}s")
            raise
        log(f"{source} hit {name} {clock() - began:.1f}s")
        return True

    while True:
        rounds += 1
        github_answers: list[bool] = []
        want = sha256
        if use_mirror:
            try:
                if want is None:
                    began = clock()
                    try:
                        want = read_index(url)
                    except SourceFailed as failure:
                        log(f"index {'miss' if failure.definitive else 'failed'} {name} ({failure.reason}) "
                            f"{clock() - began:.1f}s")
                        if failure.definitive:
                            raise FetchError(
                                f"the mirror has no URL index entry for {url}, so nothing can check its bytes\n"
                                "next: pass --sha256 from the pin, or let the Mirror release assets workflow "
                                "(fill) mirror it first", "no-index") from None
                        last["index"] = failure.reason
                if want is not None and attempt("mirror", lambda: _land(f"{mirror_base()}/{object_key(want)}",
                                                                        want, out)):
                    return "mirror"
            except SourceFailed:
                pass
        if use_upstream and want is not None:
            try:
                if attempt("upstream", lambda: _land(url, want, out)):
                    return "upstream"
            except SourceFailed as failure:
                github_answers.append(failure.definitive)
            if has_token and GITHUB_RELEASE_DOWNLOAD.fullmatch(url):
                def through_api() -> None:
                    api_url = api_asset_url(url)
                    _land(api_url, want, out, "application/octet-stream")
                try:
                    if attempt("api", through_api):
                        return "api"
                except SourceFailed as failure:
                    github_answers.append(failure.definitive)
            for extra in also:
                try:
                    if attempt("also", lambda: _land(extra, want, out, "application/octet-stream")):
                        return "also"
                except SourceFailed as failure:
                    github_answers.append(failure.definitive)
        definitive_rounds = definitive_rounds + 1 if github_answers and all(github_answers) else 0
        elapsed = clock() - started
        summary = "; ".join(f"{source}: {reason}" for source, reason in last.items()) or "no source answered"
        if definitive_rounds >= DEFINITIVE_ROUNDS:
            raise FetchError(f"could not fetch {name} ({url}): the upstream answered the same way {rounds} times "
                             f"({summary})\nnext: check the pin; the release has no such asset, or it no "
                             "longer has these bytes", "definitive")
        wait = min(delay, BACKOFF_CAP) * random.uniform(0.8, 1.2)
        if elapsed + wait > deadline:
            sources = [s for s, on in (("mirror", use_mirror), ("upstream", use_upstream)) if on]
            raise FetchError(f"could not fetch {name} ({url}) from {' or '.join(sources)} in {elapsed:.0f}s, "
                             f"{rounds} rounds ({summary})\nnext: the upstream is unavailable and the mirror "
                             "has no copy; rerun the job once the upstream recovers, or raise --deadline "
                             "(CMUX_RELEASE_FETCH_DEADLINE)", "unavailable")
        log(f"round {rounds} failed for {name}; retrying in {wait:.0f}s")
        sleep(wait)
        delay *= 2


# --- What to mirror -------------------------------------------------------------------------------------

@dataclasses.dataclass(frozen=True)
class Pair:
    url: str
    sha256: str
    origin: str
    pinned: bool = True


MANIFEST = re.compile(r"(^|/)Package(@swift-[0-9.]+)?\.swift$")
RESOLVED = re.compile(r"(^|/)Package\.resolved$")
STRING_LET = re.compile(r'\b(?:let|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?::\s*String\s*)?=\s*"((?:[^"\\\n]|\\.)*)"')
INTERPOLATION = re.compile(r"\\\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*\)")
GITHUB_PIN = re.compile(r"https://github\.com/([^/\s]+)/([^/\s]+?)(?:\.git)?/?$")


def _call_args(text: str, start: int) -> str | None:
    """The text between the parenthesis at `start` and its match, skipping string literals and comments."""
    depth, i, n = 0, start, len(text)
    while i < n:
        char = text[i]
        if char == '"':
            i += 1
            interpolation = 0
            while i < n:
                if text[i] == "\\" and i + 1 < n:
                    if text[i + 1] == "(":
                        interpolation += 1
                    i += 2
                    continue
                if interpolation and text[i] == ")":
                    interpolation -= 1
                elif not interpolation and text[i] == '"':
                    break
                i += 1
        elif text.startswith("//", i):
            i = text.find("\n", i)
            if i < 0:
                return None
        elif text.startswith("/*", i):
            i = text.find("*/", i)
            if i < 0:
                return None
            i += 1
        elif char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                return text[start + 1:i]
        i += 1
    return None


def _argument(args: str, label: str, strings: dict[str, str]) -> str | None:
    """A labelled argument's value: a string literal (with \\(name) of literal constants filled in) or the
    name of a literal constant. None for anything evaluated at manifest time."""
    match = re.search(rf'\b{label}\s*:\s*(?:"((?:[^"\\\n]|\\.)*)"|([A-Za-z_][A-Za-z0-9_]*))', args)
    if not match:
        return None
    if match.group(2) is not None:
        return strings.get(match.group(2))
    value = match.group(1)
    unresolved = False

    def fill(found: re.Match) -> str:
        nonlocal unresolved
        if found.group(1) not in strings:
            unresolved = True
            return ""
        return strings[found.group(1)]
    value = INTERPOLATION.sub(fill, value)
    if unresolved or "\\" in value:
        return None
    return value


def binary_targets(manifest: str) -> list[tuple[str, str]]:
    """(url, checksum) of every .binaryTarget in a Package.swift whose url and checksum are literal, or built
    only from literal `let` constants of the same file (CmuxTerminalClient's releaseRepository/releaseTag)."""
    strings: dict[str, str] = {}
    for name, value in STRING_LET.findall(manifest):
        if "\\" not in value:
            strings.setdefault(name, value)
    for name, value in STRING_LET.findall(manifest):  # one level of constants built from constants
        if name not in strings:
            filled = INTERPOLATION.sub(lambda m: strings.get(m.group(1), "\\"), value)
            if "\\" not in filled:
                strings[name] = filled
    found = []
    for match in re.finditer(r"\.binaryTarget\s*\(", manifest):
        args = _call_args(manifest, match.end() - 1)
        if args is None:
            continue
        url, checksum = _argument(args, "url", strings), _argument(args, "checksum", strings)
        if url and checksum and url.startswith("https://") and SHA256_HEX.fullmatch(checksum.lower()):
            found.append((url, checksum.lower()))
    return found


def resolved_pins(text: str) -> list[tuple[str, str, str]]:
    """(owner, repo, revision) of every github.com pin in a Package.resolved (format 1, 2 or 3)."""
    try:
        data = json.loads(text)
    except ValueError:
        return []
    pins = data.get("pins") or (data.get("object") or {}).get("pins") or []
    found = []
    for pin in pins:
        location = str(pin.get("location") or pin.get("repositoryURL") or "")
        revision = str((pin.get("state") or {}).get("revision") or "")
        match = GITHUB_PIN.match(location)
        if match and re.fullmatch(r"[0-9a-f]{40}", revision):
            found.append((match.group(1), match.group(2), revision))
    return found


def parse_lock(text: str, origin: str = "release-assets.lock") -> list[Pair]:
    """`URL SHA256` per line; `#` starts a comment. A malformed line is an error, not a skip."""
    pairs = []
    for number, raw in enumerate(text.splitlines(), 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        fields = line.split()
        if len(fields) != 2 or not fields[0].startswith("https://") or not SHA256_HEX.fullmatch(fields[1]):
            raise ValueError(f"{origin}:{number}: expected `URL SHA256`, got {raw!r}")
        pairs.append(Pair(fields[0], fields[1], f"{origin}:{number}"))
    return pairs


def git(*args: str) -> str:
    return subprocess.run(["git", "-C", str(ROOT), *args], check=True, capture_output=True, text=True).stdout


def ref_exists(ref: str) -> bool:
    return subprocess.run(["git", "-C", str(ROOT), "rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}"],
                          capture_output=True).returncode == 0


GHOSTTYKIT_FLAVOR = "crashsubdir-cmux-crash-sentry-off-noi18n-v2"


def tree_pairs(refs: list[str]) -> tuple[list[Pair], list[tuple[str, str, str]]]:
    """Binary targets of every manifest in each ref, the GhosttyKit archive each ref pins, and the remote
    pins of every Package.resolved."""
    pairs: list[Pair] = []
    pins: list[tuple[str, str, str]] = []
    for ref in refs:
        if not ref_exists(ref):
            log(f"skipping {ref}: not a commit here (fetch it first)")
            continue
        for path in git("ls-tree", "-r", "--name-only", ref).splitlines():
            if MANIFEST.search(path):
                text = git("show", f"{ref}:{path}")
                if "binaryTarget" in text:
                    pairs += [Pair(url, sha, f"{ref}:{path}") for url, sha in binary_targets(text)]
            elif RESOLVED.search(path):
                pins += resolved_pins(git("show", f"{ref}:{path}"))
        # download-prebuilt-ghosttykit.sh's default archive for this tree's ghostty revision.
        submodule = git("ls-tree", ref, "ghostty").split()
        if len(submodule) >= 3 and submodule[1] == "commit":
            try:
                checksums = git("show", f"{ref}:scripts/ghosttykit-checksums.txt")
            except subprocess.CalledProcessError:
                checksums = ""
            for line in checksums.splitlines():
                fields = line.split()
                if len(fields) >= 2 and fields[0] == submodule[2] and SHA256_HEX.fullmatch(fields[1]):
                    url = (f"https://github.com/manaflow-ai/ghostty/releases/download/xcframework-{fields[0]}-"
                           f"{GHOSTTYKIT_FLAVOR}/GhosttyKit.xcframework.tar.gz")
                    pairs.append(Pair(url, fields[1], f"{ref}:scripts/ghosttykit-checksums.txt"))
    return pairs, sorted(set(pins))


MAX_PINS = 80
PIN_BUDGET_SECONDS = 180.0


def dependency_pairs(pins: list[tuple[str, str, str]]) -> list[Pair]:
    """Literal binary targets in each pinned dependency's Package.swift at its revision (third-party
    xcframeworks come in this way). Bounded in count and time; a manifest that cannot be read is skipped."""
    pairs: list[Pair] = []
    started = time.monotonic()
    for count, (owner, repo, revision) in enumerate(pins):
        if count >= MAX_PINS or time.monotonic() - started > PIN_BUDGET_SECONDS:
            log(f"read {count} of {len(pins)} pinned manifests; the rest wait for the next run")
            break
        url = f"https://raw.githubusercontent.com/{owner}/{repo}/{revision}/Package.swift"
        try:
            text = _read_small(url, limit=1 << 20).decode("utf-8", "replace")
        except SourceFailed as failure:
            log(f"skipping {owner}/{repo}@{revision[:12]} manifest ({failure.reason})")
            continue
        pairs += [Pair(u, s, f"{owner}/{repo}@{revision[:12]}") for u, s in binary_targets(text)]
    return pairs


SCAN = (
    ("manaflow-ai/cmux", ("cmux-app-ffi-", "cmux-terminal-client-")),
    ("manaflow-ai/ghostty-next", ("xcframework-",)),
    ("manaflow-ai/ghostty", ("xcframework-",)),
)
SCAN_SUFFIXES = (".zip", ".tar.gz", ".tar.xz")
SCAN_MAX_BYTES = 1 << 30
SCAN_MAX_PAGES = 10


def scan_pairs(newest: int = 30) -> list[Pair]:
    """Assets of the newest `newest` releases per tag prefix whose API digest is a sha256. Needs a token;
    without one, or on any API failure, it returns what it has (a scan is never pinned)."""
    if not (os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")):
        log("release scan skipped: no GH_TOKEN or GITHUB_TOKEN")
        return []
    pairs: list[Pair] = []
    for repo, prefixes in SCAN:
        taken = {prefix: 0 for prefix in prefixes}
        for page in range(1, SCAN_MAX_PAGES + 1):
            if all(count >= newest for count in taken.values()):
                break
            try:
                releases = json.loads(_read_small(f"{GITHUB_API}/repos/{repo}/releases?per_page=100&page={page}",
                                                  "application/vnd.github+json", limit=64 << 20))
            except (SourceFailed, ValueError) as failure:
                log(f"release scan of {repo} stopped at page {page} ({failure})")
                break
            if not releases:
                break
            for release in releases:
                tag = str(release.get("tag_name") or "")
                prefix = next((p for p in prefixes if tag.startswith(p)), None)
                if prefix is None or taken[prefix] >= newest or release.get("draft"):
                    continue
                taken[prefix] += 1
                for asset in release.get("assets") or []:
                    digest = str(asset.get("digest") or "")
                    name = str(asset.get("name") or "")
                    if (digest.startswith("sha256:") and SHA256_HEX.fullmatch(digest[7:])
                            and name.endswith(SCAN_SUFFIXES) and int(asset.get("size") or 0) <= SCAN_MAX_BYTES):
                        pairs.append(Pair(str(asset["browser_download_url"]), digest[7:], f"{repo} {tag}", False))
    return pairs


SOURCES = ("pins", "deps", "scan", "lock")


def gather(refs: list[str], sources: tuple[str, ...] = SOURCES, newest: int = 30,
           lock: Path = LOCK_FILE) -> list[Pair]:
    pairs: list[Pair] = []
    pins: list[tuple[str, str, str]] = []
    if "pins" in sources or "deps" in sources:
        tree, pins = tree_pairs(refs)
        if "pins" in sources:
            pairs += tree
    if "deps" in sources:
        pairs += dependency_pairs(pins)
    if "lock" in sources:
        pairs += parse_lock(lock.read_text(encoding="utf-8"), lock.name)
    if "scan" in sources:
        pairs += scan_pairs(newest)
    # One entry per (url, sha256); pinned wins over scanned.
    unique: dict[tuple[str, str], Pair] = {}
    for pair in pairs:
        key = (pair.url, pair.sha256)
        if key not in unique or (pair.pinned and not unique[key].pinned):
            unique[key] = pair
    return list(unique.values())


# --- Writing the mirror ---------------------------------------------------------------------------------

class Store:
    """Signed requests to the bucket through curl --aws-sigv4, as r2-cache.sh does. The credential goes to
    curl on stdin, never on its command line. Tests replace this with a fake."""

    def __init__(self, endpoint: str, bucket: str):
        self.base = f"{endpoint.rstrip('/')}/{bucket}"

    def _curl(self, key: str, *args: str, out: str = os.devnull) -> int:
        config = 'user = "%s:%s"\n' % (os.environ["AWS_ACCESS_KEY_ID"], os.environ["AWS_SECRET_ACCESS_KEY"])
        result = subprocess.run(
            ["curl", "--config", "-", "--silent", "--show-error", "--retry", "3", "--retry-delay", "2",
             "--connect-timeout", "15", "--max-time", "1800", "--aws-sigv4", "aws:amz:auto:s3",
             "-H", "x-amz-content-sha256: UNSIGNED-PAYLOAD", "-o", out, "-w", "%{http_code}", *args,
             f"{self.base}/{key}"],
            input=config, capture_output=True, text=True)
        try:
            return int(result.stdout.strip() or 0)
        except ValueError:
            return 0

    def head(self, key: str) -> int:
        return self._curl(key, "--head")

    def put(self, key: str, path: Path, content_type: str) -> int:
        return self._curl(key, "-H", "If-None-Match: *", "-H", f"content-type: {content_type}",
                          "-T", str(path))

    def get(self, key: str, path: Path) -> int:
        return self._curl(key, out=str(path))


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(CHUNK), b""):
            digest.update(chunk)
    return digest.hexdigest()


def ensure_index(store, url: str, sha256: str, work: Path) -> str:
    """Write the URL index once its object is verified. Returns "ok" or "conflict" (the index already names
    other bytes: write-once, so it stays, and readers keep getting what it named)."""
    key = index_key(url)
    entry = work / "index"
    for _ in range(2):
        status = store.head(key)
        if status == 404:
            entry.write_text(sha256 + "\n", encoding="ascii")
            status = store.put(key, entry, "text/plain")
            if status == 200:
                return "ok"
            if status != 412:  # 412: another writer won; read what it wrote
                raise SourceFailed(f"index upload answered HTTP {status}")
            continue
        if status != 200:
            raise SourceFailed(f"index HEAD answered HTTP {status}")
        status = store.get(key, entry)
        if status != 200:
            raise SourceFailed(f"index read answered HTTP {status}")
        current = entry.read_text(encoding="ascii", errors="replace").strip()
        if current == sha256:
            return "ok"
        print(f"::warning::release-asset: URL index for {url} names {current}, not {sha256}; left as is",
              file=sys.stderr, flush=True)
        return "conflict"
    raise SourceFailed("index write raced twice")


def mirror_pair(store, pair: Pair, deadline: float, work: Path) -> tuple[str, str]:
    """(outcome, detail): "present", "mirrored", or a failure kind ("unavailable", "definitive", "storage")."""
    key = object_key(pair.sha256)
    try:
        status = store.head(key)
        outcome = "present"
        if status == 404:
            blob = work / "asset"
            try:
                fetch(pair.url, pair.sha256, blob, deadline, mirror=False, upstream=True)
            except FetchError as error:
                return error.kind, str(error).splitlines()[0]
            status = store.put(key, blob, "application/octet-stream")
            if status not in (200, 412):  # 412: the object already exists
                return "storage", f"upload answered HTTP {status}"
            blob.unlink()
            status = store.get(key, blob)
            if status != 200:
                return "storage", f"read-back answered HTTP {status}"
            got = _sha256_file(blob)
            blob.unlink()
            if got != pair.sha256:
                return "storage", f"read back as {got}"
            outcome = "mirrored"
        elif status != 200:
            return "storage", f"HEAD answered HTTP {status}"
        if ensure_index(store, pair.url, pair.sha256, work) == "conflict":
            return outcome, "index names other bytes"
        return outcome, ""
    except SourceFailed as failure:
        return "storage", failure.reason


def fill(pairs: list[Pair], store, deadline: float, budget: float, workers: int = 4) -> dict:
    started = time.monotonic()
    results: dict[str, list[tuple[Pair, str]]] = {}

    def one(pair: Pair) -> tuple[Pair, str, str]:
        if time.monotonic() - started > budget:
            return pair, "deferred", "run budget spent; next run"
        # One pair's unexpected error is that pair's failure, never the run's: map() would re-raise it.
        try:
            with tempfile.TemporaryDirectory(prefix="release-asset-") as work:
                outcome, detail = mirror_pair(store, pair, deadline, Path(work))
        except Exception as error:  # noqa: BLE001
            return pair, "storage", f"{type(error).__name__}: {error}"
        return pair, outcome, detail

    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        for pair, outcome, detail in pool.map(one, pairs):
            results.setdefault(outcome, []).append((pair, detail))
            if outcome not in ("present",):
                log(f"{outcome} {pair.url} {pair.sha256[:12]} ({pair.origin}){': ' + detail if detail else ''}")
    return results


def fatal(results: dict) -> list[tuple[Pair, str]]:
    """Pinned pairs that failed for a reason other than the upstream being unavailable."""
    return [(pair, detail) for outcome in ("definitive", "storage", "config", "no-index")
            for pair, detail in results.get(outcome, []) if pair.pinned]


def render(results: dict) -> str:
    counts = {outcome: len(items) for outcome, items in sorted(results.items())}
    lines = ["Release asset mirror: " + ", ".join(f"{count} {outcome}" for outcome, count in counts.items())]
    for outcome in ("definitive", "storage", "unavailable", "deferred"):
        for pair, detail in results.get(outcome, []):
            pinned = "pinned" if pair.pinned else "scanned"
            lines.append(f"- {outcome} ({pinned}, {pair.origin}): {pair.url} {detail}")
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    get = commands.add_parser("fetch", help="download one asset, mirror first")
    get.add_argument("url")
    which = get.add_mutually_exclusive_group(required=True)
    which.add_argument("--sha256")
    which.add_argument("--from-index", action="store_true")
    get.add_argument("--out", required=True)
    get.add_argument("--deadline", type=float)
    get.add_argument("--also", action="append", default=[], metavar="URL",
                     help="another pinned endpoint for the same bytes, tried every round (repeatable)")
    for name in ("fill", "list"):
        sub = commands.add_parser(name)
        sub.add_argument("--ref", action="append", dest="refs")
        sub.add_argument("--sources", default=",".join(SOURCES))
        sub.add_argument("--newest", type=int, default=30, help="releases per tag prefix in the scan")
        if name == "fill":
            sub.add_argument("--deadline", type=float, default=180.0, help="per asset, for the upstream download")
            sub.add_argument("--budget", type=float, default=1200.0, help="seconds before remaining pairs wait")
            sub.add_argument("--workers", type=int, default=4)
    args = parser.parse_args(argv)

    if args.command == "fetch":
        try:
            fetch(args.url, None if args.from_index else args.sha256, args.out, args.deadline,
                  also=tuple(args.also))
        except FetchError as error:
            print(f"release-asset: {error}", file=sys.stderr)
            return 2 if error.kind == "config" else 1
        return 0

    sources = tuple(s for s in args.sources.split(",") if s)
    unknown = set(sources) - set(SOURCES)
    if unknown:
        parser.error(f"unknown sources {sorted(unknown)}; choose from {SOURCES}")
    refs = args.refs or ["origin/main", "origin/feat-cmux-next"]
    pairs = gather(refs, sources, args.newest)
    if args.command == "list":
        for pair in sorted(pairs, key=lambda p: (not p.pinned, p.url)):
            print(f"{pair.url} {pair.sha256} {'pinned' if pair.pinned else 'scanned'} {pair.origin}")
        return 0

    missing = [n for n in ("AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "CI_CACHE_R2_ENDPOINT", "CI_CACHE_R2_BUCKET")
               if not os.environ.get(n)]
    if missing:
        print(f"release-asset: {', '.join(missing)} not set; nothing to write with\n"
              "next: run fill from the Mirror release assets workflow (environment ci-cache-writer)", file=sys.stderr)
        return 2
    log(f"{len(pairs)} assets to check ({sum(p.pinned for p in pairs)} pinned)")
    store = Store(os.environ["CI_CACHE_R2_ENDPOINT"], os.environ["CI_CACHE_R2_BUCKET"])
    results = fill(pairs, store, args.deadline, args.budget, args.workers)
    text = render(results)
    print(text)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as handle:
            handle.write(text + "\n")
    bad = fatal(results)
    if bad:
        print("release-asset: pinned assets failed for a reason other than the upstream being unavailable\n"
              "next: fix the pins or the bucket named above; an unavailable upstream alone never fails this",
              file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
