#!/usr/bin/env python3
"""Every network fetch the nightly-next-one job runs has its own bound, and the ones that fail it retry.

Nightly run 44232805509 (2026-11-18), step "Assemble the Computer Use helper": a cmux-cua
`git clone` stalled from 04:00:23 to 04:09:49Z, then died with `RPC failed; curl 56`, and the
whole nightly died with it. A git transfer or a curl download with no bound of its own waits on
the job's budget. #45916 bounded that clone; this checks the class across the job:

- every `curl` in a step's run block, in a script a step runs, or in a script that script names,
  carries `--max-time` (`-m`);
- every remote `git fetch`/`clone`/`ls-remote`/`pull`/`submodule update` there runs with a
  low-speed abort (`http.lowSpeedLimit`/`GIT_HTTP_LOW_SPEED_*`, on the line or exported by the
  script), under `net_retry` (scripts/cmux-next/lib/origin-net.sh, which sets one), under
  scripts/ci/git_fetch_retry.py, or under a `timeout`;
- every Python `urlopen(` passes `timeout=`.

It also runs the two retried paths against a fake git whose first fetch dies the way run
44232805509's did, and checks the second try lands with the low-speed abort set.
"""
from __future__ import annotations

import os
import re
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
NIGHTLY = ROOT / ".github/workflows/nightly.yml"
JOB = "nightly-next-one"

# Fetches that read no network, or are bounded in a way the scan cannot see, with why.
EXEMPT = {
    # Fetches from the host's own build-root clone on local disk, not from a remote.
    ("scripts/ci/nightly-steps/app-host-build-root.sh", "fetch"),
    # curl_args, built just above the call, carry --max-time and --speed-limit/--speed-time.
    ("scripts/install-cmux-tui-client.sh", "curl"),
}

SCRIPT_REF = re.compile(r"(?:\$PUBLISH_TOOLING/|\.publish-tooling/scripts/|\./)?((?:scripts/)?[A-Za-z0-9_./-]+\.(?:sh|py))")
LIB_DIRS = ("scripts/", "scripts/ci/", "scripts/ci/nightly-steps/", "scripts/lib/", "scripts/cmux-next/")
# Text before a word that puts the word in command position.
COMMAND_START = re.compile(r"(?:^|\$\(|`|[|;&({!]|\bif|\bthen|\bdo|\belse|\bexec|\bnet_retry\s+\"[^\"]*\"|\bnet_retry\s+'[^']*'"
                           r"|(?:\b[A-Z_][A-Z0-9_]*=\S*\s+)+|\btimeout(?:\.sh)?\s+\S+|\\)\s*$")
# curl followed by an option, a quoted or expanded word: not "curl exit 56" in a message.
CURL = re.compile(r"(?<![\w./-])curl(?=\s+[-\"'$])")
GIT_NET = re.compile(r"(?<![\w./-])git(?:\s+(?:-c\s+\S+|-C\s+\S+|--git-dir[= ]\S+|--work-tree[= ]\S+))*\s+"
                     r"(fetch|clone|ls-remote|pull|submodule\s+update)\b")
# git applies a low-speed abort only when both the limit and the time are set.
LOW_SPEED = re.compile(r"http\.lowSpeedLimit=\S+.*http\.lowSpeedTime=|GIT_HTTP_LOW_SPEED_LIMIT=\S+.*GIT_HTTP_LOW_SPEED_TIME="
                       r"|git_fetch_retry|\bnet_retry\b|\btimeout(?:\.sh)?\s+\S+\s")
FILE_LOW_SPEED = re.compile(r"^export GIT_HTTP_LOW_SPEED_LIMIT=\S+ GIT_HTTP_LOW_SPEED_TIME=", re.MULTILINE)
GH_DOWNLOAD = re.compile(r"(?<![\w./-])gh\s+release\s+download\b")
# The end of one command on a logical line: a pipe, a list operator or a semicolon.
COMMAND_END = re.compile(r"\s(?:\|\|?|&&|;)\s")


def job_steps() -> list[dict]:
    return yaml.safe_load(NIGHTLY.read_text())["jobs"][JOB]["steps"]


def strip_comments(text: str) -> str:
    return "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("#"))


def script_refs(text: str) -> set[str]:
    found = set()
    for match in SCRIPT_REF.finditer(text):
        path = match.group(0).replace("$PUBLISH_TOOLING/", "scripts/").replace(".publish-tooling/scripts/", "scripts/")
        path = path.removeprefix("./")
        if not path.startswith("scripts/"):
            path = next((base + path for base in LIB_DIRS if (ROOT / (base + path)).is_file()), path)
        if (ROOT / path).is_file():
            found.add(path)
    return found


def job_sources() -> dict[str, str]:
    """{name: text} for each step's run block, each script a step runs, and each script those name."""
    sources = {f"nightly.yml {JOB} step {step.get('name', i)!r}": step["run"]
               for i, step in enumerate(job_steps(), 1) if step.get("run")}
    level0 = set().union(*(script_refs(text) for text in sources.values()))
    level1 = set().union(*(script_refs(strip_comments((ROOT / path).read_text(errors="replace"))) for path in level0))
    for path in sorted(level0 | level1):
        sources[path] = (ROOT / path).read_text(errors="replace")
    return sources


def logical_lines(text: str):
    """(first line number, line) with backslash continuations joined and comment lines dropped."""
    pending, start = "", 0
    for number, line in enumerate(text.splitlines(), 1):
        if not pending and line.lstrip().startswith("#"):
            continue
        if not pending:
            start = number
        if line.endswith("\\"):
            pending += line[:-1] + " "
            continue
        yield start, pending + line
        pending = ""
    if pending:
        yield start, pending


def in_command_position(line: str, at: int) -> bool:
    return COMMAND_START.search(line[:at]) is not None


def unbounded(name: str, text: str) -> list[str]:
    problems = []
    is_python = name.endswith(".py")
    file_bound = bool(FILE_LOW_SPEED.search(text))
    for number, line in logical_lines(text):
        where = f"{name}:{number}: {line.strip()[:160]}"
        if is_python:
            if "urlopen(" in line and "timeout" not in line:
                problems.append(f"urlopen without timeout= ({where})")
            continue
        for match in CURL.finditer(line):
            if (name, "curl") in EXEMPT:
                continue
            # The bound must be on this curl, not on another command of the same line.
            end = COMMAND_END.search(line, match.end())
            command = line[match.start():end.start() if end else len(line)]
            if in_command_position(line, match.start()) and not re.search(r"--max-time\b|\s-m\s", command):
                problems.append(f"curl without --max-time ({where})")
        for match in GH_DOWNLOAD.finditer(line):
            if in_command_position(line, match.start()) and not LOW_SPEED.search(line[:match.start()]):
                problems.append(f"gh release download without a time limit ({where})")
        for match in GIT_NET.finditer(line):
            if (name, match.group(1)) in EXEMPT or not in_command_position(line, match.start()):
                continue
            if not (file_bound or LOW_SPEED.search(line)):
                problems.append(f"git {match.group(1)} without a low-speed abort or time limit ({where})")
    return problems


def write_executable(path: Path, text: str) -> None:
    path.write_text(text)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


# A git whose first `fetch` dies like run 44232805509's clone; it logs each fetch and the
# low-speed abort it ran with. Everything else answers as a shallow clone that has the history.
FAKE_GIT = """#!/usr/bin/env bash
log="$FAKE_GIT_LOG"
for arg in "$@"; do
  case "$arg" in
    fetch)
      echo "fetch limit=${GIT_HTTP_LOW_SPEED_LIMIT:-} time=${GIT_HTTP_LOW_SPEED_TIME:-} args=$*" >> "$log"
      if [[ ! -e "$log.failed" ]]; then
        : > "$log.failed"
        echo "error: RPC failed; curl 56 Recv failure: Connection reset by peer" >&2
        echo "fatal: early EOF" >&2
        exit 128
      fi
      exit 0 ;;
    --is-shallow-repository) echo true; exit 0 ;;
    merge-base|ls-remote) exit 0 ;;
  esac
done
exit 0
"""


class NightlyNextNetworkBoundsTest(unittest.TestCase):
    def test_the_scan_reaches_the_steps_that_fetch(self):
        sources = job_sources()
        for path in ("scripts/cmux-next/fetch-release-notes-span.sh", "scripts/cmux-next/ensure-cef.sh"):
            self.assertIn(path, sources)

    def test_every_fetch_on_the_job_path_is_bounded(self):
        problems = [problem for name, text in job_sources().items() for problem in unbounded(name, text)]
        self.assertEqual(problems, [], "\n".join(problems))

    def test_the_scan_flags_an_unbounded_clone_and_download(self):
        bad = 'git clone https://github.com/manaflow-ai/cmux-cua.git "$dir"\nbody="$(curl -fsSL "$url")"\n'
        self.assertEqual(len(unbounded("x.sh", bad)), 2)
        # A bound on a neighbour, half a low-speed pair, or a gh download with no limit is no bound.
        also_bad = ('curl -fsSL "$a" -o a && curl -fsSL --max-time 9 "$b"\n'
                    'git -c http.lowSpeedLimit=1000 fetch origin "$sha"\n'
                    'gh release download "$tag" --repo "$repo" --dir "$tmp"\n')
        self.assertEqual(len(unbounded("x.sh", also_bad)), 3, unbounded("x.sh", also_bad))
        good = ('GIT_HTTP_LOW_SPEED_LIMIT=1000 GIT_HTTP_LOW_SPEED_TIME=60 git clone "$u" "$d"\n'
                'curl -fsSL --max-time 60 \\\n  "$url"\necho "install it: curl -fsSL https://x | sh"\n')
        self.assertEqual(unbounded("x.sh", good), [])

    def run_with_fake_git(self, command: list[str]) -> tuple[subprocess.CompletedProcess, list[str]]:
        with tempfile.TemporaryDirectory() as tmp:
            bin_dir = Path(tmp) / "bin"
            bin_dir.mkdir()
            write_executable(bin_dir / "git", FAKE_GIT)
            log = Path(tmp) / "git.log"
            log.touch()
            env = {**os.environ, "PATH": f"{bin_dir}:{os.environ['PATH']}", "FAKE_GIT_LOG": str(log),
                   "ORIGIN_NET_SLEEP_S": "0"}
            for name in ("GIT_HTTP_LOW_SPEED_LIMIT", "GIT_HTTP_LOW_SPEED_TIME"):
                env.pop(name, None)
            result = subprocess.run(command, cwd=ROOT, env=env, capture_output=True, text=True, timeout=60)
            return result, log.read_text().splitlines()

    def test_release_notes_span_retries_a_stalled_fetch(self):
        # publish-prepare-release-notes.sh runs this on every nightly-next publish.
        result, fetches = self.run_with_fake_git(
            ["bash", "scripts/cmux-next/fetch-release-notes-span.sh", "origin", "a" * 40, "nightly-next", "b" * 40])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertGreaterEqual(len(fetches), 2, fetches)
        for line in fetches:
            self.assertIn("limit=1 time=120", line)

    def test_net_retry_ends_a_stalled_git_transfer_and_retries(self):
        # scripts/cmux-next/generate-third-party-notices.sh fetches cmux-cua through net_retry.
        result, fetches = self.run_with_fake_git(
            ["bash", "-c", 'source scripts/cmux-next/lib/origin-net.sh; '
                           'net_retry "fetch cmux-cua" git fetch --depth 1 origin "$0"', "c" * 40])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(fetches), 2, fetches)
        for line in fetches:
            self.assertIn("limit=1 time=120", line)


if __name__ == "__main__":
    unittest.main()
