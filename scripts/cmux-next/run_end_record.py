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
     files, the newest reports of the app's own writer, and the system's reports of the bundle from the last 14
     days. A report of the system is the bundle's by the bundle id that the report itself names: the system names
     a report's file after the PROCESS, and a build's process does not have the app folder's name, so a search by
     file name alone finds none. The newest of them are printed with the crashed thread's first 12 frames and the
     build that the report names. A commit is printed only where a record has one (`run.json`, a report of the
     app's own writer): a report of the system names a version, a process and an image's uuid, and no commit;
  2. moves the 3 files aside (`set_aside`). The folder's other files (the crash forwarders' own) stay;
  3. after its launch reads `run.json` again (`launch_fault`): it must be this launch's and say `recovery` false.
     A launch that does not say so is not known to be a clean one, and each row of the driver is INVALID;
  4. at its end, after its quit, prints what its OWN launch left (`own`; each line starts `OWN-END-RECORD`) and
     says whether that run crashed: a fatal signal's number in `run.signal`, a `run.exception`, or a process that
     a fatal signal ended. A quit that the driver had to end with KILL is printed, and is not a crash by itself.

This reads files and prints. It gives no cause of a crash: the frames are the report's own, as the report has them.
"""
import glob
import json
import os
import re
import signal
import time

import bench_launch

LAST, OWN = "LAST-END-RECORD", "OWN-END-RECORD"
FILES = ("run.json", "run.signal", "run.exception")
# LaunchRecovery.requestedQuitSignals, and the signals of AppRunMarker.installHandlers that are no asked quit.
ASKED = {int(getattr(signal, name)) for name in ("SIGTERM", "SIGINT", "SIGHUP")}
FATAL = {int(getattr(signal, name)) for name in ("SIGSEGV", "SIGBUS", "SIGILL", "SIGABRT", "SIGTRAP", "SIGFPE", "SIGSYS")}
WHOLE = 20000  # the most characters of one file that a line prints
REPORTS = 2  # the newest reports of the app's own writer that are printed whole, and of the system's with their frames
REPORT_DAYS = 14  # a report of the system that is older is not searched
REPORT_FILES = 400  # the newest files of the system's report folders that are read
REPORT_BYTES = 16 << 20  # a larger file is not read: it is then the bundle's only by its name
FRAMES = 12  # the crashed thread's first frames that are printed


def safe(text):
    """CrashReportWriter.safe: a letter, a number, `.` and `-` stay, each other character is `_`."""
    return "".join(c if c.isalnum() or c in ".-" else "_" for c in text)


def signal_name(number):
    try:
        return signal.Signals(number).name
    except ValueError:
        return "a signal with no name"


def build_said(record, where="report"):
    """The build that a record of the app names (`run.json`: `where` is `record`; a report of the app's own writer):
    its version, and its commit when it has one. No commit there: the words say so, and the tool gives none."""
    version, commit = record.get("version"), record.get("commit")
    return (f"version {version}" if version else f"version: not in the {where}") + "; " + (f"commit {commit}" if commit else f"commit: not in the {where}")


def report_parts(text):
    """A report of the system in its form of a header line and a body, each an object: (header, body). A part that
    is no object is None; a text report gives (None, None)."""
    if not text.lstrip().startswith("{"):
        return None, None
    head, _, rest = text.lstrip().partition("\n")
    parts = []
    for part in (head, rest):
        try:
            value = json.loads(part)
        except ValueError:
            value = None
        parts.append(value if isinstance(value, dict) else None)
    return parts[0], parts[1]


def crashed_thread(body):
    """(the crashed thread's number, the thread) of a report's body: `faultingThread`, else the thread that the
    report marks `triggered`. (None, None) when the body names none."""
    threads = [thread for thread in body.get("threads") or [] if isinstance(thread, dict)]
    index = body.get("faultingThread")
    if not isinstance(index, int) or isinstance(index, bool) or not 0 <= index < len(threads):
        index = next((at for at, thread in enumerate(threads) if thread.get("triggered")), None)
    return (None, None) if index is None else (index, threads[index])


def frame_said(frame, images):
    """One frame of a report's thread: its image's name, then its symbol and the place in it, or its place in the
    image when the report has no symbol for it."""
    at = frame.get("imageIndex")
    image = images[at] if isinstance(at, int) and not isinstance(at, bool) and 0 <= at < len(images) and isinstance(images[at], dict) else {}
    name = image.get("name") or os.path.basename(str(image.get("path") or "")) or f"image {at}"
    if frame.get("symbol"):
        return f"{name} {frame['symbol']} + {frame.get('symbolLocation', 0)}"
    offset = frame.get("imageOffset")
    return f"{name} {hex(offset) if isinstance(offset, int) else offset} (no symbol)"


class RunEnd:
    """The record of one bundle (`app`: its path). `home`: the account's home (the app's own). `out`: the printer."""

    def __init__(self, app, home=None, out=None):
        self.app = os.path.realpath(app)
        self.bundle = bench_launch.bundle_id(self.app) or "unknown"  # AppRunMarker.standardDirectory's word for no id
        self.home = home or bench_launch.account_home()
        # The system's report folders: the account's and, for the machine's own account, the machine's; each with
        # the folder into which the system moves older reports.
        tops = [os.path.join(self.home, "Library/Logs/DiagnosticReports")] + ([] if home else ["/Library/Logs/DiagnosticReports"])
        self.report_folders = [path for top in tops for path in (top, os.path.join(top, "Retired"))]
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
        if self.facts(found)[0] is not None:
            self.out(f"{LAST} run.json build: {build_said(self.facts(found)[0], 'record')}")
        self.out(f"{LAST} verdict: {self.verdict(found)}")
        logs = os.path.join(self.home, "Library/Logs/cmux-next")
        reports = sorted(glob.glob(os.path.join(glob.escape(logs), f"{glob.escape(safe(self.bundle))}-app-*.json")), key=os.path.getmtime)
        self.out(f"{LAST} the app's own crash reports of this bundle in {logs}: {len(reports)}"
                 + ("" if not reports else "; the newest: " + ", ".join(os.path.basename(path) for path in reports[-5:])))
        for path in reports[-REPORTS:]:
            try:
                with open(path, errors="replace") as handle:
                    text = handle.read()
            except OSError as error:
                self.out(f"{LAST} {os.path.basename(path)}: not read ({error})")
                continue
            self.whole(LAST, os.path.basename(path), text)
            try:
                record = json.loads(text)
            except ValueError:
                record = None
            if isinstance(record, dict):
                self.out(f"{LAST} {os.path.basename(path)} build: {build_said(record)}")
        # The system's reports of this bundle from the last 14 days: their names, and the newest ones with their frames.
        system, searched, missed, not_read = self.system_reports(now or time.time())
        self.out(f"{LAST} the system's reports of this bundle from the last {REPORT_DAYS} days: {len(system)}"
                 + ("" if not system else "; the newest: " + ", ".join(os.path.basename(path) for path, _ in system[-5:]))
                 + " (a report is the bundle's by its own bundle id; with none, by its process's path under the app; with neither, by a "
                   f"file name that starts with the app folder's name; searched: {', '.join(searched) or 'no folder'}; "
                   f"not there or not read: {', '.join(missed) or 'none'}"
                 + (f"; {not_read} older files not read: only the newest {REPORT_FILES} are" if not_read else "") + ")")
        for path, text in system[-REPORTS:]:
            self.system_report(path, text)
        return found

    def is_the_bundles(self, path, text):
        """Whether the system's report at `path` is this bundle's, and by what: its own bundle id; with none, its
        process's path under the app; with neither (also a file that was not read), a name that starts with the app
        folder's name."""
        name = os.path.basename(self.app)
        by_name = os.path.basename(path).startswith(name[:-4] if name.endswith(".app") else name)
        if text is None:
            return by_name
        header, body = report_parts(text)
        bundle = (header or {}).get("bundleID") or ((body or {}).get("bundleInfo") or {}).get("CFBundleIdentifier")
        process = (body or {}).get("procPath")
        if header is None and body is None:
            named = re.search(r"^Identifier:[ \t]+(\S.*?)[ \t]*$", text, re.M)
            placed = re.search(r"^Path:[ \t]+(\S.*?)[ \t]*$", text, re.M)
            bundle, process = named and named.group(1), placed and placed.group(1)
        if bundle:
            return bundle == self.bundle
        if process:
            return any(place.startswith(self.app + "/") for place in (str(process), os.path.realpath(str(process))))
        return by_name

    def system_reports(self, now):
        """(the bundle's reports of the system from the last REPORT_DAYS days as (path, text or None), oldest
        first; the folders that were searched; the ones that are not there or were not read; the files that were
        not read because the folders had more than REPORT_FILES of that age)."""
        since, files, searched, missed = now - REPORT_DAYS * 86400, [], [], []
        for folder in self.report_folders:
            try:
                with os.scandir(folder) as entries:
                    for entry in entries:
                        if entry.is_file() and entry.stat().st_mtime >= since:
                            files.append((entry.stat().st_mtime, entry.path, entry.stat().st_size))
                searched.append(folder)
            except OSError:
                missed.append(folder)
        files.sort()
        found = []
        for _, path, size in files[-REPORT_FILES:]:
            text = None
            if size <= REPORT_BYTES:
                try:
                    with open(path, errors="replace") as handle:
                        text = handle.read()
                except OSError:
                    text = None
            if self.is_the_bundles(path, text):
                found.append((path, text))
        return found, searched, missed, max(0, len(files) - REPORT_FILES)

    def system_report(self, path, text):
        """Prints one report of the system: its summary, the build that it names, and the crashed thread's first frames."""
        name = os.path.basename(path)
        if text is None:
            self.out(f"{LAST} {name}: not read (the bundle's by its file's name only)")
            return
        self.out(f"{LAST} {name}: {bench_launch.crash_summary(path)}")
        header, body = report_parts(text)
        if body is None:
            # A text report: the lines below its `Thread N Crashed` line, to the next empty line.
            version = re.search(r"^Version:[ \t]+(\S.*?)[ \t]*$", text, re.M)
            if version:
                self.out(f"{LAST} {name} build: version {version.group(1)}; commit: not in the report")
            lines = text.splitlines()
            start = next((at for at, line in enumerate(lines) if re.match(r"Thread \d+ Crashed", line)), None)
            if start is None:
                self.out(f"{LAST} {name} crashed thread: the report names none")
                return
            frames = []
            for line in lines[start + 1:]:
                if not line.strip():
                    break
                frames.append(line.rstrip())
            self.out(f"{LAST} {name} crashed thread: {lines[start].strip()}; {len(frames)} frames" + (f", the first {FRAMES}" if len(frames) > FRAMES else ""))
            for line in frames[:FRAMES]:
                self.out(f"{LAST} {name} frame {line}")
            return
        images = body.get("usedImages") if isinstance(body.get("usedImages"), list) else []
        info = body.get("bundleInfo") if isinstance(body.get("bundleInfo"), dict) else {}
        version = (header or {}).get("app_version") or info.get("CFBundleShortVersionString")
        build = (header or {}).get("build_version") or info.get("CFBundleVersion")
        process = body.get("procName")
        image = next((image for image in images if isinstance(image, dict) and image.get("name") == process), None)
        self.out(f"{LAST} {name} build: version {version if version else 'not in the report'}" + (f" ({build})" if build else "")
                 + f"; the process {process}; image uuid {(image or {}).get('uuid') or 'not in the report'}; commit: not in the report")
        index, thread = crashed_thread(body)
        if thread is None:
            self.out(f"{LAST} {name} crashed thread: the report names none")
            return
        frames = [frame for frame in thread.get("frames") or [] if isinstance(frame, dict)]
        where = f" (queue {thread['queue']})" if thread.get("queue") else f" (name {thread['name']})" if thread.get("name") else ""
        self.out(f"{LAST} {name} crashed thread {index}{where}: {len(frames)} frames" + (f", the first {FRAMES}" if len(frames) > FRAMES else ""))
        for at, frame in enumerate(frames[:FRAMES]):
            self.out(f"{LAST} {name} frame {at}: {frame_said(frame, images)}")

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
