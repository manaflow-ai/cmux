#!/usr/bin/env python3
"""Fetch one cache object from the site's LAN cache host through this mini's glaeda broker.

    lan_cache_fetch.py PUBLIC_URL OBJECT DEST     OBJECT is v1/<namespace>/objects/<file>

Exit 0: DEST holds the object. 3: the bucket has no such object (the cache host asked it), so the
direct download would miss too. Anything else (no broker, an older broker, the host down, a timeout):
the caller downloads from PUBLIC_URL itself.

Every mini behind the site's gateway shares one slow uplink (2026-10-27: 0.86-0.94 MB/s a mini for a
200 MB range from ci-cache.cmux.com, four at once). The LAN cache host (the fleet registry's lan-cache
role, glaeda-seed-serve --role cache) downloads each object once and serves the minis at LAN speed. A CI step cannot open a LAN socket
itself (macOS Local Network Privacy), so it asks glaeda-lan-fetch's broker, a LaunchAgent that can, over
its Unix socket.
"""

from __future__ import annotations

import json
import os
import re
import socket
import sys
import time
from pathlib import Path

SOCKET = Path(os.environ.get("CMUX_LAN_CACHE_SOCKET") or Path.home() / ".local/state/glaeda/lan-fetch/fetch.sock")
# glaeda-lan-fetch CACHE_DEADLINE (5400 s) plus margin: the host may be filling the object from the bucket.
TIMEOUT = float(os.environ.get("CMUX_LAN_CACHE_TIMEOUT") or 5420)
OBJECT_RE = re.compile(r"v1/([A-Za-z0-9][A-Za-z0-9._-]{0,63})/objects/([A-Za-z0-9][A-Za-z0-9._-]{0,250}\.tar\.(?:zst|gz))")
EXIT_HIT, EXIT_ERROR, EXIT_MISS = 0, 1, 3
# A mini the LAN cache is not set up on yet: nothing to report.
QUIET = ("no LAN cache config", "no glaeda broker")
# A broker that answers "bad request" is a glaeda release without the cache verb: every object then crosses
# the site's uplink while the LAN cache host sits idle (2026-10-27: the R2 web-bundle restore went from 1-4 s
# to a 25 s median). That is a fleet rollout gap, so it is a warning, once per job.
OLD_BROKER = "bad request"


def warn_old_broker_once() -> None:
    marker_dir = os.environ.get("RUNNER_TEMP") or os.environ.get("TMPDIR") or "/tmp"
    marker = Path(marker_dir) / f"cmux-lan-cache-old-broker-{os.environ.get('GITHUB_RUN_ID', '')}-{os.environ.get('GITHUB_JOB', '')}"
    try:
        os.close(os.open(marker, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600))
    except FileExistsError:
        return
    except OSError:
        pass  # an unwritable temp dir still gets the warning, perhaps more than once
    print("::warning title=LAN cache unused::r2-cache: this mini's glaeda-lan-fetch broker has no cache verb "
          "(an older glaeda release), so cache objects download over the site's uplink; update glaeda on this mini")


def request(public_url: str, obj: str, dest: Path, sock_path: Path = SOCKET, timeout: float = TIMEOUT) -> tuple[int, dict]:
    match = OBJECT_RE.fullmatch(obj)
    host = re.fullmatch(r"https://([a-z0-9.-]+)/?", public_url)
    if not match or not host:
        return EXIT_ERROR, {"error": "not a cache object URL"}
    if os.environ.get("CMUX_LAN_CACHE") == "0":
        return EXIT_ERROR, {"error": "turned off (CMUX_LAN_CACHE=0)"}
    if not sock_path.is_socket():
        return EXIT_ERROR, {"error": "no glaeda broker"}
    conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    deadline = time.monotonic() + timeout
    try:
        conn.settimeout(timeout)
        conn.connect(os.fspath(sock_path))
        conn.sendall((json.dumps({"verb": "cache", "bucket": host.group(1), "ns": match.group(1),
                                  "file": match.group(2), "dest": os.fspath(dest)}) + "\n").encode())
        data = b""
        while not data.endswith(b"\n") and len(data) < 65536:
            left = deadline - time.monotonic()  # one deadline for the whole answer, however it trickles in
            if left <= 0:
                raise TimeoutError
            conn.settimeout(left)
            chunk = conn.recv(4096)
            if not chunk:
                break
            data += chunk
        answer = json.loads(data)
    except (OSError, ValueError) as error:
        return EXIT_ERROR, {"error": f"broker: {type(error).__name__}"}
    finally:
        conn.close()
    code = answer.get("code") if isinstance(answer, dict) else None
    code = code if type(code) is int else None  # noqa: E721 - True and False are not exit codes
    record = answer.get("record", {}) if isinstance(answer, dict) else {}
    if code == EXIT_HIT and not dest.is_file():
        return EXIT_ERROR, {**record, "error": "broker said hit but wrote nothing"}
    return (code if code in (EXIT_HIT, EXIT_MISS) else EXIT_ERROR), record


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 2
    code, record = request(argv[0], argv[1], Path(argv[2]).absolute())
    if code == EXIT_HIT:
        print(f"r2-cache: {argv[1].rsplit('/', 1)[-1]} from the LAN cache host: {record.get('bytes')} bytes in "
              f"{record.get('seconds')} s (waited {record.get('wait_seconds')} s)")
    elif code == EXIT_ERROR and record.get("error") == OLD_BROKER:
        warn_old_broker_once()
    elif code == EXIT_ERROR and record.get("error") not in QUIET:
        print(f"r2-cache: LAN cache host unavailable ({str(record.get('error') or record.get('reason') or '')[:160]});"
              " downloading directly")
    return code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
