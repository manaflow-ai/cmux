#!/usr/bin/env python3
"""Guard against unannounced default changes (Leo 2026-10-13).

A default is what someone gets without configuring anything: an action's
default keys, a setting's default value, a Ghostty keybind cmux writes (an
unbind takes a chord from Ghostty), a feature flag compiled on or off. Changing
one changes what everyone gets, so it needs a call.

schemas/defaults/<app>.json is the golden snapshot of every default, made from
the sources of truth with no hand list:
- cmux NEXT: plans/cmux-next/action-surfaces.json (each action's default
  shortcut, chord and aliases, exported from the catalog by Swift) and
  schemas/settings/settings-schema.json (each setting's default), both kept
  current by the generated-files check; the Ghostty `keybind = ...` lines and
  the `static let ...Enabled = true|false` flags in the app's Swift sources.

  python3 scripts/ci/defaults_guard.py snapshot           # regenerate it
  python3 scripts/ci/defaults_guard.py check-fresh        # it matches the sources

The settings exports' source stamp is derived, never committed (Leo 2026-10-21):
`source-stamp [--ref REF]` prints one `sha256  path` entry per CmuxNextSettings
source and export test at REF, a blank line apart. Base autofix compares the
stamp of the commit its exports were made at with the tip's: equal means the
exports' inputs did not move. A committed copy changed in every pull request that
touched a settings source and conflicted on nearly every base move (#22674); the
exports themselves are checked against a fresh Swift export (the generated files
job of cmux-next.yml).
  python3 scripts/ci/defaults_guard.py check --base B --head H [--pr N --repo R]

`check` compares the defaults at the merge base with the ones at the head, each
computed from that tree's exports and sources (the trees are read with git as
data; nothing from the head runs). The snapshot is bot-only (#21946): the base
autofix rewrites it after a merge, no pull request commits it, and `check`
never reads it, so a hand-edited copy hides nothing.

A setting the pull request adds whose default is off (false, null, "off",
"never", "none", "disabled" or empty) keeps the behavior from before it
existed (new things ship off), so it passes on its own (Leo 2026-10-21); it
stays listed. Any other change passes with an independent review receipt on
the head: a comment or review whose first line is
`Review (<reviewer>): SHIP at <full head sha>` from a member (OWNER, MEMBER or
COLLABORATOR, a user, not a bot), not a self-review, the grammar
scripts/ci/risk_tier.py reads. The newest verdict naming the head decides, so
a later BLOCK beats an earlier SHIP, and a push needs a new receipt. An
approving review of the head from a call owner in
.github/defaults-call-owners.json other than the author still passes too. The
`needs a call` label alone never passes. The workflow (pull_request_target
only) runs this script and reads the owners file from the base branch, so a
pull request cannot approve itself by editing either.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import time
from collections.abc import Callable, Iterable, Mapping
from dataclasses import dataclass, field
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parents[2]
APP = "cmux-next"
SNAPSHOT = f"schemas/defaults/{APP}.json"
OWNERS = ".github/defaults-call-owners.json"
ACTION_SURFACES = "plans/cmux-next/action-surfaces.json"
SETTINGS_SCHEMA = "schemas/settings/settings-schema.json"
SWIFT_SOURCES = "Packages/macOS/CmuxNext/Sources"
# The settings exporter's inputs, which the source stamp hashes.
SETTINGS_SOURCE_DIR = "Packages/macOS/CmuxNext/Sources/CmuxNextSettings"
SETTINGS_SOURCE_SUFFIXES = (".swift", ".xcstrings")
SETTINGS_EXPORTER_FILES = (
    "Packages/macOS/CmuxNext/Tests/CmuxNextSettingsTests/ManagedPreferencesManifestTests.swift",
    "Packages/macOS/CmuxNext/Tests/CmuxNextSettingsTests/SettingsSchemaExportTests.swift",
)
# Default bindings that step aside in a context (a code editor, a focused terminal): a change to
# one changes what a key does there.
KEY_BINDING_DEFAULTS = "Packages/macOS/CmuxNext/Sources/CmuxNextActions/KeyBindingDefaults.swift"
MARKER = "<!-- cmux:defaults-guard -->"
REGENERATE = "python3 scripts/ci/defaults_guard.py snapshot"
# The guard's own files: changing how defaults are read or who approves is a call too.
GUARD_FILES = (
    "scripts/ci/defaults_guard.py",
    OWNERS,
    ".github/workflows/cmux-next-defaults-guard.yml",
    ".github/workflows/cmux-next-defaults-guard-review.yml",
)

# AppKit's function-key characters, as the catalog export writes them.
FUNCTION_KEYS = {
    0xF700: "up", 0xF701: "down", 0xF702: "left", 0xF703: "right",
    0xF728: "forwarddelete", 0xF729: "home", 0xF72B: "end",
    0xF72C: "pageup", 0xF72D: "pagedown",
}
NAMED_KEYS = {"\t": "tab", "\r": "return", "\n": "return", " ": "space", "\x1b": "escape", "\x7f": "delete", "\x08": "delete"}
MODIFIER_ORDER = ("ctrl", "opt", "shift", "cmd")

KEYBIND_RE = re.compile(r'"keybind\s*=\s*([^"=]+?)\s*=\s*([^"]*)"')
YIELDS_RE = re.compile(r"static\s+let\s+(yieldsTo\w+)\s*:\s*Set<ActionID>\s*=\s*\[(.*?)\]", re.S)
FLAG_RE = re.compile(r"\bstatic\s+(?:let|var)\s+(\w*Enabled)\s*(?::\s*Bool\s*)?=\s*(true|false)\b")
# An independent review's verdict on the exact head, on a comment's or review's first line:
# "Review (subagent, correctness first): SHIP at <full head sha>". Same grammar as
# scripts/ci/risk_tier.py RECEIPT (and next_autoland, merge_audit).
RECEIPT = re.compile(r"^\W*(?:independent\s+)?review\s*\(([^)\n]*)\)\s*:\W*(ship|block|fix|not ship|hold)(?![\w-])",
                     re.I)
TRUSTED = ("OWNER", "MEMBER", "COLLABORATOR")
# Default values that read as "off": a new setting with one of them changes nothing for anyone.
OFF_WORDS = ("off", "never", "none", "disabled", "")


# MARK: Reading a tree


class Tree:
    """Files of one commit (git, read as data) or of a directory (a checkout of one)."""

    @staticmethod
    def named(value: str) -> "Tree":
        """A directory when `value` is one, else a git commit of this repository."""
        path = Path(value)
        return Tree(None, path.resolve()) if path.is_dir() else Tree(value)

    def __init__(self, ref: str | None, root: Path = ROOT) -> None:
        self.ref = ref
        self.root = root

    def read(self, path: str) -> str | None:
        if self.ref is None:
            file = self.root / path
            self.refuse_links(file)
            return file.read_text(encoding="utf-8") if file.is_file() else None
        result = subprocess.run(["git", "-C", str(self.root), "show", f"{self.ref}:{path}"],
                                capture_output=True, text=True)
        return result.stdout if result.returncode == 0 else None

    def read_bytes(self, paths: list[str]) -> dict[str, bytes]:
        """The exact bytes of each file (a link is refused; a missing file raises)."""
        if self.ref is None:
            found = {}
            for path in paths:
                file = self.root / path
                self.refuse_links(file)
                if not file.is_file():
                    raise SystemExit(f"DEFAULTS tree: {path} is missing")
                found[path] = file.read_bytes()
            return found
        listing = self.blobs(paths)
        missing = [path for path in paths if path not in listing]
        if missing:
            raise SystemExit(f"DEFAULTS tree: {', '.join(missing)} is not in {self.ref}")
        request = "".join(f"{listing[path]}\n" for path in paths).encode()
        result = subprocess.run(["git", "-C", str(self.root), "cat-file", "--batch"],
                                input=request, capture_output=True, check=True)
        found, out, offset = {}, result.stdout, 0
        for path in paths:
            header_end = out.index(b"\n", offset)
            header = out[offset:header_end].split()
            if len(header) != 3 or header[1] != b"blob":
                raise SystemExit(f"DEFAULTS tree: {path} is not readable in {self.ref} ({header!r})")
            size = int(header[2])
            found[path] = out[header_end + 1:header_end + 1 + size]
            offset = header_end + 1 + size + 1
        return found

    def blobs(self, paths: Iterable[str]) -> dict[str, str]:
        """Object id of every blob at or under `paths` in the commit (a link is refused)."""
        result = subprocess.run(["git", "-C", str(self.root), "ls-tree", "-r", "-z", "--full-tree", self.ref, "--", *paths],
                                capture_output=True, check=True)
        listing = {}
        for entry in result.stdout.split(b"\0"):
            if not entry:
                continue
            meta, _, name = entry.partition(b"\t")
            mode, kind, oid = meta.decode().split()
            path = name.decode("utf-8")
            if mode == "120000":
                raise SystemExit(f"DEFAULTS tree: {path} is a symbolic link; the defaults guard reads no links")
            if kind == "blob":
                listing[path] = oid
        return listing

    def files(self, path: str) -> list[str]:
        """Repository-relative paths of the regular files under `path` (a link is refused)."""
        if self.ref is not None:
            return sorted(self.blobs([path]))
        top = self.root / path
        if not top.exists():
            return []
        self.refuse_links(top)
        found = []
        for file in top.rglob("*"):
            self.refuse_links(file)
            if file.is_file():
                found.append(file.relative_to(self.root).as_posix())
        return found

    def refuse_links(self, file: Path) -> None:
        """A checked-out head is data: a link in it could read the runner's own files."""
        part = file
        while part != self.root and self.root in part.parents:
            if part.is_symlink():
                raise SystemExit(f"DEFAULTS tree: {part.relative_to(self.root)} is a symbolic link; the defaults guard reads no links")
            part = part.parent

    def grep(self, pattern: str, path: str) -> list[tuple[str, str]]:
        """(file, line) for every line under `path` matching the extended regex `pattern`."""
        if self.ref is None:
            if not (self.root / path).exists():
                return []
            self.refuse_links(self.root / path)
            for found in (self.root / path).rglob("*"):
                self.refuse_links(found)
            args = ["git", "-C", str(self.root), "grep", "--no-index", "-I", "-E", "-e", pattern, "--", path]
        else:
            args = ["git", "-C", str(self.root), "grep", "-I", "-E", "-e", pattern, self.ref, "--", path]
        result = subprocess.run(args, capture_output=True, text=True)
        if result.returncode not in (0, 1):
            raise SystemExit(f"git grep failed: {result.stderr.strip()}")
        prefix = f"{self.ref}:" if self.ref else ""
        lines = []
        for raw in result.stdout.splitlines():
            raw = raw.removeprefix(prefix)
            name, _, line = raw.partition(":")
            lines.append((name, line))
        return lines


# MARK: The defaults


def key_name(key: str) -> str:
    if len(key) == 1 and ord(key) in FUNCTION_KEYS:
        return FUNCTION_KEYS[ord(key)]
    if len(key) == 1 and 0xF704 <= ord(key) <= 0xF726:
        return f"f{ord(key) - 0xF703}"
    if key in NAMED_KEYS:
        return NAMED_KEYS[key]
    if len(key) == 1 and not key.isprintable():
        return f"U+{ord(key):04X}"
    return key.lower()


def stroke(value: Mapping[str, object]) -> str:
    modifiers = [str(m) for m in value.get("modifiers") or []]
    ordered = [m for m in MODIFIER_ORDER if m in modifiers] + sorted(m for m in modifiers if m not in MODIFIER_ORDER)
    return "+".join([*ordered, key_name(str(value.get("key", "")))])


def binding(keys: Iterable[Mapping[str, object]], when: object = None) -> str:
    text = " ".join(stroke(k) for k in keys)
    return f"{text} when {when}" if when else text


def action_keys(action: Mapping[str, object]) -> list[str]:
    keys: set[str] = set()
    shortcut = action.get("default_shortcut")
    if isinstance(shortcut, dict):
        keys.add(binding([shortcut]))
    chord = action.get("default_chord")
    if isinstance(chord, dict):
        keys.add(binding(chord.get("keys") or [chord]))
    elif isinstance(chord, list):
        keys.add(binding(chord))
    for alias in action.get("default_aliases") or []:
        if isinstance(alias, dict):
            keys.add(binding(alias.get("keys") or [], alias.get("when")))
    return sorted(keys)


def defaults(tree: Tree) -> dict[str, object]:
    """Every default of the app in `tree`, by stable id."""
    found: dict[str, object] = {}
    surfaces = tree.read(ACTION_SURFACES)
    if surfaces is None:
        raise SystemExit(f"{ACTION_SURFACES} is missing")
    for action in json.loads(surfaces)["actions"]:
        keys = action_keys(action)
        if keys:
            found[f"key.{action['id']}"] = keys
    schema = tree.read(SETTINGS_SCHEMA)
    if schema is None:
        raise SystemExit(f"{SETTINGS_SCHEMA} is missing")
    for row in json.loads(schema)["rows"]:
        found[f"setting.{row['key']}"] = row.get("default")
    for _, line in tree.grep(r'"keybind *= *[^"]+=', SWIFT_SOURCES):
        for trigger, action in KEYBIND_RE.findall(line):
            # An interpolated line (`\(trigger)`) is built at run time from the user's config, not a default.
            if "\\(" not in trigger + action:
                found[f"ghostty.{trigger.strip()}"] = action.strip()
    for name, block in YIELDS_RE.findall(tree.read(KEY_BINDING_DEFAULTS) or ""):
        found[f"steps-aside.{name}"] = sorted(re.findall(r'"([^"]+)"', block))
    for name, line in tree.grep(r"static +(let|var) +[A-Za-z0-9_]*Enabled *(: *Bool *)?= *(true|false)", SWIFT_SOURCES):
        for flag, value in FLAG_RE.findall(line):
            # The file's path under the sources keeps two `isEnabled` flags apart; a second one in
            # the same file gets a number, in file order.
            base = f"flag.{name.removeprefix(SWIFT_SOURCES + '/').removesuffix('.swift')}.{flag}"
            key, n = base, 2
            while key in found:
                key, n = f"{base}#{n}", n + 1
            found[key] = value == "true"
    return dict(sorted(found.items()))


def render_snapshot(values: Mapping[str, object]) -> str:
    lines = [f"    {json.dumps(key)}: {json.dumps(value, ensure_ascii=False, sort_keys=True)}" for key, value in values.items()]
    header = {"app": APP, "regenerate": REGENERATE, "version": 1}
    head = ",\n".join(f"  {json.dumps(k)}: {json.dumps(v)}" for k, v in header.items())
    return "{\n" + head + ',\n  "defaults": {\n' + ",\n".join(lines) + "\n  }\n}\n"


def snapshot_of(tree: Tree) -> dict[str, object] | None:
    text = tree.read(SNAPSHOT)
    return None if text is None else dict(json.loads(text)["defaults"])


# MARK: Changes


def plain(text: str) -> str:
    """Text from the head on one line: a newline cannot start a workflow command or a Markdown block."""
    return text.replace("\r", "\\r").replace("\n", "\\n")


def command_text(text: str) -> str:
    """A workflow command's message, encoded as the runner expects."""
    return plain(text).replace("%", "%25")


def code(text: str) -> str:
    """Head text as a Markdown code span: no formatting, links or mentions."""
    text = plain(text)
    # The fence is longer than any run of backticks in the text, so nothing inside can close it.
    longest = max((len(run) for run in re.findall(r"`+", text)), default=0)
    fence = "`" * (longest + 1)
    return f"{fence} {text} {fence}" if longest else f"`{text}`"


@dataclass(frozen=True)
class Change:
    id: str
    old: object
    new: object

    @staticmethod
    def show(value: object) -> str:
        if value is None:
            return "(none)"
        if isinstance(value, list):
            return ", ".join(str(v) for v in value) if value else "(none)"
        return json.dumps(value, ensure_ascii=False)

    @property
    def detail(self) -> str:
        if isinstance(self.old, list) or isinstance(self.new, list):
            old = set(self.old if isinstance(self.old, list) else [])
            new = set(self.new if isinstance(self.new, list) else [])
            parts = [f"+ {k}" for k in sorted(new - old)] + [f"- {k}" for k in sorted(old - new)]
            return "; ".join(parts)
        return f"{self.show(self.old)} -> {self.show(self.new)}"

    @property
    def line(self) -> str:
        return plain(f"DEFAULTS {self.id}: {self.detail}")


def changes(old: Mapping[str, object], new: Mapping[str, object]) -> list[Change]:
    found = []
    for key in sorted(set(old) | set(new)):
        if old.get(key) != new.get(key) or (key in old) != (key in new):
            found.append(Change(key, old.get(key), new.get(key)))
    return found


def is_off(value: object) -> bool:
    return value is None or value is False or value == [] or value == {} or \
        (isinstance(value, str) and value.lower() in OFF_WORDS)


def exempt(found: list[Change], before: Mapping[str, object]) -> list[Change]:
    """The settings the head adds with an off default: what everyone got before the setting existed."""
    return [c for c in found if c.id.startswith("setting.") and c.id not in before and is_off(c.new)]


def guard_changes(base: Tree, head: Tree) -> list[Change]:
    found = []
    for path in GUARD_FILES:
        before, after = base.read(path), head.read(path)
        if before != after:
            state = "added" if before is None else "removed" if after is None else "edited"
            found.append(Change(f"guard.{path}", None, state))
    return found


# MARK: Approval


@dataclass
class Approval:
    owners: list[str]
    author: str
    head: str
    approvers: list[str] = field(default_factory=list)
    stale: list[str] = field(default_factory=list)
    shipped: str | None = None  # the reviewer whose SHIP receipt is the newest verdict on the head
    blocked: str | None = None  # the reviewer whose BLOCK receipt is

    @property
    def eligible(self) -> list[str]:
        return [o for o in self.owners if o.lower() != self.author.lower()]

    @property
    def approved(self) -> bool:
        return bool(self.approvers) or self.shipped is not None


def receipt_verdict(pull: Mapping[str, object], head: str) -> tuple[str, str] | None:
    """("ship" or "block", reviewer) of the newest receipt naming the full head sha on the first line
    of a trusted comment or review body; a self-review never counts and a BLOCK wins a tie."""
    found = []
    items = [(c, c.get("createdAt")) for c in (pull.get("comments") or {}).get("nodes") or []]
    items += [(r, r.get("submittedAt")) for r in (pull.get("reviews") or {}).get("nodes") or []]
    for item, at in items:
        author = item.get("author") or {}
        if author.get("__typename") != "User" or item.get("authorAssociation") not in TRUSTED:
            continue
        first = next((line for line in str(item.get("body") or "").splitlines() if line.strip()), "")
        line = RECEIPT.match(first)
        if head and line and "self" not in line.group(1).lower() and head in first:
            verdict = "ship" if line.group(2).lower() == "ship" else "block"
            found.append((str(at or ""), verdict == "block", verdict, f"review ({line.group(1).strip()})"))
    if not found:
        return None
    _, _, verdict, who = max(found)
    return verdict, who


def owners_for(text: str | None) -> list[str]:
    if text is None:
        return []
    return [str(o) for o in json.loads(text).get(APP, [])]


def approval(owners: list[str], pull: Mapping[str, object]) -> Approval:
    """Who approved the head: each reviewer's latest decisive review counts."""
    author = str((pull.get("author") or {}).get("login") or "")
    head = str(pull.get("headRefOid") or "")
    result = Approval(owners=owners, author=author, head=head)
    latest: dict[str, Mapping[str, object]] = {}
    for review in (pull.get("reviews") or {}).get("nodes") or []:
        login = str((review.get("author") or {}).get("login") or "")
        if review.get("state") in ("APPROVED", "CHANGES_REQUESTED", "DISMISSED") and login:
            latest[login.lower()] = review
    for owner in result.eligible:
        review = latest.get(owner.lower())
        if not review or review.get("state") != "APPROVED":
            continue
        if str((review.get("commit") or {}).get("oid") or "") == head:
            result.approvers.append(owner)
        else:
            result.stale.append(owner)
    receipt = receipt_verdict(pull, head)
    if receipt:
        if receipt[0] == "ship":
            result.shipped = receipt[1]
        else:
            result.blocked = receipt[1]
    return result


PULL_QUERY = """
query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      author { login } headRefOid merged mergeCommit { oid }
      reviews(last: 100) { nodes { author { login __typename } authorAssociation state body submittedAt commit { oid } } }
      comments(last: 100) { nodes { databaseId body createdAt authorAssociation author { login __typename } } }
    }
  }
}
"""


def gh(args: list[str]) -> str:
    result = subprocess.run(["gh", *args], capture_output=True, text=True)
    if result.returncode != 0:
        raise SystemExit(f"gh {' '.join(args[:3])} failed: {result.stderr.strip()}")
    return result.stdout


def fetch_pull(repo: str, number: int) -> dict:
    owner, name = repo.split("/", 1)
    out = gh(["api", "graphql", "-f", f"query={PULL_QUERY}", "-f", f"owner={owner}", "-f", f"name={name}",
              "-F", f"number={number}"])
    return json.loads(out)["data"]["repository"]["pullRequest"]


# MARK: Report


def signed(verdict: Approval) -> str:
    who = [f"@{a}" for a in verdict.approvers] + ([f"`{plain(verdict.shipped)}`"] if verdict.shipped else [])
    return ", ".join(who)


def comment_body(found: list[Change], verdict: Approval | None, head: str, merged: str | None = None,
                 free: list[Change] | None = None) -> str:
    lines = [MARKER, "## Default changes"]
    if not found:
        lines.append(f"No defaults change at `{head[:12]}`.")
        return "\n".join(lines) + "\n"
    lines.append(f"This pull request changes {len(found)} default{'s' if len(found) != 1 else ''} at `{head[:12]}` "
                 "(what everyone gets without configuring anything):")
    lines.append("")
    free = free or []
    lines += [f"- {code(c.id)}: {code(c.detail)}" + (" (a new setting, off by default: passes on its own)" if c in free else "")
              for c in found]
    lines.append("")
    if all(c in free for c in found):
        lines.append("Every change is a new setting that defaults to off, the behavior from before it existed.")
    elif verdict is not None:
        if verdict.approved:
            lines.append(f"Signed off on this commit by {signed(verdict)}.")
        else:
            who = " or ".join(f"@{o}" for o in verdict.eligible) or "(no eligible call owner)"
            if verdict.blocked:
                lines.append(f"The newest verdict on this commit is a BLOCK from `{plain(verdict.blocked)}`.")
            lines.append(f"**Needs a review.** It passes with an independent review receipt on this commit: a comment "
                         f"or review whose first line is `Review (<reviewer>): SHIP at {head}`, from a member, not a "
                         "self-review (the newest verdict naming the head decides; a later BLOCK beats an earlier "
                         f"SHIP), or with an approving review on this commit from {who} (the call owners in `{OWNERS}`, "
                         "never the author). A receipt posted as a review re-runs this check; after a plain comment, "
                         "re-run it. The `needs a call` label alone does not pass, and a new push needs a new receipt.")
            if verdict.stale:
                lines.append(f"Earlier approvals on an older commit: {', '.join('@' + s for s in verdict.stale)}.")
    if merged:
        lines += ["", f"**Merge receipt:** merged as `{merged[:12]}` with these defaults changed"
                  + (f", signed off by {signed(verdict)}." if verdict and verdict.approved
                     else ", WITHOUT a SHIP receipt or an approving call owner review on its head.")]
    lines += ["", f"Regenerate the snapshot with `{REGENERATE}`."]
    return "\n".join(lines) + "\n"


def annotate(found: list[Change]) -> None:
    for c in found:
        print(f"::warning title=Default changed::{command_text(c.line)}")


def summary(text: str) -> None:
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if path:
        with open(path, "a", encoding="utf-8") as handle:
            handle.write(text)


def post_comment(repo: str, number: int, pull: Mapping[str, object], body: str, found: list[Change]) -> None:
    existing = None
    for comment in (pull.get("comments") or {}).get("nodes") or []:
        if MARKER in str(comment.get("body") or "") and str((comment.get("author") or {}).get("login") or "") == "github-actions":
            existing = comment.get("databaseId")
    if existing is None and not found:
        return  # nothing changed and nothing said before: no comment
    if existing is None:
        gh(["api", f"repos/{repo}/issues/{number}/comments", "-f", f"body={body}"])
    else:
        gh(["api", "-X", "PATCH", f"repos/{repo}/issues/comments/{existing}", "-f", f"body={body}"])


# MARK: Commands


def command_snapshot(args: argparse.Namespace) -> int:
    path = ROOT / SNAPSHOT
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(render_snapshot(defaults(Tree(None))), encoding="utf-8")
    print(f"wrote {SNAPSHOT}")
    return 0


def freshness(tree: Tree) -> list[str]:
    """Problems with the committed snapshot of `tree` (empty when it matches the sources)."""
    committed = tree.read(SNAPSHOT)
    if committed is None:
        return [f"DEFAULTS snapshot: {SNAPSHOT} is missing; run `{REGENERATE}`"]
    if committed != render_snapshot(defaults(tree)):
        stale = changes(dict(json.loads(committed)["defaults"]), defaults(tree))
        return [f"DEFAULTS snapshot: {SNAPSHOT} does not match the sources; run `{REGENERATE}` and commit it"] + \
            [f"  {c.line}" for c in stale]
    return []


def settings_source_stamp(tree: Tree) -> str:
    """The settings exports' source stamp: one `sha256  path` entry per exporter input
    (lowercase hex of the file's bytes, two spaces, the repository-relative path) in UTF-8 path
    order, with a blank line between entries and a newline at the end. It is derived for a
    commit, never committed."""
    paths = list(SETTINGS_EXPORTER_FILES) + [
        path for path in tree.files(SETTINGS_SOURCE_DIR) if PurePosixPath(path).suffix in SETTINGS_SOURCE_SUFFIXES]
    paths.sort(key=lambda path: path.encode("utf-8"))
    contents = tree.read_bytes(paths)
    return "\n\n".join(f"{hashlib.sha256(contents[path]).hexdigest()}  {path}" for path in paths) + "\n"


def command_check_fresh(args: argparse.Namespace) -> int:
    tree = Tree.named(args.ref) if args.ref else Tree(None)
    problems = freshness(tree)
    for problem in problems:
        print(problem)
    return 1 if problems else 0


def command_source_stamp(args: argparse.Namespace) -> int:
    """The stamp the settings sources of a commit give. Base autofix compares the stamp of the commit
    its exports were made at with the tip's: equal means the exports' inputs did not move."""
    sys.stdout.write(settings_source_stamp(Tree.named(args.ref) if args.ref else Tree(None)))
    return 0


def command_check(args: argparse.Namespace) -> int:
    base, head = Tree.named(args.base), Tree.named(args.head)
    head_sha = args.head_sha or args.head
    # Both sides are judged by their sources and exports, never by a committed
    # snapshot: the snapshot is bot-only (#21946), so a pull request does not
    # commit it, and a hand-edited copy could hide a change.
    problems: list[str] = []
    before = defaults(base)
    after = defaults(head)
    found = changes(before, after) + guard_changes(base, head)
    free = exempt(found, before)
    trusted = Tree(None)  # the base checkout the workflow runs from
    owners = owners_for(trusted.read(OWNERS))
    pull = None
    if args.pull_json:
        pull = json.loads(Path(args.pull_json).read_text(encoding="utf-8"))
    elif args.pr and args.repo:
        pull = fetch_pull(args.repo, args.pr)
        # Right after a push GitHub can still report the previous head for a few seconds.
        for _ in range(4):
            if str(pull.get("headRefOid") or "") == head_sha:
                break
            time.sleep(5)
            pull = fetch_pull(args.repo, args.pr)
    verdict = approval(owners, pull) if pull is not None else None
    if pull is not None and verdict is not None and verdict.head != head_sha:
        problems.append(f"DEFAULTS head: the pull request's head is {verdict.head[:12]}, not {head_sha[:12]}; re-run on the new head")
    merged = str((pull.get("mergeCommit") or {}).get("oid") or "") if pull and pull.get("merged") else None
    body = comment_body(found, verdict, head_sha, merged, free)
    annotate(found)
    for problem in problems:
        print(f"::error title=Defaults snapshot::{command_text(problem)}" if not problem.startswith("  ") else plain(problem))
    for c in found:
        print(c.line)
    summary(body)
    if args.comment and pull is not None:
        try:
            post_comment(args.repo, args.pr, pull, body, found)
        except SystemExit as error:  # a fork's review event has a read-only token: the verdict stands
            print(f"::warning title=Defaults comment not posted::{error}")
    if problems:
        return 1
    needed = [c for c in found if c not in free]
    if needed and not (verdict and verdict.approved):
        who = " or ".join(verdict.eligible) if verdict else "a call owner"
        print(f"::error title=Default changes need a review::{len(needed)} default(s) changed; needs a comment or review "
              f"whose first line is `Review (<reviewer>): SHIP at {head_sha}` from a member (not a self-review), "
              f"or an approving review on {head_sha[:12]} from {who}")
        return 1
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("snapshot", help="regenerate the golden snapshot from the sources").set_defaults(run=command_snapshot)
    fresh = sub.add_parser("check-fresh", help="the committed snapshot matches the sources")
    fresh.add_argument("--ref", help="a commit to check instead of the working tree")
    fresh.set_defaults(run=command_check_fresh)
    source = sub.add_parser("source-stamp", help="print the settings export stamp the CmuxNextSettings sources give")
    source.add_argument("--ref", help="a commit to read instead of the working tree")
    source.set_defaults(run=command_source_stamp)
    check = sub.add_parser("check", help="list changed defaults between two commits and judge the approval")
    check.add_argument("--base", required=True, help="the merge base: a commit, or a directory checked out at it")
    check.add_argument("--head", required=True, help="the head: a commit, or a directory checked out at it")
    check.add_argument("--head-sha", help="the head commit when --head is a directory")
    check.add_argument("--repo")
    check.add_argument("--pr", type=int)
    check.add_argument("--pull-json", help="the pull request as fetch_pull returns it (tests)")
    check.add_argument("--comment", action="store_true", help="post or update the sticky comment")
    check.set_defaults(run=command_check)
    args = parser.parse_args(argv)
    return args.run(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
