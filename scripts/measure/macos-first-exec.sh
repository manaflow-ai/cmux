#!/usr/bin/env bash
# macos-first-exec: what the first exec of a newly written executable costs on this Mac, by file size.
#
# What it measures: rust-live's daemon swap (scripts/cmux-next/rust-live.py Swapper.swap) runs a freshly
# linked debug cmux-tui twice (the `server restart` CLI, then the daemon it starts). The dev-loop-ceiling
# daemon_restart loop measured that swap at 6.0 s p50 on a fleet Mac against a 0.14 s floor of `server stop` +
# `server ensure` from the build already running. This script separates the first-exec cost from the restart:
# for each size it writes an executable that does nothing (a `main` that returns, with SIZE MB of random bytes
# in __TEXT,__const), then times, in ms: the first exec, a second exec, an exec after a hard link to it was
# made and removed (cmux#44204's XProtect rescan), and the first exec of a copy. It also prints whether this
# process tree is a Developer Tool (DevToolsSecurity), which exempts its children from the scan.
#
# Run: scripts/measure/macos-first-exec.sh OUT [SIZES_MB, default 1,100,600]
#   cmux-ci run --class light --os macos --script scripts/measure/macos-first-exec.sh --ref SHA \
#     --arg .build/first-exec --artifact .build/first-exec/report.json
set -euo pipefail
out="${1:?usage: macos-first-exec.sh OUT [SIZES_MB]}"
sizes="${2:-1,100,600}"
[[ "$(uname -s)" == Darwin ]] || { echo "macos-first-exec: macOS only" >&2; exit 2; }
mkdir -p "$out"
out="$(cd "$out" && pwd)"
work="$(mktemp -d /tmp/first-exec.XXXXXX)"
trap 'rm -rf "$work"' EXIT

python3 - "$out/report.json" "$work" "$sizes" <<'EOF'
import json, os, shutil, subprocess, sys, time
report_path, work, sizes = sys.argv[1], sys.argv[2], [int(s) for s in sys.argv[3].split(",")]

def sh(*argv):
    r = subprocess.run(argv, capture_output=True, text=True)
    return (r.stdout + r.stderr).strip()

def timed(path):
    t = time.perf_counter()
    rc = subprocess.run([path]).returncode
    return round((time.perf_counter() - t) * 1000, 1), rc

chain, pid = [], os.getpid()
while pid > 1 and len(chain) < 12:
    line = sh("ps", "-o", "ppid=,comm=", "-p", str(pid))
    if not line:
        break
    ppid, comm = line.split(None, 1)
    chain.append(comm)
    pid = int(ppid)
report = {"schema": "macos-first-exec/v1", "host_os": sh("sw_vers", "-productVersion"),
          "devtools_security": sh("DevToolsSecurity", "-status"), "process_chain": chain, "sizes": []}
for mb in sizes:
    d = os.path.join(work, f"s{mb}")
    os.makedirs(d)
    blob = os.path.join(d, "blob")
    with open(blob, "wb") as f:
        for _ in range(mb):
            f.write(os.urandom(1 << 20))
    asm = os.path.join(d, "main.s")
    with open(asm, "w") as f:
        f.write(f'.section __TEXT,__const\n.incbin "{blob}"\n.text\n.globl _main\n.p2align 2\n'
                '_main:\n  mov w0, #0\n  ret\n')
    exe = os.path.join(d, "exe")
    subprocess.run(["cc", "-o", exe, asm], check=True)
    os.unlink(blob)
    row = {"size_mb": mb, "file_bytes": os.path.getsize(exe)}
    row["first_ms"], row["rc"] = timed(exe)
    row["second_ms"], _ = timed(exe)
    link = exe + ".link"
    os.link(exe, link)
    os.unlink(link)
    row["after_link_removed_ms"], _ = timed(exe)
    row["second_after_link_ms"], _ = timed(exe)
    copy = exe + ".copy"
    shutil.copy2(exe, copy)
    row["copy_first_ms"], _ = timed(copy)
    row["copy_second_ms"], _ = timed(copy)
    report["sizes"].append(row)
    print(f"first-exec {mb} MB: {json.dumps(row)}", flush=True)
    shutil.rmtree(d)
json.dump(report, open(report_path, "w"), indent=2)
print(json.dumps({k: v for k, v in report.items() if k != "sizes"}))
EOF
