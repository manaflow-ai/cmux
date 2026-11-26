#!/usr/bin/env python3
"""Conformance vectors for the chief's memory: run OptMem's reference `memo`
(github.com/VictorTaelin/OptMem, not vendored: it has no license) on seeded
command sequences and record every command's stdout, stderr and exit code.
test/memory-conformance.test.ts replays them against src/memory.

  OPTMEM_MEMO=/path/to/OptMem/memo python3 conformance/generate.py

The reference is used only as an oracle. Its commit is recorded in the output.
"""

import contextlib
import gzip
import datetime as real_datetime
import importlib.machinery
import importlib.util
import io
import json
import os
import random
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "memory-vectors.json.gz")
# (seed, steps, deep): deep sequences keep naps current and grow large trees.
PROFILES = [(seed, 260, False) for seed in range(8)] + [(seed, 3000, True) for seed in range(100, 102)]

WORDS = ("chief spawn worker deploy staging Lawrence Austin decided prefers "
         "dark mode PR merged failed retry cmux Home memory café naïve → "
         "日本 test build fleet mini laptop invoice api route bug fixed "
         "tuesday 42 2026 alpha beta").split()
PATTERNS = ["chief", "^#1", "café", "a.c", "(deploy|merge)", "[0-9]{2}", "日本",
            "zzz-no-match", "Lawrence", "→", "^#[0-9]+ 2026-10-0[12]"]


def load(path):
    loader = importlib.machinery.SourceFileLoader("memo", path)
    spec = importlib.util.spec_from_loader("memo", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


class Clock:
    """Stands in for the module's `datetime`: today() is the step's date."""
    def __init__(self):
        self.today = "2026-10-01"
        clock = self

        class _Date:
            @staticmethod
            def today():
                return real_datetime.date.fromisoformat(clock.today)

        self.date = _Date
        self.datetime = real_datetime.datetime


def run(memo, clock, argv):
    for k, (default, _) in memo.KNOBS.items():
        setattr(memo, k, default)  # a fresh process per command, as in real use
    out, err = io.StringIO(), io.StringIO()
    code = 0
    old = sys.argv
    sys.argv = ["memo"] + argv
    try:
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            memo.main()
    except SystemExit as e:
        code = e.code if isinstance(e.code, int) else (0 if e.code is None else 1)
    finally:
        sys.argv = old
    return out.getvalue(), err.getvalue(), code


def text(rng, limit=None):
    roll = rng.random()
    if roll < 0.03:
        return "   "
    if roll < 0.06:
        return "line one\nline two"
    if roll < 0.09:
        return "é" * 150  # 300 bytes
    n = rng.randint(1, 18)
    s = " ".join(rng.choice(WORDS) for _ in range(n))
    if limit:
        while len(s.encode()) > limit:
            s = s[:-1]
    return s


def block_of(rng, T):
    size = 2 ** rng.randint(1, max(1, (max(T, 2)).bit_length()))
    k = rng.randint(0, max(0, (T + size) // size))
    return "%d-%d" % (k * size, k * size + size - 1)


def settled_block(memo, rng, d, T):
    """A block that has a summary, so forget succeeds."""
    levels = []
    size = 2
    while size <= T:
        n = memo.count(memo.tree_path(d, size), memo.TREE_REC)
        if n:
            levels.append((size, n))
        size *= 2
    if not levels:
        return block_of(rng, T)
    size, n = rng.choice(levels)
    k = rng.randrange(n)
    return "%d-%d" % (k * size, k * size + size - 1)


def deep_step(memo, rng, d, clock):
    T = memo.log_len(d)
    todo = memo.pending(d, T, limit=1)
    r = rng.random()
    if todo and r < 0.5:
        lo, hi = todo[0]
        return ["nap", "%d-%d" % (lo, hi - 1), text(rng, limit=280)], None
    if r < 0.85:
        return ["note", text(rng, limit=280)], None
    if r < 0.93:
        return ["wake"] if rng.random() < 0.8 else ["wake", "2"], None
    if r < 0.96:
        return ["zoom", settled_block(memo, rng, d, T)], None
    if r < 0.975:
        return ["forget", settled_block(memo, rng, d, T)], None
    if r < 0.99:
        return ["recall", rng.choice(PATTERNS)], None
    return ["config", "WAKE_LINES=%d" % rng.randint(6, 40)], None


def step(memo, rng, d, clock):
    T = memo.log_len(d)
    r = rng.random()
    if rng.random() < 0.04:
        y, m, dd = map(int, clock.today.split("-"))
        clock.today = (real_datetime.date(y, m, dd) + real_datetime.timedelta(days=rng.randint(1, 3))).isoformat()
    if r < 0.42:
        return ["note", text(rng)], None
    if r < 0.62:
        todo = memo.pending(d, T, limit=1)
        if todo and rng.random() < 0.85:
            lo, hi = todo[0]
            return ["nap", "%d-%d" % (lo, hi - 1), text(rng, limit=None if rng.random() < 0.05 else 280)], None
        choice = rng.random()
        if choice < 0.3:
            return ["nap"], None
        if choice < 0.6:
            return ["nap", block_of(rng, T), "summary"], None
        return ["nap", rng.choice(["3-4", "x-y", "0-0", "5"]), "summary"], None
    if r < 0.74:
        roll = rng.random()
        if roll < 0.7:
            return ["wake"], None
        if roll < 0.85:
            return ["wake", str(rng.randint(0, 3))], None
        return ["wake", str(rng.randint(1, 3)), str(rng.randint(0, T + 2))], None
    if r < 0.82:
        return ["zoom", block_of(rng, T) if rng.random() < 0.9 else "1-2"], None
    if r < 0.88:
        return ["recall", rng.choice(PATTERNS)], None
    if r < 0.92:
        return ["forget", settled_block(memo, rng, d, T) if rng.random() < 0.6 else block_of(rng, T)], None
    if r < 0.97:
        roll = rng.random()
        if roll < 0.35:
            return ["config", "WAKE_LINES=%d" % rng.randint(3, 24)], None
        if roll < 0.55:
            return ["config", "PART_LINES=%d" % rng.randint(2, 9)], None
        if roll < 0.65:
            return ["config", "PART_CHARS=%d" % rng.randint(60, 400)], None
        if roll < 0.72:
            return ["config", rng.choice(["ENTRY_CHARS=300", "WAKE_LINES=0", "WAKE_LINES=x", "BOGUS=1"])], None
        if roll < 0.85:
            return ["config", rng.choice(["WAKE_LINES=", "PART_LINES=", "PART_CHARS=", "ENTRY_CHARS=200", "ENTRY_CHARS="])], None
        return ["config"], None
    # import: dated lines, mostly valid
    lines = []
    date = clock.today
    for _ in range(rng.randint(1, 12)):
        roll = rng.random()
        if roll < 0.05:
            lines.append("not-a-date hello")
        elif roll < 0.08:
            lines.append("2026-02-30 bad day")
        elif roll < 0.11:
            lines.append("")
        else:
            lines.append("%s %s" % (date, text(rng, limit=280)))
    return ["import", "import.txt"], "\n".join(lines) + "\n"


def main():
    path = os.environ.get("OPTMEM_MEMO")
    if not path:
        sys.exit("Set OPTMEM_MEMO to OptMem's memo script.")
    repo = os.path.dirname(os.path.abspath(path))
    commit = subprocess.run(["git", "-C", repo, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
    memo = load(path)
    memo.ME = "memo"
    clock = Clock()
    memo.datetime = clock
    sequences = []
    for seed, count, deep in PROFILES:
        rng = random.Random(seed)
        with tempfile.TemporaryDirectory() as tmp:
            d = os.path.join(tmp, "memory")
            os.environ["MEMORY_DIR"] = d
            with contextlib.redirect_stdout(io.StringIO()):
                memo.cmd_init(d, [])
            cwd = os.getcwd()
            os.chdir(tmp)
            clock.today = "2026-10-01"
            steps = []
            try:
                if deep:
                    argv = ["config", "WAKE_LINES=12", "PART_LINES=7"]
                    stdout, stderr, code = run(memo, clock, argv)
                    steps.append({"argv": argv, "today": clock.today, "stdout": stdout, "stderr": stderr, "code": code})
                for _ in range(count):
                    argv, file_text = (deep_step if deep else step)(memo, rng, d, clock)
                    if file_text is not None:
                        with open("import.txt", "w", encoding="utf-8") as f:
                            f.write(file_text)
                    stdout, stderr, code = run(memo, clock, argv)
                    item = {"argv": argv, "today": clock.today, "stdout": stdout, "stderr": stderr, "code": code}
                    if file_text is not None:
                        item["file"] = file_text
                    steps.append(item)
            finally:
                os.chdir(cwd)
        sequences.append({"seed": seed, "steps": steps})
    doc = json.dumps({"reference": "github.com/VictorTaelin/OptMem@" + commit, "sequences": sequences},
                     ensure_ascii=False, separators=(",", ":")) + "\n"
    with open(OUT, "wb") as f:  # mtime 0: the same vectors give the same bytes
        f.write(gzip.compress(doc.encode("utf-8"), mtime=0))
    print("wrote %s: %d sequences, %d steps" % (OUT, len(sequences), sum(len(s["steps"]) for s in sequences)))


if __name__ == "__main__":
    main()
