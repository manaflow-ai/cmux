#!/usr/bin/env python3
"""Put one fleet build into a capture mini's build cache, once per mini and job. Runs ON the mini.

    /usr/bin/python3 -I build_cache.py JOB SHA256_HEX KEEP [COMMIT] < URL_LINE

run.py sends this program with each lease's set-up (and with `run.py --prestage`, outside any lease). It fills
~/.cache/cmux-journeys/builds/JOB/ (build/<name>.app and the `ok` marker) and prints the .app path.

- One download per mini and job (2026-11-03: cmux20 ran three downloads of one build at once, each round's set-up
  timed out and left its download running, and the next round started one more): the fill holds an exclusive lock on
  ~/.cache/cmux-journeys/locks/JOB.lock. A second set-up waits on the lock and then finds the cache filled. The lock
  dies with its holder, so a set-up that was killed leaves no stale lock. The lock folder is outside builds/, so the
  trim below never counts it.
- A download of this job by an older harness copy (no lock; its folder is JOB.tmp.<its shell pid>) is waited for
  while it still makes progress at TAKEOVER_BYTES_PER_SECOND or more; a crawling one does not hold this set-up.
- The first input line is the store's signed URL (or empty): it never goes on a command line or in a log. One
  connection to the store edge runs at 30-46 MB/s or crawls at 0.1-1 MB/s for its whole life (measured on the minis,
  2026-11-03 05:18Z); a new connection is usually fast. So a connection under SLOW_BYTES_PER_SECOND for SLOW_SECONDS
  is dropped and opened again (CONNECT_TRIES at most), and the file is checked against SHA256_HEX. With no URL, or
  when every try fails, `cmux-ci artifact JOB` reads it (it checks the hash itself).
- The newest KEEP builds (by time; folders being filled are not counted) stay; older ones are removed.
Exit 0 with the .app path on stdout; 2 when the build could not be put in the cache.
"""
import fcntl
import glob
import hashlib
import os
import shutil
import subprocess
import sys
import time
import zipfile

SLOW_BYTES_PER_SECOND = 3_000_000
SLOW_SECONDS = 10
CONNECT_TRIES = 6
TAKEOVER_BYTES_PER_SECOND = 2_000_000
TAKEOVER_PROBE_SECONDS = float(os.environ.get("JOURNEYS_TAKEOVER_PROBE_SECONDS") or 15)  # shorter in tests


def say(message):
    # A set-up whose ssh went away (run.py's timeout) keeps filling the cache for the next round: a closed stderr
    # must not stop it halfway (review of #33108, finding 6).
    try:
        print(f"journeys: {message}", file=sys.stderr, flush=True)
    except OSError:
        pass


def remove_dead_temporaries(builds):
    """Remove the <job>.tmp.<pid> folders whose process is gone (a fill that was killed). Under the job's lock, and
    never the folder of a live process: a slow download by an older harness copy keeps its folder (before, a
    60-minute find removed it under that download; review of #33108, finding 7)."""
    for name in os.listdir(builds):
        stem, sep, pid = name.rpartition(".tmp.")
        if sep and pid.isdigit() and int(pid) != os.getpid() and not alive(int(pid)):
            shutil.rmtree(os.path.join(builds, name), ignore_errors=True)


def clear(cache):
    """Remove CACHE, a folder or (an older copy's `touch "$c"` after its folder went away) a plain file."""
    if os.path.isdir(cache) and not os.path.islink(cache):
        shutil.rmtree(cache, ignore_errors=True)
    else:
        try:
            os.unlink(cache)
        except OSError:
            pass


def install(temporary, cache):
    """Move the filled TEMPORARY to CACHE. The `ok` marker is written first, inside TEMPORARY, so CACHE appears
    complete or not at all. An older harness copy (no lock) may move its own copy to CACHE at the same moment
    (`rm -rf "$c"; mv "$t" "$c"; touch "$c/ok"`): then the rename fails or CACHE is replaced; whichever copy is in
    place once it is filled is kept (review of #33108, finding 1)."""
    open(os.path.join(temporary, "ok"), "w").close()
    for _ in range(3):
        if filled(cache):
            shutil.rmtree(temporary, ignore_errors=True)
            return
        if app_in(cache):  # an older copy moved its build in and has yet to touch its ok: give it a moment
            time.sleep(1)
            if filled(cache):
                continue
        clear(cache)
        try:
            os.rename(temporary, cache)
            return
        except OSError:  # another copy came in between (ENOTEMPTY, EEXIST): give its ok a moment
            time.sleep(1)
    if not filled(cache):
        raise RuntimeError(f"{cache}: another fill keeps replacing it")
    shutil.rmtree(temporary, ignore_errors=True)


def cache_root():
    return os.environ.get("JOURNEYS_CACHE_ROOT") or os.path.expanduser("~/.cache/cmux-journeys")


def app_in(folder):
    found = sorted(glob.glob(os.path.join(folder, "build", "*.app")) + glob.glob(os.path.join(folder, "build", "*", "*.app")))
    return found[0] if found else ""


def filled(folder):
    return os.path.isfile(os.path.join(folder, "ok")) and app_in(folder)


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def folder_bytes(folder):
    total = 0
    for base, _, files in os.walk(folder):
        for name in files:
            try:
                total += os.path.getsize(os.path.join(base, name))
            except OSError:
                pass
    return total


def wait_for_older_download(cache):
    """Wait while a live, unlocked download of this job (an older harness copy's) still makes progress fast enough."""
    while not filled(cache):
        live = []
        for other in glob.glob(cache + ".tmp.*"):
            try:
                pid = int(other.rsplit(".", 1)[1])
            except ValueError:
                continue
            if pid != os.getpid() and alive(pid):
                live.append(other)
        if not live:
            return
        before = sum(folder_bytes(o) for o in live)
        time.sleep(TAKEOVER_PROBE_SECONDS)
        rate = (sum(folder_bytes(o) for o in live) - before) / TAKEOVER_PROBE_SECONDS
        if rate < TAKEOVER_BYTES_PER_SECOND:
            say(f"another download of this build crawls at {rate / 1e6:.2f} MB/s: not waiting for it")
            return
        say(f"waiting for another download of this build ({rate / 1e6:.1f} MB/s)")


def sha256_of(path):
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def fetch_direct(url, zip_path, want):
    config = 'url = "%s"\n' % url.replace('"', "%22")
    for attempt in range(1, CONNECT_TRIES + 1):
        done = subprocess.run(["curl", "-fsS", "--connect-timeout", "20", "--max-time", "1200",
                               "--speed-limit", str(SLOW_BYTES_PER_SECOND), "--speed-time", str(SLOW_SECONDS),
                               "-H", "User-Agent: cmux-ci", "-o", zip_path, "-K", "-"], input=config.encode())
        if done.returncode == 0:
            if sha256_of(zip_path) == want:
                return attempt
            say(f"store read {attempt}: the file's sha256 does not match")
            return 0  # the same object again will not match: take cmux-ci at once
        say(f"store read {attempt}: curl exit {done.returncode} (28: slower than "
            f"{SLOW_BYTES_PER_SECOND / 1e6:.0f} MB/s for {SLOW_SECONDS}s)")
    return 0


def fetch_cmux_ci(job, zip_path):
    tool = os.environ.get("JOURNEYS_CMUX_CI") or shutil.which("cmux-ci") or os.path.expanduser("~/.local/bin/cmux-ci")
    # Its output goes through say(), never straight to fd 2: when the caller's ssh is gone, a write to that closed pipe
    # would fail the client's exit (Python ignores SIGPIPE) after a whole good download (review of #33170).
    proc = subprocess.Popen([tool, "artifact", job, zip_path], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            stdin=subprocess.DEVNULL)
    for line in proc.stdout:
        say(line.decode(errors="replace").rstrip())
    return proc.wait() == 0


def unpack(zip_path, into):
    if shutil.which("ditto"):  # macOS: keeps the bundle's symlinks, modes and extended attributes
        return subprocess.run(["ditto", "-x", "-k", zip_path, into]).returncode == 0
    try:
        with zipfile.ZipFile(zip_path) as z:
            z.extractall(into)
        return True
    except (OSError, zipfile.BadZipFile):
        return False


def trim(builds, keep):
    def mtime(name):
        try:
            return os.path.getmtime(os.path.join(builds, name))
        except OSError:  # removed meanwhile by another fill's trim
            return 0.0
    names = [n for n in os.listdir(builds) if ".tmp." not in n]
    names.sort(key=mtime, reverse=True)
    for old in names[keep:]:
        shutil.rmtree(os.path.join(builds, old), ignore_errors=True)


def fill(job, want, keep, url):
    root = cache_root()
    builds, locks = os.path.join(root, "builds"), os.path.join(root, "locks")
    os.makedirs(builds, exist_ok=True)
    os.makedirs(locks, exist_ok=True)
    cache = os.path.join(builds, job)
    lock = open(os.path.join(locks, job + ".lock"), "a")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        say(f"another set-up on this mini downloads build {job}: waiting for it")
        fcntl.flock(lock, fcntl.LOCK_EX)
    remove_dead_temporaries(builds)
    if filled(cache):
        say("build cache hit")
        os.utime(cache)
        return app_in(cache)
    wait_for_older_download(cache)
    if filled(cache):
        say("build cache hit (an older download filled it)")
        os.utime(cache)
        return app_in(cache)
    temporary = "%s.tmp.%d" % (cache, os.getpid())
    shutil.rmtree(temporary, ignore_errors=True)
    os.makedirs(temporary)
    zip_path = os.path.join(temporary, "app.zip")
    started = time.monotonic()
    tries = fetch_direct(url, zip_path, want) if url and len(want) == 64 else 0
    route = f"store, {tries} connection(s)"
    if not tries:
        route = "cmux-ci artifact"
        try:
            os.unlink(zip_path)
        except OSError:
            pass
        if not fetch_cmux_ci(job, zip_path):
            shutil.rmtree(temporary, ignore_errors=True)
            raise RuntimeError(f"build {job} could not be downloaded")
    size, spent = os.path.getsize(zip_path), max(time.monotonic() - started, 0.001)
    if not unpack(zip_path, os.path.join(temporary, "build")):
        shutil.rmtree(temporary, ignore_errors=True)
        raise RuntimeError(f"build {job}: the zip did not unpack")
    os.unlink(zip_path)
    install(temporary, cache)
    os.utime(cache)
    trim(builds, keep)
    say(f"build {job}: {size / 1e6:.0f} MB in {spent:.0f}s ({size / spent / 1e6:.1f} MB/s, {route})")
    return app_in(cache)


def main(argv):
    if len(argv) < 3:
        say("usage: build_cache.py JOB SHA256_HEX KEEP [COMMIT] < URL_LINE")
        return 2
    job, want, keep = argv[0], argv[1].removeprefix("sha256:"), int(argv[2])
    commit = argv[3] if len(argv) > 3 else ""
    url = (sys.stdin.readline() if not sys.stdin.isatty() else "").strip()
    try:
        app = fill(job, want, keep, url)
    except (RuntimeError, OSError) as error:
        say(str(error))
        return 2
    if not app:
        say(f"build {job} has no app bundle")
        return 2
    if len(commit) == 40:
        # The commit the build job names, beside the bundle: capture-host launch --commit checks it.
        with open(os.path.join(os.path.dirname(app), "capture-commit"), "w") as f:
            f.write(commit + "\n")
    try:
        print(app)
    except OSError:  # the caller is gone; the cache is filled for the next round
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
