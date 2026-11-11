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
reason, keyed by path and a piece of its line holding what the hit found (it approves that hit, never another
on its line); an entry nothing matches fails, so the list only shrinks.
"""
from __future__ import annotations

import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
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
    # Shell blocks shell_tree cannot parse (shell_tree.unparsed), each reported by its first line: none is bash.
    (".github/workflows/cmux-tui-build-package.yml",
     "pwsh -NoProfile -File cmux-tui/scripts/smoke-windows-install-key-handoff.ps1 `"):
        "a run block of a `shell: pwsh` step: PowerShell, which this lint does not read; it names no shared temp path",
    (".github/workflows/cmux-tui.yml", "$ErrorActionPreference = 'Stop'"):
        "the first line of each of two `shell: pwsh` run blocks: PowerShell, which this lint does not read; their "
        "folders are C:\\ paths on a throwaway Windows runner",
    ("scripts/server-release/install.sh.in", "#!/bin/sh"):
        "a template: @@KEYS@@ and @@UNIX_CASES@@ are filled in at release time, so the file is shell only once "
        "generated; its fixed text names no shared temp path",
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


# A mktemp template word is found in the line's parse tree (shell_tree.py beside this file, the same bytes in
# manaflow-ai/cmux, manaflow-ai/cmux-platform, manaflow-ai/cmuxterm-hq and teamleaderleo/leo-workspace). Shell read by
# regex, then by token masking, let a guessable name through three times, and a comment cut at any # once more
# (shell_tree.MISSES): a line with XXXXXX was exempt whole; a redirection's target was taken for mktemp's argument;
# overlapping template spans shifted each other, and a template word exempted the substitutions inside it. Now only the
# literal text of a mktemp argument with XXXXXX in that literal text is left out. Each command substitution inside the
# word is still scanned, and so is every redirection. A line the parser cannot read exempts nothing and keeps its #s.
# shell_tree.corpus() is the detector's own check: every unsafe write in it is flagged and no safe template is.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import shell_tree  # noqa: E402

SHELL_TREE_PIN = Path(__file__).resolve().parent / "shell_tree.pin"


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


def hits(root: Path = ROOT) -> list[tuple[str, int, str, str, int]]:
    """(path, line number, the line, what was found, its offset in the line): one hit per set -C or guessable name,
    each with its own text and place, so an allowance approves that hit and no other on its line."""
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
            out.append((path, 1, first, first, 0))
        # A shell block shell_tree cannot parse is a hit of its own, its first line: what it runs is unknown, and its
        # raw text is scanned besides, never read line by line (manaflow-ai/cmux-platform#1271 review, F2).
        text_lines = text.split("\n")
        for n in shell_tree.unparsed(path, text):
            first = text_lines[n - 1]
            out.append((path, n, first, first.strip(), len(first) - len(first.lstrip())))
        # The file is read whole where it is shell (shell_tree.scan_file), so a here-document, a continued line or
        # a quote across lines keeps its context; the hit keeps the line's own text.
        for n, (line, scan) in enumerate(zip(text.split("\n"), shell_tree.scan_file(path, text)), 1):
            for m in [*NOCLOBBER.finditer(scan), *SHARED_TMP.finditer(scan)]:
                out.append((path, n, line, m.group(0), m.start()))
    return out


def approves(entry: tuple[str, str], hit: tuple[str, int, str, str, int]) -> bool:
    """Whether the allowance ENTRY ((path, a piece of the line)) is HIT's own: the piece is on its line at a place
    that covers the hit's span, never only beside it, and never another hit with the same text (review of
    manaflow-ai/cmux#41336 at c1c62c86, F1)."""
    (path, piece), (p, _, line, found, at) = entry, hit
    starts = [i for i in range(len(line)) if line.startswith(piece, i)]
    return p == path and any(i <= at and at + len(found) <= i + len(piece) for i in starts)


def allowed(hit: tuple[str, int, str, str, int], allowlist=ALLOWED) -> bool:
    """An allowance approves HIT, or what it found is a name the app picks (APP_NAMES), never a set -C."""
    found = hit[3]
    return any(approves(e, hit) for e in allowlist) or (
        not NOCLOBBER.match(found) and any(found.startswith(p) for p in APP_NAMES))


def unapproved(found, allowlist=ALLOWED) -> list[str]:
    """The hits in FOUND that no entry of ALLOWLIST (or an app name) approves."""
    return [f"{h[0]}:{h[1]}: {h[3]} in {h[2].strip()[:160]}" for h in found if not allowed(h, allowlist)]


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


def mktemp_names() -> set[str]:
    """The names in /tmp (and $TMPDIR) owned by this user that mktemp's default template (tmp.XXXXXXXXXX) makes."""
    out = set()
    for folder in {"/tmp", os.environ.get("TMPDIR") or "/tmp"}:
        try:
            with os.scandir(folder) as entries:
                out |= {e.path for e in entries if re.fullmatch(r"tmp\.[A-Za-z0-9]{10}", e.name)
                        and e.stat(follow_symlinks=False).st_uid == os.getuid()}
        except OSError:
            continue
    return out


class NoclobberSweep(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.found = hits()

    def test_no_noclobber_and_no_guessable_shared_temp_name(self):
        bad = unapproved(self.found)
        self.assertEqual(bad, [], "noclobber is not exclusive creation: use mktemp, a mkdtemp folder of your own, "
                                  "or ~/.cache (this file's docstring); or add the hit to ALLOWED with its reason")

    def test_every_allowance_is_still_used(self):
        for (path, piece), why in ALLOWED.items():
            with self.subTest(path=path, piece=piece):
                self.assertGreater(len(why.strip()), 10)
                self.assertTrue(any(approves((path, piece), h) for h in self.found),
                                f"stale allowance: no line of {path} has {piece!r} any more; remove it")
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
        """Review of manaflow-ai/cmux-platform#1262, F2: a line with XXXXXX was exempt whole; of #1265, F1: a
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
                     # Review of teamleaderleo/leo-workspace#4346, F1: the same overlap with the write on the outer
                     # mktemp; of manaflow-ai/cmuxterm-hq#9338: XXXXXX only inside substitutions made the word a
                     # template, masked whole; of leo-workspace#4346, F2: code() cut the line at a quoted #.
                     'mktemp "$(mktemp /tmp/a.XXXXXX).XXXXXX" > /tmp/out.$$',
                     'mktemp "$(printf /tmp/a.XXXXXX)$(printf secret > /tmp/out.$$)"',
                     "printf '%s' 'foo # bar' > /tmp/out.$$",
                     # Review of manaflow-ai/cmux#41306 (block at 1f84d085): the outer word's template is only inside
                     # its substitution, and the write is on the outer mktemp; an unbalanced ) is not shell, so it
                     # exempts nothing.
                     'mktemp "$(mktemp /tmp/a.XXXXXX)" > /tmp/out.$$', "mktemp /tmp/a.$$.XXXXXX)",
                     # Review of manaflow-ai/cmux#41306 at 7e60a832, F1: an array's words read as a command; of
                     # manaflow-ai/cmuxterm-hq#9338 at 0ea8b97f, F1: a process substitution in ${ } read as text.
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
        # -O extglob: bash -n runs no shopt, and a FILES case turns extglob on (manaflow-ai/cmux-platform#1271, F2)
        bad += [path for path, text, _ in shell_tree.FILES if not path.endswith(".yml")
                and subprocess.run(["bash", "-O", "extglob", "-n"], input=text, capture_output=True,
                                   text=True).returncode != 0]
        self.assertEqual(bad, [])

    def test_a_whole_file_is_read_in_context(self):
        """Review of manaflow-ai/cmuxterm-hq#9338 at 0ea8b97f, F2: read line by line, a here-document's
        `# $(...)` was a comment, though bash runs the substitution. hits() runs on each of shell_tree.FILES (here-
        documents, continued lines, quotes across lines, case, arrays, a workflow's run block) in a scratch repo."""
        files = shell_tree.FILES
        found = scratch_hits(files)
        self.assertEqual([p for p, _, unsafe in files if (p in found) != unsafe], [], "files the sweep got wrong")

    def test_bash_agrees_with_the_tree(self):
        """The differential detector (teamleaderleo/leo-workspace#4368 review at 3aa1ae3e: the parser kept quoting or
        line state bash does not). Each corpus line and each shell file in FILES is run by bash in a scratch folder
        (shell_tree.bash_verdicts); every one with which bash makes a name no mktemp made must be flagged by the tree
        and called unsafe by the corpus. The other way round is the sweep's design: it flags a guessable name outside a
        template even where bash never writes it (an echo, an array's words, a function never called)."""
        corpus = shell_tree.corpus()
        before = mktemp_names()
        lines = [c for c, wrote in zip(corpus, shell_tree.bash_verdicts([line for line, _ in corpus])) if wrote]
        self.assertEqual([line for line, unsafe in lines if not (unsafe and flagged(code(line)))], [],
                         "lines bash writes a guessable name with, which the tree passes or the corpus calls safe")
        shell = [f for f in shell_tree.FILES if not f[0].endswith(".yml")]
        files = [f for f, wrote in zip(shell, shell_tree.bash_verdicts([text for _, text, _ in shell])) if wrote]
        found = scratch_hits(files)
        self.assertEqual([p for p, _, unsafe in files if not (unsafe and p in found)], [],
                         "files bash writes a guessable name with, which hits() passes or FILES calls safe")
        self.assertGreater(len(lines), 300)
        # teamleaderleo/leo-workspace#4368 review at cfd7897e, F4: env -i mktemp found the real mktemp on the default
        # PATH and made its name in the real temp folder. No fixture may reach it.
        self.assertEqual(sorted(mktemp_names() - before), [], "a fixture's mktemp made a name in the real temp folder")

    def test_an_allowance_approves_only_its_own_hit(self):
        """Review of manaflow-ai/cmuxterm-hq#9370, F2: an allowance approved its whole line, so an unsafe name on the
        line of an approved one passed. Each hit is matched with its own entry, by its own text."""
        line = 'ssh host "mktemp -d /tmp/$NAME-XXXXXX" && printf s > /tmp/out.$$'
        # manaflow-ai/cmux#41336 review at c1c62c86, F1: matched by text, the template's allowance also approved a
        # second hit with the same text; an allowance approves only the hit at an offset inside its piece.
        same = 'ssh host "mktemp -d /tmp/$NAME-XXXXXX" && printf secret > /tmp/$NAME-unsafe'
        allowlist = {("scripts/a.sh", '"mktemp -d /tmp/$NAME-XXXXXX"'): "made on the host by mktemp"}
        with tempfile.TemporaryDirectory() as tmp:
            env = dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
            subprocess.run(["git", "init", "-q", tmp], check=True, env=env)
            (Path(tmp) / "scripts").mkdir()
            (Path(tmp) / "scripts/a.sh").write_text(line + "\n" + same + "\n")
            subprocess.run(["git", "-C", tmp, "add", "-A"], check=True, env=env)
            found = hits(Path(tmp))
        left = unapproved(found, allowlist)
        self.assertEqual([h.split(":")[1] for h in left], ["1", "2"], found)
        self.assertEqual(len(unapproved(found, {})), 4, found)

    def test_bash_runs_within_a_fixed_process_count(self):
        """Review of manaflow-ai/cmuxterm-hq#9395 at 064f2c7c: bash holds one live process per level of nested
        substitutions, so _deep(200) wants 200 at once, and a host near its process limit makes bash's fork retry and
        back off past the time budget. A fixture over MAX_BASH_PROCESSES is never run by bash (the tree alone reads
        it); the rest run with each one's process count bounded, and the count grows by one per level."""
        stats = {}
        self.assertIsNone(shell_tree.bash_writes(shell_tree._deep(200), stats=stats))
        self.assertEqual(stats, {"runs": 0, "peak": 0})
        self.assertTrue(flagged(code(shell_tree._deep(200))), "the tree flags what bash is never asked about")
        self.assertLessEqual(shell_tree.bash_processes(shell_tree._deep(shell_tree.MAX_DEPTH)),
                             shell_tree.MAX_BASH_PROCESSES)
        if not os.path.exists("/proc/self/stat"):
            self.skipTest("counting a session's processes reads /proc")
        peaks = {}
        for depth in (8, shell_tree.MAX_DEPTH):
            stats = {}
            self.assertFalse(shell_tree.bash_writes(shell_tree._deep(depth), timeout=5, stats=stats))
            self.assertEqual(stats["runs"], 1)
            self.assertLessEqual(stats["peak"], shell_tree.bash_processes(shell_tree._deep(depth)))
            peaks[depth] = stats["peak"]
        self.assertEqual(peaks[shell_tree.MAX_DEPTH] - peaks[8], shell_tree.MAX_DEPTH - 8, peaks)

    def test_a_bash_past_its_time_is_killed_with_its_group_and_named(self):
        """Review of manaflow-ai/cmuxterm-hq#9395 at 064f2c7c: TimeoutExpired escaped bash_writes(). Past its time
        the whole process group bash started is killed, and the error names the fixture."""
        text = "(while :; do :; done) & while :; do :; done"
        with self.assertRaises(shell_tree.BashTimeout) as raised:
            shell_tree.bash_writes(text, timeout=0.5)
        self.assertIn(text, str(raised.exception))
        group = raised.exception.pgid
        alive = []
        for stat in Path("/proc").glob("[0-9]*/stat") if os.path.exists("/proc/self/stat") else ():
            try:
                fields = stat.read_text().rsplit(") ", 1)[1].split()
            except (OSError, IndexError):
                continue
            if int(fields[2]) == group and fields[0] != "Z":
                alive.append(stat.parent.name)
        self.assertEqual(alive, [], "processes of the killed group still run")

    def test_a_quoted_env_split_shebang_is_shell(self):
        """Review of manaflow-ai/cmux#41336 at c1c62c86, F2: `#!/usr/bin/env -S 'bash' -e` read as another program,
        so the here-document's substitution was missed. env's -S string is split as env splits it, quotes included."""
        body = "\ncat <<EOF\n# $(printf s > /tmp/out.$$)\nEOF\n"
        files = [("scripts/q", "#!/usr/bin/env -S 'bash' -e" + body, True),
                 ("scripts/qq", '#!/usr/bin/env -S "bash" -e' + body, True)]
        self.assertEqual(scratch_hits(files), {"scripts/q", "scripts/qq"})

    def test_an_assignment_word_is_read_where_bash_reads_it(self):
        """Review of #4382 at 311cf8e9, F1, and of manaflow-ai/cmuxterm-hq#9393 at 52412c22, F1 and F2: a NAME=value
        word sets NAME or names the command by where it sits. Each row of shell_tree.ASSIGNMENT_WORDS is what the tree
        reads and what bash does: `cmd` prints the X names in its environment."""
        bindir = tempfile.mkdtemp(prefix="assign-")
        try:
            with open(os.path.join(bindir, "cmd"), "w") as f:
                f.write("#!/bin/sh\nexec env\n")
            os.chmod(os.path.join(bindir, "cmd"), 0o700)
            for text, want in shell_tree.ASSIGNMENT_WORDS:
                with self.subTest(text=text):
                    self.assertEqual(shell_tree.assigned_names(text), want, "the tree")
                    run = subprocess.run([shutil.which("bash"), "--noprofile", "--norc", "-c", text],
                                         env={"PATH": bindir + ":/usr/bin:/bin"}, stdin=subprocess.DEVNULL,
                                         capture_output=True, text=True, timeout=30)
                    got = sorted(re.findall(r"(?m)^(X\w*)=", run.stdout))
                    named = sorted(n for n in want if n != "?")
                    self.assertEqual(len(got), len(want), f"bash set {got}")
                    self.assertTrue(set(named) <= set(got), f"bash set {got}")
        finally:
            shutil.rmtree(bindir, ignore_errors=True)

    def test_a_setsid_child_is_killed_at_the_deadline(self):
        """Review of manaflow-ai/cmuxterm-hq#9393 at 52412c22, F3: a setsid child left bash's process group, so the
        group kill missed it and the run waited for it. Every process the run leaves is killed at the deadline."""
        started = time.monotonic()
        with self.assertRaises(shell_tree.BashTimeout):
            shell_tree.bash_writes("setsid /bin/sleep 2", timeout=0.2)
        self.assertLess(time.monotonic() - started, 0.5)

    def test_a_mktemp_by_its_path_never_reaches_the_real_temp_folder(self):
        """Review of manaflow-ai/cmuxterm-hq#9393 at 52412c22, F4: /usr/bin/mktemp ran the real mktemp, which made
        its name in the real /tmp. Each mktemp is the fake, and TMPDIR is the run's own folder besides."""
        before = mktemp_names()
        for text in ("/usr/bin/mktemp", "d=$(env -i /usr/bin/mktemp -d)", "m=/usr/bin/mktemp; $m"):
            with self.subTest(text=text):
                self.assertIs(shell_tree.bash_writes(text), False)
        # Another process of this user may make a name there meanwhile; a name is never removed here, since which
        # process made it cannot be told.
        self.assertEqual(mktemp_names() - before, set())

    def test_a_shell_inside_a_shell_runs(self):
        """Review of manaflow-ai/cmux-platform#1274, F1: the scratch PATH had no bash and no sh, so a shell inside a
        shell failed before it ran, and bash could not check the tree there."""
        for text in ("env -S \"bash -c 'printf x > /tmp/out.$$'\"", "sh -c 'printf x > /tmp/out.$$'"):
            with self.subTest(text=text):
                self.assertIs(shell_tree.bash_writes(text), True)

    def test_shell_tree_is_the_pinned_copy(self):
        """shell_tree.py is vendored from teamleaderleo/leo-workspace tools/shell_tree.py, byte for byte, at the commit
        shell_tree.pin names; leo-workspace's VendoredCopies test checks it against that commit."""
        pin = dict(kv.split("=", 1) for kv in SHELL_TREE_PIN.read_text().split())
        self.assertRegex(pin.get("leo-workspace", ""), r"^[0-9a-f]{40}$")
        digest = hashlib.sha256(Path(shell_tree.__file__).read_bytes()).hexdigest()
        self.assertEqual(digest, pin.get("sha256"), "shell_tree.py was edited here: change leo-workspace "
                         "tools/shell_tree.py, then copy it here and its commit and sha256 into shell_tree.pin")

    def test_an_app_name_excuses_only_app_names(self):
        self.assertTrue(app_named('sock="/tmp/cmux-debug-$tag.sock"'))
        self.assertFalse(app_named('cp "/tmp/cmux-debug-$tag.log" "/tmp/mine-$$.log"'))
        self.assertFalse(app_named('f=/tmp/out.$$'))


if __name__ == "__main__":
    unittest.main()
