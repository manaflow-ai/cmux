#!/usr/bin/env python3
"""Run xcodebuild behind a per-user configurable slot lock."""

from __future__ import annotations

import argparse
import fcntl
import os
import pathlib
import re
import shlex
import sys
import time


DEFAULT_CONFIG_FILE = pathlib.Path.home() / ".config/cmux/xcodebuild-concurrency"
WAIT_NOTICE_INTERVAL_SECONDS = 30
WAIT_POLL_SECONDS = 1


class ConfigError(Exception):
    pass


def write_user(message: str) -> None:
    try:
        os.write(4, message.encode("utf-8"))
    except OSError:
        sys.stderr.write(message)
        sys.stderr.flush()


def parse_positive_int(raw_value: str, source: str) -> int:
    value = raw_value.strip()
    if not re.fullmatch(r"[0-9]+", value):
        raise ConfigError(f"{source} must be a positive integer, got {raw_value!r}")
    parsed = int(value, 10)
    if parsed < 1:
        raise ConfigError(f"{source} must be a positive integer, got {raw_value!r}")
    return parsed


def first_config_value(path: pathlib.Path) -> str | None:
    try:
        contents = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return None
    except OSError as exc:
        raise ConfigError(f"could not read {path}: {exc}") from exc

    for line in contents.splitlines():
        value = line.split("#", 1)[0].strip()
        if value:
            return value
    return None


def choose_concurrency(args: argparse.Namespace) -> int:
    if args.concurrency:
        return parse_positive_int(args.concurrency, "--xcodebuild-concurrency")

    env_value = os.environ.get("CMUX_XCODEBUILD_CONCURRENCY")
    if env_value:
        return parse_positive_int(env_value, "CMUX_XCODEBUILD_CONCURRENCY")

    config_file = pathlib.Path(
        args.config_file
        or os.environ.get("CMUX_XCODEBUILD_CONCURRENCY_FILE")
        or DEFAULT_CONFIG_FILE
    )
    config_value = first_config_value(config_file)
    if config_value:
        return parse_positive_int(config_value, str(config_file))

    return 1


def lock_file_path(lock_root: pathlib.Path, slot_index: int) -> pathlib.Path:
    return lock_root / f"slot-{slot_index}.lock"


def try_acquire_slot(
    lock_root: pathlib.Path,
    concurrency: int,
    command: list[str],
) -> tuple[int, int] | None:
    for slot_index in range(concurrency):
        path = lock_file_path(lock_root, slot_index)
        fd = os.open(path, os.O_CREAT | os.O_RDWR, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            os.close(fd)
            continue
        except OSError:
            os.close(fd)
            raise

        os.set_inheritable(fd, True)
        record = (
            f"pid={os.getpid()}\n"
            f"slot={slot_index + 1}/{concurrency}\n"
            f"cwd={os.getcwd()}\n"
            f"command={shlex.join(command)}\n"
        )
        os.ftruncate(fd, 0)
        os.write(fd, record.encode("utf-8"))
        os.lseek(fd, 0, os.SEEK_SET)
        return slot_index, fd

    return None


def acquire_slot(
    lock_root: pathlib.Path,
    concurrency: int,
    command: list[str],
) -> tuple[int, int]:
    lock_root.mkdir(mode=0o700, parents=True, exist_ok=True)
    announced = False
    start = time.monotonic()
    next_notice = start + WAIT_NOTICE_INTERVAL_SECONDS

    while True:
        acquired = try_acquire_slot(lock_root, concurrency, command)
        if acquired is not None:
            if announced:
                slot_index, _ = acquired
                write_user(
                    f"==> xcodebuild slot {slot_index + 1}/{concurrency} acquired.\n"
                )
            return acquired

        now = time.monotonic()
        if not announced:
            write_user(
                f"==> All {concurrency} local xcodebuild slots are busy; "
                f"waiting under {lock_root}...\n"
            )
            announced = True
        elif now >= next_notice:
            elapsed = int(now - start)
            write_user(
                f"==> Still waiting for a local xcodebuild slot "
                f"({elapsed}s; limit {concurrency})...\n"
            )
            next_notice = now + WAIT_NOTICE_INTERVAL_SECONDS

        time.sleep(WAIT_POLL_SECONDS)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run a command while holding a configurable xcodebuild slot lock."
    )
    parser.add_argument("--lock-root", required=True)
    parser.add_argument("--concurrency")
    parser.add_argument("--config-file")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    if args.command and args.command[0] == "--":
        args.command = args.command[1:]
    if not args.command:
        parser.error("missing command after --")
    return args


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    try:
        concurrency = choose_concurrency(args)
        acquire_slot(pathlib.Path(args.lock_root), concurrency, args.command)
    except ConfigError as exc:
        print(f"xcodebuild concurrency config error: {exc}", file=sys.stderr)
        return 2
    except OSError as exc:
        print(f"xcodebuild concurrency lock error: {exc}", file=sys.stderr)
        return 1

    # Keep the slot lock fd open across exec. If xcodebuild is killed by
    # SIGTERM/SIGKILL, the kernel closes the fd and releases the slot.
    os.environ["CMUX_XCODEBUILD_SLOT_HELD"] = "1"
    try:
        os.execvp(args.command[0], args.command)
    except OSError as exc:
        print(f"xcodebuild concurrency exec error: {exc}", file=sys.stderr)
        return 127


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
