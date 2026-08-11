#!/usr/bin/env python3
"""Hold an app-host attempt lease until the test fixture requests release."""

import fcntl
import os
import sys


def main() -> int:
    if len(sys.argv) != 4:
        return 2

    lease_path, ready_fifo, release_fifo = sys.argv[1:]
    descriptor = os.open(lease_path, os.O_RDWR)
    fcntl.lockf(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
    ready_descriptor = os.open(ready_fifo, os.O_WRONLY)
    os.write(ready_descriptor, b"r")
    os.close(ready_descriptor)
    with open(release_fifo, "rb", buffering=0) as release_stream:
        if release_stream.read(1) != b"x":
            return 1
    os.close(descriptor)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
