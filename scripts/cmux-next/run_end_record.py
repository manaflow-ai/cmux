"""How the app's last run ended, and how this run's own launch ends, for a driver that launches a tagged DEV app
(cmd-n-paint-e2e.py --screen).

The app keeps a record of a run while the run lives (AppRunMarker.swift), in
`<the account's home>/Library/Application Support/cmux-next/<bundle id>/`: `run.json` (the process, its launch
time, `recovery`: this launch follows a crash or a quick kill, `quitting`: a quit that was asked for began, the
build), `run.signal` (empty until a signal's handler writes the signal's number) and `run.exception` (an uncaught
exception). A normal quit removes them. The next launch reads what a run left (LaunchRecovery.swift): a run that
left a fatal signal or an exception crashed, and that launch then shows a notice in its window and writes a
report of its own into `<home>/Library/Logs/cmux-next/<bundle id>-app-<time>.json`. The folder is per bundle id
and under the account's home, so it stays from one run of a tag to the next: a launch for a measure can then show
the notice of ANOTHER run's crash, and nothing in the measure's log says which run that was.

So the driver
  1. prints what is there, whole, BEFORE it changes a thing (`last`; each line starts `LAST-END-RECORD`): the 3
     files, the newest reports of the app's own writer, and the names of the system's crash reports of the app;
  2. moves the 3 files aside (`set_aside`). The folder's other files (the crash forwarders' own) stay;
  3. after its launch reads `run.json` again (`launch_fault`): it must be this launch's and say `recovery` false.
     A launch that does not say so is not known to be a clean one, and each row of the driver is INVALID;
  4. at its end, after its quit, prints what its OWN launch left (`own`; each line starts `OWN-END-RECORD`) and
     says whether that run crashed: a fatal signal's number in `run.signal`, a `run.exception`, or a process that
     a fatal signal ended. A quit that the driver had to end with KILL is printed, and is not a crash by itself.

This reads files and prints. It does not say why a run crashed: the system's report of the crash has that.
"""
import glob
import json
import os
import signal
import time

import bench_launch

LAST, OWN = "LAST-END-RECORD", "OWN-END-RECORD"
FILES = ("run.json", "run.signal", "run.exception")
# LaunchRecovery.requestedQuitSignals, and the signals of AppRunMarker.installHandlers that are no asked quit.
ASKED = {int(getattr(signal, name)) for name in ("SIGTERM", "SIGINT", "SIGHUP")}
FATAL = {int(getattr(signal, name)) for name in ("SIGSEGV", "SIGBUS", "SIGILL", "SIGABRT", "SIGTRAP", "SIGFPE", "SIGSYS")}
WHOLE = 20000  # the most characters of one file that a line prints
REPORTS = 2  # the newest reports of the app's own writer that are printed whole


def safe(text):
    """CrashReportWriter.safe: a letter, a number, `.` and `-` stay, each other character is `_`."""
    return "".join(c if c.isalnum() or c in ".-" else "_" for c in text)


def signal_name(number):
    try:
        return signal.Signals(number).name
    except ValueError:
        return "a signal with no name"


class RunEnd:
    """The record of one bundle (`app`: its path). `home`: the account's home (the app's own). `out`: the printer."""

    def __init__(self, app, home=None, out=None):
        self.app = os.path.realpath(app)
        self.bundle = bench_launch.bundle_id(self.app) or "unknown"  # AppRunMarker.standardDirectory's word for no id
        self.home = home or bench_launch.account_home()
        self.folder = os.path.join(self.home, "Library/Application Support/cmux-next", safe(self.bundle))
        self.out = out or (lambda line: print(line, flush=True))
        self.ended = None  # `own`'s answer, after its one print

    def read(self):
        """The 3 files as they are now: {name: text} for each that is there (`run.signal` is empty in a live run)."""
        found = {}
        for name in FILES:
            try:
                with open(os.path.join(self.folder, name), errors="replace") as handle:
                    found[name] = handle.read()
            except OSError:
                continue
        return found

    @staticmethod
    def facts(found):
        """(run.json as an object or None, the signal's number or None, an exception was recorded)."""
        try:
            run = json.loads(found.get("run.json") or "")
        except ValueError:
            run = None
        first = (found.get("run.signal") or "").strip().splitlines()[:1]
        number = int(first[0]) if first and first[0].strip().isdigit() and int(first[0]) > 0 else None
        return (run if isinstance(run, dict) else None), number, bool((found.get("run.exception") or "").strip())

    @classmethod
    def verdict(cls, found):
        """What the files say about the run that left them, by the app's own rule (PreviousRun, LaunchRecovery.decide)."""
        run, number, exception = cls.facts(found)
        if not found:
            return "no record: the last run of this bundle quit as it was asked to, or the bundle did not run on this account"
        if number in ASKED:
            return f"ended as asked: signal {number} ({signal_name(number)}), a quit signal"
        if number:
            return f"CRASHED: signal {number} ({signal_name(number)})"
        if exception:
            return "CRASHED: an uncaught exception" if not (run or {}).get("quitting") else "ended as asked by the app's rule: an exception in a quit that had begun"
        if run is None:
            return "not known: no run.json that can be read"
        if run.get("quitting"):
            return "a quit that was asked for began and did not come to its end (the app's rule: ended as asked)"
        return "ended with no signal handler: a KILL, the system, or the power (the app's rule: no crash)"

    def whole(self, mark, name, text):
        cut = "" if len(text) <= WHOLE else f" (the first {WHOLE} of {len(text)} characters)"
        self.out(f"{mark} {name}{cut}: {text[:WHOLE].strip() or '(empty)'}")

    def last(self, now=None):
        """Prints the record that the bundle's last run left, whole. Changes nothing. Returns the files' texts."""
        found = self.read()
        self.out(f"{LAST} bundle {self.bundle}; folder {self.folder}; files: {', '.join(sorted(found)) or 'none'}")
        for name in FILES:
            if name in found:
                self.whole(LAST, name, found[name])
        self.out(f"{LAST} verdict: {self.verdict(found)}")
        logs = os.path.join(self.home, "Library/Logs/cmux-next")
        reports = sorted(glob.glob(os.path.join(glob.escape(logs), f"{glob.escape(safe(self.bundle))}-app-*.json")), key=os.path.getmtime)
        self.out(f"{LAST} the app's own crash reports of this bundle in {logs}: {len(reports)}"
                 + ("" if not reports else "; the newest: " + ", ".join(os.path.basename(path) for path in reports[-5:])))
        for path in reports[-REPORTS:]:
            try:
                with open(path, errors="replace") as handle:
                    self.whole(LAST, os.path.basename(path), handle.read())
            except OSError as error:
                self.out(f"{LAST} {os.path.basename(path)}: not read ({error})")
        # The system's own reports of this app's name from the last 14 days: their names, and the newest one's summary.
        name = os.path.basename(self.app)
        system = bench_launch.crash_report_candidates((now or time.time()) - 14 * 86400, name[:-4] if name.endswith(".app") else name)
        self.out(f"{LAST} the system's reports of the app from the last 14 days: {len(system)}"
                 + ("" if not system else "; the newest: " + ", ".join(os.path.basename(path) for path in system[-5:])))
        if system:
            self.out(f"{LAST} {os.path.basename(system[-1])}: {bench_launch.crash_summary(system[-1])}")
        return found

    def set_aside(self):
        """Moves the 3 files into `<folder>.bench-prev` (over what an earlier run moved there): the next launch
        then follows no run. Call it only while no app of the bundle runs. Returns the names that moved."""
        aside, moved = self.folder + ".bench-prev", []
        for name in FILES:
            source = os.path.join(self.folder, name)
            if os.path.exists(source):
                os.makedirs(aside, exist_ok=True)
                os.replace(source, os.path.join(aside, name))
                moved.append(name)
        self.out(f"{LAST} moved aside into {aside}: {', '.join(moved) or 'nothing'}")
        return moved

    def launch_fault(self, pid):
        """None when `run.json` is the launch `pid`'s and says that the launch follows no crash and no quick kill;
        else the reason, for each row of the driver. Prints the file."""
        found = self.read()
        run, _, _ = self.facts(found)
        self.whole(OWN, "at the launch, run.json", found.get("run.json") or "")
        fault = None
        if run is None:
            fault = f"launch: no run.json of this launch in {self.folder}: the app does not say that it started with no restart"
        elif run.get("pid") != pid:
            fault = f"launch: run.json is of the process {run.get('pid')}, and this launch is the process {pid}"
        elif run.get("recovery") is not False:
            fault = (f"launch: run.json says `recovery` {json.dumps(run.get('recovery'))}: the launch follows a crash or a quick "
                     "kill of the bundle's last run, and the window can show the notice of it")
        self.out(f"{OWN} at the launch: {fault or f'run.json is of this launch (the process {pid}) and says no restart'}")
        return fault

    def own(self, pid, quit_fact):
        """Prints what the launch `pid` left after the driver's quit (`quit_fact`: what the quit did, with the
        process's `returncode`). Returns True when that run crashed. A second call prints nothing more."""
        if self.ended is not None:
            return self.ended
        self.ended = self._own(pid, quit_fact)
        return self.ended

    def _own(self, pid, quit_fact):
        found = self.read()
        run, number, exception = self.facts(found)
        mine = run is not None and run.get("pid") == pid
        self.out(f"{OWN} the driver's quit: {json.dumps(quit_fact, default=str)}")
        self.out(f"{OWN} files after the quit: {', '.join(sorted(found)) or 'none (a quit that came to its end removes them)'}"
                 + ("" if not found or mine else f"; run.json is not of this launch's process {pid}"))
        for name in FILES:
            if name in found:
                self.whole(OWN, name, found[name])
        code = (quit_fact or {}).get("returncode")
        by_signal = -code if isinstance(code, int) and code < 0 else None
        crashed = bool(mine and ((number and number not in ASKED) or exception)) or by_signal in FATAL
        self.out(f"{OWN} verdict: " + (
            "THIS RUN CRASHED: " + (f"signal {number} ({signal_name(number)}) in run.signal" if mine and number and number not in ASKED
                                    else "an uncaught exception in run.exception" if mine and exception
                                    else f"the process ended by signal {by_signal} ({signal_name(by_signal)})")
            if crashed else f"no crash of this run ({self.verdict(found) if mine else 'no record of it is left'})"))
        return crashed
