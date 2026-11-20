"""A stand-in `__agent-host` for the bootstrap tests (host_start_wave.rs).

Started as `python3 fake_slow_host.py <mode> <arg> __agent-host` by a
`HostLauncher` whose prefix is this script. It reads the spawn spec frame
(u32 big-endian length, then JSON) from stdin, like a real host, then:

- `slow <seconds>`: works for that long (a host on a busy Mac), then answers
  `ready` with a record for the spec's session;
- `die <code>`: exits with that code without an answer (a host that crashed);
- `hang <lock file> <fifo> <marker>`: takes an exclusive lock on the file,
  opens the FIFO for writing (the test learns it runs), then never answers
  (a wedged host). When its bootstrap pipe closes (its start was dropped)
  and it is still alive, it writes the marker file and exits: it ran on
  after its start was given up. The lock is free again once it is gone.
"""

import fcntl
import json
import os
import struct
import sys
import time


def read_frame():
    head = sys.stdin.buffer.read(4)
    if len(head) < 4:
        sys.exit(9)
    (length,) = struct.unpack(">I", head)
    return json.loads(sys.stdin.buffer.read(length))


def write_frame(value):
    body = json.dumps(value).encode()
    sys.stdout.buffer.write(struct.pack(">I", len(body)) + body)
    sys.stdout.buffer.flush()


def main():
    mode, arg = sys.argv[1], sys.argv[2]
    if mode == "hang":
        lock = open(arg, "w")
        fcntl.flock(lock, fcntl.LOCK_EX)
        running = open(sys.argv[3], "w")  # noqa: F841 (held open)
        read_frame()
        while sys.stdin.buffer.read(1 << 16):
            pass
        with open(sys.argv[4], "w") as marker:
            marker.write("ran on after its start was dropped")
        sys.exit(0)
    spec = read_frame()
    if mode == "die":
        sys.exit(int(arg))
    time.sleep(float(arg))
    write_frame(
        {
            "t": "ready",
            "record": {
                "record_version": 1,
                "session_id": spec["session_id"],
                "incarnation": "fake",
                "host_pid": os.getpid(),
                "start_nonce": "00",
                "harness_pid": None,
                "owner_token": "00",
                "protocol_min": 1,
                "protocol_max": 1,
                "host_build": "fake",
                "socket": spec["socket"],
            },
        }
    )


main()
