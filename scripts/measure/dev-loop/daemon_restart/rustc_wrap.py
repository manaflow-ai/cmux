#!/usr/bin/env python3
"""RUSTC_WRAPPER (and linker wrapper) of the daemon_restart measurement: times every rustc cargo
runs and the daemon binary's link, without changing what is built.

As RUSTC_WRAPPER (`rustc_wrap.py RUSTC ARGS...`): runs RUSTC ARGS (through DLC_INNER_WRAPPER, the
sccache rust-live.py would have used, when set) and writes one JSON record per compile to
DLC_LOG_DIR: the crate, its kind, wall start and end (time.time()), and the argv, cwd and cargo
environment, so a floor can replay the same rustc alone. For the cmux-tui binary's rustc it points
`-C linker` at itself (keeping the linker cargo configured, else `cc`, rustc's default on macOS and
Linux) so the link is timed as its own stage.

As the linker (link_wrap.sh, which runs `rustc_wrap.py --link ARGS...`): runs DLC_REAL_LINKER ARGS and writes a `link` record.
"""

import json
import os
import subprocess
import sys
import time

start = time.time()
LOG = os.environ.get("DLC_LOG_DIR", "")
LINKED_CRATE = "cmux_tui"  # the daemon binary's crate (cmux-tui/crates/cmux-tui/src/bin/cmux-tui.rs)
ENV_KEEP = ("CARGO", "OUT_DIR", "RUST", "DEP_", "ZIG", "PATH", "HOME", "DYLD_", "LD_LIBRARY_PATH",
            "SDKROOT", "MACOSX_DEPLOYMENT_TARGET", "DEVELOPER_DIR", "TMPDIR", "DLC_")


def record(entry: dict) -> None:
    if not LOG:
        return
    path = os.path.join(LOG, f"{time.time_ns()}-{os.getpid()}.json")
    with open(path + ".tmp", "w") as f:
        json.dump(entry, f)
    os.replace(path + ".tmp", path)


def arg_after(argv: list, flag: str) -> str:
    for i, a in enumerate(argv):
        if a == flag and i + 1 < len(argv):
            return argv[i + 1]
    return ""


def main() -> int:
    if len(sys.argv) > 1 and sys.argv[1] == "--link":
        linker = os.environ.get("DLC_REAL_LINKER") or "cc"
        t0 = time.time()
        rc = subprocess.call([linker, *sys.argv[2:]])
        record({"kind": "link", "crate": LINKED_CRATE, "start": t0, "end": time.time(),
                "wrapper_start": start, "rc": rc, "linker": linker})
        return rc
    rustc, args = sys.argv[1], sys.argv[2:]
    crate = arg_after(args, "--crate-name")
    kind = arg_after(args, "--crate-type") or ("probe" if not crate else "")
    env = dict(os.environ)
    if crate == LINKED_CRATE and kind == "bin":
        configured = ""
        out = []
        skip = False
        for i, a in enumerate(args):
            if skip:
                skip = False
                continue
            if a == "-C" and i + 1 < len(args) and args[i + 1].startswith("linker="):
                configured = args[i + 1][len("linker="):]
                skip = True
                continue
            if a.startswith("-Clinker="):
                configured = a[len("-Clinker="):]
                continue
            out.append(a)
        env["DLC_REAL_LINKER"] = configured or "cc"
        args = out + ["-C", "linker=" + os.path.join(os.path.dirname(os.path.abspath(__file__)), "link_wrap.sh")]
    inner = os.environ.get("DLC_INNER_WRAPPER", "")
    argv = ([inner] if inner else []) + [rustc, *args]
    t0 = time.time()
    rc = subprocess.call(argv, env=env)
    end = time.time()
    if crate and crate != "___":  # "___": cargo's target-info probe, not a compile
        record({"kind": kind, "crate": crate, "start": t0, "end": end, "wrapper_start": start, "rc": rc,
                "argv": sys.argv[1:], "cwd": os.getcwd(),
                "env": {k: v for k, v in os.environ.items() if k.startswith(ENV_KEEP)}})
    return rc


if __name__ == "__main__":
    sys.exit(main())
