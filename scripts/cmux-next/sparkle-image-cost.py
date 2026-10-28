#!/usr/bin/env python3
"""What Sparkle.framework costs a cmux-next launch before main() (p08-startup task 067).

dyld maps, validates, fixes up and initializes every non-system image the app links before main() runs, on the
launch's critical path. Sparkle is one of the two (`otool -L`, p08-startup.md Q9). This measures that work for
Sparkle alone: each run is a fresh process that first loads Sparkle's system dependencies (already loaded in any
AppKit app, so they are not Sparkle's cost), then times `dlopen(Sparkle, RTLD_NOW)`: mapping, code signature,
fixups, Objective-C class registration and initializers, the work dyld does for the image at launch. A control
`dlopen` of an image already loaded in the same process is timed too and subtracted, so the probe's own cost
(ctypes, the call) is not counted. A runtime dlopen builds its loader at run time, so the number is an upper
bound of the image's share of a launch.

The decision (p08-startup.md section 2): Sparkle stays linked, and the task closes with this number, unless the
p50 cost is >= DLOPEN_THRESHOLD_MS; then UpdaterService gets a protocol whose implementation dlopens Sparkle off
the main thread at afterStartup (risk:high). Chrome keeps its updater out of the browser's launch the same way: the
browser talks to an out-of-process updater only when asked (chrome/browser/updater/browser_updater_client_mac.mm).

  scripts/cmux-next/sparkle-image-cost.py --app "/path/cmux DEV tag.app" [--runs 20] [--purge] [--json out.json]
  scripts/cmux-next/sparkle-image-cost.py --framework /path/Sparkle.framework [--runs 20] [--json out.json]
  scripts/cmux-next/sparkle-image-cost.py --package-dir Packages/macOS/CmuxNext   # after `swift package resolve`
  scripts/cmux-next/sparkle-image-cost.py --report out.json                       # print a saved result anywhere

--app also lists the main executable's non-system dylibs (`sparkle_linked` is the task's otool acceptance) and
measures the bundle's own Contents/Frameworks/Sparkle.framework, the signed copy that ships. --package-dir finds
the framework SwiftPM resolved (.build/artifacts/sparkle/Sparkle/Sparkle.xcframework, macOS slice): the same
prebuilt binary, since Sparkle is a binary target and its image cost does not depend on cmux's build config.
--purge empties the file cache before each run (`sudo -n /usr/sbin/purge`, as bench-startup.py --purge) so the
pages come from disk, as after a reboot. The probe runs only on the fleet (cmux-ci sets CMUX_CI_STEP_KEY,
nx-remote sets NX_JOB_ID); --report runs anywhere.
"""

import argparse
import glob
import importlib.util
import json
import os
import platform
import plistlib
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DLOPEN_THRESHOLD_MS = 3.0
DEFAULT_RUNS = 20
SYSTEM_PREFIXES = ("/System/", "/usr/lib/")
KEEP = "keep-linked"
DLOPEN = "dlopen-off-main"

# One run, in a fresh `python3 -I` process: argv is `--` then the preload paths, then the target last.
# RTLD_NOW (0x2) binds everything, as the launch does; RTLD_GLOBAL is 0x8 and RTLD_LOCAL 0x4 on Darwin.
PROBE = r"""
import ctypes, sys, time
paths = sys.argv[sys.argv.index("--") + 1:]
preload, target = paths[:-1], paths[-1]
for path in preload:
    ctypes.CDLL(path, mode=0x2 | 0x8)
control = preload[0] if preload else "/usr/lib/libSystem.B.dylib"
t0 = time.perf_counter_ns()
ctypes.CDLL(control, mode=0x2 | 0x8)
t1 = time.perf_counter_ns()
ctypes.CDLL(target, mode=0x2 | 0x4)
t2 = time.perf_counter_ns()
print(t1 - t0, t2 - t1)
"""


class CostError(Exception):
    """A refusal with its reason (exit 2)."""


def load_perf_stats():
    path = os.path.join(ROOT, "scripts", "perf-lab", "perf_stats.py")
    spec = importlib.util.spec_from_file_location("perf_stats", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def parse_otool_l(text):
    """The install names `otool -L` lists, in order (the header line, ending in `:`, left out)."""
    names = []
    for line in text.splitlines():
        if not line.startswith(("\t", " ")):
            continue
        name = line.strip().split(" (compatibility version", 1)[0].strip()
        if name:
            names.append(name)
    return names


def is_system(name):
    return name.startswith(SYSTEM_PREFIXES)


def framework_dependencies(names, own_id):
    """Split an image's load commands into (system, other), leaving out its own LC_ID_DYLIB."""
    deps = [n for n in names if n != own_id]
    return [n for n in deps if is_system(n)], [n for n in deps if not is_system(n)]


def is_sparkle(name):
    return "/Sparkle.framework/" in name


def parse_probe_line(line):
    """(control_ns, target_ns) from one probe run's output line."""
    parts = line.split()
    if len(parts) != 2 or not all(p.isdigit() for p in parts):
        raise CostError(f"probe printed {line!r}, not two nanosecond counts")
    return int(parts[0]), int(parts[1])


def costs_ms(samples):
    """Each run's Sparkle cost in ms: its dlopen minus the same run's control dlopen (never below 0)."""
    return [max(target - control, 0) / 1e6 for control, target in samples]


def verdict(cost_summary, threshold_ms=DLOPEN_THRESHOLD_MS):
    """KEEP when the p50 cost is under the threshold, else DLOPEN; None without samples."""
    p50 = cost_summary.get("p50")
    if p50 is None:
        return None
    return DLOPEN if p50 >= threshold_ms else KEEP


def result(samples, *, perf_stats, framework, version, app=None, purge=False, host=None):
    costs = costs_ms(samples)
    summary = perf_stats.summary(costs)
    return {
        "schema": "cmux-sparkle-image-cost/v1",
        "framework": framework,
        "sparkle_version": version,
        "host": host or {},
        "purge": purge,
        "runs": len(samples),
        "cost_ms": summary,
        "control_ms": perf_stats.summary([c / 1e6 for c, _ in samples]),
        "samples_ns": [list(s) for s in samples],
        "threshold_ms": DLOPEN_THRESHOLD_MS,
        "verdict": verdict(summary),
        "app": app,
    }


def fmt(value):
    return "-" if value is None else f"{value:.3f}"


def report_lines(doc):
    cost = doc["cost_ms"]
    lines = [
        f"Sparkle {doc.get('sparkle_version') or '?'}: {doc['framework']}",
        f"host {doc['host'].get('name', '?')}, macOS {doc['host'].get('macos', '?')}, "
        f"{doc['host'].get('arch', '?')}; {doc['runs']} runs, {'purged (cold pages)' if doc['purge'] else 'warm pages'}",
        f"image cost ms: p50 {fmt(cost['p50'])}  p95 {fmt(cost['p95'])}  p99 {fmt(cost['p99'])}  max {fmt(cost['max'])}"
        f"  (control p50 {fmt(doc['control_ms']['p50'])}, subtracted)",
    ]
    app = doc.get("app")
    if app:
        others = ", ".join(app["non_system_dylibs"]) or "none"
        lines.append(f"{app['executable']}: non-system dylibs {others}; Sparkle linked: {app['sparkle_linked']}")
    if doc["verdict"] == KEEP:
        lines.append(f"verdict {KEEP}: p50 {fmt(cost['p50'])} ms < {doc['threshold_ms']} ms; close task 067 with this number")
    elif doc["verdict"] == DLOPEN:
        lines.append(f"verdict {DLOPEN}: p50 {fmt(cost['p50'])} ms >= {doc['threshold_ms']} ms; "
                     "load Sparkle off main at afterStartup (risk:high)")
    else:
        lines.append("verdict: none (no samples)")
    return lines


# ---------- the macOS side ----------


def run(argv):
    return subprocess.run(argv, check=True, capture_output=True, text=True).stdout


def plist(path):
    with open(path, "rb") as handle:
        return plistlib.load(handle)


def framework_binary(framework):
    binary = os.path.realpath(os.path.join(framework, "Sparkle"))
    if not os.path.isfile(binary):
        raise CostError(f"{framework} has no Sparkle binary")
    return binary


def framework_version(framework):
    for info in glob.glob(os.path.join(framework, "Versions", "*", "Resources", "Info.plist")):
        version = plist(info).get("CFBundleShortVersionString")
        if version:
            return version
    return None


def resolved_framework(package_dir):
    pattern = os.path.join(package_dir, ".build", "artifacts", "sparkle", "Sparkle", "Sparkle.xcframework",
                           "macos-*", "Sparkle.framework")
    found = sorted(glob.glob(pattern))
    if not found:
        raise CostError(f"no {pattern}: run `swift package resolve --package-path {package_dir}` first")
    return found[0]


def app_linkage(app):
    executable = plist(os.path.join(app, "Contents", "Info.plist"))["CFBundleExecutable"]
    path = os.path.join(app, "Contents", "MacOS", executable)
    names = parse_otool_l(run(["otool", "-L", path]))
    others = [n for n in names if not is_system(n)]
    return {"executable": executable, "non_system_dylibs": others, "sparkle_linked": any(map(is_sparkle, others))}


def require_purge():
    probe = subprocess.run(["sudo", "-n", "-l", "/usr/sbin/purge"], capture_output=True, text=True)
    if probe.returncode != 0:
        raise CostError("--purge needs `sudo -n /usr/sbin/purge` (host-setup.sh --grant-privileged): "
                        + (probe.stderr.strip() or "not permitted"))


def measure(binary, runs, purge):
    own_id = run(["otool", "-D", binary]).splitlines()[-1].strip()
    system, other = framework_dependencies(parse_otool_l(run(["otool", "-L", binary])), own_id)
    if other:
        print(f"note: Sparkle links non-system images {other}; their cost is counted as Sparkle's", file=sys.stderr)
    samples = []
    for _ in range(runs):
        if purge:
            subprocess.run(["sudo", "-n", "/usr/sbin/purge"], check=True)
        out = run([sys.executable, "-I", "-c", PROBE, "--", *system, binary])
        samples.append(parse_probe_line(out.strip()))
    return samples


def host_info():
    return {"name": platform.node(), "macos": platform.mac_ver()[0], "arch": platform.machine()}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n", 1)[0])
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--app", help="a built cmux-next .app: its linkage and its bundled Sparkle.framework")
    source.add_argument("--framework", help="a Sparkle.framework")
    source.add_argument("--package-dir", help="a SwiftPM package dir whose .build holds the resolved Sparkle")
    source.add_argument("--report", help="print a saved --json result")
    parser.add_argument("--runs", type=int, default=DEFAULT_RUNS)
    parser.add_argument("--purge", action="store_true", help="empty the file cache before each run")
    parser.add_argument("--json", help="write the result here")
    args = parser.parse_args(argv)
    try:
        if args.report:
            with open(args.report, encoding="utf-8") as handle:
                doc = json.load(handle)
        else:
            if sys.platform != "darwin":
                raise CostError("the probe dlopens a Mach-O framework: macOS only (--report reads a result anywhere)")
            if not os.environ.get("CMUX_CI_STEP_KEY") and not os.environ.get("NX_JOB_ID"):
                raise CostError("the probe runs only on the fleet (cmux-ci run or nx-remote); see the usage at the top")
            if args.runs < 1:
                raise CostError("--runs must be at least 1")
            if args.purge:
                require_purge()
            app = app_linkage(args.app) if args.app else None
            if args.app:
                framework = os.path.join(args.app, "Contents", "Frameworks", "Sparkle.framework")
            elif args.package_dir:
                framework = resolved_framework(args.package_dir)
            else:
                framework = args.framework
            samples = measure(framework_binary(framework), args.runs, args.purge)
            doc = result(samples, perf_stats=load_perf_stats(), framework=framework,
                         version=framework_version(framework), app=app, purge=args.purge, host=host_info())
        if args.json:
            with open(args.json, "w", encoding="utf-8") as handle:
                json.dump(doc, handle, indent=2)
                handle.write("\n")
    except (CostError, OSError, subprocess.CalledProcessError, KeyError, ValueError) as error:
        print(f"sparkle-image-cost: {error}", file=sys.stderr)
        return 2
    print("\n".join(report_lines(doc)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
