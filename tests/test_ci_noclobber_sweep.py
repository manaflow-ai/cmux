#!/usr/bin/env python3
"""Noclobber is not exclusive creation: no `set -C`, and no guessable name in a shared temp folder, in scripts/ and
.github/ (shell, Python, TypeScript, Go and workflow `run:` blocks).

`set -C` (noclobber) makes `>` refuse an existing regular file only. An existing FIFO, device, or a link to one opens
as it is. So a temp file made with noclobber, or with nothing, at a name another account can guess can be a FIFO or
link that account made first: it reads what is written there, answers as the socket a client then trusts, or swaps
a script that runs next. Exclusive creation is `mkdir` (any existing entry, FIFO and link included, fails it),
mktemp / tempfile.mkdtemp, or O_CREAT|O_EXCL. A name a variable fills (`/tmp/x.$$`, f"/tmp/x-{os.getpid()}",
`${TMPDIR:-/tmp}/x.$(id -u)`, a remote "/tmp/$NAME.sh") in a shared temp folder is guessable, so it is made
exclusively or not at all: in a mktemp folder of the run's own, or in the user's own folder (~/.cache, the remote
home). scripts/check-test-determinism.py's predictable-tmp-path covers fixed names in tests and git hooks; this
covers the rest of scripts/ and .github/.

The detector, ported from cmuxterm-hq tests/test_noclobber_sweep.py (the same two greps):

    git grep -nE 'set -[a-zA-Z]*C\\b|set -o noclobber' -- scripts .github
    git grep -nE '((/private)?/tmp|\\$\\{?TMPDIR(:-/tmp)?\\}?)/[A-Za-z0-9._-]*(\\$\\$|\\$\\{?[A-Za-z_]|\\$\\(|\\{[A-Za-z_])' -- scripts .github

Tests, comment lines and a mktemp call's template word (the word with XXXXXX in it) do not count; the rest of a line
with a template is still read. A name the app, its daemons or acpmux pick (APP_NAMES) is theirs to move: a script
here only names it to them or reads it. A hit that is safe for a reason the grep cannot see goes in ALLOWED with that
reason, keyed by path and a piece of its line; an entry nothing matches fails, so the list only shrinks.
"""
from __future__ import annotations

import re
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DIRS = ("scripts", ".github")
NOCLOBBER = re.compile(r"(?<![\w-])(?:set\s+-[a-zA-Z]*C\b|set\s+-o\s+noclobber)")
SHARED_TMP = re.compile(r"(?:(?<![\w.])(?:/private)?/tmp|\$\{?TMPDIR(?::-/tmp)?\}?)/[A-Za-z0-9._-]*"
                        r"(?:\$\$|\$\{?[A-Za-z_]\w*\}?|\$\(|\{[A-Za-z_][^}]*\})")
SKIP_SUFFIXES = (".md", ".json", ".jsonl", ".csv", ".txt", ".html", ".toml", "_test.py", "_test.go", "_test.sh",
                 ".test.ts", ".test.mjs", ".test.js", ".spec.ts")

# Name prefixes the app, its daemons or acpmux choose. The app makes these sockets, logs and records; a script here
# passes the name to the app or connects to, reads or removes it. Moving one is the app's change.
APP_NAMES = {
    "/tmp/cmux-debug-": "a tagged DEV build's socket and debug log (ControlSocketPath.swift, BuildIdentity+AppNames.swift)",
    "/tmp/cmux-nightly-": "the NIGHTLY app's socket and last-socket-path record (the app's naming)",
    "/tmp/cmux-staging-": "the STAGING app's socket and last-socket-path record (the app's naming)",
    "/tmp/cmux-dev-": "a DEV app's last-socket-path record (the app's naming)",
    "/tmp/cmux-rc-": "an RC app's last-socket-path record (the app's naming, reload.sh's marker table)",
    "/tmp/cmux-tui-": "cmux-tui's per-user socket folder (its own naming)",
    "/tmp/cmux-hd-": "the holder daemon's per-user socket folder (holder_runtime/service.rs)",
    "/tmp/acpmux-": "acpmux's per-user socket folder: acpmux makes it 700 and refuses one it does not own",
    "/tmp/cmux-reload-": "reload.sh's xcodebuild log, which other tools read by this name after a build",
    "/tmp/cmux-next-irx-journal-": "the app's irx journal (MobileIrxHost.swift); scripts read or remove it",
}

# (path, a piece of the line): why the grep's hit is safe
ALLOWED = {
    ("scripts/cmux-next/push-from-host.sh", '"mktemp -d /tmp/$NAME-XXXXXX"'):
        "a mktemp template in the command string ssh runs on HOST: mktemp makes it there, and the line after checks it",
    ("scripts/check-test-determinism.py", "lib/git-fixture.sh took ${TMPDIR:-/tmp}/cmux-git-fixture-"):
        "a docstring naming the bad shape predictable-tmp-path catches",
    ("scripts/check-test-determinism.py", "'_global=\"${TMPDIR:-/tmp}/cmux-git-fixture-$(id -u)-v1.gitconfig\""):
        "the detector's own fixture of the bad shape",
    ("scripts/ci/owned_catch_up.sh", 'root="/private/tmp/cmux-ci-$root_number"'):
        "the canonical build root: the compile cache keys on this exact path (canonical-build-root.sh), and on an "
        "owned Mac glaeda-canonical-root holds it for the job",
    (".github/workflows/seed-derived-data.yml", 'root="/private/tmp/cmux-ci-$CMUX_SEED_ROOT"'):
        "the canonical build root (canonical-build-root.sh), taken through glaeda-canonical-root for the job",
    ("scripts/reload.sh", 'local own="" link="/tmp/cmux-${tag}"'):
        "the tag's DerivedData compatibility link, a name other tools follow (#41021 kept it); read with readlink",
    ("scripts/reload.sh", 'local own="" link="/tmp/cmux-${tag}" root=""'):
        "the tag's DerivedData compatibility link, read with readlink to print cleanup commands",
    ("scripts/reload.sh", '"/tmp/cmux-${tag}" "/tmp/cmux-debug-${tag}.sock"'):
        "printed cleanup commands for the tag's own compatibility link and socket, never run here",
    ("scripts/reload.sh", 'TMP_COMPAT_DERIVED_LINK="/tmp/cmux-${TAG_SLUG}"'):
        "the tag's DerivedData compatibility link other tools follow (#41021 kept it and tests reload.sh with /tmp "
        "moved)",
    ("scripts/cleanup-dev-builds.sh", '"/tmp/cmux-${tag}" \\'):
        "removal of the tag's compatibility link: bytes_in_path and rm read the entry, never write through it",
    ("scripts/cleanup-dev-builds.sh", '"/tmp/cmux-${tag}.tar" \\'):
        "removal of a tag's old build archive by name; nothing is written there",
    ("scripts/ci/cmux-next-ios-sim.sh", 'if [[ -L "/tmp/cmux-$mac_tag" ]]; then rm -f "/tmp/cmux-$mac_tag"'):
        "removes the run's own tag link only when it is a link; nothing is written through it",
    ("scripts/cmux-next/bench_launch.py", 'f"/tmp/{name}"]'):
        "a candidate path of the tagged app's own socket (name is cmux-debug-<tag>.sock), connected to, not made",
    ("scripts/cmux-next/classic-to-next-live.py", 'return f"/tmp/cmux-{channel}.sock"'):
        "the app's control socket by channel (ControlSocketPath.swift), connected to, not made",
    ("scripts/cmux-next/classic-to-next-live.py", 'return f"/tmp/cmux-{channel}-{slug('):
        "the app's control socket by channel and bundle (ControlSocketPath.swift), connected to, not made",
    ("scripts/cmux-next/home-image-drop-proof.py", 'SRC = f"/tmp/hidp-{TAG}"'):
        "made by os.makedirs after the rmtree: mkdir fails on any entry another account left there",
    ("scripts/cmux-next/rust-live.py", 'path = f"/tmp/rust-live-{os.getuid()}"'):
        "control_dir refuses it unless it is a real 700 folder this user owns",
    ("scripts/journeys/ext_marker.py", 'path = f"/tmp/jr-m-{j.nonce}-{os.urandom(4).hex()}"'):
        "made with O_CREAT|O_EXCL, which fails on any entry already there",
    ("scripts/irx-soak.py", "cmux-irx-journal-mac-{args.tag}.jsonl"):
        "read only: the journal of the tagged app the runner launched; nothing is written there",
    ("scripts/cmux-next/cloud-chaos.ts", "`/tmp/cmux-chaos-seq-${tag}.txt`"):
        "a path in the Cloud machine's terminal the run made, a single-account VM of its own",
    ("scripts/gallery-matrix/runner.ts", "const remoteRoot = `/tmp/${runId}`;"):
        "a path in the Freestyle VMs this run created, where its account is the only one",
    ("scripts/fuzz/macos-matrix/fuzz.py", 'exit_file = f"/tmp/cmux-fuzz-exit-{os.getpid()}"'):
        "a path in the fuzz guest VM the run boots, where its account is the only one",
    ("scripts/fuzz/macos-matrix/fuzz.py", 'live_sample = f"/tmp/fuzz-live-sample-{run_id}-{i}.txt"'):
        "a path in the fuzz guest VM the run boots, where its account is the only one",
    ("scripts/fuzz/macos-matrix/fuzz.py", 'g.sh(f"sudo -n /usr/bin/sample {pid} 2 -file /tmp/fuzz-unresp-{i}.txt'):
        "a path in the fuzz guest VM the run boots, where its account is the only one",
    ("scripts/fuzz/macos-matrix/fuzz.py", 'f"/usr/bin/sample {pid} 2 -file /tmp/fuzz-unresp-{i}.txt'):
        "a path in the fuzz guest VM the run boots, where its account is the only one",
    ("scripts/fuzz/macos-matrix/fuzz.py", 'g.sh(f"cat /tmp/fuzz-unresp-{i}.txt")'):
        "a path in the fuzz guest VM the run boots, where its account is the only one",
}


def code(line: str) -> str:
    return re.sub(r"(^|\s)#.*$", "", line)


# The template word of each mktemp call, found by a small shell tokenizer, never a regex: shell parsed by regex let
# through a guessable name beside a template twice (review of manaflow-ai/cmux-platform#1262, F2:
# `d=$(mktemp -d ".../safe.XXXXXX"); printf secret > /tmp/out.$$`; of #1265, F1: `d=$(mktemp -d) > /tmp/out.$$.XXXXXX`).
# The tokenizer tracks quotes, escapes, $( ), backticks, ${ }, $(( )), subshells, separators and redirections. A word
# containing XXXXXX is left out of the scan only when it is an argument of a command whose name is mktemp, not a
# redirection's target. A line it cannot parse (an unclosed quote or substitution) exempts nothing.
class Unparsed(Exception):
    """The line is not shell this tokenizer can read through."""


ASSIGNMENT = re.compile(r"[A-Za-z_]\w*\+?=")
REDIRECT = re.compile(r"&>>|&>|<<<|<<-|<<|<>|<&|<|>>|>&|>\||>")
WORD_END = " \t\n;&|()<>"


def shell_commands(line: str) -> list[list[tuple[int, int, bool]]]:
    """Every simple command in LINE, those inside $( ) and backticks too: its words as (start, end, is a redirection
    target) spans of LINE."""
    out: list[list[tuple[int, int, bool]]] = []
    if _commands(line, 0, None, out) != len(line):
        raise Unparsed(line)
    return out


def _commands(s: str, i: int, close: str | None, out: list) -> int:
    """Commands from s[i:] up to CLOSE (")" or "`", or None for the end); the index after it."""
    cmd: list[tuple[int, int, bool]] = []
    target, depth, n = False, 0, len(s)

    def end_command() -> None:
        nonlocal cmd
        if target:
            raise Unparsed(s)
        if cmd:
            out.append(cmd)
        cmd = []

    while True:
        while i < n and s[i] in " \t":
            i += 1
        if i >= n:
            if close is not None:
                raise Unparsed(s)
            end_command()
            return i
        c = s[i]
        if c == close and (close == "`" or depth == 0):
            end_command()
            return i + 1
        m = REDIRECT.match(s, i)
        if m:
            if target:
                raise Unparsed(s)
            target, i = True, m.end()
            continue
        if c in ";&|\n":
            end_command()
            i += 2 if s.startswith(("&&", "||", ";;", "|&"), i) else 1
            continue
        if c == "(":
            end_command()
            depth, i = depth + 1, i + 1
            continue
        if c == ")":
            end_command()
            depth, i = max(0, depth - 1), i + 1
            continue
        if c == "#":  # a comment to the end
            if close is not None:
                raise Unparsed(s)
            end_command()
            return n
        j = _word(s, i, close, out)
        if not target and s[i:j].isdigit() and j < n and s[j] in "<>":
            i = j  # a file descriptor's number: the redirection follows
            continue
        cmd.append((i, j, target))
        target, i = False, j


def _word(s: str, i: int, close: str | None, out: list) -> int:
    n = len(s)
    while i < n and s[i] not in WORD_END and not (close == "`" and s[i] == "`"):
        i = _piece(s, i, out)
    return i


def _piece(s: str, i: int, out: list) -> int:
    """The index after the quoted string, substitution, expansion, escape or character at s[i]."""
    c = s[i]
    if c == "\\":
        return i + 2
    if c == "'":
        j = s.find("'", i + 1)
        if j < 0:
            raise Unparsed(s)
        return j + 1
    if c == '"':
        i += 1
        while i < len(s) and s[i] != '"':
            i = _piece(s, i, out) if s[i] in "\\$`" else i + 1
        if i >= len(s):
            raise Unparsed(s)
        return i + 1
    if s.startswith("$((", i):
        depth, i = 0, i + 3
        while i < len(s):
            if s[i] == "(":
                depth += 1
            elif s[i] == ")":
                if depth == 0:
                    if s.startswith("))", i):
                        return i + 2
                    raise Unparsed(s)
                depth -= 1
            i += 1
        raise Unparsed(s)
    if s.startswith("$(", i):
        return _commands(s, i + 2, ")", out)
    if s.startswith("${", i):
        i += 2
        while i < len(s) and s[i] != "}":
            i = _piece(s, i, out)
        if i >= len(s):
            raise Unparsed(s)
        return i + 1
    if c == "`":
        return _commands(s, i + 1, "`", out)
    return i + 1


def mktemp_templates(line: str) -> list[tuple[int, int]]:
    """The spans of LINE that are a mktemp call's template word; none when LINE does not parse."""
    try:
        commands = shell_commands(line)
    except Unparsed:
        return []
    spans = []
    for cmd in commands:
        words = [(a, b) for a, b, target in cmd if not target]
        k = 0
        while k < len(words) and ASSIGNMENT.match(line, words[k][0]):
            k += 1
        if k < len(words) and line[words[k][0]:words[k][1]].rsplit("/", 1)[-1] == "mktemp":
            spans += [(a, b) for a, b in words[k + 1:] if "XXXXXX" in line[a:b]]
    return spans


def without_templates(line: str) -> str:
    """LINE with each mktemp template word replaced by TEMPLATE."""
    for a, b in sorted(set(mktemp_templates(line)), reverse=True):
        line = line[:a] + "TEMPLATE" + line[b:]
    return line


def shared_tmp(line: str) -> list[str]:
    """The guessable shared-temp names in LINE, a mktemp template word left out."""
    return [m.group(0) for m in SHARED_TMP.finditer(without_templates(line))]


def flagged(line: str) -> bool:
    return bool(NOCLOBBER.search(line) or shared_tmp(line))


def app_named(line: str) -> bool:
    found = shared_tmp(line)
    return bool(found) and all(any(m.startswith(p) for p in APP_NAMES) for m in found)


def skipped(path: str) -> bool:
    name = path.rsplit("/", 1)[-1]
    return (name.startswith(("test_", "test-")) or "/tests/" in path or "/test/" in path or "/fixtures/" in path
            or path.endswith(SKIP_SUFFIXES))


def hits(root: Path = ROOT) -> list[tuple[str, int, str]]:
    files = subprocess.run(["git", "-C", str(root), "ls-files", "--", *DIRS], capture_output=True, text=True,
                           check=True).stdout.splitlines()
    out = []
    for path in files:
        if skipped(path):
            continue
        try:
            text = (root / path).read_text()
        except (OSError, UnicodeDecodeError):
            continue
        for n, line in enumerate(text.splitlines(), 1):
            c = code(line)
            if flagged(c):
                out.append((path, n, c.strip()))
    return out


def allowed(path: str, line: str) -> bool:
    return any(path == ap and piece in line for ap, piece in ALLOWED) or (not NOCLOBBER.search(line) and app_named(line))


class NoclobberSweep(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.found = hits()

    def test_no_noclobber_and_no_guessable_shared_temp_name(self):
        bad = [f"{p}:{n}: {line[:160]}" for p, n, line in self.found if not allowed(p, line)]
        self.assertEqual(bad, [], "noclobber is not exclusive creation: use mktemp, a mkdtemp folder of your own, "
                                  "or ~/.cache (this file's docstring); or add the hit to ALLOWED with its reason")

    def test_every_allowance_is_still_used(self):
        for (path, piece), why in ALLOWED.items():
            with self.subTest(path=path, piece=piece):
                self.assertGreater(len(why.strip()), 10)
                self.assertTrue(any(p == path and piece in line for p, _, line in self.found),
                                f"stale allowance: no line of {path} has {piece!r} any more; remove it")
        for prefix, why in APP_NAMES.items():
            with self.subTest(prefix=prefix):
                self.assertGreater(len(why.strip()), 10)
                self.assertTrue(any(prefix in line for _, _, line in self.found), f"stale app name {prefix!r}")

    def test_the_detector_finds_the_classes(self):
        for line in ('set -C; : > "$f"', "(umask 077; set -C; : > x)", "set -o noclobber", "set -eC"):
            self.assertTrue(NOCLOBBER.search(code(line)), line)
        for line in ('f=/tmp/out.$$', 'ACP_SOCKET = f"/tmp/kvmz-acp-{os.getpid()}.sock"',
                     'c="${TMPDIR:-/tmp}/x.$(id -u)"', '"${SSH[@]}" "cat > /tmp/$NAME.sh"',
                     'const bundle = `/tmp/land-${Date.now()}.bundle`;'):
            self.assertTrue(SHARED_TMP.search(code(line)), line)
        for line in ('# set -C is not exclusive', 'd=$(mktemp -d "${TMPDIR:-/tmp}/x.XXXXXX")',
                     'cache="$HOME/.cache/x"', 'set -eu', 'p=/tmp/fixed-name', 'x="$tmp/a/$b"',
                     "t=$(mktemp -p /tmp ${TMPDIR:-/tmp}/run.XXXXXX)",
                     'tmp="$(mktemp -d "${TMPDIR:-/tmp}/cmux-join.XXXXXX")"', "t=`mktemp /tmp/$USER.XXXXXX`",
                     'f=$(TMPDIR=/x mktemp "/tmp/a.$$.XXXXXX") || exit 1',
                     '( cd x && d="$(mktemp -d /tmp/${name}.XXXXXX)" )'):
            self.assertFalse(flagged(code(line)), line)

    def test_a_mktemp_template_exempts_only_itself(self):
        """Review of manaflow-ai/cmux-platform#1262, F2: a line with XXXXXX was exempt whole; of #1265, F1: a
        template-shaped redirection target beside a bare mktemp was exempt too (shell parsed by regex)."""
        for line in ('d=$(mktemp -d ".../safe.XXXXXX"); printf secret > /tmp/out.$$',
                     "d=$(mktemp -d) > /tmp/out.$$.XXXXXX", "mktemp /tmp/a.XXXXXX > /tmp/b.$$.XXXXXX",
                     "t=`mktemp -d`; cp x /tmp/y.$$.XXXXXX", "x=$(echo mktemp /tmp/a.$$.XXXXXX)",
                     'd=$(mktemp -d "/tmp/x.$$.XXXXXX',  # unclosed: a line it cannot parse exempts nothing
                     'd=$(mktemp -d "${TMPDIR:-/tmp}/x.XXXXXX") && cp a /tmp/run.$$',
                     "t=$(mktemp /tmp/a.XXXXXX); echo > ${TMPDIR:-/tmp}/b.$(id -u)"):
            self.assertTrue(flagged(code(line)), line)

    def test_an_app_name_excuses_only_app_names(self):
        self.assertTrue(app_named('sock="/tmp/cmux-debug-$tag.sock"'))
        self.assertFalse(app_named('cp "/tmp/cmux-debug-$tag.log" "/tmp/mine-$$.log"'))
        self.assertFalse(app_named('f=/tmp/out.$$'))


if __name__ == "__main__":
    unittest.main()
