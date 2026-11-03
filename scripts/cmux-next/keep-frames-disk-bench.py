#!/usr/bin/env python3
"""REOPEN-F6 disk cost: what the app writes while its 12-pane HEAVY session runs, before and after the launch frame
keeper (each shown terminal's last frame kept on disk while the app runs, TerminalLaunchFrameKeeper).

  scripts/cmux-next/keep-frames-disk-bench.py --app APP --tag TAG --out DIR [--json FILE] [--seconds 60] [--seed 7]

Launches the tagged app (bench_launch.BenchApp), builds the HEAVY profile in it (scripts/journeys/tui-kit/
heavy_profile.py: 12 TUI panes repainting in the shown workspace, plus a browser and an agent pane), waits
--settle seconds, then measures for --seconds, in two phases:

  heavy  the 12 TUI panes run (gradient, flood, vim-scroll, top, ...);
  idle   the same layout after the programs end (heavy_profile --duration), every pane quiet.

Per phase: the app process's logical bytes written per second (proc_pid_rusage ri_logical_writes, as #31643's
daemon table) and disk bytes written (ri_diskio_byteswritten); the launch frame folder's writes (files whose mtime
or size changed, polled every 0.2 s) per second and bytes per second, in all and per shown terminal; the newest
frame's age at the end of the phase (the staleness a kill then would show). Writes report.json; prints one line
KEEP-FRAMES-DISK {json}. Quits the app and tears the HEAVY profile down.
"""
import argparse, ctypes, json, os, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from bench_launch import BenchApp, LaunchError  # noqa: E402

KIT = os.path.join(HERE, "..", "journeys", "tui-kit", "heavy_profile.py")


class RUsage(ctypes.Structure):
    _fields_ = [(name, ctypes.c_uint64) for name in (
        "ri_uuid0", "ri_uuid1", "ri_user_time", "ri_system_time", "ri_pkg_idle_wkups", "ri_interrupt_wkups",
        "ri_pageins", "ri_wired_size", "ri_resident_size", "ri_phys_footprint", "ri_proc_start_abstime",
        "ri_proc_exit_abstime", "ri_child_user_time", "ri_child_system_time", "ri_child_pkg_idle_wkups",
        "ri_child_interrupt_wkups", "ri_child_pageins", "ri_child_elapsed_abstime", "ri_diskio_bytesread",
        "ri_diskio_byteswritten", "ri_cpu_time_qos_default", "ri_cpu_time_qos_maintenance",
        "ri_cpu_time_qos_background", "ri_cpu_time_qos_utility", "ri_cpu_time_qos_legacy",
        "ri_cpu_time_qos_user_initiated", "ri_cpu_time_qos_user_interactive", "ri_billed_system_time",
        "ri_serviced_system_time", "ri_logical_writes", "ri_lifetime_max_phys_footprint", "ri_instructions", "ri_cycles",
        "ri_billed_energy", "ri_serviced_energy", "ri_interval_max_phys_footprint", "ri_runnable_time")] + [
        # Spare room: a later kernel's V4 may be longer; the kernel must never write past this buffer (a too-short struct
        # segfaulted this bench at its first read, job fbe8728d).
        ("ri_spare", ctypes.c_uint64 * 32)]


_LIBC = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
_LIBC.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
_LIBC.proc_pid_rusage.restype = ctypes.c_int


def rusage(pid):
    """RUSAGE_INFO_V4 of `pid` (ri_logical_writes is in V4), or None."""
    info = RUsage()
    return info if _LIBC.proc_pid_rusage(pid, 4, ctypes.byref(info)) == 0 else None


def frame_files(directory):
    """{name: (mtime_ns, size)} of the launch frame folder."""
    out = {}
    try:
        for name in os.listdir(directory):
            try:
                st = os.stat(os.path.join(directory, name))
            except OSError:
                continue
            out[name] = (st.st_mtime_ns, st.st_size)
    except OSError:
        pass
    return out


def measure(pid, directory, seconds):
    """One phase: rusage deltas and the frame folder's writes, polled every 0.2 s."""
    start, began = rusage(pid), time.monotonic()
    last = frame_files(directory)
    writes, bytes_written, per_key = 0, 0, {}
    while time.monotonic() - began < seconds:
        time.sleep(0.2)  # bench: poll the frame folder
        now = frame_files(directory)
        for name, (mtime, size) in now.items():
            if last.get(name) != (mtime, size):
                writes += 1
                bytes_written += size
                key = name.split("@", 1)[0]
                per_key[key] = per_key.get(key, 0) + 1
        last = now
    end, elapsed = rusage(pid), time.monotonic() - began
    newest = max((m for m, _ in last.values()), default=None)
    row = {"seconds": round(elapsed, 1), "frame_files": len(last),
           "frame_writes_per_s": round(writes / elapsed, 3), "frame_bytes_per_s": round(bytes_written / elapsed, 1),
           "frame_writes_per_terminal_per_s": {k: round(v / elapsed, 3) for k, v in sorted(per_key.items())},
           "newest_frame_age_s": None if newest is None else round(time.time() - newest / 1e9, 2)}
    if start and end:
        row["app_logical_write_bytes_per_s"] = round((end.ri_logical_writes - start.ri_logical_writes) / elapsed, 1)
        row["app_disk_write_bytes_per_s"] = round((end.ri_diskio_byteswritten - start.ri_diskio_byteswritten) / elapsed, 1)
    return row


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--json")
    parser.add_argument("--seconds", type=float, default=60)
    parser.add_argument("--settle", type=float, default=15)
    parser.add_argument("--seed", type=int, default=7)
    parser.add_argument("--heavy-duration", type=float, default=120, help="seconds the HEAVY programs run, then end")
    opts, _ = parser.parse_known_args()
    os.makedirs(opts.out, exist_ok=True)
    report = {"seconds": opts.seconds, "seed": opts.seed}
    bench = BenchApp(opts.app, out=opts.out, log_name="app.log")
    manifest = None
    try:
        try:
            bench.launch(timeout=180)
        except LaunchError as error:
            report["launch_failure"] = {"reason": error.reason, "detail": error.report.get("detail")}
            raise
        pid = bench.process.pid
        # Beside the sidebar snapshot: a tagged build's state folder, cmux/tags/<tag>/ (SidebarSnapshotFile).
        directory = os.path.join(bench.state_root(), "terminal-launch-frames")
        heavy_out = os.path.join(opts.out, "heavy")
        built = subprocess.run([sys.executable, KIT, "build", "--tag", opts.tag, "--app-socket", bench.socket,
                                "--seed", str(opts.seed), "--duration", str(opts.heavy_duration), "--out", heavy_out,
                                "--build-bins"], capture_output=True, text=True, timeout=1800)
        manifest = os.path.join(heavy_out, "heavy.json")
        report["heavy_build"] = {"exit": built.returncode, "out": built.stdout.strip()[-600:], "err": built.stderr.strip()[-600:]}
        report["frame_directory"] = directory
        time.sleep(opts.settle)  # bench: the HEAVY programs start and the panes draw
        report["heavy"] = measure(pid, directory, opts.seconds)
        # The programs end after --heavy-duration; the idle phase starts once they did.
        rest = opts.heavy_duration - opts.settle - opts.seconds + 10
        if rest > 0:
            time.sleep(rest)  # bench: the HEAVY programs end
        report["idle"] = measure(pid, directory, opts.seconds)
    finally:
        if manifest and os.path.exists(manifest):
            subprocess.run([sys.executable, KIT, "teardown", "--manifest", manifest, "--app-socket", bench.socket],
                           capture_output=True, text=True, timeout=300)
        bench.stop()
        print("KEEP-FRAMES-DISK " + json.dumps(report), flush=True)
        path = opts.json or os.path.join(opts.out, "report.json")
        with open(path, "w") as out:
            json.dump(report, out, indent=1)


if __name__ == "__main__":
    main()
