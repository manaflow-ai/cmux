#!/usr/bin/env python3
from __future__ import annotations

import argparse
import atexit
import os
import select
import socket
import sys
import threading


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Bridge a Unix socket to a localhost TCP listener.")
    parser.add_argument("unix_socket_path")
    parser.add_argument("tcp_port", type=int)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--daemonize", action="store_true")
    parser.add_argument("--pid-file")
    parser.add_argument("--log-file")
    return parser.parse_args()


def pump(source: socket.socket, destination: socket.socket) -> None:
    try:
        while True:
            data = source.recv(8192)
            if not data:
                return
            destination.sendall(data)
    finally:
        try:
            destination.shutdown(socket.SHUT_WR)
        except OSError:
            pass


def handle_client(client: socket.socket, unix_socket_path: str) -> None:
    upstream = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        upstream.connect(unix_socket_path)
        threads = [
            threading.Thread(target=pump, args=(client, upstream), daemon=True),
            threading.Thread(target=pump, args=(upstream, client), daemon=True),
        ]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
    finally:
        try:
            upstream.close()
        except OSError:
            pass
        try:
            client.close()
        except OSError:
            pass


def daemonize(pid_file: str | None, log_file: str | None) -> None:
    first_pid = os.fork()
    if first_pid > 0:
        os.waitpid(first_pid, 0)
        raise SystemExit(0)

    os.setsid()

    second_pid = os.fork()
    if second_pid > 0:
        os._exit(0)

    os.chdir("/")
    os.umask(0)

    stdin_fd = os.open(os.devnull, os.O_RDONLY)
    try:
        os.dup2(stdin_fd, 0)
    finally:
        os.close(stdin_fd)

    if log_file:
        log_fd = os.open(log_file, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
    else:
        log_fd = os.open(os.devnull, os.O_WRONLY)
    try:
        os.dup2(log_fd, 1)
        os.dup2(log_fd, 2)
    finally:
        if log_fd > 2:
            os.close(log_fd)

    write_pid_file(pid_file)


def write_pid_file(pid_file: str | None) -> None:
    if not pid_file:
        return

    with open(pid_file, "w", encoding="utf-8") as handle:
        handle.write(f"{os.getpid()}\n")

    def cleanup() -> None:
        try:
            os.remove(pid_file)
        except FileNotFoundError:
            pass

    atexit.register(cleanup)


def main() -> int:
    args = parse_args()

    if args.daemonize:
        daemonize(pid_file=args.pid_file, log_file=args.log_file)
    elif args.pid_file:
        write_pid_file(args.pid_file)

    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((args.host, args.tcp_port))
    server.listen()

    print(f"ready {args.host}:{args.tcp_port}", flush=True)

    try:
        while True:
            ready, _, _ = select.select([server], [], [], 0.5)
            if not ready:
                continue
            client, _ = server.accept()
            threading.Thread(
                target=handle_client,
                args=(client, args.unix_socket_path),
                daemon=True,
            ).start()
    except KeyboardInterrupt:
        return 0
    finally:
        server.close()


if __name__ == "__main__":
    sys.exit(main())
