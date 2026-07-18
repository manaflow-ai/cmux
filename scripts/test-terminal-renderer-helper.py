#!/usr/bin/env python3

import os
import socket
import struct
import subprocess
import sys
import uuid


executable = sys.argv[1]
control_fd = 198
daemon_id = uuid.UUID("11111111-1111-4111-8111-111111111111")
workspace_id = uuid.UUID("22222222-2222-4222-8222-222222222222")
renderer_epoch = 9


def frame(direction: int, kind: int, sequence: int, payload: bytes) -> bytes:
    return struct.pack(
        ">4sHHBBHIQQ",
        b"CMRC",
        1,
        32,
        direction,
        kind,
        0,
        0,
        sequence,
        len(payload),
    ) + payload


def read_exact(stream: socket.socket, length: int) -> bytes:
    result = bytearray()
    while len(result) < length:
        chunk = stream.recv(length - len(result))
        if not chunk:
            raise RuntimeError(f"renderer closed after {len(result)} of {length} bytes")
        result.extend(chunk)
    return bytes(result)


parent, child = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
parent.settimeout(5.0)
os.dup2(child.fileno(), control_fd, inheritable=True)

environment = os.environ.copy()
environment["CMUX_RENDERER_CONTROL_FD"] = str(control_fd)
environment["CMUX_DAEMON_INSTANCE_ID"] = str(daemon_id)
process = subprocess.Popen(
    [
        executable,
        "--workspace",
        str(workspace_id),
        "--renderer-epoch",
        str(renderer_epoch),
    ],
    stdin=subprocess.DEVNULL,
    stdout=subprocess.DEVNULL,
    stderr=subprocess.PIPE,
    close_fds=True,
    pass_fds=(control_fd,),
    env=environment,
)
child.close()
os.close(control_fd)

try:
    bootstrap = daemon_id.bytes + workspace_id.bytes + struct.pack(">QQ", renderer_epoch, 0)
    parent.sendall(frame(1, 0x01, 1, bootstrap))
    header = read_exact(parent, 32)
    magic, version, header_length, direction, kind, flags, reserved, sequence, length = (
        struct.unpack(">4sHHBBHIQQ", header)
    )
    assert (magic, version, header_length) == (b"CMRC", 1, 32)
    assert (direction, kind, flags, reserved, sequence, length) == (2, 0x81, 0, 0, 1, 24)
    pid, euid, capabilities, ready_reserved = struct.unpack(">IIQQ", read_exact(parent, 24))
    assert pid == process.pid
    assert euid == os.geteuid()
    assert capabilities == 0b111
    assert ready_reserved == 0

    parent.sendall(frame(1, 0x06, 2, struct.pack(">Q", 0)))
    result = process.wait(timeout=5.0)
    if result != 0:
        stderr = process.stderr.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"renderer exited {result}: {stderr}")
except BaseException as error:
    if process.poll() is None:
        process.kill()
        process.wait(timeout=5.0)
    stderr = process.stderr.read().decode("utf-8", errors="replace")
    raise RuntimeError(
        f"renderer handshake failed: {error}; exit={process.returncode}; stderr={stderr}"
    ) from error
finally:
    parent.close()
    if process.poll() is None:
        process.kill()
        process.wait(timeout=5.0)

print("terminal renderer helper handshake verified")
