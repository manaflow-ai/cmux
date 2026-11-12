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

The detector, ported from the upstream sweep's tests (the same two greps):

    git grep -nE 'set -[a-zA-Z]*C\\b|set -o noclobber' -- scripts .github
    git grep -nE '((/private)?/tmp|\\$\\{?TMPDIR(:-/tmp)?\\}?)/[A-Za-z0-9._-]*(\\$\\$|\\$\\{?[A-Za-z_]|\\$\\(|\\{[A-Za-z_])' -- scripts .github

Tests, comment lines and a mktemp call's template word (the word with XXXXXX in it) do not count; the rest of a line
with a template is still read. A name the app, its daemons or acpmux pick (APP_NAMES) is theirs to move: a script
here only names it to them or reads it. A hit that is safe for a reason the grep cannot see goes in ALLOWED with that
reason, keyed by path, a piece of its line holding what the hit found, and which occurrence (1 when left out): it
approves that one hit, never another on its line or another line with the same piece; an entry nothing matches fails,
so the list only shrinks.
"""
from __future__ import annotations

import hashlib
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock
import importlib.util as _git_fixture_importlib  # noqa: E402
from os import path as _git_fixture_path  # noqa: E402
# The scratch repositories below are git writes: the helper drops an inherited GIT_DIR and turns maintenance off.
_git_fixture_spec = _git_fixture_importlib.spec_from_file_location(
    "git_fixture_env", _git_fixture_path.join(_git_fixture_path.dirname(_git_fixture_path.abspath(__file__)), "git_fixture_env.py"))
git_fixture_env = _git_fixture_importlib.module_from_spec(_git_fixture_spec)
_git_fixture_spec.loader.exec_module(git_fixture_env)

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

# (path, a piece of the line[, which occurrence]): why the grep's hit is safe. The occurrence counts, in file order,
# the hits of PATH this piece holds (approves()); left out, it is 1. An entry approves that one hit only.
ALLOWED = {
    ("scripts/cmux-next/austins-day/austins-day.sh", '"${TMPDIR:-/tmp}/austins-day-$(date -u +%Y%m%dT%H%M%SZ).XXXXXX"'):
        "a mktemp -d template; shell_tree exempts nothing in this file because it sources $repo/scripts/cmux-next/"
        "capture-host-env.sh through a variable it cannot follow (it may redefine mktemp); that file defines no "
        "mktemp, and its one eval runs the capture host's route helper, whose output sets the ssh routes to the "
        "capture hosts (that file's own header)",
    ("scripts/cmux-next/restore-journey-slot.sh", '"/tmp/restore-journey-$job-$(date +%H%M%S).XXXXXX"'):
        "a mktemp -d template; shell_tree follows the source of capture-host-env.sh but exempts nothing, since that "
        "file evals the capture host's route helper's output (it may redefine mktemp); that output sets the ssh "
        "routes to the capture hosts (that file's own header)",
    ("scripts/reload.sh", '"${TMPDIR:-/tmp}/cmux-launch-${TAG_SLUG}.XXXXXX"'):
        "a mktemp -d template; shell_tree exempts nothing in this file because it sources "
        "$PWD/scripts/lib/dev-backend-origin.sh, a path it cannot follow (it may redefine mktemp), and that file "
        "defines none",
    ("scripts/server-release/install.sh.in", "#!/bin/sh"):
        "a template, not shell until scripts/server-release/render.py fills it: its @@UNIX_CASES@@ line sits where "
        "a case pattern must, so the whole file is unparsed; its one temp name is a mktemp -d template",
    ("scripts/cmux-next/push-from-host.sh", '"mktemp -d /tmp/$NAME-XXXXXX"'):
        "a mktemp template in the command string ssh runs on HOST: mktemp makes it there, and the line after checks it",
    ("scripts/check-test-determinism.py", "lib/git-fixture.sh took ${TMPDIR:-/tmp}/cmux-git-fixture-$UID"):
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
        "a printed cleanup command for the tag's own compatibility link (the socket beside it is an app name), never "
        "run here",
    ("scripts/reload.sh", 'TMP_COMPAT_DERIVED_LINK="/tmp/cmux-${TAG_SLUG}"'):
        "the tag's DerivedData compatibility link other tools follow (#41021 kept it and tests reload.sh with /tmp "
        "moved)",
    ("scripts/cleanup-dev-builds.sh", '"/tmp/cmux-${tag}" \\'):
        "removal of the tag's compatibility link: bytes_in_path and rm read the entry, never write through it",
    ("scripts/cleanup-dev-builds.sh", '"/tmp/cmux-${tag}.tar" \\'):
        "removal of a tag's old build archive by name; nothing is written there",
    ("scripts/ci/cmux-next-ios-sim.sh", 'if [[ -L "/tmp/cmux-$mac_tag" ]]; then rm -f "/tmp/cmux-$mac_tag"', 1):
        "the -L test of the run's own tag link: it reads the entry, never writes through it",
    ("scripts/ci/cmux-next-ios-sim.sh", 'if [[ -L "/tmp/cmux-$mac_tag" ]]; then rm -f "/tmp/cmux-$mac_tag"', 2):
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
    ("scripts/irx-soak.py", "/tmp/cmux-irx-journal-mac-{args.tag}.jsonl"):
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
    """LINE without its comments, taken from the shell parser: a quoted # is not one (shell_tree.code)."""
    return shell_tree.code(line)


# A mktemp template word is found in the line's parse tree (shell_tree.py beside this file, vendored byte for byte
# from a pinned upstream blob: SHELL_TREE_SHA256 below). Shell read by
# regex, then by token masking, let a guessable name through three times, and a comment cut at any # once more
# (shell_tree.MISSES): a line with XXXXXX was exempt whole; a redirection's target was taken for mktemp's argument;
# overlapping template spans shifted each other, and a template word exempted the substitutions inside it. Now only the
# literal text of a mktemp argument with XXXXXX in that literal text is left out. Each command substitution inside the
# word is still scanned, and so is every redirection. A line the parser cannot read exempts nothing and keeps its #s.
# shell_tree.corpus() is the detector's own check: every unsafe write in it is flagged and no safe template is.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import shell_tree  # noqa: E402

SHELL_TREE_SHA256 = "aa41e3640d1b4995c343676c9ad1bc493202afc5c05ea4252aa92b49ce7cf61d"


def without_templates(line: str) -> str:
    """LINE with the literal text of each mktemp template word blanked (shell_tree.scan_text)."""
    return shell_tree.scan_text(line)


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


def hits(root: Path = ROOT) -> list[tuple[str, int, str, str]]:
    """(path, line number, the line, what was found): one hit per set -C or guessable name, each with its own text, so
    an allowance approves that hit and no other on its line."""
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
        # A #! line shell_tree cannot resolve is a hit of its own: what reads the file is unknown.
        if shell_tree.shebang(text) == "unresolved":
            first = text.split("\n", 1)[0]
            out.append((path, 1, first, first))
        # A shell block shell_tree cannot parse is a hit of its own, its first line: what it runs is unknown, and its
        # raw text is scanned besides, never read line by line (shell_tree.unparsed).
        text_lines = text.split("\n")
        for n in shell_tree.unparsed(path, text):
            out.append((path, n, text_lines[n - 1].strip(), text_lines[n - 1].strip()))
        # The file is read whole where it is shell (shell_tree.scan_file), so a here-document, a continued line or
        # a quote across lines keeps its context; the hit keeps the line's own text.
        scans = shell_tree.scan_file(path, text, root=str(root))  # a source in the repository is followed
        for n, (line, scan) in enumerate(zip(text.split("\n"), scans), 1):
            for m in [*NOCLOBBER.finditer(scan), *SHARED_TMP.finditer(scan)]:
                out.append((path, n, code(line).strip() or line.strip(), m.group(0)))
    return out


def holds(entry: tuple, hit: tuple[str, int, str, str]) -> bool:
    """Whether the allowance ENTRY's piece is on HIT's line in its path and holds what the hit found, never only
    another name beside it."""
    (path, piece), (p, _, line, found) = entry[:2], hit
    return p == path and piece in line and found in piece


def approves(entry: tuple, found) -> tuple[str, int, str, str] | None:
    """The one hit of FOUND that the allowance ENTRY ((path, piece[, occurrence])) approves: the occurrence-th, in
    file order, of the hits it holds (manaflow-ai/cmux#41336 review at 911fed64, F2: matched by text alone, one entry
    approved every line and every name with the same piece). None when there is no such hit: the entry is stale."""
    n = entry[2] if len(entry) > 2 else 1
    held = [h for h in found if holds(entry, h)]
    return held[n - 1] if 0 < n <= len(held) else None


def app_name(hit: tuple[str, int, str, str]) -> bool:
    """What HIT found is a name the app picks (APP_NAMES), never a set -C."""
    return not NOCLOBBER.match(hit[3]) and any(hit[3].startswith(p) for p in APP_NAMES)


def unapproved(found, allowlist=ALLOWED) -> list[str]:
    """The hits in FOUND that no entry of ALLOWLIST (each approving one hit) or an app name approves."""
    ok = {id(h) for h in (approves(e, found) for e in allowlist) if h is not None}
    return [f"{h[0]}:{h[1]}: {h[3]} in {h[2][:160]}" for h in found if id(h) not in ok and not app_name(h)]


def scratch_hits(files) -> set[str]:
    """The paths hits() flags in a scratch repository holding FILES ((path, text, is unsafe))."""
    env = dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
    with tempfile.TemporaryDirectory() as tmp:
        subprocess.run(["git", "init", "-q", tmp], check=True, env=env)
        for path, text, _ in files:
            (Path(tmp) / path).parent.mkdir(parents=True, exist_ok=True)
            (Path(tmp) / path).write_text(text)
        subprocess.run(["git", "-C", tmp, "add", "-A"], check=True, env=env)
        return {h[0] for h in hits(Path(tmp))}


class NoclobberSweep(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.found = hits()

    def test_no_noclobber_and_no_guessable_shared_temp_name(self):
        bad = unapproved(self.found)
        self.assertEqual(bad, [], "noclobber is not exclusive creation: use mktemp, a mkdtemp folder of your own, "
                                  "or ~/.cache (this file's docstring); or add the hit to ALLOWED with its reason")

    def test_every_allowance_is_still_used(self):
        approved = {}
        for entry, why in ALLOWED.items():
            with self.subTest(entry=entry):
                self.assertGreater(len(why.strip()), 10)
                hit = approves(entry, self.found)
                self.assertIsNotNone(hit, f"stale allowance: {entry[0]} has no such hit of {entry[1]!r} any more; "
                                          "remove it")
                self.assertNotIn(id(hit), approved, f"{entry} approves the hit {approved.get(id(hit))} approves")
                approved[id(hit)] = entry
        for prefix, why in APP_NAMES.items():
            with self.subTest(prefix=prefix):
                self.assertGreater(len(why.strip()), 10)
                self.assertTrue(any(h[3].startswith(prefix) for h in self.found), f"stale app name {prefix!r}")

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
        """A downstream review, F2: a line with XXXXXX was exempt whole; another, F1: a
        template-shaped redirection target beside a bare mktemp was exempt too (shell parsed by regex)."""
        for line in ('d=$(mktemp -d ".../safe.XXXXXX"); printf secret > /tmp/out.$$',
                     "d=$(mktemp -d) > /tmp/out.$$.XXXXXX", "mktemp /tmp/a.XXXXXX > /tmp/b.$$.XXXXXX",
                     "t=`mktemp -d`; cp x /tmp/y.$$.XXXXXX", "x=$(echo mktemp /tmp/a.$$.XXXXXX)",
                     'd=$(mktemp -d "/tmp/x.$$.XXXXXX',  # unclosed: a line it cannot parse exempts nothing
                     'd=$(mktemp -d "${TMPDIR:-/tmp}/x.XXXXXX") && cp a /tmp/run.$$',
                     "t=$(mktemp /tmp/a.XXXXXX); echo > ${TMPDIR:-/tmp}/b.$(id -u)",
                     # Review of manaflow-ai/cmux#41306, F1: an inner template's span shifted the outer one's; F2: a
                     # whole template word exempted the substitution inside it (shell read by token masking).
                     'mktemp "$(mktemp /tmp/$USER.XXXXXX).XXXXXX"; echo > /tmp/out.$$',
                     'mktemp "/tmp/$(printf secret > /tmp/out.$$)x.XXXXXX"',
                     # Review of upstream #4346, F1: the same overlap with the write on the outer
                     # mktemp; of a downstream review: XXXXXX only inside substitutions made the word a
                     # template, masked whole; of upstream #4346, F2: code() cut the line at a quoted #.
                     'mktemp "$(mktemp /tmp/a.XXXXXX).XXXXXX" > /tmp/out.$$',
                     'mktemp "$(printf /tmp/a.XXXXXX)$(printf secret > /tmp/out.$$)"',
                     "printf '%s' 'foo # bar' > /tmp/out.$$",
                     # Review of manaflow-ai/cmux#41306 (block at 1f84d085): the outer word's template is only inside
                     # its substitution, and the write is on the outer mktemp; an unbalanced ) is not shell, so it
                     # exempts nothing.
                     'mktemp "$(mktemp /tmp/a.XXXXXX)" > /tmp/out.$$', "mktemp /tmp/a.$$.XXXXXX)",
                     # Review of manaflow-ai/cmux#41306 at 7e60a832, F1: an array's words read as a command; of
                     # a downstream review at 0ea8b97f, F1: a process substitution in ${ } read as text.
                     "paths=(mktemp ';' /tmp/out.$$.XXXXXX); printf secret > \"${paths[2]}\"",
                     "mktemp ${TMPDIR:-<(printf secret > /tmp/out.$$)}/x.XXXXXX"):
            self.assertTrue(flagged(code(line)), line)

    def test_the_tree_walk_misses_nothing_in_the_corpus(self):
        """Every unsafe write in shell_tree.corpus() (nesting depth x substitution form x quoting x where the write
        sits) is flagged, and no safe mktemp template is."""
        misses = [(line, unsafe) for line, unsafe in shell_tree.corpus() if flagged(code(line)) != unsafe]
        self.assertEqual(misses, [], "(line, is unsafe) the sweep got wrong")

    def test_the_corpus_is_shell(self):
        self.assertTrue(shutil.which("bash"), "bash is needed to read the corpus; a host without it fails, never skips")
        bad = [line for line, _ in shell_tree.corpus() if line not in shell_tree.NOT_SHELL
               and subprocess.run(["bash", "-n", "-c", line], capture_output=True).returncode != 0]
        # -O extglob: bash -n runs no shopt, and a FILES case turns extglob on (the upstream's extglob rows).
        bad += [path for path, text, _ in shell_tree.FILES if not path.endswith(".yml")
                and subprocess.run(["bash", "-O", "extglob", "-n"], input=text, capture_output=True,
                                   text=True).returncode != 0]
        self.assertEqual(bad, [])

    def test_a_whole_file_is_read_in_context(self):
        """A downstream review at 0ea8b97f, F2: read line by line, a here-document's
        `# $(...)` was a comment, though bash runs the substitution. hits() runs on each of shell_tree.FILES (here-
        documents, continued lines, quotes across lines, case, arrays, a workflow's run block) in a scratch repo."""
        files = shell_tree.FILES
        found = scratch_hits(files)
        self.assertEqual([p for p, _, unsafe in files if (p in found) != unsafe], [], "files the sweep got wrong")

    def test_a_bash_timeout_is_a_named_unavailable_answer(self):
        """manaflow-ai/cmux#41336 review at 911fed64, F1: a bash past its timeout raised TimeoutExpired and stopped
        the sweep. It is the row's own answer, a named OracleUnavailable (falsy, never agreement), and the row's
        processes are stopped."""
        spin = "while :; do :; done"
        started = time.monotonic()
        [late] = shell_tree.bash_verdicts([spin], timeout=1)
        self.assertLess(time.monotonic() - started, 8)
        self.assertIsInstance(late, shell_tree.BashTimeout)
        self.assertFalse(late, "no answer is never read as an answer")
        [message] = shell_tree.no_oracle([spin], [late])
        self.assertIn("no answer from bash", message)
        self.assertIn(spin, message)

    def test_every_oracle_row_is_within_its_budget(self):
        """F1 of the same review: _deep(200) ran bash out of processes. A depth fixture meant for the parser is tree-
        only, with its reason, and has a bash-sized twin bash answers; a row over MAX_BASH_PROCESSES is unavailable,
        never run."""
        corpus = dict(shell_tree.corpus())
        self.assertIn(shell_tree._deep(200), shell_tree.TREE_ONLY)
        for line, why in shell_tree.TREE_ONLY.items():
            with self.subTest(line=line[:60]):
                self.assertIn(line, corpus)
                self.assertGreater(len(why.strip()), 20)
        [wide] = shell_tree.bash_verdicts([shell_tree._deep(200)])
        self.assertIsInstance(wide, shell_tree.OracleUnavailable)
        self.assertIn("MAX_BASH_PROCESSES", wide.reason)
        depth = shell_tree.BASH_TWIN_DEPTH
        self.assertGreaterEqual(depth, 16)
        twins = [shell_tree._deep(depth), shell_tree._deep(depth, "; echo > /tmp/out.$$")]
        self.assertEqual([corpus.get(t) for t in twins], [False, True])
        self.assertEqual(shell_tree.bash_verdicts(twins), [False, True])

    def test_bash_agrees_with_the_tree(self):
        """The differential detector (upstream #4368 review at 3aa1ae3e: the parser kept quoting or
        line state bash does not). Each corpus line and each shell file in FILES is run by bash in a scratch folder
        (shell_tree.bash_verdicts); every one with which bash makes a name no mktemp made must be flagged by the tree
        and called unsafe by the corpus. The other way round is the sweep's design: it flags a guessable name outside a
        template even where bash never writes it (an echo, an array's words, a function never called)."""
        corpus = [c for c in shell_tree.corpus() if c[0] not in shell_tree.TREE_ONLY]
        verdicts = shell_tree.bash_verdicts([line for line, _ in corpus])
        shell = [f for f in shell_tree.FILES if not f[0].endswith(".yml")]
        file_verdicts = shell_tree.bash_verdicts([text for _, text, _ in shell])
        # A row bash gave no answer for (past its time, unable to fork) fails here, with why: UNKNOWN is not a pass.
        self.assertEqual(shell_tree.no_oracle([line for line, _ in corpus], verdicts)
                         + shell_tree.no_oracle([text for _, text, _ in shell], file_verdicts), [],
                         "rows the bash oracle could not answer")
        lines = [c for c, wrote in zip(corpus, verdicts) if wrote is True]
        self.assertEqual([line for line, unsafe in lines if not (unsafe and flagged(code(line)))], [],
                         "lines bash writes a guessable name with, which the tree passes or the corpus calls safe")
        files = [f for f, wrote in zip(shell, file_verdicts) if wrote is True]
        found = scratch_hits(files)
        self.assertEqual([p for p, _, unsafe in files if not (unsafe and p in found)], [],
                         "files bash writes a guessable name with, which hits() passes or FILES calls safe")
        self.assertGreater(len(lines), 300)

    def test_an_allowance_approves_only_its_own_hit(self):
        """A downstream review, F2: an allowance approved its whole line, so an unsafe name on the
        line of an approved one passed. Each hit is matched with its own entry, by its own text."""
        line = 'ssh host "mktemp -d /tmp/$NAME-XXXXXX" && printf s > /tmp/out.$$'
        allowlist = {("scripts/a.sh", '"mktemp -d /tmp/$NAME-XXXXXX"'): "made on the host by mktemp"}
        with tempfile.TemporaryDirectory() as tmp:
            env = dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
            subprocess.run(["git", "init", "-q", tmp], check=True, env=env)
            (Path(tmp) / "scripts").mkdir()
            (Path(tmp) / "scripts/a.sh").write_text(line + "\n")
            subprocess.run(["git", "-C", tmp, "add", "-A"], check=True, env=env)
            found = hits(Path(tmp))
        self.assertEqual(len(unapproved(found, allowlist)), 1, found)
        self.assertEqual(len(unapproved(found, {})), 2, found)

    def test_an_allowance_approves_one_occurrence(self):
        """manaflow-ai/cmux#41336 review at 911fed64, F2: an allowance matched by text approved every hit with the same
        text, so one safe use of a path let every other use of it through, on its line and on others. Each entry is
        keyed by path, piece and occurrence, and approves that one hit."""
        text = ('[[ -L "/tmp/x-$tag" ]] && rm -f "/tmp/x-$tag"\n'
                'printf secret > "/tmp/x-$tag"\n')
        with tempfile.TemporaryDirectory() as tmp:
            env = dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
            subprocess.run(["git", "init", "-q", tmp], check=True, env=env)
            (Path(tmp) / "scripts").mkdir()
            (Path(tmp) / "scripts/a.sh").write_text(text)
            subprocess.run(["git", "-C", tmp, "add", "-A"], check=True, env=env)
            found = hits(Path(tmp))
        self.assertEqual([h[1] for h in found], [1, 1, 2], found)
        one = {("scripts/a.sh", '"/tmp/x-$tag"'): "the -L test reads the link"}
        self.assertEqual(len(unapproved(found, one)), 2, found)
        both = {("scripts/a.sh", '[[ -L "/tmp/x-$tag" ]] && rm -f "/tmp/x-$tag"', 1): "the -L test reads the link",
                ("scripts/a.sh", '[[ -L "/tmp/x-$tag" ]] && rm -f "/tmp/x-$tag"', 2): "rm removes the link"}
        self.assertEqual([u.split(":")[1] for u in unapproved(found, both)], ["2"], found)
        self.assertIsNone(approves(("scripts/a.sh", '"/tmp/x-$tag"', 4), found))

    def own_runs(self) -> list[str]:
        """The scratch folders bash_writes() makes from here on, each the HOME of every process its run starts; at
        cleanup each process whose environment names one (made by mkdtemp, so this test's alone) is killed."""
        roots: list[str] = []
        real = tempfile.mkdtemp

        def mkdtemp(*args, **kwargs):
            got = real(*args, **kwargs)
            if kwargs.get("prefix") == "shell-tree-":
                roots.append(got)
            return got

        def kill_left():
            for pid in left(roots):
                try:
                    os.kill(pid, signal.SIGKILL)
                except OSError:
                    pass

        patcher = mock.patch.object(shell_tree.tempfile, "mkdtemp", mkdtemp)
        patcher.start()
        self.addCleanup(kill_left)
        self.addCleanup(patcher.stop)
        return roots

    def test_a_reaper_that_fails_is_no_answer(self):
        """A review of this copy, F2 (the detector for its class): a reaper that crashed exited 1, and bash_writes()
        read the scratch folder as bash's answer, False, while bash ran on. A reaper that fails, whatever the reason,
        is OracleUnavailable, never True or False, and what it left running is stopped."""
        roots = self.own_runs()
        crash = shell_tree.REAPER.replace("\nwhile reap(False):", "\nraise RuntimeError('injected')\nwhile reap(False):")
        self.assertNotEqual(crash, shell_tree.REAPER)
        with mock.patch.object(shell_tree, "REAPER", crash):
            for text in ("SECONDS=0; while ((SECONDS < 20)); do :; done", ": > /tmp/out.$$; SECONDS=0; "
                         "while ((SECONDS < 20)); do :; done"):
                with self.subTest(text=text):
                    with self.assertRaises(shell_tree.OracleUnavailable) as raised:
                        shell_tree.bash_writes(text, timeout=5)
                    self.assertIn("reaper exited 1", raised.exception.reason)
                    self.assertFalse(raised.exception.skipped)
        self.assertEqual(len(roots), 2)
        self.assertEqual(left(roots), [], "processes of the run outlived it")

    def test_a_reaper_with_no_sigtimedwait_still_answers(self):
        """A review of this copy, F2: macOS has no signal.sigtimedwait, so the reaper crashed on every row there. With
        it taken away, the reaper still waits for every process the run leaves and answers as it does with it."""
        self.own_runs()
        portable = "import signal\ndel signal.sigtimedwait\n" + shell_tree.REAPER
        rows = [(": > /tmp/out.$$", True), ("d=$(mktemp -d /tmp/x.XXXXXX)", False)]
        if os.path.isdir("/proc/self"):  # the child subreaper waits for an orphan (Linux)
            rows.append(("{ x=0; while ((x < 20000)); do ((x++)); done; : > /tmp/late.$$; } & exit 0", True))
        with mock.patch.object(shell_tree, "REAPER", portable):
            for text, wrote in rows:
                with self.subTest(text=text):
                    self.assertIs(shell_tree.bash_writes(text, timeout=10), wrote)

    def test_bash_source_in_a_sourced_file_is_that_file(self):
        """A review of this copy, F1: a test for "0" in the argument took ${BASH_SOURCE[0]} for $0, so a source inside
        a sourced file resolved against the script's folder. $0 is the script's in every file; each BASH_SOURCE form
        is the file being read. lib/b.sh defines mktemp(), b.sh (beside the script) does not: the template is a hit
        only when the source is read as lib/b.sh."""
        use = 'd=$(mktemp -d /tmp/x.$$.XXXXXX)\n'
        here = 'here=$(cd "$(dirname "$0")" && pwd)\n'
        rows = []
        for form in ('"${BASH_SOURCE[0]}"', '"${BASH_SOURCE}"', '"$BASH_SOURCE"'):
            rows.append((f'h2=$(cd "$(dirname {form})" && pwd)\n. "$h2/b.sh"\n', True))
            rows.append((f'. "$(dirname {form})/b.sh"\n', True))
        for form in ('"$0"', "$0", '"${0}"'):
            rows.append((f'h2=$(cd "$(dirname {form})" && pwd)\n. "$h2/b.sh"\n', False))
            rows.append((f'. "$(dirname {form})/b.sh"\n', False))
        with tempfile.TemporaryDirectory() as tmp:
            for n, (lib, hit) in enumerate(rows):
                root = Path(tmp) / str(n)
                files = {"s.sh": here + '. "$here/lib/a.sh"\n' + use, "lib/a.sh": lib, "b.sh": "",
                         "lib/b.sh": "mktemp() { :; }\n"}
                for path, text in files.items():
                    (root / path).parent.mkdir(parents=True, exist_ok=True)
                    (root / path).write_text(text)
                with self.subTest(row=n, lib=lib):
                    scan = "\n".join(shell_tree.scan_file("s.sh", files["s.sh"], root=str(root)))
                    self.assertEqual(bool(SHARED_TMP.search(scan)), hit, scan)

    def test_shell_tree_is_the_shared_copy(self):
        """shell_tree.py is vendored byte for byte from a pinned upstream blob (its docstring); this pin is its
        SHA-256."""
        digest = hashlib.sha256(Path(shell_tree.__file__).read_bytes()).hexdigest()
        self.assertEqual(digest, SHELL_TREE_SHA256, "shell_tree.py was edited here: change it upstream, then copy "
                         "the blob byte for byte and update this pin")

    def test_an_app_name_excuses_only_app_names(self):
        self.assertTrue(app_named('sock="/tmp/cmux-debug-$tag.sock"'))
        self.assertFalse(app_named('cp "/tmp/cmux-debug-$tag.log" "/tmp/mine-$$.log"'))
        self.assertFalse(app_named('f=/tmp/out.$$'))


def left(roots: list[str]) -> list[int]:
    """The pids of live (not zombie) processes whose environment has HOME set to one of ROOTS (Linux: /proc)."""
    marks = [b"HOME=" + r.encode() + b"\0" for r in roots]
    out = []
    for d in os.listdir("/proc") if marks and os.path.isdir("/proc/self") else ():
        try:
            with open(f"/proc/{d}/environ", "rb") as f:
                env = f.read()
            with open(f"/proc/{d}/stat") as f:
                state = f.read().rsplit(")", 1)[1].split()[0]
        except (OSError, IndexError):
            continue
        if state != "Z" and any(m in env for m in marks):
            out.append(int(d))
    return out


if __name__ == "__main__":
    unittest.main()
