#!/usr/bin/env python3
"""Grade a feat-cmux-next pull request low, normal or high risk by what it changes, and say what
it still needs before merge.

The policy, and the regression audit behind every rule, is docs/ci/risk-tiers.md. In short:

  low     docs, copy, generated files, tests, tooling. Merges on green; post-merge checks catch the rest.
  normal  everything else, which is most cmux NEXT UI and logic: agent review and the relevant
          checks, then auto-merge. Nothing here waits for a person.
  high    auth and credentials, socket and relay access policy (with peer and code-signature
          trust), stored-data migrations, release, signing, notarization and the updater, the
          risk gate itself, code that adds a delete of user data, and a workflow that adds a
          pull_request_target or workflow_run trigger. Read for
          a review verdict on the head: an independent review's `Review (<reviewer>): SHIP at <full
          head sha>` line in the description or leading a comment, an approving review on the head
          commit, or `risk:human-ok` from a maintainer. A BLOCK or FIX on the head, or no verdict yet,
          is a warning: the lander refuses a BLOCK, and risk-tier.yml turns red only on a takeback.

Size is not a rule: in the audit, the changes that broke things were as often small as large.
Separately from the tier, a pull request that takes back what another pull request merged in the
last RECENT_DAYS (a stale-base squash) is held until it says so on a `Takes back #N: <why>` line,
or merges its base and stops taking it back. An agent clears that; no person is needed.

Usage:
  risk_tier.py classify --files FILE [--patches FILE] [--json]
  risk_tier.py evidence --tier TIER [--human-ok] [--blocked]
  risk_tier.py pr --repo OWNER/REPO --number N [--repo-dir DIR] [--github-output FILE] [--summary FILE]
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import re
import subprocess
import sys
import time
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path
from urllib.parse import quote

TIERS = ("low", "normal", "high")
LABELS = {tier: f"risk:{tier}" for tier in TIERS}
# Labels an older version of this check set; the label step removes them.
OLD_LABELS = ("risk:medium",)
HUMAN_OK_LABEL = "risk:human-ok"
# The earlier name for the same maintainer sign-off; still honored.
WAIVED_LABEL = "risk:waived"
# An independent review's verdict on the exact head, on a comment's first line: "Review (subagent, correctness
# first): SHIP at <full head sha>", the form next_autoland.py and merge_audit.py read. A self-review doesn't
# count, and the newest verdict naming the head decides, so a later BLOCK beats an earlier SHIP. The same line
# also counts anywhere in the description (outside <!-- comments -->), where it ranks below every comment.
RECEIPT = re.compile(r"^\W*(?:independent\s+)?review\s*\(([^)\n]*)\)\s*:\W*(ship|block|fix|not ship|hold)(?![\w-])",
                     re.I)
TRUSTED = ("OWNER", "MEMBER", "COLLABORATOR")
NEXT = "Packages/macOS/CmuxNext/Sources/"

# Ordered: the first matching rule wins, so the high paths sit above the broad low ones.
# Each rule is (tier, reason, patterns). Patterns are fnmatch globs on the repo path.
# A pattern starting with "re:" is a regular expression searched in the path.
RELEASE_WORDS = (
    r"re:(^|/)(scripts|\.github/workflows)/(.*/)?([^/]*[-_])?"
    r"(sign(ing)?|codesign|notari[sz]\w*|appcast|sparkle|release|publish|deploy|nightly|promote|rollback)([-_.][^/]*)?$"
)
RULES: tuple[tuple[str, str, tuple[str, ...]], ...] = (
    # Prose, copy and logs stay low even inside a high directory (a relay's LICENSE, the updater's
    # strings). CODEOWNERS is not among them.
    ("low", "docs or copy", (
        "*.md", "*.mdx", "LICENSE*", "*/LICENSE*", "*.xcstrings", "*.strings", "docs/*", "release-notes/*", "*.log",
    )),
    # Lockfiles are the package graph: never high (an auth service's package-lock), never low (a
    # swapped dependency still gets agent review).
    ("normal", "package graph", ("*.lock", "*-lock.json")),
    ("low", "test", (
        "*/Tests/*", "*/tests/*", "tests/*", "tests_v2/*", "*/test/*", "*_test.*", "*_tests.*",
        "*/tests.rs", "*/test_*.py", "*.test.*", "*Tests.swift", "*/fixtures/*", "*/__snapshots__/*",
    )),
    # Scripts that only mention a release: notes, benchmarks, end-to-end probes, compile checks.
    ("low", "CI and tooling", (
        r"re:^scripts/.*(release[-_]notes|[-_]perf[-_]|[-_]e2e\.|release-compile|derived-data)",
    )),
    # Named like release work, but not shipping: PR media publishing, and the updater's views.
    ("normal", "app code, UI or CI", (
        "scripts/cmux-next/media/*", NEXT + "CmuxNextUpdater/*View.swift", NEXT + "CmuxNextUpdater/Share/*",
    )),
    # Who may sign in, and where tokens live. A bug here leaks or loses credentials, and a revert
    # doesn't un-leak a token.
    ("high", "auth or credentials", (
        "Packages/Shared/CmuxAuthRuntime/*", "Packages/Shared/CMUXAuthCore/*", "*/WebAuth/*",
        "*/Keychain/*", "*Keychain*Store*", "*TokenStore*", "web/services/auth/*", "workers/*/src/auth/*",
        "ios/CmuxiOS/Sources/CmuxiOSAuth/*", "*.entitlements", "web/proxy.ts", "web/middleware.ts",
        # A path segment or file-name word: dashboard-auth.ts, auth/, oauth_callback.rs, sign-in/.
        r"re:(^|/|[-_.])(auth|oauth|sign[-_]?in|login)([-_./]|$)",
    )),
    # Who may drive the app over its socket, and what a relay may forward. The app has no relay
    # policy yet (skills/cmux-socket-policy), so every relay path must stay default-deny.
    ("high", "socket or relay access policy", (
        NEXT + "CmuxNextControl/ControlAuthorizer.swift", NEXT + "CmuxNextControl/ControlPeer*.swift",
        NEXT + "CmuxNextControl/CheckedAccess.swift", NEXT + "CmuxNextControl/ControlSocketPath.swift",
        NEXT + "CmuxNextWakeups/UnixSocketPeer.swift", "*/CmuxCuaHelperCore/PeerInspector.swift",
        "cmux-tui/crates/*relay*/*", "cmux-tui/relays/*", "cmux-tui/crates/cmux-tui-core/src/server/remote_relay/*",
        "services/iroh-relay-minter/*", "web/services/relay/*", "daemon/remote/cmd/cmuxd-remote/*peer*",
        r"re:(?i)relay[-_]?(command[-_]?)?polic", r"re:(?i)(socket|control)[-_]?(access|auth)",
    )),
    # Who answers or connects on a local socket or XPC service, and which code may run, decided by
    # the peer's uid, executable or code signature: the Chief's acpmux peer check and its
    # kernel-signature rule for a moved acpmux (code_signature.rs), the app's acpmux server peer
    # check, cmux-link's caller and containing-app checks, the Computer Use helper's admission rule,
    # state and control pipe (where the app's admission values arrive), host check and the two
    # socket servers that call them, the app's check of the helper on that socket, the requirement
    # or cdhash, the acpmux daemon and executable and the per-launch secret the app gives the helper
    # for acpmux bridges, which acpmux executable the app runs and trusts (its team-signature
    # refusal, and the DEBUG override), the requirement of the helper the app or acpmux may
    # launch (Swift, Rust and shell copies) and the check of its staged copy, the root server
    # helper's XPC requirements (its clients', and the app's of it), and the signature checks of a
    # downloaded browser runtime. A wrong time or anchor here lets another process take the socket
    # (#29072 changed which time a signing chain is valid at and graded normal).
    ("high", "peer identity or code-signature trust", (
        "Native/OptChat/optchat-chief/src/acpmux_peer.rs", NEXT + "CmuxNextAgentPane/AcpmuxServerPeer.swift",
        "cmux-tui/crates/cmux-link/src/caller.rs", "cmux-tui/crates/cmux-link/src/caller_macos.rs",
        "cmux-tui/crates/cmux-link/src/app_caller.rs", "*/CmuxCuaHelperCore/HostVerifier.swift",
        NEXT + "CmuxNextAgentActivity/CuaHelperIdentity.swift", "*/CmuxCuaHelperCore/Admission.swift",
        "*/CmuxCuaHelperCore/AdmissionState.swift", "*/CmuxCuaHelperCore/HelperController.swift",
        "*/CmuxCuaHelperCore/HelperSocketServer.swift", "*/CmuxCuaHelperCore/HostConsentServer.swift",
        NEXT + "CmuxNextComputerUse/ComputerUseHelperV2+Secret.swift", NEXT + "CmuxNextApp/AgentTabs+PaneSource.swift",
        NEXT + "CmuxNextAgentPane/AcpmuxEnvironment+Resolve.swift",
        NEXT + "CmuxNextAgentPane/AcpmuxEnvironment+DebugOverride.swift",
        "cmux-tui/crates/acpmux/src/agent_tools/cua_helper.rs", "scripts/cmux-cua-helper-trust.sh",
        NEXT + "CmuxNextComputerUse/ComputerUseHelperStaging.swift",
        NEXT + "CmuxNextComputerUse/ComputerUseHelperV2HostLink.swift",
        NEXT + "CmuxNextComputerUse/ComputerUseHelperV2+Admission.swift",
        NEXT + "CmuxNextServerHelper/ServerHelperListener.swift", NEXT + "CmuxNextServerHelper/ServerHelperProtocol.swift",
        NEXT + "CmuxNextApp/Server/ServerHelperClient.swift",
        # A file named for a code-signature check: code_signature.rs, *CodeSignatureChecker.swift.
        r"re:(?i)(^|/)[^/]*(code[-_]?signature|signature[-_]?check)[^/]*\.(rs|swift|go)$",
    )),
    # What an agent pane's web page may make the host do or read: the page ops (AgentPageOps), the
    # _acpmux methods and params it may relay, the frame check, the gesture rule (the tickets, which
    # methods a click's ticket redeems, and the decision that spends one), the app actions a page may
    # run, the folder policy and the folders a person picks, the relayed-allow proof, the full-access
    # refusal, the Rust mirror, acpmux's guard on non-local connections, and host ops
    # that open their own daemon connection for a page. #22646's chat.asks.pending graded normal here
    # and reached a peer daemon until review caught it. A new op edits AgentPageProvider.swift's list.
    # Pane UI stays normal.
    ("high", "agent pane host op or allowlist", (
        NEXT + "CmuxNextAgentPane/AgentPageProvider.swift", NEXT + "CmuxNextAgentPane/AcpmuxPaneMethods*.swift",
        NEXT + "CmuxNextAgentPane/AgentPaneEnvironmentRequest.swift",
        NEXT + "CmuxNextAgentPane/AgentPaneReplyRequest.swift",
        NEXT + "CmuxNextAgentPane/AgentPaneTransport+Check.swift", NEXT + "CmuxNextAgentPane/AcpmuxPathPolicy.swift",
        NEXT + "CmuxNextAgentPane/AgentPanePendingAsks.swift", NEXT + "CmuxNextAgentPane/AgentPaneTransport+Frames.swift",
        NEXT + "CmuxNextAgentPane/AgentPaneGestureIntent.swift",
        NEXT + "CmuxNextAgentPane/AgentPaneUserGestures.swift", NEXT + "CmuxNextAgentPane/AgentPaneModel+Actions.swift",
        NEXT + "CmuxNextAgentPane/AgentPaneTransport+RelayedAllow.swift",
        NEXT + "CmuxNextAgentPane/AgentPaneTransport+PickedFolder.swift",
        NEXT + "CmuxNextAgentPane/AgentPaneTransport+FullAccess.swift",
        "cmux-tui/crates/cmux-agent-pane-policy/*", "cmux-tui/crates/acpmux/src/server/remote_guard*",
    )),
    # Stored data other builds read back: a bad migration loses user data on every machine that
    # runs it, and a revert doesn't bring the data back.
    ("high", "stored-data migration", (
        "migrations/*", "*/migrations/*", "*/drizzle/*", "*/migrate/*", "*[Mm]igrat*.swift", "*[Mm]igrat*.rs",
        "*[Mm]igrat*.ts", "web/convex/schema*", "backend/db/schema*",
    )),
    # The update channel and preference values: which ring of the existing signed feeds to follow
    # (UpdateRing, the `updates.channel` setting), and when to install or notify. Picking a ring reuses
    # feeds the release pipeline already signs, and Sparkle still verifies every download, so it is
    # normal (Leo, 2026-10-21, after #22781). UpdateTrack is not here: it decides whether Sparkle runs
    # at all. Parsing, probing, installing and verifying an update stay high below.
    ("normal", "update channel or preference setting", (
        "Packages/macOS/CmuxUpdater/Sources/CmuxUpdater/UpdateRing.swift",
        NEXT + "CmuxNextUpdater/UpdatePreferences.swift",
    )),
    # Shipping. A broken updater also breaks the safety net every other tier relies on: nightly
    # auto-update is how a fix forward reaches users. CmuxUpdater holds the Sparkle driver, the
    # install code, the feed resolver and the channel switch's signature check.
    ("high", "release, signing, notarization or update path", (
        ".github/workflows/nightly*.yml", RELEASE_WORDS, NEXT + "CmuxNextUpdater/*", "Packages/macOS/CmuxUpdater/*",
        "scripts/ci/lib/*",
    )),
    # The gate grades every other pull request, so a change to it gets a person.
    ("high", "the risk gate itself", (
        ".github/CODEOWNERS", ".github/workflows/risk-tier.yml", ".github/workflows/risk-tier-tests.yml",
        "scripts/ci/risk_tier.py",
        # What refuses a red `risk evidence`: gh-merge-green, and next-autoland's batch lander.
        "scripts/gh-merge-green", "scripts/ci/next_batch.py", ".github/workflows/cmux-next-batch.yml",
    )),
    ("low", "docs, plans or skills", (
        "*.md", "*.mdx", "docs/*", "skills/*", "plans/*", "LICENSE*",
    )),
    ("low", "copy or generated output", (
        "*.xcstrings", "*.strings", "*/Resources/agent-pane/*", "Resources/markdown-viewer/*",
        "*/ci-target-graph.json", "*/generated/*", "*.generated.*", "*.sha256",
        "schemas/settings-export/*", "schemas/settings/settings-schema.json",
    )),
    ("low", "CI and tooling", (
        ".claude/*", ".codex/*", ".agents/*", "tools/*", "biome.json", ".coderabbit.yaml", ".greptile/*",
        "dogfood/*", "Prototypes/*", "KeyboardPinningLab/*", "samples/*", "examples/*",
    )),
)

# Files that stay low under any content: tests and generated output follow their sources.
GENERATED = (
    "*.xcstrings", "*/Resources/agent-pane/*", "Resources/markdown-viewer/*", "*.lock",
    "*/ci-target-graph.json", "*.pbxproj", "*-lock.json", "*/generated/*", "*.generated.*",
    "*.sha256", "schemas/settings-export/*", "schemas/settings/settings-schema.json",
)

# A change kind, read from the lines a pull request adds: a new delete of files or rows. Only in
# product code (not tests, scripts, workflows or docs), where it can reach a user's data.
# An in-memory purge (purge_stream_locked) is not here: it loses nothing a user stored.
DELETES = re.compile(
    r"(\bremoveItem\s*\(\s*at|\bremove_dir_all\s*\(|\bfs::remove_(file|dir)\s*\(|\bshutil\.rmtree\b"
    r"|\brmSync\s*\(|\bfs\.(promises\.)?rm\s*\(|\brimraf\b|\bDROP\s+(TABLE|COLUMN)\b|\bTRUNCATE\s+TABLE\b"
    r"|\bDELETE\s+FROM\b|\.trashItem\s*\(|\bdeleteAll\w*\s*\(|\b(db|tx)\.delete\s*\()")
DELETE_SCOPE_EXCLUDED = ("scripts/*", "*/scripts/*", ".github/*", "tools/*", "dogfood/*", "Prototypes/*",
                         "samples/*", "examples/*", ".claude/*", ".codex/*", ".agents/*", "cmux-tui/bindings/*")

# A change kind, read from the lines a workflow adds: a trigger that runs with the base's secrets
# and a write token on a fork's pull request. A cache or checkout of the fork's code under one is
# how 16c570b576 opened a cache-poisoning path.
PRIVILEGED_TRIGGER = re.compile(r"\b(pull_request_target|workflow_run)\b")
WORKFLOW_FILES = (".github/workflows/*.yml", ".github/workflows/*.yaml", ".github/actions/*")

TAKES_BACK = re.compile(r"^[ \t]*[-*]?[ \t]*\**takes back\**[ \t]+#(\d+)\**[ \t]*:[ \t]*\S", re.I | re.M)


def matches(path: str, pattern: str) -> bool:
    if pattern.startswith("re:"):
        return re.search(pattern[3:], path) is not None
    return fnmatch.fnmatchcase(path, pattern) or (pattern.endswith("/*") and path == pattern[:-2])


def classify_path(path: str) -> tuple[str, str]:
    for tier, reason, patterns in RULES:
        if any(matches(path, p) for p in patterns):
            return tier, reason
    return "normal", "app code, UI or CI"


@dataclass
class Grade:
    tier: str
    reasons: dict[str, list[str]] = field(default_factory=dict)

    def as_json(self) -> dict:
        return {"tier": self.tier, "label": LABELS[self.tier], "reasons": self.reasons}


HUNK = re.compile(r"^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@")
# A Rust test module is test code, like a file under tests/: `#[cfg(test)] mod name { ... }`. Its
# attributes are read on its own line or the lines above; a multi-line attribute ends the search,
# so that module counts as product code. A file that `#[cfg(test)] mod name;` declares is not
# exempt: the same file can also be reached as product code (`#[path]`, an enclosing module).
RUST_ATTRIBUTE = re.compile(r"#\s*\[([^\[\]]*)\]\s*")
# Only these test cfgs, read with whitespace removed: cfg(test), or cfg(all(...)) with a bare `test`
# beside identifiers, not(identifier) and key="simple value". Anything else (any, comments, other
# strings, deeper nesting) counts as product code.
RUST_CFG_ARGUMENT = r'(?:[A-Za-z_]\w*|not\([A-Za-z_]\w*\)|[A-Za-z_]\w*="[\w.+-]*")'
RUST_TEST_CFG = re.compile(rf"cfg\((?:test|all\((?:{RUST_CFG_ARGUMENT},)*test(?:,{RUST_CFG_ARGUMENT})*,?\))\)")
RUST_MOD = re.compile(r"(?:pub\s*(?:\([^)]*\))?\s*)?mod\s+\w+\s*\{")
RUST_RAW_STRING = re.compile(r'(?<![A-Za-z0-9_])[bc]?r(#*)"')
# A char or byte literal: one character, or one escape (`'\''`, `'\x7f'`, `'\u{1F600}'`).
RUST_CHAR = re.compile(r"'(?:\\(?:x[0-9A-Fa-f]{2}|u\{[0-9A-Fa-f_]{1,6}\}|.)|[^\\'\n])'")


class RustBraces:
    """Brace depth over Rust lines fed in order, skipping braces in strings, chars and comments,
    with the depth of open parentheses and brackets beside it."""

    def __init__(self) -> None:
        self.depth = 0
        self.low = 0  # the lowest brace depth the last line fed reached
        self.nest = 0  # open ( and [
        self.comments = 0  # nested /* */ depth
        self.string = False  # inside an ordinary string, where a backslash escapes
        self.raw: str | None = None  # inside a raw string: the '"' plus hashes that end it

    def in_code(self) -> bool:
        return not self.comments and not self.string and self.raw is None

    def feed(self, line: str, floor: int | None = None) -> bool:
        """Read one line. True when a closing brace on it brings the depth to `floor` or below."""
        closed = False
        self.low = self.depth
        i = 0
        while i < len(line):
            if self.comments:
                if line.startswith(("*/", "/*"), i):
                    self.comments += 1 if line[i] == "/" else -1
                    i += 2
                else:
                    i += 1
            elif self.string:
                if line[i] == "\\":
                    i += 2
                    continue
                self.string = line[i] != '"'
                i += 1
            elif self.raw is not None:
                if line.startswith(self.raw, i):
                    i += len(self.raw)
                    self.raw = None
                else:
                    i += 1
            elif line.startswith("//", i):
                break
            elif line.startswith("/*", i):
                self.comments, i = 1, i + 2
            elif raw := RUST_RAW_STRING.match(line, i):
                self.raw, i = '"' + raw.group(1), raw.end()
            elif line[i] == '"':
                self.string, i = True, i + 1
            elif line[i] == "'":
                char = RUST_CHAR.match(line, i)  # else a lifetime or a label
                i = char.end() if char else i + 1
            else:
                if line[i] == "{":
                    self.depth += 1
                elif line[i] == "}":
                    self.depth -= 1
                    self.low = min(self.low, self.depth)
                    closed |= floor is not None and self.depth <= floor
                elif line[i] in "([":
                    self.nest += 1
                elif line[i] in ")]":
                    self.nest -= 1
                i += 1
        return closed


def skip_block_comment(text: str) -> str:
    """What follows the (possibly nested) block comment `text` starts with, or "" when it runs
    past the line: a comment between `#[cfg(test)]` and its `mod` keeps the attribute pending."""
    depth, i = 0, 0
    while i < len(text):
        if text.startswith("/*", i):
            depth, i = depth + 1, i + 2
        elif text.startswith("*/", i):
            depth, i = depth - 1, i + 2
            if depth == 0:
                return text[i:].lstrip()
        else:
            i += 1
    return ""


def rust_test_lines(lines: list[str], edges: set[int] | None = None) -> set[int]:
    """Of a Rust file's lines from its first line on, the indexes of those inside a
    `#[cfg(test)] mod name { ... }`. The lines that open and close the module are not inside: code
    can sit before or after the module on them, and their indexes go to `edges` when given, with
    the attribute lines above that made the module a test module. A test module counts only where
    an item can stand: outside any parenthesis or bracket, and inside no brace but module bodies. In
    a macro's tokens (`emit! { #[cfg(test)] mod m { ... } }`) the attribute may never apply."""
    braces, inside = RustBraces(), set()
    module_braces: set[int] = set()  # the brace depths, from 1, that open a plain `mod name {` body
    test_attribute = False
    attribute_lines: list[int] = []  # lines of the attributes read so far for the next item
    module_depth: int | None = None  # the depth outside the open test module
    for index, text in enumerate(lines):
        opened, module_brace = False, None
        if module_depth is None and not braces.in_code():
            # A line that starts inside a comment is read from where the comment ends; one that starts
            # inside a string ends the search.
            rest = skip_block_comment("/*" * braces.comments + text.strip()) if braces.comments else None
            if rest is None:
                test_attribute, attribute_lines = False, []
        else:
            rest = text.strip() if module_depth is None else None
        if rest is not None:
            while True:
                if attribute := RUST_ATTRIBUTE.match(rest):
                    test_attribute |= RUST_TEST_CFG.fullmatch("".join(attribute.group(1).split())) is not None
                    rest = rest[attribute.end():]
                    if not attribute_lines or attribute_lines[-1] != index:
                        attribute_lines.append(index)
                elif rest.startswith("/*"):
                    rest = skip_block_comment(rest)
                else:
                    break
            item_place = braces.nest == 0 and module_braces >= set(range(1, braces.depth + 1))
            if (mod := RUST_MOD.match(rest)) and item_place:
                if test_attribute:
                    module_depth, opened = braces.depth, True
                    if edges is not None:
                        edges.update(attribute_lines)
                elif not rest[mod.end():].strip() or rest[mod.end():].lstrip().startswith("//"):
                    module_brace = braces.depth + 1
            # Blank lines, comments and attribute-only lines keep looking for the item.
            if rest and not rest.startswith("//"):
                test_attribute, attribute_lines = False, []
        closed = braces.feed(text, module_depth)
        module_braces = {depth for depth in module_braces if depth <= braces.low} | (
            {module_brace} if module_brace is not None and braces.depth >= module_brace else set())
        if closed and module_depth is not None:
            module_depth = None
            if edges is not None:
                edges.add(index)
        elif opened and edges is not None:
            edges.add(index)
        elif module_depth is not None and not opened:
            inside.add(index)
    return inside


# Code that may be test-only although no test module above was read as one: a `test` cfg in a form
# rust_test_lines doesn't take (`cfg(all(test, any(...)))`, `cfg_attr(test, ...)`, a `#[test]` outside
# a test module), or an attribute that goes on past its line.
RUST_TEST_WORD = re.compile(r"\btest\b")
RUST_OPEN_ATTRIBUTE = re.compile(r"\s*#\s*!?\s*\[")


def rust_test_doubt(lines: list[str], tests: set[int], edges: set[int]) -> bool:
    """Whether lines outside the test modules rust_test_lines found may still be test code."""
    for index, text in enumerate(lines):
        if index in tests or index in edges:
            continue
        if RUST_TEST_WORD.search(text) or (RUST_OPEN_ATTRIBUTE.match(text) and text.count("[") > text.count("]")):
            return True
    return False


def patch_hunks(patch: str) -> list[list[tuple[str, int | None, int | None, str]]]:
    """A patch's hunks, each a list of (kind " ", "+" or "-", base line number, head line number,
    text). The numbers are None in a patch with no hunk header."""
    hunks: list[list[tuple[str, int | None, int | None, str]]] = []
    old = new = None
    for line in patch.splitlines():
        if header := HUNK.match(line):
            old, new = int(header.group(1)), int(header.group(2))
            hunks.append([])
        elif line[:1] in (" ", "+", "-"):
            if not hunks:
                hunks.append([])
            kind = line[0]
            hunks[-1].append((kind, old if kind != "+" else None, new if kind != "-" else None, line[1:]))
            if old is not None:
                old += kind != "+"
                new += kind != "-"
    return hunks


def rust_test_roles(patch: str, sign: str, source: str | None = None) -> dict[tuple[int, int], bool]:
    """For the lines on one side of a Rust patch ("+" the head, "-" the base), keyed (hunk, index):
    True in a test module, False in product code. A line is missing when that can't be known: a
    hunk shows a module only if the whole file up to it is there, so each hunk is read against
    `source` (the file on that side) when every line of it matches, else on its own only when it
    starts at line 1, else not at all. A line that opens or closes a test module is missing too: it
    can hold test code and product code at once. On the base side ("-"), where product code earns
    removal credit, no line is product code when rust_test_doubt finds possible test code the
    module reading missed."""
    whole = source.splitlines() if source else []
    whole_edges: set[int] = set()
    whole_tests = rust_test_lines(whole, whole_edges)
    whole_doubt = sign == "-" and rust_test_doubt(whole, whole_tests, whole_edges)
    roles = {}
    for h, hunk in enumerate(patch_hunks(patch)):
        side = [(i, (old if sign == "-" else new), text) for i, (kind, old, new, text) in enumerate(hunk)
                if kind in (" ", sign)]
        if whole and all(n is not None and 0 < n <= len(whole) and whole[n - 1].rstrip() == text.rstrip()
                         for _, n, text in side):
            roles |= {(h, i): n - 1 in whole_tests for i, n, _ in side
                      if n - 1 not in whole_edges and not (whole_doubt and n - 1 not in whole_tests)}
        elif side and side[0][1] == 1:
            edges: set[int] = set()
            texts = [text for _, _, text in side]
            tests = rust_test_lines(texts, edges)
            doubt = sign == "-" and rust_test_doubt(texts, tests, edges)
            roles |= {(h, i): k in tests for k, (i, _, _) in enumerate(side)
                      if k not in edges and not (doubt and k not in tests)}
    return roles


def delete_lines(patch: str, sign: str, path: str = "", source: str | None = None) -> list[str]:
    """The code lines a patch adds (sign "+") or removes ("-") that delete files or rows, with
    whitespace collapsed. Comment lines don't count. In a Rust file (`source` is the file on that
    side), an added line counts unless it is known to be in a test module, and a removed line
    counts only if it is known to be product code: a removed test cleanup must not pay for a new
    product delete."""
    roles = rust_test_roles(patch, sign, source) if path.endswith(".rs") else None
    found = []
    for h, hunk in enumerate(patch_hunks(patch)):
        for i, (kind, _, _, text) in enumerate(hunk):
            if kind != sign or text.startswith(sign * 2):
                continue
            if roles is not None and (roles.get((h, i)) is not False if sign == "-" else roles.get((h, i)) is True):
                continue
            code = " ".join(text.split())
            if code.startswith(("//", "#", "--", "*", "/*")):
                continue
            if DELETES.search(code):
                found.append(code)
    return found


def in_delete_scope(path: str) -> bool:
    """Product code, where a delete can reach a user's data: not low, a script, CI or generated."""
    return classify_path(path)[0] != "low" and not any(matches(path, p) for p in DELETE_SCOPE_EXCLUDED + GENERATED)


def new_delete_files(patches: dict[str, str], sources: dict[str, str] | None = None,
                     base_sources: dict[str, str] | None = None) -> set[str]:
    """The product-code files that gain a delete of files or rows. A delete line the pull request
    also removes, in the same file or another, was moved; a file that removes as many delete lines
    as it adds was edited. Neither is new. `sources` and `base_sources` hold Rust files at the head
    and at the merge base (keyed by the head path), which place a line in or out of a test module."""
    sources, base_sources = sources or {}, base_sources or {}
    # Only product code can be the source of a move: a cleanup line taken out of a test, a doc or a
    # script and put into product code is a new delete there.
    removed = {path: Counter(delete_lines(patch, "-", path, base_sources.get(path)) if in_delete_scope(path) else [])
               for path, patch in patches.items()}
    added = {path: delete_lines(patch, "+", path, sources.get(path)) for path, patch in patches.items()}
    unmatched: dict[str, list[str]] = {}
    # A moved line cancels one removal of the same text, in its own file first, then anywhere.
    for path in sorted(added, key=lambda p: 0 if removed[p] else 1):
        for line in added[path]:
            source = path if removed[path][line] else next((p for p in removed if removed[p][line]), None)
            if source is None:
                unmatched.setdefault(path, []).append(line)
            else:
                removed[source][line] -= 1
    flagged = set()
    for path, lines in unmatched.items():
        if not in_delete_scope(path):
            continue
        # A delete line still removed here was rewritten: each one pays for one added line.
        if len(lines) > sum(removed[path].values()):
            flagged.add(path)
    return flagged


def added_privileged_trigger(path: str, patch: str) -> bool:
    """Whether the patch adds a pull_request_target or workflow_run trigger to a workflow."""
    if not any(matches(path, p) for p in WORKFLOW_FILES):
        return False
    for line in patch.splitlines():
        if line.startswith("+") and not line.startswith("+++"):
            # The YAML before any comment: `on: [push, pull_request_target]` counts, `# ...` does not.
            code = line[1:].split("#", 1)[0]
            # A mention inside a shell step or an expression is not a trigger.
            if PRIVILEGED_TRIGGER.search(code) and not re.search(r"(\$\{\{|\b(run|echo|if)\b|github\.event_name)", code):
                return True
    return False


def classify(files: list[str], patches: dict[str, str] | None = None, sources: dict[str, str] | None = None,
             base_sources: dict[str, str] | None = None) -> Grade:
    """The highest tier of any changed path, raised to high by a new delete of user data or a new
    privileged workflow trigger. `sources` and `base_sources`: Rust files at the head and the merge
    base (see new_delete_files)."""
    patches = patches or {}
    deleting = new_delete_files(patches, sources, base_sources)
    rank = 0
    reasons: dict[str, list[str]] = {}
    for path in files:
        tier, reason = classify_path(path)
        if tier != "high" and path in deleting:
            tier, reason = "high", "adds a delete of files or stored rows"
        if tier != "high" and added_privileged_trigger(path, patches.get(path, "")):
            tier, reason = "high", "adds a pull_request_target or workflow_run trigger"
        reasons.setdefault(f"{tier}: {reason}", []).append(path)
        rank = max(rank, TIERS.index(tier))
    return Grade(TIERS[rank], reasons)


SIGN_OFF_HOW = (f"a line `Review (<reviewer>): SHIP at <full head sha>` from an independent review, in the "
                f"description or leading a comment, an approving review from someone other than the author, or "
                f"`{HUMAN_OK_LABEL}` added by a maintainer (agents never add it)")


def missing_evidence(tier: str, human_ok: bool = False, body: str = "",
                     taken_back: list[int] | None = None, blocked: bool = False,
                     unread: bool = False) -> list[str]:
    """What the summary lists as held. Empty means nothing is. A high pull request is listed only for a
    BLOCK (or FIX, or a change request) that is the newest verdict on its head, which risk-tier.yml
    only warns on (the lander refuses it); with no verdict yet it gets a warning (pending_review). A
    takeback is listed for any tier until the description owns it, and only that turns the check red
    (unowned_takebacks)."""
    missing = []
    if tier == "high" and unread and not human_ok:
        missing.append("the review verdicts on the head commit could not be read (a GitHub API error), so a "
                       "BLOCK may be hidden. Re-run this check")
    elif tier == "high" and blocked and not human_ok:
        missing.append(f"the newest review verdict on the head commit is a BLOCK, FIX or change request. "
                       f"Address it and push; a review of the new head clears it: {SIGN_OFF_HOW}")
    for number in unowned_takebacks(body, taken_back):
        missing.append(
            f"this takes back #{number}'s change from the last {RECENT_DAYS} days. If the base is stale, "
            f"merge it and push; if it's on purpose, add a line `Takes back #{number}: <why>`")
    return missing


def unowned_takebacks(body: str = "", taken_back: list[int] | None = None) -> list[int]:
    """The pull requests this one takes back without a `Takes back #N: <why>` line owning it."""
    acknowledged = {int(n) for n in TAKES_BACK.findall(strip_comments(body or ""))}
    return [number for number in sorted(set(taken_back or [])) if number not in acknowledged]


def pending_review(tier: str, human_ok: bool = False, blocked: bool = False) -> str:
    """The warning for a high pull request with no verdict on its head yet ("" when it needs none)."""
    if tier != "high" or human_ok or blocked:
        return ""
    return f"no review verdict on the head commit yet. Land after an independent review passes: {SIGN_OFF_HOW}"


def strip_comments(body: str) -> str:
    return re.sub(r"<!--.*?-->", "", body, flags=re.S)


def gh_json(*args: str):
    out = gh_run(["gh", *args])
    return json.loads(out) if out.strip() else None


def gh_run(args: list[str], attempts: int = 3) -> str:
    """stdout of a gh call, retried so one transient API error doesn't turn the check red."""
    for attempt in range(attempts):
        try:
            return subprocess.run(args, check=True, capture_output=True, text=True).stdout
        except subprocess.CalledProcessError:
            if attempt == attempts - 1:
                raise
            time.sleep(2 * (attempt + 1))
    return ""


PER_PAGE = 100
MAX_PAGES = 30  # 3000 items: the most changed files GitHub's files API lists


def gh_items(endpoint: str, max_pages: int = MAX_PAGES) -> list[dict]:
    """Every item of a paginated list endpoint, one bounded `gh api` call per page. The gh quota
    wrapper refuses an unbounded paginating call, so pages are asked for one at a time (the same loop
    as scripts/ci/gh_pages.py, inlined: risk-tier.yml checks out this file alone). A list past the
    cap raises: a list cut short is never read as complete."""
    path, _, query = endpoint.partition("?")
    kept = [part for part in query.split("&") if part and not re.match(r"(per_page|page)=", part)]
    items: list[dict] = []
    for page in range(1, max_pages + 1):
        batch = json.loads(gh_run(["gh", "api", f"{path}?{'&'.join([*kept, f'per_page={PER_PAGE}', f'page={page}'])}"]))
        if not isinstance(batch, list):
            raise TypeError(f"{endpoint} page {page} is not a list")
        items.extend(batch)
        if len(batch) < PER_PAGE:
            return items
    raise ValueError(f"{endpoint} has more than {max_pages} pages of {PER_PAGE}; "
                     "refusing to read a list cut short as complete")


# A pull request that takes back another pull request's change from this recently is high: that is
# how a stale-base squash silently undoes other people's work (50a0c607aee undid #21369, #21384
# and #21199, all merged in the two days before it).
RECENT_DAYS = 7
MAX_BLAME_FILES = 60
# The whole revert check stops after this many seconds and lists what it didn't get to, so the
# job always finishes inside its own timeout (a timed-out check is red and can't be waived).
REVERT_BUDGET_SECONDS = 90
PR_SUFFIX = re.compile(r"\(#(\d+)\)\s*$")


def deleted_ranges(patch: str) -> list[tuple[int, int]]:
    """The base-side line ranges a unified diff patch deletes, merged into runs."""
    runs: list[tuple[int, int]] = []
    old = 0
    for line in patch.splitlines():
        hunk = re.match(r"^@@ -(\d+)(?:,\d+)? \+\d+(?:,\d+)? @@", line)
        if hunk:
            old = int(hunk.group(1))
            continue
        if line.startswith("-"):
            if runs and runs[-1][1] == old - 1:
                runs[-1] = (runs[-1][0], old)
            else:
                runs.append((old, old))
            old += 1
        elif line.startswith(" "):
            old += 1
    return runs


def diff_lines(patch: str) -> tuple[list[str], list[str]]:
    """The non-blank lines a patch removes and adds, stripped."""
    removed = [l[1:].strip() for l in patch.splitlines() if l.startswith("-") and not l.startswith("---")]
    added = [l[1:].strip() for l in patch.splitlines() if l.startswith("+") and not l.startswith("+++")]
    return [l for l in removed if l], [l for l in added if l]


def undoes(pr_patch: str, commit_patch: str, added_elsewhere: frozenset[str] = frozenset()) -> bool:
    """Whether a pull request's change to a file takes back a commit's change to it: it deletes
    most of what the commit added, and, when the commit replaced lines, puts most of them back."""
    pr_removed, pr_added = map(set, diff_lines(pr_patch))
    # A line the pull request removes and adds back, here or in another file, moved; it wasn't
    # taken back.
    gone, back = pr_removed - pr_added - added_elsewhere, pr_added - pr_removed
    commit_removed, commit_added = map(set, diff_lines(commit_patch))
    if not commit_added:
        return False
    if len(commit_added & gone) / len(commit_added) < 0.8:
        return False
    if not commit_removed:
        return True
    return len(commit_removed & back) / len(commit_removed) >= 0.5


def recent_reverts(entries: list[dict], repo_dir: str, base_sha: str, own: int,
                   now: float | None = None, unread: list[str] | None = None,
                   budget: float = REVERT_BUDGET_SECONDS) -> dict[int, list[str]]:
    """Pull requests (other than `own`) merged in the last RECENT_DAYS whose change to a file this
    pull request takes back, from `git blame` of the base: {pr number: [paths]}. The base's history
    only needs to reach RECENT_DAYS back; older lines blame to the shallow boundary and are skipped.
    Editing recent lines is ordinary; deleting what a recent commit added and restoring what it
    replaced is how a stale base undoes someone's work. Files git couldn't read in time are
    appended to `unread`, so the report can say what went unchecked."""
    cutoff = (now or time.time()) - RECENT_DAYS * 86400
    found: dict[int, list[str]] = {}
    added_anywhere = frozenset(line for e in entries for line in diff_lines(e.get("patch") or "")[1])
    deadline = time.monotonic() + budget
    for entry in entries[:MAX_BLAME_FILES]:
        path = entry.get("previous_filename") or entry["filename"]
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            if unread is not None and deleted_ranges(entry.get("patch") or ""):
                unread.append(path)
            continue
        patch = entry.get("patch") or ""
        ranges = deleted_ranges(patch)
        # Generated files follow their sources; a revert shows on the source.
        if not ranges or entry.get("status") == "added" or any(matches(path, g) for g in GENERATED):
            continue
        args = ["git", "-C", repo_dir, "blame", "--porcelain"]
        for start, end in ranges[:50]:
            args += ["-L", f"{start},{end}"]
        try:
            out = subprocess.run([*args, base_sha, "--", path], capture_output=True, text=True, errors="replace",
                                 timeout=min(30, max(1, remaining)))
        except subprocess.TimeoutExpired:
            out = None
        if out is None or out.returncode != 0:
            if unread is not None:
                unread.append(path)
            continue
        commits: dict[str, dict[str, str]] = {}
        current = None
        for line in out.stdout.splitlines():
            head = re.match(r"^([0-9a-f]{40}) \d+ \d+", line)
            if head:
                current = commits.setdefault(head.group(1), {})
            elif current is not None and line == "boundary":
                current["boundary"] = "1"
            elif current is not None and " " in line and not line.startswith("\t"):
                key, value = line.split(" ", 1)
                current.setdefault(key, value)
        for sha, info in commits.items():
            if time.monotonic() > deadline:
                if unread is not None:
                    unread.append(path)
                break
            if "boundary" in info or int(info.get("committer-time", "0")) < cutoff:
                continue
            number = PR_SUFFIX.search(info.get("summary", ""))
            if not number or int(number.group(1)) == own:
                continue
            try:
                shown = subprocess.run(["git", "-C", repo_dir, "show", "--format=", sha, "--", path],
                                       capture_output=True, text=True, errors="replace",
                                       timeout=max(1, deadline - time.monotonic())).stdout
            except subprocess.TimeoutExpired:
                if unread is not None:
                    unread.append(path)
                continue
            if undoes(patch, shown, added_anywhere):
                found.setdefault(int(number.group(1)), []).append(path)
    return {number: sorted(set(paths)) for number, paths in found.items()}


# At most this many Rust files are read on each side per grading. A file past the cap is graded on
# its hunks alone, which errs toward high.
MAX_RUST_SOURCES = 20


def rust_sources(repo: str, ref: str, paths: dict[str, str]) -> dict[str, str]:
    """{key: the Rust file at `ref`} for paths given as {key: path at ref}. A file that can't be
    read is left out, so its lines are graded on their hunks alone."""
    sources = {}
    for key, path in sorted(paths.items())[:MAX_RUST_SOURCES]:
        try:
            sources[key] = gh_run(["gh", "api", "-H", "Accept: application/vnd.github.raw+json",
                                   f"repos/{repo}/contents/{quote(path)}?ref={ref}"])
        except (subprocess.CalledProcessError, UnicodeDecodeError):
            print(f"::warning::couldn't read {printable(path)} at {ref[:12]}; its hunks alone grade it")
    return sources


def merge_base_of(repo: str, pr: dict) -> str:
    """The commit the pull request's patches are relative to; the base tip if it can't be read."""
    try:
        return gh_json("api", f"repos/{repo}/compare/{pr['base']['sha']}...{pr['head']['sha']}",
                       "--jq", "{sha: .merge_base_commit.sha}")["sha"] or pr["base"]["sha"]
    except (subprocess.CalledProcessError, json.JSONDecodeError, KeyError, TypeError):
        return pr["base"]["sha"]


def pr_mode(args: argparse.Namespace) -> int:
    base = f"repos/{args.repo}/pulls/{args.number}"
    entries = gh_items(f"{base}/files?per_page=100")
    files = [f["filename"] for f in entries]
    patches = {f["filename"]: f.get("patch") or "" for f in entries}
    # A rename moves the old path too: grade both ends.
    files += [f["previous_filename"] for f in entries if f.get("previous_filename")]
    pr = gh_json("api", base)
    # Rust product files that add or remove a delete: read on that side, they place each line in or
    # out of a test module.
    rust = {e["filename"]: e for e in entries if e["filename"].endswith(".rs") and in_delete_scope(e["filename"])}
    adds = {path: path for path in rust if delete_lines(patches[path], "+")}
    removes = {path: e.get("previous_filename") or path for path, e in rust.items()
               if e.get("status") != "added" and delete_lines(patches[path], "-")}
    # The patches' line numbers are relative to the merge base, not the base branch's tip.
    merge_base = merge_base_of(args.repo, pr) if removes or args.repo_dir else pr["base"]["sha"]
    grade = classify(files, patches, rust_sources(args.repo, pr["head"]["sha"], adds),
                     rust_sources(args.repo, merge_base, removes))
    undone: dict[int, list[str]] = {}
    if args.repo_dir:
        unread: list[str] = []
        try:
            undone = recent_reverts(entries, args.repo_dir, merge_base, int(args.number), unread=unread)
        except Exception as error:  # The takeback check informs the grade; it never crashes it.
            print(f"::warning::takeback check failed: {type(error).__name__}")
            unread.extend(e["filename"] for e in entries if deleted_ranges(e.get("patch") or ""))
        for number, paths in sorted(undone.items()):
            grade.reasons.setdefault(f"held: takes back #{number}'s change from the last {RECENT_DAYS} days",
                                     []).extend(paths)
        if unread:
            # Never silent: the reviewer checks these by hand.
            grade.reasons.setdefault("note: the takeback check couldn't read these in time, so check them by hand",
                                     []).extend(sorted(set(unread)))
    # Only looked up for high, so low and normal cost no extra API calls.
    signed, blocked, unread = None, False, False
    if grade.tier == "high":
        try:
            signed, blocked = human_ok_by(args.repo, args.number, pr)
        except (subprocess.CalledProcessError, ValueError, TypeError):
            # An unreadable comment, review or label read (or one past the page cap) could hide a
            # BLOCK: list it as held (risk-tier.yml then warns; the lander reads the verdict itself).
            signed, blocked, unread = None, False, True
    missing = missing_evidence(grade.tier, signed is not None, pr.get("body") or "", list(undone), blocked,
                               unread)
    pending = pending_review(grade.tier, signed is not None, blocked or unread)
    report = render(grade, missing, signed, pending)
    print(report)
    if pending:
        print(f"::warning::risk:high: {pending}")
    if args.summary:
        Path(args.summary).open("a").write(report + "\n")
    if args.github_output:
        with Path(args.github_output).open("a") as out:
            out.write(f"tier={grade.tier}\nlabel={LABELS[grade.tier]}\n")
            out.write(f"ready={'false' if missing else 'true'}\n")
            # Only an unowned takeback keeps the check red (risk-tier.yml): it is a stale-base squash
            # quietly reverting a merged change. A BLOCK on the head is the lander's to refuse.
            takes_back = bool(unowned_takebacks(pr.get("body") or "", list(undone)))
            out.write(f"takes_back={'true' if takes_back else 'false'}\n")
    return 0


def last_labeler(events: list[dict], name: str) -> str | None:
    """Who added the label, if it is still on: the last add, cleared by a later removal."""
    actor = None
    for event in events:
        if (event.get("label") or {}).get("name") != name:
            continue
        if event.get("event") == "labeled":
            actor = (event.get("actor") or {}).get("login")
        elif event.get("event") == "unlabeled":
            actor = None
    return actor


def head_verdicts(comments: list[dict], reviews: list[dict], head_sha: str,
                  author: str, pr: dict | None = None) -> list[tuple[str, str, str]]:
    """(at, "ship" or "block", who) for every trusted verdict on the head, one timeline as
    next_autoland reads it: an approval (not the author's) or change request of the head commit, a
    receipt line naming the full head sha that leads a comment or a review body, and such a line
    anywhere in the description. The description has no time of its own, so its lines rank below
    every comment and review (at ""): a later BLOCK comment still beats a SHIP line in it. Its author
    must be trusted the same way a commenter must."""
    found = []

    def verdict(text: str, at: str, where: str = "") -> None:
        line = RECEIPT.match(text)
        if line and "self" not in line.group(1).lower() and head_sha in text:
            found.append((at, "ship" if line.group(2).lower() == "ship" else "block",
                          f"review ({line.group(1).strip()}){where}"))

    def receipt(item: dict, at: str) -> None:
        verdict(next((line for line in (item.get("body") or "").splitlines() if line.strip()), ""), at)

    def trusted(item: dict) -> bool:
        user = item.get("user") or {}
        return user.get("type") == "User" and item.get("author_association") in TRUSTED

    if pr and trusted(pr):
        for text in strip_comments(pr.get("body") or "").splitlines():
            verdict(text, "", " in the description")

    for review in reviews:
        if not trusted(review):
            continue
        at, login = review.get("submitted_at") or "", (review.get("user") or {}).get("login") or ""
        if review.get("commit_id") == head_sha:
            if review.get("state") == "APPROVED" and login != author:
                found.append((at, "ship", f"@{login}"))
            elif review.get("state") == "CHANGES_REQUESTED":
                found.append((at, "block", f"@{login}"))
        receipt(review, at)
    for comment in comments:
        if trusted(comment):
            receipt(comment, comment.get("created_at") or "")
    return found


def signed_off(comments: list[dict], reviews: list[dict], head_sha: str, author: str = "",
               pr: dict | None = None) -> str | None:
    """Who passed the head, or None: the newest verdict on it must be a SHIP, so a later BLOCK or
    change request beats an earlier SHIP or approval, and a BLOCK wins a tie."""
    found = head_verdicts(comments, reviews, head_sha, author, pr)
    if not found:
        return None
    _, verdict, who = max(found, key=lambda f: (f[0], f[1] == "block"))
    return who if verdict == "ship" else None


def human_ok_by(repo: str, number: str, pr: dict) -> tuple[str | None, bool]:
    """(who signed off, blocked) for a high pull request. Signed off: the newest verdict on the head
    (an independent review's receipt in a comment, a review or the description, an approval or a
    change request) is a SHIP, or, with no verdict on the head, the sign-off label added by a
    maintainer (admin or maintain role). Blocked: the newest verdict on the head is not a SHIP. The
    green compile is required on every tier by the merge path, not here."""
    head_sha = pr["head"]["sha"]
    comments = gh_items(f"repos/{repo}/issues/{number}/comments?per_page=100")
    reviews = gh_items(f"repos/{repo}/pulls/{number}/reviews?per_page=100")
    author = (pr.get("user") or {}).get("login") or ""
    if head_verdicts(comments, reviews, head_sha, author, pr):
        who = signed_off(comments, reviews, head_sha, author, pr)
        return (f"{who} shipped {head_sha[:12]}", False) if who else (None, True)
    labels = {label["name"] for label in pr.get("labels", [])}
    for name in (HUMAN_OK_LABEL, WAIVED_LABEL):
        if name not in labels:
            continue
        actor = last_labeler(gh_items(f"repos/{repo}/issues/{number}/events?per_page=100"), name)
        if actor:
            role = (gh_json("api", f"repos/{repo}/collaborators/{actor}/permission") or {}).get("role_name")
            if role in ("admin", "maintain"):
                return f"`{name}` is set by @{actor}", False
    return None, False


def printable(path: str) -> str:
    """A changed path as it may appear in a log or summary: no control characters (a newline in a
    file name could start a `::` workflow command), no backticks to break the code span."""
    return re.sub(r"[\x00-\x1f\x7f-\x9f\u2028\u2029`]", "?", path)


ORDER = {"held": 3, "high": 2, "normal": 1, "low": 0, "note": -1}


def render(grade: Grade, missing: list[str], signed: str | None = None, pending: str = "") -> str:
    out = [f"## Risk tier: {grade.tier}", ""]
    for reason, paths in sorted(grade.reasons.items(), key=lambda kv: -ORDER.get(kv[0].split(":")[0], 0)):
        shown = ", ".join(f"`{printable(p)}`" for p in paths[:5]) + (f" and {len(paths) - 5} more" if len(paths) > 5 else "")
        out.append(f"- {reason}: {shown}")
    out.append("")
    if signed:
        out.append(f"Signed off: {signed}.")
    if missing:
        out.append("Before merge:")
        out += [f"- {item}" for item in missing]
    elif pending:
        out.append(f"Warning: {pending}")
    elif grade.tier == "high":
        out.append("Nothing holds this pull request.")
    else:
        out.append(f"Nothing holds this pull request: {grade.tier} needs no person, only the usual agent "
                   "review and the checks relevant to the change.")
    out.append("\nPolicy: docs/ci/risk-tiers.md")
    return "\n".join(out)


def split_diff(diff: str) -> dict[str, str]:
    """A `git diff` split into {new path: its hunks}."""
    out: dict[str, list[str]] = {}
    current = None
    for line in diff.splitlines():
        if line.startswith("diff --git "):
            current = None
        elif line.startswith("+++ "):
            name = line[4:].strip()
            current = name[2:] if name.startswith("b/") else None
            if current is not None:
                out.setdefault(current, [])
        elif current is not None and not line.startswith("--- "):
            out[current].append(line)
    return {path: "\n".join(lines) for path, lines in out.items()}


def read_lines(path: str | None) -> list[str]:
    if not path:
        return []
    return [line.strip() for line in Path(path).read_text().splitlines() if line.strip()]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="mode", required=True)
    c = sub.add_parser("classify")
    c.add_argument("--files", required=True, help="one changed path per line")
    c.add_argument("--patches", help="a `git diff` of the change, for the data-deletion check")
    c.add_argument("--json", action="store_true")
    e = sub.add_parser("evidence")
    e.add_argument("--tier", choices=TIERS, required=True)
    e.add_argument("--human-ok", action="store_true")
    e.add_argument("--blocked", action="store_true", help="the newest verdict on the head is a BLOCK or FIX")
    p = sub.add_parser("pr")
    p.add_argument("--repo", required=True)
    p.add_argument("--number", required=True)
    p.add_argument("--repo-dir", help="a clone holding the base commit and RECENT_DAYS of its history, "
                   "for the takeback check (skipped without it)")
    p.add_argument("--github-output")
    p.add_argument("--summary")
    args = parser.parse_args(argv)

    if args.mode == "classify":
        patches = split_diff(Path(args.patches).read_text()) if args.patches else {}
        grade = classify(read_lines(args.files), patches)
        print(json.dumps(grade.as_json(), indent=2) if args.json else grade.tier)
        return 0
    if args.mode == "evidence":
        missing = missing_evidence(args.tier, args.human_ok, blocked=args.blocked)
        for item in missing:
            print(f"missing: {item}")
        return 1 if missing else 0
    return pr_mode(args)


if __name__ == "__main__":
    sys.exit(main())
