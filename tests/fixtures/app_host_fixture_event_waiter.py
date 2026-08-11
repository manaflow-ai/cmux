#!/usr/bin/env python3
"""Wait for app-host fixture publications and exits without timer polling."""

import argparse
import ctypes
import errno
import math
import os
import select
import sys
import time


OWNER_EXITED = 3
DEADLINE_EXPIRED = 124


def remaining_seconds(deadline):
    return max(0.0, deadline - time.monotonic())


def receipt_exists(path):
    return os.path.isfile(path)


def wait_for_receipt_darwin(path, owner_pid, deadline):
    directory_fd = os.open(os.path.dirname(path), os.O_RDONLY | os.O_CLOEXEC)
    queue = select.kqueue()
    try:
        changes = [
            select.kevent(
                directory_fd,
                filter=select.KQ_FILTER_VNODE,
                flags=select.KQ_EV_ADD | select.KQ_EV_ENABLE | select.KQ_EV_CLEAR,
                fflags=(
                    select.KQ_NOTE_WRITE
                    | select.KQ_NOTE_EXTEND
                    | select.KQ_NOTE_ATTRIB
                    | select.KQ_NOTE_RENAME
                ),
            ),
            select.kevent(
                owner_pid,
                filter=select.KQ_FILTER_PROC,
                flags=select.KQ_EV_ADD | select.KQ_EV_ENABLE | select.KQ_EV_ONESHOT,
                fflags=select.KQ_NOTE_EXIT,
            ),
        ]
        try:
            events = queue.control(changes, 2, 0)
        except OSError as error:
            if error.errno == errno.ESRCH:
                return 0 if receipt_exists(path) else OWNER_EXITED
            raise
        if receipt_exists(path):
            return 0
        if any(event.filter == select.KQ_FILTER_PROC for event in events):
            return OWNER_EXITED

        while True:
            remaining = remaining_seconds(deadline)
            if remaining == 0:
                return DEADLINE_EXPIRED
            events = queue.control(None, 2, remaining)
            if not events:
                return DEADLINE_EXPIRED
            if receipt_exists(path):
                return 0
            if any(event.filter == select.KQ_FILTER_PROC for event in events):
                return OWNER_EXITED
    finally:
        queue.close()
        os.close(directory_fd)


def linux_inotify(directory):
    library = ctypes.CDLL(None, use_errno=True)
    library.inotify_init1.argtypes = [ctypes.c_int]
    library.inotify_init1.restype = ctypes.c_int
    library.inotify_add_watch.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_uint32]
    library.inotify_add_watch.restype = ctypes.c_int

    descriptor = library.inotify_init1(os.O_CLOEXEC | os.O_NONBLOCK)
    if descriptor == -1:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))
    event_mask = 0x00000008 | 0x00000080 | 0x00000100 | 0x00000400 | 0x00000800
    if library.inotify_add_watch(descriptor, os.fsencode(directory), event_mask) == -1:
        error = ctypes.get_errno()
        os.close(descriptor)
        raise OSError(error, os.strerror(error))
    return descriptor


def open_pidfd(process_id):
    if not hasattr(os, "pidfd_open"):
        raise RuntimeError("Linux app-host event waits require pidfd_open")
    return os.pidfd_open(process_id, 0)


def wait_for_receipt_linux(path, owner_pid, deadline):
    inotify_fd = linux_inotify(os.path.dirname(path))
    try:
        try:
            process_fd = open_pidfd(owner_pid)
        except ProcessLookupError:
            return 0 if receipt_exists(path) else OWNER_EXITED
        try:
            if receipt_exists(path):
                return 0
            poller = select.poll()
            poller.register(inotify_fd, select.POLLIN)
            poller.register(process_fd, select.POLLIN)
            while True:
                remaining = remaining_seconds(deadline)
                if remaining == 0:
                    return DEADLINE_EXPIRED
                events = poller.poll(math.ceil(remaining * 1000))
                if not events:
                    return DEADLINE_EXPIRED
                if receipt_exists(path):
                    return 0
                for descriptor, _ in events:
                    if descriptor == process_fd:
                        return OWNER_EXITED
                    if descriptor == inotify_fd:
                        try:
                            os.read(inotify_fd, 65536)
                        except BlockingIOError:
                            pass
        finally:
            os.close(process_fd)
    finally:
        os.close(inotify_fd)


def wait_for_exit_darwin(process_ids, deadline):
    queue = select.kqueue()
    active = set()
    try:
        for process_id in process_ids:
            change = select.kevent(
                process_id,
                filter=select.KQ_FILTER_PROC,
                flags=select.KQ_EV_ADD | select.KQ_EV_ENABLE | select.KQ_EV_ONESHOT,
                fflags=select.KQ_NOTE_EXIT,
            )
            try:
                events = queue.control([change], 1, 0)
            except OSError as error:
                if error.errno == errno.ESRCH:
                    continue
                raise
            active.add(process_id)
            for event in events:
                active.discard(event.ident)

        while active:
            remaining = remaining_seconds(deadline)
            if remaining == 0:
                return DEADLINE_EXPIRED
            events = queue.control(None, len(active), remaining)
            if not events:
                return DEADLINE_EXPIRED
            for event in events:
                active.discard(event.ident)
        return 0
    finally:
        queue.close()


def wait_for_exit_linux(process_ids, deadline):
    poller = select.poll()
    descriptors = {}
    try:
        for process_id in process_ids:
            try:
                descriptor = open_pidfd(process_id)
            except ProcessLookupError:
                continue
            descriptors[descriptor] = process_id
            poller.register(descriptor, select.POLLIN)

        while descriptors:
            remaining = remaining_seconds(deadline)
            if remaining == 0:
                return DEADLINE_EXPIRED
            events = poller.poll(math.ceil(remaining * 1000))
            if not events:
                return DEADLINE_EXPIRED
            for descriptor, _ in events:
                poller.unregister(descriptor)
                os.close(descriptor)
                descriptors.pop(descriptor)
        return 0
    finally:
        for descriptor in descriptors:
            os.close(descriptor)


def parse_arguments():
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    receipt = subparsers.add_parser("receipt")
    receipt.add_argument("path")
    receipt.add_argument("owner_pid", type=int)
    receipt.add_argument("timeout", type=float)

    process_exit = subparsers.add_parser("exit")
    process_exit.add_argument("timeout", type=float)
    process_exit.add_argument("process_ids", nargs="+", type=int)
    return parser.parse_args()


def main():
    arguments = parse_arguments()
    if arguments.timeout <= 0:
        raise SystemExit("timeout must be positive")
    deadline = time.monotonic() + arguments.timeout

    if arguments.command == "receipt":
        if sys.platform == "darwin":
            status = wait_for_receipt_darwin(
                arguments.path,
                arguments.owner_pid,
                deadline,
            )
        elif sys.platform.startswith("linux"):
            status = wait_for_receipt_linux(
                arguments.path,
                arguments.owner_pid,
                deadline,
            )
        else:
            raise SystemExit("unsupported app-host fixture platform")
        if status == OWNER_EXITED:
            print("app-host owner exited before receipt publication", file=sys.stderr)
        elif status == DEADLINE_EXPIRED:
            print("app-host receipt publication deadline expired", file=sys.stderr)
        return status

    if sys.platform == "darwin":
        return wait_for_exit_darwin(arguments.process_ids, deadline)
    if sys.platform.startswith("linux"):
        return wait_for_exit_linux(arguments.process_ids, deadline)
    raise SystemExit("unsupported app-host fixture platform")


if __name__ == "__main__":
    raise SystemExit(main())
