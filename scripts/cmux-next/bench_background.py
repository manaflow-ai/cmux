"""Background daemon CPU over a bench round (cmux-ad 2026-11-05, STATUS 13226: mediaanalysisd took 10.6 s CPU in one arm
of an A/B on a perf mini). A round records the CPU seconds that these daemons used over its timed window; a reader drops
a round above LIMIT_S (in an A/B, the pair). Copied from frame-owner-s4's scratch sampler (c299a4668253), with the ps
time field parsed in full (days, hours, minutes, seconds) and a bad field skipping only that process."""
import os
import subprocess

DAEMONS = ("mediaanalysisd", "mds", "mds_stores", "mdworker", "mdworker_shared", "mdbulkimport",
           "photoanalysisd", "corespotlightd")
LIMIT_S = 1.0


def parse_cpu_time(field):
    """Seconds of a `ps -o time=` field: "S.ss", "M:SS.ss", "H:MM:SS" or "D-HH:MM:SS"; None when it does not parse."""
    days = 0
    text = field.strip()
    if "-" in text:
        day_text, _, text = text.partition("-")
        try:
            days = int(day_text)
        except ValueError:
            return None
    seconds = 0.0
    for part in text.split(":"):
        try:
            seconds = seconds * 60 + float(part)
        except ValueError:
            return None
    return days * 86400 + seconds


def parse_ps(text):
    """{pid: (name, CPU seconds)} of the DAEMONS in `ps -A -o pid=,time=,comm=` output."""
    found = {}
    for line in text.splitlines():
        parts = line.split(None, 2)
        if len(parts) < 3:
            continue
        name = os.path.basename(parts[2].strip())
        if name not in DAEMONS:
            continue
        seconds = parse_cpu_time(parts[1])
        if seconds is not None:
            found[parts[0]] = (name, seconds)
    return found


def sample():
    """CPU seconds so far per pid of the DAEMONS; {} when ps fails."""
    try:
        # LC_ALL=C: a comma-decimal locale would make every time field unreadable (and the round read 0 s)
        out = subprocess.run(["ps", "-A", "-o", "pid=,time=,comm="], capture_output=True, text=True, timeout=5,
                             env={**os.environ, "LC_ALL": "C"}).stdout
    except (OSError, subprocess.SubprocessError):
        return {}
    return parse_ps(out)


def delta(before, after=None):
    """CPU seconds the DAEMONS used from `before` to `after` (default: now), per name, with the total and the limit.
    A pid new since `before` counts all its time; a pid that ended counts nothing (its last seconds are unknown)."""
    after = sample() if after is None else after
    by_name = {}
    for pid, (name, seconds) in after.items():
        used = seconds - before.get(pid, (name, 0.0))[1]
        if used > 0:
            by_name[name] = round(by_name.get(name, 0.0) + used, 2)
    total = round(sum(by_name.values()), 2)
    return {"by_name": by_name, "total_s": total, "limit_s": LIMIT_S, "over_limit": total > LIMIT_S}
