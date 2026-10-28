"""`leaks <pid>` of a running cmux app, read into a report row: leaked blocks, bytes and top types.

Report only: a leak never fails a run. The smoke (in the VM guest) and relaunch-e2e (local) run it on
the app just before they quit it, so the heap holds a whole session's leaks and none of the teardown.

`leaks` exits 0 with no leak, 1 with leaks, and higher on an error (no task port: the hardened runtime
refuses task_for_pid to a non-root caller unless the build has get-task-allow). Its list format
("classic", `-list`) has one `Leak:` line per block; parse() also reads the tree format (leaks' default),
one line per block under each ROOT LEAK or ROOT CYCLE. Both name the block's type when leaks knows it
(an ObjC, Swift or CF class), otherwise it is plain malloc.
`-nocontext` keeps the blocks' contents out of the output.
"""

from __future__ import annotations

import re
import subprocess
from collections import Counter

ARGS = ["-list", "-nocontext"]
TIMEOUT = 300  # s: leaks walks the whole heap; a VM with a Chromium tab open takes about a minute
TOP = 10

_SUMMARY = re.compile(r"^Process \d+: (\d+) leaks? for (\d+) total leaked bytes", re.M)
_LIST = re.compile(r"^Leak: 0x[0-9a-fA-F]+\s+size=(\d+)\s+zone:\s*\S+(.*)$")
# "  1 (48 bytes) ROOT LEAK: <NSMutableArray 0x6000020a4000> [48]", "  1 (16 bytes) 0x600000c04010 [16]".
# "CYCLE BACK TO" lines point at a block already counted.
_TREE = re.compile(r"^\s*\d+ \([^)]*\) (?:ROOT (?:LEAK|CYCLE): )?(?:<(.+?) 0x[0-9a-fA-F]+>|0x[0-9a-fA-F]+) \[(\d+)\]")


def parse(text: str, status: int) -> dict:
    """The report row for one `leaks` run's output and exit status."""
    summary = _SUMMARY.search(text)
    if status not in (0, 1) or not summary:
        tail = "\n".join(text.strip().splitlines()[-6:])
        return {"error": f"leaks exit {status}: {tail[-600:]}" if tail else f"leaks exit {status}"}
    counts: Counter[str] = Counter()
    sizes: Counter[str] = Counter()
    blocks = 0
    for line in text.splitlines():
        listed = _LIST.match(line)
        tree = None if listed else _TREE.match(line)
        if listed:
            fields = re.split(r"\s{2,}", listed.group(2).strip())
            kind, size = (fields[0] if fields and fields[0] else "malloc"), int(listed.group(1))
        elif tree:
            kind, size = (tree.group(1) or "malloc"), int(tree.group(2))
        else:
            continue
        blocks += 1
        counts[kind] += 1
        sizes[kind] += size
    top = sorted(counts, key=lambda k: (-sizes[k], -counts[k], k))[:TOP]
    return {"leaks": int(summary.group(1)), "bytes": int(summary.group(2)), "blocks_read": blocks,
            "top_types": [{"type": k, "count": counts[k], "bytes": sizes[k]} for k in top]}


def run_local(pid: int, out_path: str) -> dict:
    """`leaks` on a process of this Mac; the full output goes to out_path."""
    try:
        r = subprocess.run(["/usr/bin/leaks", *ARGS, str(pid)], capture_output=True, text=True, timeout=TIMEOUT,
                           stdin=subprocess.DEVNULL)
        text, status = r.stdout + r.stderr, r.returncode
    except subprocess.TimeoutExpired:
        text, status = f"no answer in {TIMEOUT} s", 124
    except OSError as error:
        text, status = str(error), 127
    with open(out_path, "w") as out:
        out.write(text)
    return {"pid": pid, **parse(text, status)}


def summary_line(row: dict) -> str:
    if "error" in row:
        return f"leaks: not measured ({row['error'].splitlines()[0][:200]})"
    top = ", ".join(f"{t['type']} {t['count']}x {t['bytes']} B" for t in row["top_types"][:3])
    return f"leaks: {row['leaks']} blocks, {row['bytes']} bytes" + (f"; top {top}" if top else "")
