#!/usr/bin/env python3
"""The compile, link and sign floors of scripts/measure/dev-loop/swift_inject.sh.

compile: the one frontend job (swift-frontend -frontend -c -primary-file Badge.swift, the module's
other files read as secondaries) that inject.sh's own driver command plans for Badge.swift (-###),
run alone. link: the linker job swiftc plans for Badge.o alone into a dylib (-###), run alone.
sign: /usr/bin/codesign --force --sign - on a fresh copy of that dylib. Each is timed by stamp
(fork, exec, wait), N times, after one warm-up run. Writes WORK/floors/{compile,link,sign}.json and
WORK/floors/commands.json (the exact commands)."""
import argparse
import json
import os
import shlex
import shutil
import subprocess


def plan(path):
    """The jobs of a `swiftc -###` plan, each as an argv."""
    jobs = []
    for line in open(path):
        line = line.strip()
        if not line or line.startswith(("warning:", "note:")):
            continue
        try:
            jobs.append(shlex.split(line))
        except ValueError:
            continue
    return jobs


def timed(stamp, cwd, label, argv, n):
    # A -### plan names the driver's temporary folders, which only a real run makes.
    for arg in argv[1:]:
        if os.path.isabs(arg) and not os.path.exists(os.path.dirname(arg)):
            os.makedirs(os.path.dirname(arg), exist_ok=True)
    log = os.path.join(cwd, f"{label}.stamps")
    if os.path.exists(log):
        os.remove(log)
    subprocess.run(argv, cwd=cwd, check=True, capture_output=True)  # warm-up, not counted
    for _ in range(n):
        subprocess.run([stamp, log, label, *argv], cwd=cwd, check=True, capture_output=True)
    samples = []
    for line in open(log):
        start, end, code = line.split()[:3]
        if code != "0":
            raise SystemExit(f"floors.py: {label} exited {code}")
        samples.append(round((float(end) - float(start)) * 1000, 3))
    return samples


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--work", required=True)
    p.add_argument("--badge", required=True)
    p.add_argument("--n", type=int, default=5)
    p.add_argument("--stamp", required=True)
    a = p.parse_args()
    fw = os.path.join(a.work, "fw")
    floors = os.path.join(a.work, "floors")
    badge = os.path.realpath(a.badge)

    compile_jobs = [j for j in plan(os.path.join(a.work, "compile-plan.txt")) if "-frontend" in j and "-c" in j]
    mine = [j for j in compile_jobs
            if any(j[i] == "-primary-file" and os.path.realpath(j[i + 1]) == badge for i in range(len(j) - 1))]
    if not mine:
        raise SystemExit("floors.py: no frontend job with Badge.swift as its primary in the -### plan")
    compile_job = mine[0]
    primaries = sum(1 for x in compile_job if x == "-primary-file")

    link_jobs = [j for j in plan(os.path.join(a.work, "link-plan.txt"))
                 if os.path.basename(j[0]) in ("ld", "ld64", "ld-prime", "clang", "swiftc") or j[0].endswith("/ld")]
    if not link_jobs:
        raise SystemExit("floors.py: no linker job in the -emit-library -### plan")
    link_job = link_jobs[-1]

    out = {"compile": timed(a.stamp, fw, "compile", compile_job, a.n),
           "link": timed(a.stamp, fw, "link", link_job, a.n)}
    dylib = os.path.join(fw, "floor-patch.dylib")
    signs = []
    for i in range(a.n + 1):
        copy = os.path.join(fw, f"sign-{i}.dylib")
        shutil.copyfile(dylib, copy)
        signs.append(copy)
    log = os.path.join(fw, "sign.stamps")
    subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", signs[0]], check=True, capture_output=True)
    for copy in signs[1:]:
        subprocess.run([a.stamp, log, "sign", "/usr/bin/codesign", "--force", "--sign", "-", copy], check=True, capture_output=True)
    out["sign"] = [round((float(l.split()[1]) - float(l.split()[0])) * 1000, 3) for l in open(log)]

    for stage, samples in out.items():
        json.dump(samples, open(os.path.join(floors, f"{stage}.json"), "w"))
    json.dump({
        "compile": shlex.join(compile_job),
        "compile_primaries": primaries,
        "inject_frontend_jobs": len(compile_jobs),
        "link": shlex.join(link_job),
        "sign": "/usr/bin/codesign --force --sign - COPY.dylib",
    }, open(os.path.join(floors, "commands.json"), "w"), indent=2)


if __name__ == "__main__":
    main()
