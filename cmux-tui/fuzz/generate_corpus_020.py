#!/usr/bin/env python3
"""Seed corpus of the task-020 fuzz targets (p10-stability.md).

Writes corpus/<target>/<name> for the byte-format targets, the seed corpus
layout of every cmux-tui/fuzz target (`cargo fuzz run <target>` reads it):
valid inputs of each wire layout, one per feature the decoder branches on, so
the fuzzer starts past the length and tag checks. The layouts are the encoders' in
crates/cmux-tui-core/src (terminal_host_runtime/shared/codec.rs,
terminal_host_runtime/colors_wire.rs, output_store/snapshot.rs,
output_store/segments.rs, server/page_files.rs). The journal targets take
`arbitrary` rows and need none.

Run: python3 cmux-tui/fuzz/generate_corpus_020.py [--check]
--check exits 1 when the files on disk differ from what this writes.
"""

from __future__ import annotations

import gzip
import json
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent / "corpus"
PROTOCOL_VERSION = 4


def u8(value: int) -> bytes:
    return struct.pack("<B", value)


def u16(value: int) -> bytes:
    return struct.pack("<H", value)


def u32(value: int) -> bytes:
    return struct.pack("<I", value)


def u64(value: int) -> bytes:
    return struct.pack("<Q", value)


def blob(value: bytes) -> bytes:
    return u32(len(value)) + value


def string(value: str) -> bytes:
    return blob(value.encode())


def optional_string(value: str | None) -> bytes:
    return u8(0) if value is None else u8(1) + string(value)


def kitty_limits(image_bytes=0, inflight=0, images=0, placements=0) -> bytes:
    return u64(image_bytes) + u64(inflight) + u64(images) + u64(placements)


def kitty_replay_state(cursor_offset=0) -> bytes:
    default_id = 2_147_483_647
    return kitty_limits() + u32(cursor_offset) + u32(default_id) * 4


def kitty_aliases(pairs) -> bytes:
    return u16(len(pairs)) + b"".join(u32(image) + u32(number) for image, number in pairs)


def snapshot(
    version: int,
    replay=b"\x1b[0mhello\r\n",
    cwd="/home/user",
    command=("zsh", "-l"),
    metadata: str | None = None,
    shell_activity: bytes | None = None,
    program_status: bytes | None = None,
) -> bytes:
    out = u16(80) + u16(24) + u32(4242) + blob(replay) + optional_string(cwd)
    out += u16(len(command)) + b"".join(string(argument) for argument in command)
    if version >= 2:
        out += kitty_aliases([(7, 1)]) + u16(9) + u16(18)
    if version >= 3:
        out += kitty_replay_state(cursor_offset=len(replay))
    if metadata is not None:
        out += string(metadata)
    if shell_activity is not None:
        out += shell_activity
    if program_status is not None:
        out += program_status
    return out


def program_status() -> bytes:
    record = string("build") + u8(2) + u8(0) + u8(40)
    record += optional_string("cargo") + optional_string("Building") + optional_string(None)
    record += u64(3) + u64(1_700_000_000_000)
    return u64(4) + u16(1) + record


def resize(version: int, replay=b"\x1b[2J") -> bytes:
    out = u16(120) + u16(40) + blob(replay)
    if version >= 2:
        out += kitty_aliases([]) + u16(8) + u16(16)
    if version >= 3:
        out += kitty_replay_state()
    return out


def default_colors(full: bool) -> bytes:
    if not full:
        return u8(0) + u16(0)
    flags = 0b111_1111
    out = u8(flags) + bytes([1, 2, 3]) * 5 + u8(3) + u8(1)
    return out + u16(2) + bytes([0, 10, 20, 30]) + bytes([255, 40, 50, 60])


def launch(seed: bytes | None, workspace_key: str | None) -> bytes:
    out = string("/tmp/cmux/host.sock") + string("/tmp/cmux/host.json") + string("xterm-256color")
    out += u16(80) + u16(24) + u32(10_000_000) + optional_string("/home/user")
    out += u16(2) + string("/bin/zsh") + string("-l")
    out += u16(1) + string("TERM") + string("xterm-ghostty")
    out += default_colors(True) + u16(9) + u16(18) + kitty_limits(1 << 20, 1 << 16, 8, 16)
    if seed is not None:
        out += blob(seed)
    if workspace_key is not None:
        out += string(workspace_key)
    return out


def colors_wire(version: int) -> bytes:
    if version == 1:
        header = u16(1) + u16(0b111) + u16(1) + u16(0)
        return header + bytes([1, 2, 3, 4, 5, 6, 7, 8, 9]) + bytes([5, 9, 9, 9])
    header = u16(2) + u16(0b1001) + u16(0) + u16(0)
    return header + bytes([200, 200, 200]) + bytes([3, 1])


def output_snapshot(replay: bytes, generation="gen-1") -> bytes:
    header = {"generation": generation, "stream_end": 4096, "cols": 80, "rows": 24}
    header["written_at_ms"] = 1_700_000_000_000
    body = gzip.compress(replay, compresslevel=1, mtime=0)
    return b"CMUXSNAP1\n" + json.dumps(header, separators=(",", ":")).encode() + b"\n" + body


def segment_frame(start: int, raw: bytes) -> bytes:
    compressed = gzip.compress(raw, compresslevel=1, mtime=0)
    return u64(start) + u32(len(compressed)) + u32(len(raw)) + compressed


def seeds() -> dict[str, dict[str, bytes]]:
    metadata_flags = 0b1000
    shell = 0b1_0000
    status = 0b10_0000
    busy = u8(0b1011) + u64(1_700_000_000_000) + u64(1_700_000_000_500)
    identity = "0123456789abcdef0123456789abcdef"
    return {
        "host_snapshot": {
            "v1": u8(1) + snapshot(1),
            "v2": u8(2) + snapshot(2),
            "v3": u8(3) + snapshot(3),
            "v4": u8(PROTOCOL_VERSION) + snapshot(4, cwd=None),
            "v4-metadata": u8(PROTOCOL_VERSION | metadata_flags) + snapshot(4, metadata="50%"),
            "v4-shell": u8(PROTOCOL_VERSION | metadata_flags | shell)
            + snapshot(4, metadata="", shell_activity=busy),
            "v4-all-tails": u8(PROTOCOL_VERSION | metadata_flags | shell | status)
            + snapshot(4, metadata="", shell_activity=u8(0), program_status=program_status()),
        },
        "host_resize": {
            "v1": u8(1) + resize(1),
            "v2": u8(2) + resize(2),
            "v4": u8(PROTOCOL_VERSION) + resize(4),
        },
        "host_launch": {
            "plain": launch(None, None),
            "seeded": launch(b"\x1b[0mprevious screen\r\n", None),
            "workspace-key": launch(b"", "workspace_1"),
        },
        "host_default_colors": {
            "empty": default_colors(False),
            "full": default_colors(True),
        },
        "host_resync_kitty_limits": {
            "limits": kitty_limits(1 << 20, 1 << 16, 8, 16),
        },
        "host_identity_hex": {
            "incarnation-lower": u8(1) + identity.encode(),
            "incarnation-any-case": u8(0) + identity.upper().encode(),
            "owner-token": u8(1) + (identity * 2).encode(),
        },
        "host_colors_wire": {
            "v1": colors_wire(1),
            "v2": colors_wire(2),
        },
        "output_snapshot": {
            "file": u8(0) + output_snapshot(b"\x1b[0m$ ls\r\nCargo.toml\r\n"),
        },
        "output_segment_frames": {
            "two-frames": u8(0) + segment_frame(0, b"hello ") + segment_frame(6, b"world\r\n"),
            "cut": u8(0) + (segment_frame(0, b"abc") + segment_frame(3, b"def"))[:-3],
        },
        "page_request_head": {
            # Byte 0: bytes per read - 1. Byte 1: the head limit (255 is the
            # daemon's 64 KiB, N is 16 * (N + 1) bytes). Then the stream.
            "page-get": u8(255)
            + u8(255)
            + b"GET /pages/home/ HTTP/1.1\r\nHost: 127.0.0.1:7777\r\nCookie: a=b\r\n\r\n",
            "websocket": u8(7)
            + u8(255)
            + b"GET /ws HTTP/1.1\r\nHost: localhost:7777\r\nOrigin: http://localhost:7777\r\n"
            + b"Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\n\r\n"
            + b"\x81\x80",
            "attachment": u8(0)
            + u8(255)
            + b"HEAD /attachments/x?y=1 HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
            "field-ows": u8(31)
            + u8(255)
            + b"GET /pages/home/ HTTP/1.0\r\nHost:\t 127.0.0.1 \r\nOrigin:x\r\n\r\n",
            "obs-fold": u8(3)
            + u8(255)
            + b"GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n Host: evil\r\n\r\n",
            "space-before-colon": u8(3) + u8(255) + b"GET / HTTP/1.1\r\nHost : evil\r\n\r\n",
            # A 64-byte limit and a head that does not end in it: 431.
            "oversized": u8(15) + u8(3) + b"GET / HTTP/1.1\r\nCookie: " + b"a" * 64,
            # The same head ending just inside a 64-byte limit: parsed.
            "at-limit": u8(15) + u8(3) + b"GET / HTTP/1.1\r\nCookie: " + b"a" * 34 + b"\r\n\r\n",
        },
    }


def main() -> int:
    check = "--check" in sys.argv[1:]
    stale = []
    for target, files in seeds().items():
        directory = ROOT / target
        for name, data in files.items():
            path = directory / name
            if check:
                if not path.is_file() or path.read_bytes() != data:
                    stale.append(str(path.relative_to(ROOT)))
                continue
            directory.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
    if stale:
        print("stale seeds (run generate_corpus_020.py):", *stale, sep="\n  ")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
