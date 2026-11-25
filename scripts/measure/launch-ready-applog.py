#!/usr/bin/env python3
"""launch-ready.sh other=: the durations an app logs about its own launch, read from its unified log.

    launch-ready-applog.py STREAM.ndjson ROW_JSON   (prints ROW_JSON with app_log and app_log_at added)

STREAM.ndjson is `log stream --style ndjson --level info --predicate 'process == "EXE"'` for one launch. Every
`NAME=N ms` pair in a message (an app's own "first frame ... launch_to_first_frame=412 ms") is kept, the first one of
each NAME: app_log {NAME: N}, what the app says, on its own clock; app_log_at {NAME: ms}, when the message carrying it
was logged, in ms from the process start (the row's start_epoch_ms), the clock the row's other times use. A row whose
stream could not be read gets app_log_error.
"""

import datetime
import json
import re
import sys

PAIR = re.compile(r"\b([A-Za-z][A-Za-z0-9_.]*)=(-?\d+(?:\.\d+)?) ?ms\b")


def epoch_ms(stamp):
    """`log`'s ndjson timestamp ("2026-11-21 08:56:17.123456+0000") in ms since the epoch, or None."""
    try:
        return datetime.datetime.strptime(stamp, "%Y-%m-%d %H:%M:%S.%f%z").timestamp() * 1000
    except (TypeError, ValueError):
        return None


def read(lines, start_ms):
    values, at = {}, {}
    for line in lines:
        try:
            event = json.loads(line)
        except ValueError:
            continue  # log's "Filtering the log data using ..." header
        if not isinstance(event, dict):
            continue
        when = epoch_ms(event.get("timestamp"))
        for name, value in PAIR.findall(event.get("eventMessage") or ""):
            if name in values:
                continue
            number = float(value)
            values[name] = int(number) if number.is_integer() else number
            at[name] = round(when - start_ms, 1) if when is not None and start_ms else None
    return values, at


def main(argv):
    row = json.loads(argv[2])
    try:
        with open(argv[1], encoding="utf-8", errors="replace") as handle:
            values, at = read(handle, row.get("start_epoch_ms"))
    except OSError as error:
        row["app_log_error"] = str(error)
        values, at = {}, {}
    row["app_log"], row["app_log_at"] = values, at
    print(json.dumps(row, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
