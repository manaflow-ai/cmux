#!/usr/bin/env python3
"""Writes the seed corpora under cmux-tui/fuzz/corpus/<target>/ (re-run after a protocol change).

Each seed is a valid message of the target's protocol, so libFuzzer starts from the shapes the
daemon really reads: control lines (legacy and cmux.protocol/2) with a revision byte, CMTH frame
streams with the target's three-byte prefix, and remote WireFrames."""
import hashlib
import json
import pathlib
import struct

ROOT = pathlib.Path(__file__).resolve().parent / "corpus"


def write(target, data):
    path = ROOT / target
    path.mkdir(parents=True, exist_ok=True)
    (path / hashlib.sha1(data).hexdigest()).write_bytes(data)


LINES = [
    {"id": 1, "cmd": "identify"},
    {"id": 2, "cmd": "server-stats", "include": ["locks", "write_path"]},
    {"id": 3, "cmd": "list-workspaces"},
    {"id": 4, "cmd": "subscribe"},
    {"id": 5, "cmd": "client-hello", "role": "main", "install_id": "inst_x"},
    {"id": 6, "cmd": "send-text", "surface": 1, "text": "ls\n"},
    {"id": 7, "cmd": "resize-surface", "surface": 1, "cols": 80, "rows": 24},
    {"id": "s", "cmd": "attach-surface", "surface": 1},
    {"protocol": "cmux.protocol/2", "type": "request", "id": "a", "operation": "workspace.list", "params": {}},
    {"protocol": "cmux.protocol/2", "type": "request", "id": "b", "operation": "workspace.create",
     "params": {"name": "w"}, "idempotency_key": "k1"},
    {"protocol": "cmux.protocol/2", "type": "request", "id": "c", "operation": "tab.create_terminal",
     "params": {"workspace": "ws_1"}, "origin": "user"},
    {"protocol": "cmux.protocol/2", "type": "request", "id": "d", "operation": "pane.split",
     "params": {"pane": "pn_1", "direction": "right"}},
]
for index, line in enumerate(LINES):
    text = json.dumps(line, separators=(",", ":")).encode()
    write("control_line", bytes([0]) + text)
    write("control_line", bytes([1 + index % 4]) + text)


def cmth(kind, payload=b"", version=4, flags=0, request=0, sequence=0):
    return (b"CMTH" + struct.pack("<HHIIQQ", version, kind, flags, len(payload), request, sequence) + payload)


exit_payload = struct.pack("<HHQ", 1, 0, 0) + struct.pack("<i", 0)
STREAMS = [
    cmth(3, b"\x00" * 8, flags=1 << 2),
    cmth(4, b"", flags=1 << 2) + cmth(6, b"hello\r\n", sequence=1) + cmth(8, b"\x01" + b"\x00" * 7, sequence=2),
    cmth(7, struct.pack("<HH", 80, 24), flags=1, sequence=3),
    cmth(12, exit_payload, sequence=4),
    cmth(20, struct.pack("<HH", 1, 1) + b"spawn failed"),
    cmth(100, b"\x1b[A" * 4, request=9) + cmth(23, b"", request=9),
    cmth(102, struct.pack("<HH", 120, 40), request=2),
]
for index, stream in enumerate(STREAMS):
    for limit in (2, 3):
        write("host_frame", bytes([limit, 1 + index * 7 % 64, 33]) + stream)

# WireFrame: magic, version, lane, flags, session, generation, sequence, ack, stream, len, payload.
def wire(lane, flags, payload=b"", stream=1, sequence=1):
    return (b"CMXR" + bytes([5, lane]) + struct.pack(">H", flags) + bytes(16)
            + struct.pack(">QQQQI", 1, sequence, 0, stream, len(payload)) + payload)


for lane, flags, payload, stream in [
    (0, 1 | 2, b"{}", 1), (1, 1, b'{"id":1}', 0), (2, 1 | 4, b"x" * 300, 7), (3, 1 | 8, b"", 9),
    (1, 1 | 64, b"", 0), (1, 1 << 4, b"", 0), (1, 1 << 7, b"", 0),
]:
    write("remote_frame", wire(lane, flags, payload, stream))

# event_stream takes an Arbitrary struct: a few raw byte seeds give libFuzzer starting shapes.
for seed in (b"\x00" * 64, b"\x01\x02" * 40, bytes(range(256)), b"\x03" + b"\xff" * 100):
    write("event_stream", seed)

for target in sorted(p.name for p in ROOT.iterdir()):
    print(target, len(list((ROOT / target).iterdir())))
