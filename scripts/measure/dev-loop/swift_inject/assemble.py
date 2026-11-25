#!/usr/bin/env python3
"""Writes OUT/swift_inject.json (schema dev-loop-ceiling/loop/v1) from what swift_inject.sh recorded:
the edit times (writes.txt), the watcher's log (fs_event at=, injected at=), inject.sh's tool runs
(stamps.log, from stamp.c on PATH), the shell's log (applied ... load_ms= at=, redrawn generation=N
at=, rendered ... width=) and the floors (floors/STAGE.json). With --error it still writes what it has."""
import argparse
import datetime
import json
import os
import re
import socket
import statistics
import subprocess

STAGES = ["fs_event", "compile", "link", "sign", "pickup", "load", "paint"]


def read(path):
    try:
        return open(path, errors="replace").read()
    except OSError:
        return ""


def p50(values):
    return round(statistics.median(values), 1) if values else None


def rounds_from(work, shell_log, watch_log, n):
    writes = [float(x) for x in read(os.path.join(work, "writes.txt")).split()]
    heard = [float(x) for x in re.findall(r"^fs_event at=([\d.]+)", read(watch_log), re.M)]
    shell = read(shell_log)
    applied = [(int(ms), float(at)) for ms, at in re.findall(r"applied \S+ functions=\d+ load_ms=(\d+) at=([\d.]+)", shell)]
    functions = [int(x) for x in re.findall(r"applied \S+ functions=(\d+)", shell)]
    redrawn = {int(g): float(at) for g, at in re.findall(r"redrawn generation=(\d+) at=([\d.]+)", shell)}
    widths = {int(g): int(w) for g, w in re.findall(r"generation-(\d+)\.png width=(\d+)", shell)}
    stamps = []
    for line in read(os.path.join(work, "stamps.log")).splitlines():
        parts = line.split()
        if len(parts) >= 4:
            stamps.append((float(parts[0]), float(parts[1]), parts[3], parts[4:]))
    rounds, gaps, problems = [], [], []
    for k in range(1, n + 1):
        if k > len(writes) or k > len(heard) or k > len(applied) or k not in redrawn:
            problems.append(f"round {k} is incomplete (write, fs event, apply or redraw missing)")
            break
        t_write, t_heard, t_drawn = writes[k - 1], heard[k - 1], redrawn[k]
        load_ms, t_applied = applied[k - 1]
        mine = [s for s in stamps if t_write <= s[0] <= t_drawn]
        # inject.sh's compile: its patch_compile.py (the patch's own frontend jobs, from the kept driver plan), the
        # driver plan it writes on a miss, or the whole-module compile it falls back to; first start to last end.
        compile_ = [s for s in mine if (s[2] == "xcrun" and "-c" in s[3] and "-emit-library" not in s[3])
                    or (s[2] == "python3" and any(a.endswith("patch_compile.py") for a in s[3]))]
        link = [s for s in mine if s[2] == "xcrun" and "-emit-library" in s[3]]
        sign = [s for s in mine if s[2] == "codesign"]
        moves = [s for s in mine if s[2] == "mv"]
        if not (compile_ and link and sign and moves):
            problems.append(f"round {k}: inject.sh's compile, link, codesign or mv has no stamp")
            break
        c, l, g, m = (min(s[0] for s in compile_), max(s[1] for s in compile_)), link[0], sign[0], moves[-1]
        t_load = t_applied - load_ms / 1000
        ms = lambda a, b: round((b - a) * 1000, 3)
        stages = {
            "fs_event": ms(t_write, t_heard),
            "compile": ms(c[0], c[1]),
            "link": ms(l[0], l[1]),
            "sign": ms(g[0], g[1]),
            "pickup": ms(m[1], t_load),
            "load": float(load_ms),
            "paint": ms(t_applied, t_drawn),
        }
        e2e = ms(t_write, t_drawn)
        stages["unattributed"] = round(e2e - sum(stages.values()), 3)
        rounds.append({"end_to_end_ms": e2e, "stages_ms": stages})
        gaps.append({
            "heard_to_compile": ms(t_heard, c[0]),  # watcher spawns inject.sh: bash, mktemp, python3 for `started`
            "compile_to_link": ms(c[1], l[0]),  # the -nt loop over the module's files
            "link_to_sign": ms(l[1], g[0]),
            "sign_to_moved": ms(g[1], m[1]),  # mkdir, the two mv
        })
        if widths.get(k) is None or widths.get(k) == widths.get(k - 1):
            problems.append(f"round {k}: the badge was not drawn wider (widths {widths.get(k - 1)} -> {widths.get(k)})")
    return rounds, gaps, problems, functions, widths


def main():
    p = argparse.ArgumentParser()
    for flag in ("--out", "--work", "--root", "--shell-log", "--watch-log"):
        p.add_argument(flag, required=True)
    p.add_argument("--n", type=int, default=5)
    p.add_argument("--error", default="")
    a = p.parse_args()

    rounds, gaps, problems, functions, widths = rounds_from(a.work, a.shell_log, a.watch_log, a.n)
    floors = {}
    for stage in STAGES:
        try:
            floors[stage] = json.load(open(os.path.join(a.work, "floors", f"{stage}.json")))
        except (OSError, ValueError):
            pass
    commands = {}
    try:
        commands = json.load(open(os.path.join(a.work, "floors", "commands.json")))
    except (OSError, ValueError):
        pass

    error = a.error or None
    if not error:
        missing = [s for s in STAGES if len(floors.get(s, [])) < a.n]
        if problems:
            error = "; ".join(problems)
        elif len(rounds) < a.n:
            error = f"{len(rounds)} of {a.n} rounds measured"
        elif missing:
            error = "no floor (or fewer than N samples) for: " + ", ".join(missing)

    stage_p50 = {s: p50([r["stages_ms"][s] for r in rounds]) for s in STAGES + ["unattributed"]} if rounds else {}
    gap_p50 = {g: p50([x[g] for x in gaps]) for g in (gaps[0] if gaps else {})}
    floor_p50 = {s: p50(v) for s, v in floors.items()}
    notes = [
        "Loop: Prototypes/ViewShell's Debug cmux-view-shell runs headless with --live and --live-render (the mechanism of "
        "scripts/measure/live-code-shell.sh); each round rewrites Badge.swift's .padding(.horizontal, N) in place (one write), an "
        "FSEvents watcher (swift_inject/probe.swift watch: file events, latency 0, NoDefer) runs Prototypes/ViewShell/inject.sh "
        "unchanged, and the round ends at the shell's 'redrawn generation=K' line, after the badge's PNG was written; every "
        "round's badge was checked wider than the last.",
        "Boundaries: the edit's write (python time.time just before it), the watcher's callback, each of inject.sh's xcrun, "
        "python3, codesign and mv runs (start and end, from swift_inject/stamp.c linked as those names first on PATH; it adds about a "
        "millisecond per call, which lands in the stage it wraps), the shell's apply (its at= minus its load_ms, integer ms) "
        "and its redraw.",
        "Stages: fs_event = write to the watcher's callback. compile = inject.sh's patch_compile.py, which runs only the "
        "frontend jobs of the files it links from the driver plan it keeps per toolchain, flags and file list (python3 start "
        "included; on a plan miss also the `xcrun swiftc -c ... -###` that writes it, and on a fallback the whole-module "
        "`xcrun swiftc -c`). link = its `xcrun swiftc -emit-library` of Badge.o. sign = its "
        "codesign. pickup = the patch renamed into the live folder to the shell starting the load (its DispatchSource on the "
        "folder, then a directory scan on the main queue). load = the shell's own load_ms (dlopen, layout check, interpose, "
        "rebind). paint = applied to redrawn: a main-queue hop, ImageRenderer of the badge, PNG encode and write. "
        "unattributed = the rest: inject.sh's own process start (bash, mktemp, a python3 start for its `started` stamp), its "
        "loop over the module's files, mkdir and the gaps between its tools.",
        "Floors: fs_event = probe fsevents-floor, a file written in a fresh folder to the same kind of FSEvents callback. "
        "compile = the exact frontend job inject.sh's driver plans for Badge.swift (swiftc -### of inject.sh's own command), run "
        "alone: one -primary-file, the module's other files as secondaries (an executable target has no built module to "
        "import, so its own files are the context). link = the linker job swiftc -### plans for Badge.o alone into a dylib "
        "(same flags as inject.sh), run alone. sign = /usr/bin/codesign --force --sign - on a copy of that dylib. pickup = "
        "probe pickup-floor, a file renamed into a folder to a DispatchSource .write on it firing. load = probe dlopen-floor, "
        "dlopen(RTLD_NOW) of a fresh copy of a one-function C dylib in a running process. paint = probe paint-floor, one "
        "ImageRenderer frame of the same badge view to a CGImage, warm (no PNG). compile, link and sign are timed by stamp "
        "after one warm-up run.",
        "Graph: a plain chain; each stage consumes the previous one's output (the source, the object, the dylib, the signed "
        "file in the folder, the loaded code, the redraw).",
        "Not this path: the app's live mode watcher (scripts/live-code/live-mode.py watch) polls the tree every 1.0 s "
        "(time.sleep(1.0)) and compiles with patch.py, which reads the build's whole xcodebuild.log to find the module's "
        "command; try-pr.sh adds a fetch and a tree. Those are waiting and work this shell loop does not have, and the "
        "10.87 s try-pr number's 6.4 s outside compile, link and load is in them, not measured here.",
    ]
    if commands:
        notes.append(f"compile floor command (run in a scratch folder): {commands.get('compile')}")
        notes.append(f"compile floor primaries: {commands.get('compile_primaries')}; frontend jobs inject.sh's compile plans: "
                     f"{commands.get('inject_frontend_jobs')} (one per file of the module)")
        notes.append(f"link floor command: {commands.get('link')}")
    if gap_p50:
        notes.append("unattributed, split at inject.sh's tool boundaries (p50 ms): " + json.dumps(gap_p50))
    if functions:
        notes.append(f"functions interposed per patch: {functions}; badge widths by generation: {widths}")
    notes.append("p50 ms, stages: " + json.dumps(stage_p50) + "; floors: " + json.dumps(floor_p50) + "; end to end: "
                 + json.dumps(p50([r['end_to_end_ms'] for r in rounds])))

    commit = subprocess.run(["git", "-C", a.root, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
    doc = {
        "schema": "dev-loop-ceiling/loop/v1",
        "loop": "swift_inject",
        "commit": commit,
        "host": socket.gethostname(),
        "measured_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "target": "Prototypes/ViewShell Badge.swift body edit (a padding) -> FSEvents watcher -> Prototypes/ViewShell/inject.sh "
                  "(compile, link, codesign, drop) -> headless Debug cmux-view-shell --live (dlopen + interpose) -> badge "
                  "redrawn to pixels; live-code-shell.sh's mechanism, not the app",
        "error": error,
        "rounds": rounds,
        "floors_ms": floors,
        "graph": {"fs_event": [], "compile": ["fs_event"], "link": ["compile"], "sign": ["link"], "pickup": ["sign"],
                  "load": ["pickup"], "paint": ["load"]},
        "notes": notes,
    }
    with open(a.out, "w") as f:
        json.dump(doc, f, indent=2)
    print(json.dumps({"error": error, "stages_p50": stage_p50, "floors_p50": floor_p50,
                      "end_to_end_p50": p50([r["end_to_end_ms"] for r in rounds])}))
    return 1 if error else 0


if __name__ == "__main__":
    raise SystemExit(main())
