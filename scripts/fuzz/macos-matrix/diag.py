#!/usr/bin/env python3
"""Diagnostic variants of the VM fuzz (vm.sh --diag NAME).

Each variant runs the same fuzz walk with an allocator, threading or sanitizer check in the app:

  gmalloc      Guard Malloc (DYLD_INSERT_LIBRARIES=/usr/lib/libgmalloc.dylib)
  scribble     MallocScribble=1 MallocGuardEdges=1
  probguard    MallocProbGuard=1 (sampled guard pages, Apple's GWP-ASan)
  mtc          the host Xcode's libMainThreadChecker.dylib (AppKit and UIKit calls off the main thread)
  coop-strict  LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 (Swift concurrency's pool is one thread wide)
  asan|tsan|ubsan  a sanitizer app (reload.sh --config asan|tsan|ubsan, bundle id suffix .asan,
               .tsan or .ubsan), with the runtime's reports written to files

Malloc and sanitizer variants run with Chromium off. In-process CEF replaces the default malloc
zone with PartitionAlloc, which these checks do not instrument: they would cover nothing or report
false bad frees (plans/cmux-next/chrome-parity/p10-stability.md, risk 8). vm.sh removes the CEF
runtime from the guest copy of the app (CEFRuntimeLayout then finds none and there is no pack to
download), the app opens WebKit tabs, and it skips its early malloc zone
(CMUX_NEXT_SKIP_EARLY_MALLOC_ZONE), so the check's zone stays the default one. After the launch
and at the end the run records the app's malloc zones in registration order (zones[0] is the
default zone; malloc-zones.c reads them with malloc_get_all_zones) and whether the CEF framework
is mapped. A Chromium-off run where PartitionAlloc holds a zone, the early zone is the default,
or the framework is mapped, is invalid: no verdict.

vm.sh reads a variant's bundle work with `diag.py info NAME`; fuzz.py runs the rest.
"""

from __future__ import annotations

import json
import os
import shlex
import sys
import time
from dataclasses import dataclass, field

SAN_DIR = "/tmp/fuzz-san"  # /tmp/fuzz-* survives fuzz.py's state reset
CONFIG_FILE = "/tmp/fuzz-diag-config.json"
APP_LOG = "/tmp/cmux-fuzz-app.log"
# The CEF runtime in an app bundle (CEFRuntimeLayout.frameworkName, .shimName) and the
# Chromium-on-demand pin (ChromiumRuntimePin, cef-runtime-pack.sh): with none of them the app
# has no Chromium to load or download.
CHROMIUM_RUNTIME = ("Contents/Frameworks/Chromium Embedded Framework.framework",
                    "Contents/Frameworks/libcmux_cef_shim.dylib",
                    "Contents/Resources/cef-runtime.json")
CHROMIUM_IMAGE = "Chromium Embedded Framework"
PARTITION_ALLOC_ZONE = "PartitionAlloc"
# CmuxNextMallocZone/early_zone.c (Chromium's EarlyMallocZoneRegistration): a forwarding zone in
# front of the zone that was the default before main(). Chromium-off runs skip it with this variable.
EARLY_ZONE = "DelegatingDefaultZoneForPartitionAlloc"
SKIP_EARLY_ZONE = "CMUX_NEXT_SKIP_EARLY_MALLOC_ZONE"
# The launch work that could map Chromium (its warm start follows the first frame) is done this
# long after the first ping; the launch snapshot waits for it.
LAUNCH_SETTLE_S = 5
# The first line of one report of each kind.
MARKERS = {"mtc": "Main Thread Checker:", "asan": "ERROR: AddressSanitizer", "tsan": "WARNING: ThreadSanitizer",
           "ubsan": "runtime error:"}


@dataclass(frozen=True)
class Diag:
    name: str
    env: dict[str, str] = field(default_factory=dict)
    # Guest paths for DYLD_INSERT_LIBRARIES.
    dyld: tuple[str, ...] = ()
    # A dylib of the host's Xcode, $(xcode-select -p)/usr/lib/NAME: the guest images have no
    # Xcode, so vm.sh copies it in and fuzz.py inserts it (--insert-dylib).
    host_dylib: str = ""
    chromium_off: bool = False
    # The sanitizer app's bundle id suffix (reload.sh --config asan|tsan|ubsan).
    bundle_suffix: str = ""
    # The factor on --hang-ms and the launch deadline (DIAGS says where each value comes from).
    slowdown: int = 1
    # MARKERS key of the reports this variant collects, "" for none (a crash is an .ips either way).
    report: str = ""


def _sanitizer(name: str, options: str, slowdown: int) -> Diag:
    return Diag(name, env={f"{name.upper()}_OPTIONS": f"log_path={SAN_DIR}/{name}:{options}"}, chromium_off=True,
                bundle_suffix=f".{name}", slowdown=slowdown, report=name)


DIAGS = {d.name: d for d in (
    # gmalloc and scribble: our estimates, not measured yet and not Chromium's (it has no such
    # variant). Guard Malloc maps pages for every allocation and unmaps them on free (libgmalloc(3));
    # MallocScribble writes every allocated and freed byte. A launch never waits past the run's end.
    Diag("gmalloc", dyld=("/usr/lib/libgmalloc.dylib",), chromium_off=True, slowdown=10),
    Diag("scribble", env={"MallocScribble": "1", "MallocGuardEdges": "1"}, chromium_off=True, slowdown=2),
    # ProbGuard guards a small sample of allocations: no slowdown.
    Diag("probguard", env={"MallocProbGuard": "1"}, chromium_off=True),
    Diag("mtc", host_dylib="libMainThreadChecker.dylib", report="mtc"),
    Diag("coop-strict", env={"LIBDISPATCH_COOPERATIVE_POOL_STRICT": "1"}),
    # Chromium's kTimeoutMultiplier off Windows (base/test/test_timeouts.cc): 2 for ASan and TSan;
    # UBSan is not in its list (1).
    # ASan stops at its first report (abort_on_error: the .ips names the run); TSan and UBSan go on.
    _sanitizer("asan", "abort_on_error=1:halt_on_error=1", 2),
    _sanitizer("tsan", "halt_on_error=0:second_deadlock_stack=1", 2),
    _sanitizer("ubsan", "halt_on_error=0:print_stacktrace=1:report_error_type=1", 1),
)}


def info_lines(d: Diag) -> str:
    """What vm.sh does to the guest app for `d`, one key=value per line."""
    lines = [f"chromium={'off' if d.chromium_off else 'on'}", f"bundle_suffix={d.bundle_suffix}", f"host_dylib={d.host_dylib}"]
    lines += [f"remove={p}" for p in (CHROMIUM_RUNTIME if d.chromium_off else ())]
    return "\n".join(lines) + "\n"


def launch_env(d: Diag, dylibs: list[str]) -> dict[str, str]:
    """The variables the app starts with for `d`; `dylibs` are the other inserted libraries."""
    env = dict(d.env)
    inserted = [*dylibs, *d.dyld]
    if inserted:
        env["DYLD_INSERT_LIBRARIES"] = ":".join(inserted)
    if d.chromium_off:
        env["CMUX_NEXT_CONFIG_FILE"] = CONFIG_FILE  # browser.defaultEngine webkit
        env[SKIP_EARLY_ZONE] = "1"
    return env


def prepare_guest(g, d: Diag) -> None:
    """Folders and files the app needs before its first launch for `d`."""
    if d.report and d.report != "mtc":
        g.sh(f"rm -rf {SAN_DIR}; mkdir -p {SAN_DIR}")
    if d.chromium_off:
        config = json.dumps({"browser": {"defaultEngine": "webkit"}})
        g.sh(f"printf '%s\\n' {shlex.quote(config)} > {CONFIG_FILE}")


def runtime_in_bundle(g, app: str) -> list[str]:
    """The Chromium runtime paths still in the guest app."""
    checks = " ".join(shlex.quote(f"{app}/{p}") for p in CHROMIUM_RUNTIME)
    r = g.sh(f"for p in {checks}; do [ -e \"$p\" ] && echo \"$p\"; done; true")
    return [line[len(app) + 1:] for line in r.stdout.splitlines() if line.startswith(app + "/")]


def parse_zones(stdout: str) -> dict:
    """malloc-zones' output: the zone names in registration order, or the error."""
    for line in reversed(stdout.strip().splitlines()):
        try:
            value = json.loads(line)
        except ValueError:
            continue
        if isinstance(value, dict) and isinstance(value.get("zones"), list):
            zones = [str(z) for z in value["zones"]]
            # Only the order is known. The early zone's target is not named here, and its place
            # moves when the early zone registers: a run that keeps it records zones[0] alone.
            return {"zones": zones, "default_zone": zones[0] if zones else None,
                    "partition_alloc": PARTITION_ALLOC_ZONE in zones, "early_zone": EARLY_ZONE in zones}
        if isinstance(value, dict) and value.get("error"):
            return {"error": str(value["error"])}
    return {"error": "no output: " + stdout.strip()[-300:]}


def malloc_zones(g, tool: str, pid: int) -> dict:
    """The app's zones. task_for_pid needs root (sudo -n), or a same-user target without the
    hardened runtime (a re-signed guest app)."""
    if not tool:
        return {"error": "no malloc-zones tool"}
    found = {}
    for prefix in ("sudo -n ", ""):
        found = parse_zones(g.sh(f"{prefix}{shlex.quote(tool)} {pid} 2>&1", timeout=60).stdout)
        if "zones" in found:
            break
    return found


def snapshot(g, tool: str) -> dict:
    """The live app's malloc zones, whether the CEF framework is mapped, and debug.cef (DEV builds)."""
    pid = g.pid()
    if pid is None:
        return {"error": "the app is not running"}
    # The framework's file mappings (lsof lists mapped images outside the shared cache); None when lsof fails.
    mapped = g.sh(f"m=$(/usr/sbin/lsof -p {pid} -Fn 2>/dev/null) || {{ echo unknown; exit 0; }}; "
                  f"printf '%s\\n' \"$m\" | grep -c -F {shlex.quote(CHROMIUM_IMAGE)}; true").stdout.strip()
    cef = None
    r = g.cmux(["app", "call", "debug.cef", "{}"], timeout=20)
    try:
        value = json.loads((r.stdout or "").strip().splitlines()[-1])
        if r.returncode == 0 and isinstance(value, dict):
            cef = {k: value.get(k) for k in ("state", "unavailable", "default_engine", "runtime")}
    except (ValueError, IndexError):
        pass  # a release or sanitizer app refuses debug.* calls
    return {"pid": pid, "malloc": malloc_zones(g, tool, pid),
            "chromium_mapped": int(mapped) > 0 if mapped.isdigit() else None, "debug_cef": cef}


def snapshot_after_launch(g, tool: str) -> dict:
    """snapshot() once the launch work is done (LAUNCH_SETTLE_S after the first ping)."""
    time.sleep(LAUNCH_SETTLE_S)
    return snapshot(g, tool)


def validity(d: Diag, left_in_bundle: list[str], snapshots: list[dict], launched: bool = True) -> str:
    """Why a Chromium-off run is invalid, "" when it is valid (or Chromium may run).

    `launched` False: the app exited before its first ping, so no snapshot could exist; the bundle
    (no framework, no pin to download one) is then the only evidence, and enough."""
    if not d.chromium_off:
        return ""
    if left_in_bundle:
        return "the Chromium runtime is still in the app: " + ", ".join(left_in_bundle)
    for s in snapshots:
        malloc = s.get("malloc", {})
        if s.get("chromium_mapped"):
            return f"the Chromium framework is mapped in pid {s['pid']}"
        if malloc.get("partition_alloc"):
            return f"PartitionAlloc holds a malloc zone in pid {s['pid']}"
        if malloc.get("default_zone") == EARLY_ZONE:
            return f"the early zone is the default zone in pid {s['pid']} ({SKIP_EARLY_ZONE} not honored)"
    if not launched:
        return ""
    # Either check alone proves it: PartitionAlloc ships in the Chromium framework.
    if not any("zones" in s.get("malloc", {}) or s.get("chromium_mapped") is False for s in snapshots):
        return "no snapshot shows the app's malloc zones or its mapped images"
    return ""


def parse_reports(kind: str, text: str) -> list[str]:
    """The first line of each report of `kind` in `text`."""
    marker = MARKERS[kind]
    return [line.strip()[:300] for line in text.splitlines() if marker in line]


class Reports:
    """Main Thread Checker reports from the app's stderr and sanitizer reports from their log files."""

    def __init__(self, d: Diag, out: str):
        self.kind, self.out, self.found = d.report, out, []

    def harvest_stderr(self, g, tag: str) -> None:
        """Main Thread Checker reports in the app's stderr so far; call before the log is emptied.
        (Sanitizers write to their log_path files instead.)"""
        if self.kind != "mtc":
            return
        text = g.sh(f"grep -F -A 40 {shlex.quote(MARKERS[self.kind])} {APP_LOG} 2>/dev/null | head -c 4000000",
                    timeout=60).stdout
        if text.strip():
            with open(os.path.join(self.out, f"{self.kind}-stderr.txt"), "a") as f:
                f.write(f"== {tag}\n{text}\n")
            self.found += parse_reports(self.kind, text)

    def collect_files(self, g) -> None:
        """The sanitizer's log files (log_path=SAN_DIR/NAME writes NAME.PID per process)."""
        if self.kind in ("", "mtc"):
            return
        text = g.sh(f"for f in {SAN_DIR}/*; do [ -f \"$f\" ] && printf '== %s\\n' \"$f\" && cat \"$f\"; done "
                    "| head -c 20000000; true", timeout=120).stdout
        if text.strip():
            with open(os.path.join(self.out, f"{self.kind}-reports.txt"), "w") as f:
                f.write(text)
            self.found += parse_reports(self.kind, text)

    def summary(self) -> dict:
        unique = sorted(set(self.found))
        return {"kind": self.kind or None, "count": len(self.found), "unique": len(unique), "first": unique[:50]}


def record(d: Diag, env: dict[str, str], runtime_left: list[str], snapshots: list[dict], reports: Reports,
           launched: bool = True) -> dict:
    """summary.json's "diag": what ran, under which environment, with which allocator, and what it found."""
    first = next((s["malloc"] for s in snapshots if "zones" in s.get("malloc", {})), {})
    invalid = validity(d, runtime_left, snapshots, launched)
    return {"name": d.name, "env": env, "chromium": "off" if d.chromium_off else "on",
            "chromium_runtime_left": runtime_left, "launched": launched,
            "chromium_mapped": any(s.get("chromium_mapped") for s in snapshots),
            "zones": first.get("zones"), "default_zone": first.get("default_zone"),
            "early_zone": first.get("early_zone"),
            "partition_alloc": any(s.get("malloc", {}).get("partition_alloc") for s in snapshots),
            "slowdown": d.slowdown, "snapshots": snapshots, "reports": reports.summary(),
            "invalid": invalid or None}


def fuzz_verdict(s: dict, failure: str, diag: str) -> tuple[str, str]:
    """vm.sh's verdict for a fuzz or repro major (PASS, FAIL or NO-VERDICT) and its line's diag text.

    `s` is the major's summary.json ({} when there is none), `failure` the step's failure text and
    `diag` the --diag name ("" for none). A diag run without its record, or whose check could not see
    the app's allocations, proves nothing: NO-VERDICT, ahead of any crash or report it had."""
    if not s:
        return "NO-VERDICT", ""
    bad = (failure or s.get("crashes", 0) or s.get("hangs", 0) or s.get("relaunches", 0)
           or s.get("guest_lost_at") is not None or s.get("launch_failed") or s.get("diag_reports", 0))
    invalid = (s.get("invalid") or ("" if "diag" in s else "no diag record")) if diag else ""
    verdict = "NO-VERDICT" if invalid else ("FAIL" if bad else "PASS")
    if not diag:
        return verdict, ""
    d = s.get("diag") or {}
    extra = " diag=%s chromium=%s zone=%s reports=%s%s%s" % (
        diag, d.get("chromium", "?"), d.get("default_zone") or "?", s.get("diag_reports", "-"),
        " LAUNCH FAILED: %s" % s["launch_failed"] if s.get("launch_failed") else "",
        " INVALID: %s" % invalid if invalid else "")
    return verdict, extra


def main(argv: list[str]) -> int:
    if len(argv) == 2 and argv[0] == "info" and argv[1] in DIAGS:
        sys.stdout.write(info_lines(DIAGS[argv[1]]))
        return 0
    print("usage: diag.py info NAME (NAME: %s)" % ", ".join(DIAGS), file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
