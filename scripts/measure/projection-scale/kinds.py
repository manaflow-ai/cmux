#!/usr/bin/env python3
"""RFD 0007's ten folder kinds on a local projected folder (FUSE), at RFD 0067's link profiles.

    kinds.py [--fixtures DIR] [--out DIR] [--kinds big-plain,media,...] [--profiles store-v6-1-low,store-v6-8,github-v4-bad]
             [--whole-cap-s 120] [--bin SLICE_BENCH]
    kinds.py table OUT          # print OUT's Markdown table again

Each kind's folder is built by cloud-chat-matrix.py's `build_fixture` (the same fixtures the prod matrix sends,
`--only kinds`), then `measure.py projection` serves it, runs the link at each profile and mounts it with
slice_bench (the real FUSE overlay over the real wire), with the steps ls, first, whole and edit. Per kind and
profile the table says: ready (connect, manifest, mount: the local stand-in for the first turn's wait), bytes moved
at ready, the listing, the largest file's first byte and whole read (time and bytes down: a lazy read fetches
only what it touches), and whether the edits (write, case-only rename, read back) held and left the source tree
untouched. A whole read a profile would take longer than --whole-cap-s for is skipped and says why.

Prod numbers (the cloud machine's first turn, the Mac's projection bytes, edits reaching the Mac) come from
`cloud-chat-matrix.py --only kinds` (cloud-chat-proof.yml `-f matrix_only=kinds`).

Run: python3 scripts/measure/projection-scale/kinds.py --out /tmp/kinds   (Linux with /dev/fuse; builds slice_bench if missing)
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
MEASURE = HERE / "measure.py"
DEFAULT_PROFILES = ("store-v6-1-low", "store-v6-8", "github-v4-bad")


def matrix_module():
    path = REPO / "scripts" / "cmux-next" / "cloud-chat-matrix.py"
    sys.path.insert(0, str(path.parent))
    spec = importlib.util.spec_from_file_location("cloud_chat_matrix", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def measure_module():
    spec = importlib.util.spec_from_file_location("projection_measure", MEASURE)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def tree_digest(tree: Path) -> str:
    """Names, sizes and mtimes under TREE (no content read), so an edit leaking to the source shows."""
    h = hashlib.sha256()
    for root, dirs, files in sorted(os.walk(tree)):
        dirs.sort()
        for name in sorted(files + [d for d in dirs]):
            st = os.lstat(os.path.join(root, name))
            h.update(f"{os.path.relpath(os.path.join(root, name), tree)}\0{st.st_size}\0{st.st_mtime_ns}\n".encode())
    return h.hexdigest()[:16]


def rows_of(path: Path) -> dict[str, dict]:
    rows = {}
    if path.exists():
        for line in path.read_text().splitlines():
            row = json.loads(line)
            rows[row["phase"]] = row
    return rows


def mb(n) -> str:
    return "" if n in (None, "") else f"{n / 1e6:.2f} MB" if n >= 1e5 else f"{n} B"


def summarize(out: Path) -> list[dict]:
    summary = []
    for path in sorted(out.glob("*/*/rows.jsonl")):
        kind, profile = path.parent.parent.name, path.parent.name
        r = rows_of(path)
        meta = json.loads((path.parent / "kind.json").read_text()) if (path.parent / "kind.json").exists() else {}
        serve = json.loads(r.get("serve_start", {}).get("note") or "{}")
        mount = r.get("mount_ls", {})
        cell = {
            "kind": meta.get("kind", kind), "cell": kind, "profile": profile,
            "files": serve.get("files"), "tree_bytes": serve.get("bytes"),
            "largest_bytes": serve.get("largest_bytes"),
            "ready_s": mount.get("wall_s"), "ready_down": mount.get("down_bytes"),
            "ls_s": r.get("ls_cold", {}).get("wall_s"),
            "first_s": r.get("first_cold", {}).get("wall_s"), "first_down": r.get("first_cold", {}).get("down_bytes"),
            "whole_s": r.get("whole_cold", {}).get("wall_s"), "whole_down": r.get("whole_cold", {}).get("down_bytes"),
            "edit": (r.get("edit_cold", {}).get("note") or "").removeprefix("out=").split(" ")[0],
            "source_untouched": meta.get("source_untouched"), "skipped": meta.get("skipped", ""),
        }
        summary.append(cell)
    order = {name: i for i, name in enumerate(DEFAULT_PROFILES)}
    summary.sort(key=lambda c: (int(str(c["kind"]).split(" ")[0]) if str(c["kind"])[:1].isdigit() else 99,
                                order.get(c["profile"], 9)))
    return summary


def table(out: Path) -> str:
    lines = ["| kind | profile | files, bytes | ready (mount) | bytes at ready | list | first byte of largest | "
             "whole largest | edits | note |", "|---|---|---|---|---|---|---|---|---|---|"]
    for c in summarize(out):
        def t(s, down=None):
            return "" if s is None else f"{s:.3f} s" + (f" ({mb(down)})" if down not in (None, "") else "")
        edits = {"ok": "held", "lost": "LOST"}.get(c["edit"], c["edit"] or "")
        if c["source_untouched"] is False:
            edits += ", source CHANGED"
        elif c["source_untouched"]:
            edits += ", source untouched"
        lines.append(f"| {c['kind']} | {c['profile']} | {c['files']}, {mb(c['tree_bytes'])} | {t(c['ready_s'])} | "
                     f"{mb(c['ready_down'])} | {t(c['ls_s'])} | {t(c['first_s'], c['first_down'])} | "
                     f"{t(c['whole_s'], c['whole_down']) or '-'} | {edits} | {c['skipped']} |")
    return "\n".join(lines)


def run(args) -> None:
    out = Path(args.out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    matrix = matrix_module()
    measure = measure_module()
    cells = {cell: kind for kind, cell in matrix.KIND_CELLS.items()}
    wanted = [c for c in (args.kinds.split(",") if args.kinds else cells) if c]
    fixtures = Path(args.fixtures or tempfile.mkdtemp(prefix="cmux-kinds-")).resolve()
    margs = matrix.parse_args(["--cli", "x", "--out", str(out / "matrix"), "--only", "kinds"])
    for cell in wanted:
        tree = fixtures / cell
        if not tree.exists():
            built, note = matrix.build_fixture(cell, fixtures, margs, "kinds")
            if built is None:
                print(f"[kinds] {cell}: not built: {note}", file=sys.stderr)
                continue
        largest_bytes = measure.largest_file(tree)[1]
        for profile in args.profiles.split(","):
            cell_out = out / cell / profile
            if (cell_out / "rows.jsonl").exists():
                print(f"[kinds] {cell} {profile}: already measured", file=sys.stderr)
                continue
            rate = measure.PROFILES[profile]["rate"] * 1e6
            steps, skipped = ["ls", "first", "whole", "edit"], ""
            if largest_bytes / rate > args.whole_cap_s:
                steps.remove("whole")
                skipped = (f"whole read not run: {largest_bytes / 1e6:.0f} MB at {rate / 1e6:g} MB/s is "
                           f"~{largest_bytes / rate:.0f} s")
            before = tree_digest(tree)
            cmd = [sys.executable, str(MEASURE), "projection", str(tree), "--steps", ",".join(steps),
                   "--profile", profile, "--out", str(cell_out), "--label", cell]
            if args.bin:
                cmd += ["--bin", args.bin]
            print(f"[kinds] {cell} {profile}: {' '.join(steps)}", file=sys.stderr, flush=True)
            got = subprocess.run(cmd, stdout=subprocess.DEVNULL)
            meta = {"kind": cells.get(cell, cell), "cell": cell, "profile": profile, "rc": got.returncode,
                    "source_untouched": tree_digest(tree) == before, "skipped": skipped}
            (cell_out / "kind.json").write_text(json.dumps(meta) + "\n")
    text = table(out)
    (out / "kinds.md").write_text(text + "\n")
    print(text)


def main() -> None:
    if len(sys.argv) > 2 and sys.argv[1] == "table":
        print(table(Path(sys.argv[2]).resolve()))
        return
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--fixtures", help="folder holding (or to hold) the kinds' fixtures; default a new temp dir")
    p.add_argument("--out", default="out-kinds")
    p.add_argument("--kinds", help="cells, comma-separated (big-plain, public-remote, ...); default all ten")
    p.add_argument("--profiles", default=",".join(DEFAULT_PROFILES))
    p.add_argument("--whole-cap-s", type=float, default=120.0,
                   help="skip a whole read the profile's rate would take longer than this")
    p.add_argument("--bin", help="slice_bench binary (default: measure.py's)")
    run(p.parse_args())


if __name__ == "__main__":
    main()
