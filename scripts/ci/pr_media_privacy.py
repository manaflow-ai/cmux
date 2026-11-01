#!/usr/bin/env python3
"""Keep private machine and account names off the public pr-media branch.

Many tools write screenshots, GIFs and videos to the public ``pr-media``
branch. Captures from the fleet minis show terminal prompts such as
``cmux@cmux7s-Mac-mini``, the Inspector's ``cmux7's Mac mini`` and the capture
account's ``/Users/cmux``. This module is the one shared check, run twice.

Before the push (``check_upload()``, or ``pr_media_privacy.py check``), by the
writers in this repository:

- ``scripts/pr-media.py``: ``main()`` checks the whole batch, generated gifs
  included, before its first upload, and ``put_file()`` checks each file for
  library callers (``scripts/ci/pr_media.py publish``, ``scripts/showcase-publish.py``,
  and the HQ and feat-cmux-next tools that import or run pr-media.py);
- ``dogfood/fuzz/cmuxfuzz/triage.py``: the UI fuzzer's frames under ``fuzz/``.

Text files are read directly; images, GIF frames and one video frame per
second go through Apple Vision (``pr_media_ocr.swift``, compiled once and
cached by ``ocr_binary()``). Without Vision (Linux) media are skipped and left
to the scan below. Any hit refuses the upload, whoever's pull request it is
(Leo, 2026-10-22: "1 ok"), and nothing refused is uploaded. The message names
the hit's category (``KIND_LABELS``, e.g. "fleet host name") and how to fix it,
never the matched text.

After the push (no subcommand), ``.github/workflows/pr-media-privacy.yml``
diffs the last scanned commit (``refs/pr-media-privacy/scanned``) against the
branch tip and reads the added and modified files, so writers that run no
check (cmux-next-media.yml tours, nightly.yml reels, older checkouts) and the
media a Linux writer skipped are still covered.

Matching folds Cyrillic and Greek look-alikes, which Vision often returns
(``сmux7's Mас mini``), back to Latin; private terms also match the digits
Vision reads for letters (``g1ow``). Built-in patterns name no specific
machine. Personal machine and account names come from ``PR_MEDIA_PRIVATE_TERMS``
(a secret holding a JSON list) or a terms file (``load_private_terms()``), and
no output ever echoes what they matched.

Who owns a file: a numeric top folder ``<N>/`` is pull request N, an agent's
when its author is listed in ``PR_MEDIA_AGENT_AUTHORS``; ``nightly-next/``,
``fuzz/`` and ``whats-new/`` (whats-new-clips.py) are bots' own output. With ``--apply`` the scan removes agent-owned
hits in one ordinary commit on top of the tip (never a history rewrite). A
teammate's file, any other folder, or an author that cannot be looked up is
reported and kept (before the push every hit refuses, as above). Private terms shorter
than ``MIN_TERM_LENGTH`` are ignored: with digit look-alikes a two-letter term
would match ordinary text such as ``10``. The
scan fails whenever anything was found, so the hit stays visible on the run
page even after its removal.

The scan's first run, with no marker, scans nothing and only records the tip:
the branch's existing files are not flagged wholesale.

Exit status: 0 clean, 1 something was found (the scan) or refused (``check``),
2 bad input.
"""

from __future__ import annotations

import argparse
import contextlib
import getpass
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import sys
import tempfile
from typing import Callable, Iterable, Mapping, TextIO
import unicodedata

BRANCH = "pr-media"
REPOSITORY = "manaflow-ai/cmux"
# Bots' own output; a hit there is always enforced.
BOT_FOLDERS = frozenset({"nightly-next", "fuzz", "whats-new"})
PR_FOLDER = re.compile(r"[1-9][0-9]{0,6}")
MEDIA_SUFFIXES = frozenset({".png", ".jpg", ".jpeg", ".webp", ".gif", ".mp4", ".mov"})
TEXT_SUFFIXES = frozenset({".html", ".json", ".md", ".txt"})
FRAME_SEPARATOR = re.compile(r"@@frame (\d+)\s*$")
PUSH_ATTEMPTS = 3
AUTHOR_BATCH = 50

# Cyrillic and Greek letters Vision reads in place of Latin ones. Digits are
# never folded: `cmux7` and `cmux1` must stay different machines.
LOOK_ALIKES = str.maketrans({
    "а": "a", "в": "b", "е": "e", "к": "k", "м": "m", "н": "h", "о": "o",
    "р": "p", "с": "c", "т": "m", "у": "y", "х": "x", "и": "u", "і": "i",
    "ј": "j", "ѕ": "s", "ь": "b",
    "α": "a", "β": "b", "ε": "e", "η": "n", "ι": "i", "κ": "k", "μ": "u",
    "ν": "v", "ο": "o", "ρ": "p", "σ": "o", "ς": "c", "τ": "t", "υ": "u",
    "χ": "x", "γ": "y", "ζ": "z",
    "‘": "'", "’": "'", "ʼ": "'",
})

# Private terms match many-to-one: each letter of a term also matches what
# Vision reads in its place, including digits (`g1ow`, `b0x`). A digit in a term
# stays a literal digit, so a term `cmux1` never matches `cmux7`. Shared with
# cmuxterm-hq build-fleet/pr_capture/driver.py.
TERM_LOOK_ALIKES = {
    "a": "аα", "b": "ьвβ", "c": "сϲς", "d": "ԁ", "e": "еёε", "g": "ɡ", "h": "һнη", "i": "іїι1l",
    "j": "ј", "k": "кκ", "l": "i1ıӏ", "m": "мтμ", "n": "пην", "o": "оοσ0", "p": "рρ", "r": "г",
    "s": "ѕ", "t": "тτ", "u": "иυ", "v": "ν", "w": "ԝ", "x": "хχ", "y": "уγυ", "z": "ζ",
}
TERM_WORD_CHARS = "a-z0-9" + "".join(TERM_LOOK_ALIKES.values())
# Every non-ASCII look-alike to a Latin letter, for addresses Vision misread.
TO_LATIN = str.maketrans({character: latin for latin, characters in TERM_LOOK_ALIKES.items()
                          for character in characters if not character.isascii()})
HQ_TERMS_FILE = "build-fleet/pr_capture/private-terms.json"
AGENT_AUTHORS_FILE = "Projects/leo-workspace/machines/agent-authors.json"
# Local account and host names too common to mean a machine (a capture mini's user is `cmux`).
COMMON_NAMES = frozenset({"cmux", "root", "runner", "admin", "user", "shared", "localhost"})
# Shorter terms match ordinary words and numbers once look-alikes are folded.
MIN_TERM_LENGTH = 4
OCR_CACHE = "Library/Caches/cmux-pr-media-privacy"

# Generic shapes of the capture and fleet machines; none names one machine.
# A lookbehind keeps each from firing inside a longer word.
_EDGE = r"(?<![a-z0-9_])"
GENERIC_PATTERNS: tuple[tuple[str, re.Pattern[str]], ...] = tuple(
    (name, re.compile(_EDGE + pattern)) for name, pattern in (
        ("mini-name", r"cmux\d*'?s[- ]mac[- ]mini(?:-\d+)?(?![a-z0-9])"),
        ("mini-host", r"cmux-mac-mini(?:-cua)?(?:-\d+)?(?![a-z0-9])"),
        ("mini-host", r"cmux-austin-mini(?:-\d+)?(?![a-z0-9])"),
        ("fleet-host", r"cmux\d{1,2}(?![a-z0-9_])"),
        ("shell-prompt", r"cmux@[\w.-]+"),
        ("capture-account", r"/users/cmux(?![a-z0-9_])"),
        ("capture-account", r"/users/shared/cmux-capture"),
    )
)
EMAIL = re.compile(r"(?<![a-z0-9._%+-])[a-z0-9._%+-]+@([a-z0-9-]+(?:\.[a-z0-9-]+)*\.[a-z]{2,})(?![a-z0-9-])")
# Reserved documentation domains and GitHub's public no-reply addresses.
PUBLIC_EMAIL_DOMAINS = ("example.com", "example.org", "example.net", "test", "users.noreply.github.com")


# The category a refusal names for each kind, so whoever captured the media knows what to change;
# the matched text itself is never printed.
KIND_LABELS = {
    "mini-name": "fleet Mac mini name",
    "mini-host": "fleet host name",
    "fleet-host": "fleet host name",
    "shell-prompt": "fleet shell prompt",
    "capture-account": "capture account path",
    "private-term": "personal machine or account name",
    "email": "personal email address",
    "unreadable": "unreadable file",
}
FIX = ("Show fixture names in the scene instead (the sample hosts, users and paths the scenes and tours use), "
       "then recapture.")


def kind_labels(kinds: Iterable[str]) -> str:
    return ", ".join(dict.fromkeys(KIND_LABELS.get(kind, kind) for kind in kinds))


class BadInput(Exception):
    pass


class Refused(Exception):
    """A pre-push check refused files; the message names paths and kinds, never the matched text."""

    def __init__(self, report: dict) -> None:
        refused = [item for item in report["files"] if item["action"] == "refuse"]
        listed = "; ".join(f"{item['path']} ({kind_labels(item['kinds'])})" for item in refused)
        super().__init__(f"refused {len(refused)} file(s) that show private names: {listed}. "
                         f"Nothing was uploaded. {FIX}")
        self.report = report


def fold(text: str) -> str:
    return text.translate(LOOK_ALIKES)


def normalize(text: str) -> str:
    return unicodedata.normalize("NFKC", text).lower()


def parse_terms(raw: str, source: str) -> list[str]:
    """A bare JSON list of strings (the secret) or {"terms": [...]} (HQ's file)."""
    try:
        terms = json.loads(raw)
    except json.JSONDecodeError as error:
        raise BadInput(f"{source} is not JSON ({error.msg})") from error
    if isinstance(terms, dict):
        terms = terms.get("terms")
    if not isinstance(terms, list) or not all(isinstance(term, str) for term in terms):
        raise BadInput(f"{source} must be a JSON list of strings or {{\"terms\": [...]}}")
    return terms


def term_pattern(term: str) -> re.Pattern[str]:
    """Whole-word, case-insensitive; each letter also matches its look-alikes."""
    body = "".join(f"[{character}{TERM_LOOK_ALIKES[character]}]" if character in TERM_LOOK_ALIKES
                   else re.escape(character) for character in normalize(term))
    return re.compile(f"(?<![{TERM_WORD_CHARS}]){body}(?![{TERM_WORD_CHARS}])")


def term_patterns(terms: Iterable[str]) -> list[tuple[str, re.Pattern[str]]]:
    return [("private-term", term_pattern(term.strip())) for term in terms
            if len(normalize(term.strip())) >= MIN_TERM_LENGTH]


def private_patterns(raw: str | None) -> list[tuple[str, re.Pattern[str]]]:
    """Patterns from the PR_MEDIA_PRIVATE_TERMS secret (either terms format)."""
    if not raw or not raw.strip():
        return []
    return term_patterns(parse_terms(raw, "PR_MEDIA_PRIVATE_TERMS"))


def public_email(domain: str) -> bool:
    return any(domain == public or domain.endswith("." + public) for public in PUBLIC_EMAIL_DOMAINS)


def findings(lines: list[str], patterns: list[tuple[str, re.Pattern[str]]]) -> list[dict]:
    """Return [{kind, text, line}] for every private name in the OCR or text lines.

    Generic patterns see the line as read and with one-to-one look-alike folding
    (no digits). Private terms carry their own look-alike classes. Every variant
    keeps the line's length, so one name found in two variants counts once.
    """
    found: list[dict] = []
    for number, raw in enumerate(lines, start=1):
        lowered = normalize(raw)
        seen: dict[tuple[str, int], str] = {}
        for variant in dict.fromkeys((lowered, fold(lowered))):
            for kind, pattern in patterns:
                for match in pattern.finditer(variant):
                    seen.setdefault((kind, match.start()), match.group(0))
        for variant in dict.fromkeys((lowered, fold(lowered), lowered.translate(TO_LATIN))):
            for match in EMAIL.finditer(variant):
                if match.group(0).isascii() and not public_email(match.group(1)):
                    seen.setdefault(("email", match.start()), match.group(0))
        unique = sorted({(kind, text) for (kind, _start), text in seen.items()})
        found.extend({"kind": kind, "text": text, "line": number} for kind, text in unique)
    return found


def local_names(home: Path) -> list[str]:
    """This machine's account, host and full names and home directory."""
    names = [str(home)]
    with contextlib.suppress(Exception):
        names.append(getpass.getuser())
    with contextlib.suppress(Exception):
        host = socket.gethostname()
        names += [host.split(".", 1)[0], host]
    if sys.platform == "darwin":
        with contextlib.suppress(Exception):
            done = subprocess.run(["id", "-F"], capture_output=True, text=True, timeout=10)
            if done.returncode == 0:
                names.append(done.stdout.strip())
    return [name for name in dict.fromkeys(name.strip() for name in names)
            if len(name) >= MIN_TERM_LENGTH and name.casefold() not in COMMON_NAMES]


def load_private_terms(env: Mapping[str, str] = os.environ) -> tuple[list[str], str]:
    """(terms, where they came from); the description names no term.

    The first source found wins: $PR_MEDIA_PRIVATE_TERMS (JSON),
    $PR_MEDIA_PRIVATE_TERMS_FILE, $CMUX_HQ's private-terms.json, then
    ~/Projects/cmuxterm-hq's. Outside CI this machine's own names are added.
    """
    home = Path(env.get("HOME") or Path.home())
    terms: list[str] = []
    source = ""
    raw = env.get("PR_MEDIA_PRIVATE_TERMS", "")
    if raw.strip():
        terms, source = parse_terms(raw, "PR_MEDIA_PRIVATE_TERMS"), "$PR_MEDIA_PRIVATE_TERMS"
    else:
        candidates: list[tuple[Path, str]] = []
        named = env.get("PR_MEDIA_PRIVATE_TERMS_FILE", "").strip()
        if named:
            path = Path(named).expanduser()
            if not path.is_file():
                raise BadInput("PR_MEDIA_PRIVATE_TERMS_FILE names no file")
            candidates.append((path, "$PR_MEDIA_PRIVATE_TERMS_FILE"))
        if env.get("CMUX_HQ", "").strip():
            candidates.append((Path(env["CMUX_HQ"]).expanduser() / HQ_TERMS_FILE, f"$CMUX_HQ/{HQ_TERMS_FILE}"))
        candidates.append((home / "Projects/cmuxterm-hq" / HQ_TERMS_FILE, f"~/Projects/cmuxterm-hq/{HQ_TERMS_FILE}"))
        for path, label in candidates:
            if path.is_file():
                terms, source = parse_terms(path.read_text(encoding="utf-8"), label), label
                break
    if not source:
        source = "no private terms list (set PR_MEDIA_PRIVATE_TERMS or PR_MEDIA_PRIVATE_TERMS_FILE)"
    if not env.get("GITHUB_ACTIONS"):
        own = local_names(home)
        if own:
            terms = [*terms, *own]
            source += " + this machine's names"
    return terms, source


def load_agent_authors(env: Mapping[str, str] = os.environ) -> frozenset[str]:
    """$PR_MEDIA_AGENT_AUTHORS (comma list), else ~/Projects/leo-workspace's list, else none.

    The workspace file is {"authors": [...]} (a bare list is read too).
    """
    raw = env.get("PR_MEDIA_AGENT_AUTHORS", "")
    if raw.strip():
        return agent_authors(raw)
    path = Path(env.get("HOME") or Path.home()) / AGENT_AUTHORS_FILE
    if not path.is_file():
        return frozenset()
    try:
        logins = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        raise BadInput(f"~/{AGENT_AUTHORS_FILE} is not JSON ({error.msg})") from error
    if isinstance(logins, dict):
        logins = logins.get("authors")
    if not isinstance(logins, list) or not all(isinstance(login, str) for login in logins):
        raise BadInput(f"~/{AGENT_AUTHORS_FILE} must be {{\"authors\": [logins]}} or a JSON list of logins")
    return agent_authors(",".join(logins))


def git(*args: str, cwd: Path, input: str | None = None, env: dict[str, str] | None = None) -> str:
    command_env = {**os.environ, **env} if env else None
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True,
                          text=True, input=input, env=command_env).stdout


def changed_files(repo: Path, start: str, end: str) -> list[str]:
    """Added or modified paths between two commits; works when start is not an ancestor."""
    raw = git("diff", "--name-status", "--no-renames", "-z", start, end, cwd=repo)
    fields = [field for field in raw.split("\0") if field]
    paths = []
    for status, path in zip(fields[0::2], fields[1::2]):
        if status in {"A", "M"} and Path(path).suffix.lower() in MEDIA_SUFFIXES | TEXT_SUFFIXES:
            paths.append(path)
    return paths


def ocr_lines(ocr: str, repo: Path, commit: str, path: str) -> list[str]:
    suffix = Path(path).suffix.lower()
    data = subprocess.run(["git", "cat-file", "blob", f"{commit}:{path}"], cwd=repo,
                          check=True, capture_output=True).stdout
    if suffix in TEXT_SUFFIXES:
        return data.decode("utf-8", errors="replace").splitlines()
    with tempfile.TemporaryDirectory(prefix="cmux-pr-media-privacy-") as directory:
        local = Path(directory) / Path(path).name
        local.write_bytes(data)
        return ocr_file(ocr, local)


def ocr_file(ocr: str, local: Path) -> list[str]:
    """The text Vision reads in one local image or video, frame markers dropped."""
    done = subprocess.run([ocr, str(local)], capture_output=True, text=True, timeout=600)
    if done.returncode != 0:
        raise RuntimeError(f"OCR exited {done.returncode}")
    return [line for line in done.stdout.splitlines() if not FRAME_SEPARATOR.match(line)]


def ocr_binary(env: Mapping[str, str] = os.environ, out: TextIO | None = None) -> str | None:
    """The compiled pr_media_ocr.swift, or None where Apple Vision is unavailable.

    $PR_MEDIA_PRIVACY_OCR overrides: a path to a compiled tool, or `none`. On
    macOS the tool is compiled once per source revision into
    ~/Library/Caches/cmux-pr-media-privacy/<sha256>/ocr and reused after.
    """
    override = env.get("PR_MEDIA_PRIVACY_OCR", "").strip()
    if override:
        return None if override.lower() == "none" else override
    source = Path(__file__).resolve().with_name("pr_media_ocr.swift")
    swiftc = shutil.which("swiftc")
    if sys.platform != "darwin" or not swiftc or not source.is_file():
        return None
    # /usr/bin/swiftc on a Mac without developer tools is a stub that opens an install dialog.
    tools = subprocess.run(["xcode-select", "-p"], capture_output=True, text=True)
    if tools.returncode != 0 or not Path(tools.stdout.strip()).is_dir():
        return None
    digest = hashlib.sha256(source.read_bytes()).hexdigest()
    binary = Path(env.get("HOME") or Path.home()) / OCR_CACHE / digest / "ocr"
    if os.access(binary, os.X_OK):
        return str(binary)
    binary.parent.mkdir(parents=True, exist_ok=True)
    partial = binary.with_name(f"ocr.{os.getpid()}.partial")
    print("pr-media privacy: compiling the OCR tool once (pr_media_ocr.swift)", file=out or sys.stderr, flush=True)
    try:
        done = subprocess.run([swiftc, "-O", str(source), "-o", str(partial)],
                              capture_output=True, text=True, timeout=900)
    except (OSError, subprocess.SubprocessError):
        done = None
    if done is None or done.returncode != 0 or not partial.is_file():
        partial.unlink(missing_ok=True)
        print("pr-media privacy: could not compile the OCR tool; media are left to pr-media-privacy.yml",
              file=out or sys.stderr, flush=True)
        return None
    os.replace(partial, binary)
    return str(binary)


def owner(path: str) -> tuple[str, int | None]:
    """('pr', N), ('bot', None) or ('other', None) from the top folder."""
    top = path.split("/", 1)[0] if "/" in path else ""
    if PR_FOLDER.fullmatch(top):
        return "pr", int(top)
    if top in BOT_FOLDERS:
        return "bot", None
    return "other", None


def github_authors(numbers: list[int], repository: str | None = None) -> dict[int, str] | None:
    """PR author logins in one batched GraphQL call; None when the lookup fails."""
    repository = repository or os.environ.get("REPOSITORY", "")
    if "/" not in repository:
        return None
    owner_name, name = repository.split("/", 1)
    authors: dict[int, str] = {}
    for start in range(0, len(numbers), AUTHOR_BATCH):
        batch = numbers[start:start + AUTHOR_BATCH]
        fields = " ".join(f"p{n}: pullRequest(number: {n}) {{ author {{ login }} }}" for n in batch)
        query = f'query {{ repository(owner: "{owner_name}", name: "{name}") {{ {fields} }} }}'
        done = subprocess.run(["gh", "api", "graphql", "-f", f"query={query}"],
                              capture_output=True, text=True)
        # A partial answer (one number is an issue, one PR is gone) also exits non-zero:
        # treat it as a failed lookup so nothing in the batch is removed.
        if done.returncode != 0:
            return None
        try:
            repo = (json.loads(done.stdout or "{}").get("data") or {}).get("repository") or {}
        except json.JSONDecodeError:
            return None
        for key, value in repo.items():
            login = ((value or {}).get("author") or {}).get("login")
            if isinstance(login, str):
                authors[int(key[1:])] = login
    return authors


def agent_authors(raw: str | None) -> frozenset[str]:
    return frozenset(part.strip().casefold() for part in (raw or "").split(",") if part.strip())


def classify(paths: Iterable[str], agents: frozenset[str], lookup) -> dict[str, tuple[str, str]]:
    """Map each hit path to (whose, why): whose is 'agent' (an agent's or a bot's
    file), 'unknown' (its PR's author could not be looked up) or 'teammate'."""
    paths = list(paths)
    numbers = sorted({number for path in paths for kind, number in [owner(path)] if kind == "pr"})
    authors: dict[int, str] | None = {}
    if numbers and agents:
        try:
            authors = lookup(numbers)
        except Exception:  # noqa: BLE001 - any lookup failure means the author is unknown
            authors = None
    decisions: dict[str, tuple[str, str]] = {}
    for path in paths:
        kind, number = owner(path)
        if kind == "bot":
            decisions[path] = ("agent", "a bot's folder")
        elif kind == "other":
            decisions[path] = ("teammate", "not an agent folder")
        elif not agents:
            # Without the list no PR folder can be told to be a teammate's: the
            # scan only reports it, and a writer refuses it (fails closed).
            decisions[path] = ("unknown", "PR_MEDIA_AGENT_AUTHORS is empty")
        elif authors is None or number not in authors:
            decisions[path] = ("unknown", "PR author unknown")
        elif authors[number].casefold() in agents:
            decisions[path] = ("agent", "an agent's pull request")
        else:
            decisions[path] = ("teammate", "PR author is not an agent")
    return decisions


def removable(hits: dict[str, list[dict]], agents: frozenset[str], lookup) -> dict[str, str]:
    """Map each hit path to 'remove' or the reason it is only reported."""
    return {path: "remove" if whose == "agent" else why
            for path, (whose, why) in classify(hits, agents, lookup).items()}


def check_files(items: Iterable[tuple[str, Path]], patterns: list[tuple[str, re.Pattern[str]]],
                ocr: str | Callable[[Path], list[str]] | None) -> dict:
    """Check local files before they are pushed to pr-media.

    items are (path on the branch, local file) pairs. ocr is a compiled
    pr_media_ocr.swift, a callable from a local file to its lines, or None, which
    skips media (the scan after the push reads them). A file that shows a
    private name, or could not be read, is refused, whoever's folder it is.
    Returns {"files": [{path, kinds, action, reason}], "skipped": [...], "refused": bool}.
    """
    report: dict = {"files": [], "skipped": [], "refused": False}
    hits: dict[str, list[str]] = {}
    for remote, local in items:
        local = Path(local)
        suffix = Path(remote).suffix.lower() or local.suffix.lower()
        try:
            if suffix in TEXT_SUFFIXES:
                lines = local.read_text(encoding="utf-8", errors="replace").splitlines()
            elif suffix in MEDIA_SUFFIXES and ocr is not None:
                lines = ocr(local) if callable(ocr) else ocr_file(ocr, local)
            else:
                report["skipped"].append(remote)
                continue
        except Exception:  # noqa: BLE001 - a file that cannot be read is held like a hit
            hits[remote] = ["unreadable"]
            continue
        kinds = sorted({hit["kind"] for hit in findings(lines, patterns)})
        if kinds:
            hits[remote] = kinds
    for remote in sorted(hits):
        why = "could not be read, so it is held like a hit" if hits[remote] == ["unreadable"] else \
            "private names are refused in every pull request's media"
        report["files"].append({"path": remote, "kinds": hits[remote], "action": "refuse", "reason": why})
    report["refused"] = bool(report["files"])
    return report


def report_lines(report: dict) -> list[str]:
    """What a writer prints: paths and kinds only, never the matched text."""
    lines = []
    for item in report["files"]:
        shows = "could not be read" if item["kinds"] == ["unreadable"] else f"shows a {kind_labels(item['kinds'])}"
        lines.append(f"{item['path']} {shows}; refused ({item['reason']})")
    if report["files"]:
        lines.append(f"nothing was uploaded. {FIX}")
    if report["skipped"]:
        lines.append(f"{len(report['skipped'])} file(s) not read here (media need Apple Vision); "
                     "pr-media-privacy.yml scans them after the push")
    return lines


_AUTO = object()


def check_upload(items: Iterable[tuple[str, Path | str]], repository: str = REPOSITORY, *,
                 env: Mapping[str, str] = os.environ, ocr=_AUTO, lookup=None,
                 out: TextIO | None = None) -> dict:
    """The pre-push check every pr-media writer runs: raises Refused, else returns the report.

    Terms come from load_private_terms(). Any hit refuses, so no PR author is looked up;
    repository and lookup are accepted for the writers that still pass them.
    """
    out = out or sys.stderr
    items = [(remote, Path(local)) for remote, local in items]
    terms, source = load_private_terms(env)
    if ocr is _AUTO:
        needs_ocr = any(local.suffix.lower() in MEDIA_SUFFIXES for _remote, local in items)
        ocr = ocr_binary(env, out) if needs_ocr else None
    report = check_files(items, [*GENERIC_PATTERNS, *term_patterns(terms)], ocr)
    report["terms"] = source
    lines = report_lines(report)
    if not terms:
        lines.append(f"generic patterns only: {source}")
    for line in lines:
        print(f"pr-media privacy: {line}", file=out, flush=True)
    if report["refused"]:
        raise Refused(report)
    return report


def remove_paths(repo: Path, tip: str, paths: dict[str, str], message: str) -> str:
    """Commit removing paths (path -> blob scanned) on top of tip; returns the commit."""
    listing = git("ls-tree", "-r", "-z", tip, "--", *paths, cwd=repo)
    present = {}
    for record in listing.split("\0"):
        if "\t" in record:
            meta, path = record.split("\t", 1)
            present[path] = meta.split()[2]
    # A writer that replaced the file since the scan is scanned on the next run.
    targets = [path for path, blob in paths.items() if present.get(path) == blob]
    if not targets:
        return tip
    with tempfile.NamedTemporaryFile(prefix="cmux-pr-media-privacy-index-", delete=False) as handle:
        index = Path(handle.name)
    index.unlink()
    env = {"GIT_INDEX_FILE": str(index)}
    try:
        git("read-tree", tip, cwd=repo, env=env)
        git("update-index", "--force-remove", "-z", "--stdin", cwd=repo, env=env,
            input="\0".join(targets) + "\0")
        # --missing-ok: a blob:none clone holds no blobs, and none are needed.
        tree = git("write-tree", "--missing-ok", cwd=repo, env=env).strip()
    finally:
        index.unlink(missing_ok=True)
    return git("commit-tree", tree, "-p", tip, "-m", message, cwd=repo).strip()


def apply_removal(repo: Path, remote: str, paths: dict[str, str], message: str) -> str | None:
    """Push one removal commit with a lease on the tip; refetch and retry on a race."""
    refspec = f"+refs/heads/{BRANCH}:refs/remotes/{remote}/{BRANCH}"
    for _attempt in range(PUSH_ATTEMPTS):
        tip = git("rev-parse", f"refs/remotes/{remote}/{BRANCH}", cwd=repo).strip()
        commit = remove_paths(repo, tip, paths, message)
        if commit == tip:
            return None
        try:
            git("push", f"--force-with-lease=refs/heads/{BRANCH}:{tip}", remote,
                f"{commit}:refs/heads/{BRANCH}", cwd=repo)
            return commit
        except subprocess.CalledProcessError:
            # The workflow's clone is shallow and blob-less; never make a full clone shallow.
            shallow = git("rev-parse", "--is-shallow-repository", cwd=repo).strip() == "true"
            depth = ["--depth=1"] if shallow else []
            git("fetch", "--no-tags", "--filter=blob:none", *depth, remote, refspec, cwd=repo)
    raise RuntimeError(f"{BRANCH} kept moving; removal not pushed after {PUSH_ATTEMPTS} attempts")


def annotation(text: str) -> str:
    return text.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def annotation_property(text: str) -> str:
    return annotation(text).replace(":", "%3A").replace(",", "%2C")


def scan(repo: Path, start: str | None, end: str, ocr: str | None, patterns, apply: bool,
         agents: frozenset[str], lookup, remote: str = "origin") -> dict:
    report: dict = {"from": start, "to": end, "files": [], "unscanned": [], "removal": None, "marker": end}
    if not start:
        print(f"No scanned marker yet; recording {end[:12]} without scanning the existing branch.", flush=True)
        return report
    hits: dict[str, list[dict]] = {}
    for path in changed_files(repo, start, end):
        is_text = Path(path).suffix.lower() in TEXT_SUFFIXES
        if not is_text and not ocr:
            raise BadInput("--ocr is required to scan media files")
        try:
            lines = ocr_lines(ocr or "", repo, end, path)
        except (RuntimeError, subprocess.SubprocessError, OSError) as error:
            report["unscanned"].append({"path": path, "error": str(error)})
            print(f"::error file={annotation_property(path)},title=pr-media privacy::could not read {annotation(path)} ({error})",
                  flush=True)
            continue
        found = findings(lines, patterns)
        if found:
            hits[path] = found
    decisions = removable(hits, agents, lookup) if hits else {}
    blobs = {}
    if hits:
        listing = git("ls-tree", "-r", "-z", end, "--", *hits, cwd=repo)
        for record in listing.split("\0"):
            if "\t" in record:
                meta, path = record.split("\t", 1)
                blobs[path] = meta.split()[2]
    to_remove = {path: blobs[path] for path, decision in decisions.items() if decision == "remove" and path in blobs}
    if apply and to_remove:
        lines = [f"PR media privacy: remove {len(to_remove)} file(s) showing private names", ""]
        lines += [f"- {path} ({', '.join(sorted({hit['kind'] for hit in hits[path]}))})" for path in sorted(to_remove)]
        lines += ["", "Found by scripts/ci/pr_media_privacy.py (.github/workflows/pr-media-privacy.yml)."]
        report["removal"] = apply_removal(repo, remote, to_remove, "\n".join(lines) + "\n")
        # The removal holds nothing new to scan when it sits right on the scanned tip.
        if report["removal"] and git("rev-parse", f"{report['removal']}^", cwd=repo).strip() == end:
            report["marker"] = report["removal"]
    for path in sorted(hits):
        kinds = sorted({hit["kind"] for hit in hits[path]})
        if path not in to_remove:
            action = f"reported, not removed: {decisions[path]}"
        elif not apply:
            action = "would be removed (dry run)"
        elif report["removal"] is None:
            action = "reported, not removed: replaced on the branch since the scan"
        else:
            action = "removed"
        kind, number = owner(path)
        report["files"].append({"path": path, "folder": path.split("/", 1)[0] if "/" in path else "",
                                "pr": number, "kinds": kinds, "action": action,
                                "lines": sorted({hit["line"] for hit in hits[path]})})
        where = f"PR #{number}" if kind == "pr" else (f"folder {path.split('/', 1)[0]}" if "/" in path else "branch root")
        print(f"::error file={annotation_property(path)},title=pr-media privacy::{annotation(path)} ({where}) shows "
              f"{', '.join(kinds)}; {action}", flush=True)
    return report


def write_summary(report: dict) -> None:
    target = os.environ.get("GITHUB_STEP_SUMMARY")
    if not target:
        return
    rows = ["## pr-media privacy", ""]
    if not report["from"]:
        rows.append(f"First run: recorded `{report['to'][:12]}` without scanning.")
    elif not report["files"]:
        rows.append(f"Clean: `{(report['from'] or '')[:12]}..{report['to'][:12]}`.")
    else:
        rows += ["| File | Folder | Found | Action |", "| --- | --- | --- | --- |"]
        rows += [f"| `{item['path']}` | {item['folder'] or '-'} | {', '.join(item['kinds'])} | {item['action']} |"
                 for item in report["files"]]
    if report["unscanned"]:
        rows += ["", "Could not read: " + ", ".join(f"`{item['path']}`" for item in report["unscanned"])]
    with open(target, "a", encoding="utf-8") as handle:
        handle.write("\n".join(rows) + "\n")


def check_main(argv: list[str], lookup=None) -> int:
    """`check --path-prefix DIR FILE...`: the pre-push check for files bound for DIR/<name>."""
    parser = argparse.ArgumentParser(prog="pr_media_privacy.py check",
                                     description="Check files before they are pushed to pr-media.")
    parser.add_argument("--path-prefix", required=True,
                        help="folder on pr-media the files land in, e.g. 15277 or fuzz/<digest>")
    parser.add_argument("--repository", default=os.environ.get("REPOSITORY") or REPOSITORY,
                        help="the repository the files are for (no PR author is looked up)")
    parser.add_argument("files", nargs="+", type=Path, metavar="FILE")
    args = parser.parse_args(argv)
    prefix = args.path_prefix.strip("/")
    try:
        missing = [str(path) for path in args.files if not path.is_file()]
        if not prefix or missing:
            raise BadInput("not a file: " + ", ".join(missing) if missing else "--path-prefix is empty")
        check_upload([(f"{prefix}/{path.name}", path) for path in args.files], args.repository,
                     lookup=lookup, out=sys.stdout)
    except BadInput as error:
        print(f"pr-media privacy: {error}", file=sys.stderr)
        return 2
    except Refused as refused:
        print(f"pr-media privacy: {refused}", file=sys.stderr)
        return 1
    return 0


def main(argv: list[str] | None = None, lookup=github_authors) -> int:
    argv = sys.argv[1:] if argv is None else argv
    if argv[:1] == ["check"]:
        return check_main(argv[1:], lookup=None if lookup is github_authors else lookup)
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", type=Path, default=Path.cwd(),
                        help="git directory holding the pr-media tip and the last scanned commit")
    parser.add_argument("--from", dest="start", default="",
                        help="last scanned commit; empty records the tip without scanning")
    parser.add_argument("--to", dest="end", required=True, help="commit to scan up to (the pr-media tip)")
    parser.add_argument("--ocr", help="compiled scripts/ci/pr_media_ocr.swift")
    parser.add_argument("--apply", action="store_true", help="push one commit removing agent-owned hits")
    parser.add_argument("--remote", default="origin")
    parser.add_argument("--report", type=Path, help="write a JSON report here")
    args = parser.parse_args(argv)
    try:
        patterns = [*GENERIC_PATTERNS, *private_patterns(os.environ.get("PR_MEDIA_PRIVATE_TERMS"))]
        start = "" if args.start in {"", "empty"} else args.start
        for value in filter(None, (start, args.end)):
            try:
                git("rev-parse", "--verify", "--quiet", f"{value}^{{commit}}", cwd=args.repo)
            except subprocess.CalledProcessError as error:
                raise BadInput(f"{value} is not a commit in {args.repo}") from error
        report = scan(args.repo, start or None, args.end, args.ocr, patterns, args.apply,
                      agent_authors(os.environ.get("PR_MEDIA_AGENT_AUTHORS")), lookup, args.remote)
    except BadInput as error:
        print(f"::error title=pr-media privacy::{annotation(str(error))}", flush=True)
        return 2
    except Exception as error:  # noqa: BLE001 - any crash must hold the marker, not pass as "hits found"
        # Only the type: a git error's text can carry paths or commit messages.
        print(f"::error title=pr-media privacy::scan stopped with {type(error).__name__}; the marker is kept",
              flush=True)
        return 3
    if args.report:
        args.report.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    write_summary(report)
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as handle:
            handle.write(f"marker={report['marker']}\n")
    found, unread = len(report["files"]), len(report["unscanned"])
    print(f"pr-media privacy: {found} file(s) with private names, {unread} unreadable.", flush=True)
    # An unreadable file is not retried, so it fails the run like a hit.
    return 1 if found or unread else 0


if __name__ == "__main__":
    sys.exit(main())
