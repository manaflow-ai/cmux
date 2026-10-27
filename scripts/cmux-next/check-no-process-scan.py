#!/usr/bin/env python3
"""NO-PROCESS-SCAN ratchet (plans/cmux-next/pty-holder.md, section 4).

cmux-next never finds terminals, agents or their state by scanning
processes. Terminal and agent holders register themselves; the daemon
reattaches through the registry and their sockets, and agents report
themselves through hooks and OSC 7501. Process scans were the source of
lag, hangs and wrong answers in the classic app.

This guard fails on a process-scanning API in product code:
  - enumeration: proc_listpids, proc_listallpids, proc_listchildpids,
    proc_listpgrppids, sysctl KERN_PROC_ALL/UID/RUID/PGRP/TTY/SESSION,
    spawning ps, pgrep, pkill, pidof or lsof (any path, as a const or as
    an argument), Toolhelp32 snapshots, (K32)EnumProcesses,
    WTSEnumerateProcesses, NtQuerySystemInformation, walking /proc,
    NSWorkspace.runningApplications, and the sysinfo, procfs, libproc,
    darwin-libproc, heim or remoteprocess crates (as code paths and as
    Cargo.toml dependencies);
  - walking a process tree: pbi_ppid, e_ppid;
  - reading another process to decide what it is: KERN_PROCARGS2,
    /proc/<pid>/{cmdline,environ,exe,comm,cwd,stat,status,task,fd,...},
    proc_pidpath, proc_name, PROC_PIDVNODEPATHINFO, PROC_PIDLISTFDS,
    proc_pidfdinfo.
The guard matches APIs, not intent: it does not see whether a pid is this
process, a held child or a foreign one. APIs that are almost only used on
this process or a held child (waitpid, pidfds, kill(pid, 0), tcgetpgrp,
/proc/self, sysctl KERN_PROC_PID) are not in the list. A reviewed use of a
listed API (peer authentication of one connected socket, a held child) gets
a `keep` row.

Existing sites are listed in scripts/cmux-next/process-scan-baseline.tsv
with the number of matching lines per file, a class (`remove` = planned
removal, `keep` = a reviewed exception) and the bead or reason. A file with
more matches than its baseline, or with matches and no baseline row, fails.
A file with fewer matches than its baseline also fails until the baseline
is lowered, so the ratchet only goes down.

Usage: scripts/cmux-next/check-no-process-scan.py [repo-root] [--list]
  --list  print every matching line (for the audit) and exit 0.
"""

from __future__ import annotations

import os
import re
import sys

SCOPES = (
    ("cmux-tui/crates", (".rs",)),
    ("Packages/macOS", (".swift",)),
)
SKIP_DIRS = {"target", ".build", "tests", "Tests", "node_modules", "fixtures", "benches"}
BASELINE = "scripts/cmux-next/process-scan-baseline.tsv"

PATTERNS = [
    r"\bproc_list(all)?pids\b",
    r"\bproc_listchildpids\b",
    r"\bproc_listpgrppids\b",
    r"\bKERN_PROC_(ALL|UID|RUID|PGRP|TTY|SESSION)\b",
    r"\bKERN_PROCARGS2?\b",
    r"\bproc_pidpath\b",
    r"\bproc_name\b",
    r"\bPROC_PIDVNODEPATHINFO\b",
    r"\bPROC_PIDLISTFDS\b",
    r"\bproc_pidfdinfo\b",
    # The checked seams over the same calls (CmuxNextCompat ProcessInfo+Blocking.swift): a caller still counts.
    r"\bblockingProc(ListPids|PidPath|PidFDInfo)\b",
    # Parent links: walking up or down a process tree.
    r"\b(pbi_ppid|e_ppid)\b",
    # Spawning a process lister, by any path, through env/sh, or as an argument.
    r"""Command::new\(\s*"(?:[\w./-]*/)?(ps|pgrep|pkill|pidof|lsof)"\s*\)""",
    r"""\.args?\(\s*\[?\s*"(ps|pgrep|pkill|pidof|lsof)[\s"]""",
    r"""\barguments\s*=\s*\[\s*"(ps|pgrep|pkill|pidof|lsof)[\s"]""",
    r"""\"(ps|pgrep|pkill|pidof|lsof)\s+-""",
    r"""(executableURL|launchPath)\s*=.*"(/bin/ps|/usr/bin/pgrep|/usr/bin/pkill|/usr/sbin/lsof)""",
    r"""const\s+\w+\s*:\s*&str\s*=\s*"(?:[\w./-]*/)?(ps|pgrep|pkill|pidof|lsof)"\s*;""",
    r"\bTH32CS_SNAPPROCESS\b",
    r"\bProcess32(First|Next)W?\b",
    r"\b(K32)?EnumProcesses\b",
    r"\bWTSEnumerateProcesses",
    r"\bNtQuerySystemInformation\b",
    r"\b(sysinfo|procfs|libproc|darwin_libproc|heim|remoteprocess)::",
    r"""(read_dir|Path::new|PathBuf::from)\(\s*"/proc/?"\s*\)""",
    r"""/proc/\{[^}]*\}/(cmdline|environ|exe|comm|cwd|stat|statm|status|task|fd|root|cgroup)""",
    r"""/proc/net/""",
    r"\brunningApplications\b",
]
BANNED_CRATES = re.compile(
    r"""^\s*(sysinfo|procfs|libproc|darwin-libproc|heim|heim-process|remoteprocess)\s*=""", re.M
)
REGEX = re.compile("|".join(f"(?:{p})" for p in PATTERNS))
COMMENT = re.compile(r"^\s*(//|/\*|\*(\s|/|$))")


def scan(root: str) -> dict[str, list[tuple[int, str]]]:
    hits: dict[str, list[tuple[int, str]]] = {}
    for scope, exts in SCOPES:
        base = os.path.join(root, scope)
        if not os.path.isdir(base):
            continue
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIRS)
            for name in sorted(filenames):
                if not name.endswith(exts):
                    continue
                if name in ("tests.rs",) or name.endswith(("_tests.rs", "_test.rs", "Tests.swift")):
                    continue
                path = os.path.join(dirpath, name)
                rel = os.path.relpath(path, root).replace(os.sep, "/")
                if "/tests/" in rel or "/Tests/" in rel:
                    continue
                try:
                    with open(path, encoding="utf-8", errors="replace") as f:
                        lines = f.readlines()
                except OSError:
                    continue
                for number, line in enumerate(lines, 1):
                    if COMMENT.match(line):
                        continue
                    if REGEX.search(line):
                        hits.setdefault(rel, []).append((number, line.rstrip()))
    return hits


def banned_dependencies(root: str) -> list[str]:
    found = []
    base = os.path.join(root, "cmux-tui")
    if not os.path.isdir(base):
        return found
    for dirpath, dirnames, filenames in os.walk(base):
        dirnames[:] = sorted(d for d in dirnames if d not in {"target", ".build", "node_modules"})
        if "Cargo.toml" in filenames:
            path = os.path.join(dirpath, "Cargo.toml")
            with open(path, encoding="utf-8", errors="replace") as f:
                for match in BANNED_CRATES.finditer(f.read()):
                    found.append(f"{os.path.relpath(path, root)}: {match.group(1)}")
    return found


def read_baseline(root: str) -> dict[str, tuple[int, str, str]]:
    rows: dict[str, tuple[int, str, str]] = {}
    path = os.path.join(root, BASELINE)
    if not os.path.exists(path):
        return rows
    with open(path, encoding="utf-8") as f:
        for raw in f:
            line = raw.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) < 4 or parts[2] not in ("remove", "keep") or not parts[1].isdigit():
                print(f"check-no-process-scan: bad baseline row: {line!r}", file=sys.stderr)
                sys.exit(2)
            rows[parts[0]] = (int(parts[1]), parts[2], parts[3])
    return rows


def main(argv: list[str]) -> int:
    args = [a for a in argv if not a.startswith("--")]
    root = os.path.abspath(args[0]) if args else os.getcwd()
    hits = scan(root)
    if "--list" in argv:
        for rel, found in sorted(hits.items()):
            for number, line in found:
                print(f"{rel}:{number}: {line.strip()}")
        return 0
    baseline = read_baseline(root)
    status = 0
    for dependency in banned_dependencies(root):
        status = 1
        print(
            f"check-no-process-scan: {dependency} is a process-listing crate. cmux-next never "
            "scans processes (plans/cmux-next/pty-holder.md).",
            file=sys.stderr,
        )
    for rel, found in sorted(hits.items()):
        allowed = baseline.get(rel, (0, "", ""))[0]
        if len(found) > allowed:
            status = 1
            print(
                f"check-no-process-scan: {rel} has {len(found)} process-scan line(s), baseline {allowed}. "
                "cmux-next never scans processes (plans/cmux-next/pty-holder.md): use the holder "
                "registry, a socket connect, hook/OSC 7501 reports or the PTY you hold.",
                file=sys.stderr,
            )
            for number, line in found:
                print(f"  {rel}:{number}: {line.strip()}", file=sys.stderr)
    for rel, (allowed, _, _) in sorted(baseline.items()):
        count = len(hits.get(rel, []))
        if count < allowed:
            status = 1
            print(
                f"check-no-process-scan: {rel} now has {count} process-scan line(s), baseline {allowed}. "
                f"Lower its row in {BASELINE} to {count}" + (" (delete the row)" if count == 0 else "") + ".",
                file=sys.stderr,
            )
    if status == 0:
        print(f"check-no-process-scan: ok ({sum(len(v) for v in hits.values())} baselined line(s) in {len(hits)} file(s))")
    return status


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
