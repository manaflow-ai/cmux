#!/usr/bin/env python3
"""Push-on-send on the sync bench's tree (scenario f): the time from "send" to "files on the
machine" after editing the bench's 10 files (`edit_set`), and for a send with nothing changed.

It runs on the bench host beside `sync_bench.py` (cmux PR #45303, `/var/tmp/sync-bench/`), under
that harness's lock, with its machine (`Machine`), link (`Link`, `tc netem` for rtt > 0) and tree.
A build with `cmux link sync on-send` pushes the tree once (cold, rtt 0), then at each rtt:

  f   edit the 10 files, `on-send` (bounded at 10 minutes, so the answer is "files on the machine"),
      put them back, `on-send` again (untimed); three times
  f0  `on-send` with nothing changed; three times
  c   (rtt 0 only) a full `cmux link sync push` after the same 10 edits, for reference

The base for f is the base's scenario c (a full re-push is the only way a base build gets an edit
to the machine): `sync-bench compare` has those rows. Results: results/<sha>/<layout>-on-send-rtt<N>.json.

    sync_bench_on_send.py --commit FULLSHA [--rtt-ms 0,50] [--layout projects] [--binary PATH]
"""

import argparse
import contextlib
import json
import os
import shutil
import statistics
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import sync_bench as bench  # noqa: E402

RUNS = 3


def on_send(binary: Path, socket: Path, local: Path, remote: Path, state: Path) -> dict:
    env = dict(os.environ, CMUX_TUI_STATE_DIR=str(state))
    cmd = [str(binary), "link", "sync", "on-send", "--socket", str(socket), "--within", "600000",
           str(local), str(remote)]
    started = time.monotonic()
    proc = subprocess.run(cmd, env=env, capture_output=True, timeout=900)
    wall = time.monotonic() - started
    answer = None
    with contextlib.suppress(ValueError, IndexError):
        answer = json.loads(proc.stdout.decode().strip().splitlines()[-1])
    row = {"exit": proc.returncode, "wall_ms": round(wall * 1000), "answer": answer}
    if proc.returncode:
        row["stderr_tail"] = proc.stderr.decode(errors="replace")[-2000:]
    return row


@contextlib.contextmanager
def edited(top: Path, layout: str):
    """The bench's 10 edited files, edited, then put back (bytes and times)."""
    _, edit = bench.edit_set(layout)
    saved = {}
    for rel in edit:
        st = (top / rel).stat()
        saved[rel] = ((top / rel).read_bytes(), st.st_atime_ns, st.st_mtime_ns)
    for rel in edit:
        with open(top / rel, "ab") as f:
            f.write(b"\n// sync-bench on-send edit\n")
    try:
        yield len(edit)
    finally:
        for rel, (data, atime, mtime) in saved.items():
            (top / rel).write_bytes(data)
            os.utime(top / rel, ns=(atime, mtime))


def median(rows):
    walls = [row["wall_ms"] for row in rows if row.get("exit") == 0]
    return statistics.median(walls) if walls else None


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--commit", required=True)
    parser.add_argument("--rtt-ms", default="0,50")
    parser.add_argument("--layout", default="projects", choices=["projects", "flat"])
    parser.add_argument("--binary")
    parser.add_argument("--build", action="store_true")
    args = parser.parse_args(argv)
    rtts = [int(x) for x in args.rtt_ms.split(",") if x]
    top = bench.layout_dir(args.layout)
    with bench.bench_lock(f"on-send {args.commit[:12]} {args.layout} rtt {rtts}"):
        binary, source = (Path(args.binary), "given") if args.binary else bench.binary_for(args.commit, args.build)
        work = bench.ROOT / "work"
        shutil.rmtree(work, ignore_errors=True)
        machine = bench.Machine(binary, work)
        machine.start()
        state = work / "mac-state"
        remote = machine.home / "work" / args.layout
        records = []
        try:
            with bench.Link(0, machine.socket, 0) as socket:
                bench.log(f"{args.layout}: cold push (rtt 0)")
                cold = bench.push(binary, socket, top, remote, state, ["--allow-large"])
                if cold["exit"]:
                    raise SystemExit(f"cold push failed: {json.dumps(cold)[:2000]}")
            for rtt in rtts:
                facts = bench.host_facts()
                rows = {"f": [], "f0": []}
                with bench.Link(rtt, machine.socket, 0) as socket:
                    # The first on-send after the cold push settles the watcher's mark.
                    rows["settle"] = on_send(binary, socket, top, remote, state)
                    for run in range(RUNS):
                        with edited(top, args.layout) as count:
                            bench.log(f"{args.layout} rtt {rtt}: f run {run + 1} ({count} edited)")
                            rows["f"].append(on_send(binary, socket, top, remote, state))
                        rows.setdefault("restore", []).append(on_send(binary, socket, top, remote, state))
                    for run in range(RUNS):
                        bench.log(f"{args.layout} rtt {rtt}: f0 run {run + 1} (nothing changed)")
                        rows["f0"].append(on_send(binary, socket, top, remote, state))
                    if rtt == 0:
                        with edited(top, args.layout):
                            bench.log(f"{args.layout} rtt {rtt}: c (full push after the same edits)")
                            rows["c"] = bench.push(binary, socket, top, remote, state, ["--allow-large"])
                        rows["c_restore"] = on_send(binary, socket, top, remote, state)
                record = {
                    "commit": args.commit, "binary": str(binary), "binary_source": source,
                    "layout": args.layout, "rtt_ms": rtt, "tree": bench.tree_id(), "host": facts,
                    "cold": cold if rtt == rtts[0] else None, "scenarios": rows,
                    "median_ms": {"f": median(rows["f"]), "f0": median(rows["f0"])},
                }
                out = bench.ROOT / "results" / args.commit / f"{args.layout}-on-send-rtt{rtt}.json"
                out.parent.mkdir(parents=True, exist_ok=True)
                out.write_text(json.dumps(record, indent=1) + "\n")
                records.append(record)
                print(json.dumps({"rtt_ms": rtt, "median_ms": record["median_ms"]}), flush=True)
        finally:
            machine.stop()
            shutil.rmtree(work, ignore_errors=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
