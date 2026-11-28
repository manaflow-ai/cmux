#!/usr/bin/env python3
"""Symbolize a macOS `sample` of acpmux/cmux-tui and rank where its CPU goes.

The app ships a stripped `cmux` binary, and `atos` against the CI artifact
returns bare addresses. The unstripped `cmux-tui-aarch64-apple-darwin` in the
"cmux-tui artifacts" run for the same commit keeps its symbol table, so this
looks frames up in `nm` and names the Rust paths.

  sample PID 5 -file s.txt
  dwarfdump --uuid "<app>/Contents/Resources/bin/acpmux"   # must match the artifact
  scripts/perf/symbolize-sample.py s.txt cmux-tui-aarch64-apple-darwin [out.txt]

Prints on-CPU samples per own frame (leaf frames that are not waits), and
the threads blocked in flock.
"""
import bisect
import collections
import re
import subprocess
import sys

WAIT = ("psynch_cvwait", "semaphore_wait", "kevent", "__ulock_wait", "mach_msg2",
        "workq_kernreturn", "recvfrom", "semwait_signal", "poll ", "read ",
        "semaphore_timedwait", "start_wqthread", "thread_start", "psynch_mutexwait",
        "implementation_callback_rpc", "flock")
OWN = re.compile(r"acpmux|hub::|server::|peer_|store::")


def short(name):
    """Readable path from a v0 (`__R`) or legacy (`__ZN`) Rust symbol."""
    if name.startswith("__R"):
        s, out, i = name[3:], [], 0
        while i < len(s):
            m = re.match(r"(\d+)_?", s[i:])
            if m and int(m.group(1)) > 0:
                n = int(m.group(1)); st = i + len(m.group(0)); tok = s[st:st + n]
                if len(tok) == n and re.match(r"^[A-Za-z_]\w*$", tok):
                    out.append(tok); i = st + n; continue
            i += 1
        return "::".join(out[-4:]) or name
    if name.startswith("__ZN"):
        s, out, i = name, [], 4
        while i < len(s) and (m := re.match(r"\d+", s[i:])):
            n = int(m.group(0)); st = i + len(m.group(0)); out.append(s[st:st + n]); i = st + n
        return "::".join(t for t in out[-4:] if not re.match(r"^h[0-9a-f]{16}$", t))
    return name


def main():
    sample, binary = sys.argv[1], sys.argv[2]
    out_path = sys.argv[3] if len(sys.argv) > 3 else None
    text = open(sample).read()
    load = int(re.search(r"Load Address:\s+(0x[0-9a-f]+)", text).group(1), 16)
    addrs, names = [], []
    nm = subprocess.run(["nm", "-n", "--defined-only", binary], capture_output=True, text=True).stdout
    for line in nm.splitlines():
        parts = line.split(" ", 2)
        if len(parts) == 3 and parts[1] in ("t", "T"):
            addrs.append(int(parts[0], 16)); names.append(parts[2])
    slide = load - 0x100000000

    def sym(m):
        k = bisect.bisect_right(addrs, int(m.group(1), 16) - slide) - 1
        return (short(names[k]) if k >= 0 else m.group(1)) + "  (in cmux)"

    text = re.sub(r"\?\?\?  \(in cmux\)  load address 0x[0-9a-f]+ \+ 0x[0-9a-f]+  \[(0x[0-9a-f]+)\]", sym, text)
    if out_path:
        open(out_path, "w").write(text)

    graph = text.split("Call graph:")[1].split("Total number in stack")[0].splitlines()
    near, incl, flock = collections.Counter(), collections.Counter(), 0
    stack, nodes = [], []
    for line in graph:
        m = re.match(r"^([\s+!:|]*?)(\d+) (.*)$", line)
        if not m:
            continue
        ind, count, frame = len(m.group(1)), int(m.group(2)), m.group(3).strip()
        while stack and stack[-1]["ind"] >= ind:
            stack.pop()
        node = {"ind": ind, "c": count, "f": frame, "kids": 0, "anc": [s["f"] for s in stack]}
        if stack:
            stack[-1]["kids"] += count
        stack.append(node); nodes.append(node)
    total = 0
    for n in nodes:
        own = n["c"] - n["kids"]
        if own <= 0:
            continue
        if "flock" in n["f"]:
            flock += own; continue
        if any(w in n["f"] for w in WAIT):
            continue
        total += own
        chain = [re.sub(r"\s+\(in .*$", "", a) for a in n["anc"] + [n["f"]] if "(in cmux)" in a]
        mine = [c for c in chain if OWN.search(c)]
        if mine:
            near[mine[-1]] += own
        for c in set(mine):
            incl[c] += own
    print(f"on-CPU samples {total}; samples blocked in flock {flock}")
    print("-- nearest own frame"); [print(v, k[:150]) for k, v in near.most_common(15)]
    print("-- inclusive"); [print(v, k[:150]) for k, v in incl.most_common(25)]


if __name__ == "__main__":
    main()
