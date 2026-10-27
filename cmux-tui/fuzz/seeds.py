#!/usr/bin/env python3
"""Write the seed corpus of each cmux-tui fuzz target.

Seeds come from files the repository already keeps (the terminal corpus, the
pane-protocol vectors, the relay-control fixture, the default settings) plus
a few frames built here from each wire's documented layout, so the fuzzer
starts past every magic number and length check. Each seed is named by its
SHA-1, as libFuzzer names corpus files, so seeding twice adds nothing. The
seeds checked in under cmux-tui/fuzz/corpus/<target>/ (batches 2 and 3), and
under the corpus/<target>/ of each --corpus-dir (the fuzz workspaces of the
other Cargo workspaces, task 181), are copied in the same way, so every
target starts from its stored seeds.

Usage: seeds.py --repo REPO_ROOT --out CORPUS_ROOT [--corpus-dir DIR ...] [TARGET ...]
"""

from __future__ import annotations

import argparse
import hashlib
import json
import struct
import sys
from pathlib import Path
from typing import Callable, Iterable

# A seed larger than this is cut: libFuzzer's default -max_len is 4096 and
# bigger seeds only slow every mutation.
MAX_SEED_BYTES = 64 * 1024


def terminal_corpus(repo: Path) -> Iterable[bytes]:
    for path in sorted((repo / "schemas/terminal-corpus").glob("*.vt")):
        yield path.read_bytes()[:MAX_SEED_BYTES]
    yield b"\x1b[31mred\x1b[0m \x1b]0;title\x07\x1b[?1049h\x1b[2J\x1b[H\xe4\xb8\x96\x1b[?1049l"
    yield b"\x1b_Ga=T,f=24,s=1,v=1;AAAA\x1b\\"
    yield b"\x1b]8;;https://cmux.dev\x1b\\link\x1b]8;;\x1b\\\x1b[?2004h\x1bP+q544e\x1b\\"


def cmth_frame(kind: int, payload: bytes, *, version: int = 1, request_id: int = 1,
               sequence: int = 0, flags: int = 0) -> bytes:
    # terminal_host_protocol.rs encode_header: magic, version u16, kind u16,
    # flags u32, payload length u32, request id u64, sequence u64 (LE).
    header = b"CMTH" + struct.pack("<HHIIQQ", version, kind, flags, len(payload),
                                   request_id, sequence)
    return header + payload


def terminal_host_frames(_repo: Path) -> Iterable[bytes]:
    # Kinds 1..6: Bootstrap, Ready, ClientHello, HostHello, Snapshot, Output.
    yield cmth_frame(1, b"")
    yield cmth_frame(6, b"hello\r\n", sequence=7)
    yield cmth_frame(3, b'{"client":1}') + cmth_frame(2, b"", request_id=2)
    yield cmth_frame(5, b"GHOSTSNP" + bytes(24), sequence=1)
    yield cmth_frame(6, b"\x1b[2J", sequence=3)[:40]


def pane_protocol(repo: Path) -> Iterable[bytes]:
    vectors = json.loads(
        (repo / "cmux-tui/crates/cmux-pane-protocol/spec/pane-protocol-vectors.json").read_text())
    for case in vectors.get("unix_framing", []):
        if "hex" in case:
            yield bytes.fromhex(case["hex"])
    for section in ("vectors", "transport_envelopes"):
        for case in vectors.get(section, []):
            text = case.get("text")
            if isinstance(text, str):
                body = text.encode()
                yield struct.pack(">I", len(body)) + body


def wire_frame(lane: int, flags: int, stream: int, payload: bytes) -> bytes:
    # cmux-remote-protocol frame.rs encode: magic, version 5, lane, flags u16,
    # session [16], generation, sequence, acknowledgement, stream (u64 each),
    # payload length u32 (BE).
    return (b"CMXR" + bytes([5, lane]) + struct.pack(">H", flags) + bytes(range(16))
            + struct.pack(">QQQQI", 1, 2, 1, stream, len(payload)) + payload)


def remote_protocol(repo: Path) -> Iterable[bytes]:
    reliable, open_, heartbeat_request = 1, 2, 1 << 7
    yield wire_frame(0, reliable | open_, 3, b"data")
    yield wire_frame(1, reliable | heartbeat_request, 0, b"")
    yield wire_frame(2, reliable, 9, bytes(64))
    request_id = "6f1d2c3b-4a59-4687-9a0b-1c2d3e4f5a6b"
    yield json.dumps({"id": request_id, "request": {"type": "capabilities"}}).encode()
    yield json.dumps({"id": request_id, "timeout_ms": 500, "request": {
        "type": "read-file", "workspace": "w", "path": "a.txt", "offset": 0, "limit": 64}}).encode()
    yield json.dumps({"id": request_id, "result": {"Ok": {
        "type": "workspace", "id": "w", "root": "/repo"}}}).encode()
    yield json.dumps({"id": request_id, "result": {"Err": {
        "code": "denied", "message": "no", "retryable": False}}}).encode()
    yield json.dumps({"sequence": 1, "event": {
        "type": "stdout", "process": request_id, "sequence": 0, "data": "aGk="}}).encode()
    fixture = repo / "cmux-tui/crates/cmux-remote-protocol/tests/fixtures/relay-control-v1.jsonl"
    for line in fixture.read_bytes().splitlines():
        if line.strip():
            yield line


def config_jsonc(repo: Path) -> Iterable[bytes]:
    defaults = repo / "schemas/defaults/cmux-next.json"
    if defaults.is_file():
        yield defaults.read_bytes()[:MAX_SEED_BYTES]
    yield b'// settings\n{\n  "terminal": { "fontSize": 13, /* inline */ },\n  "ui": [1, 2,],\n}\n'
    yield b'\xef\xbb\xbf[\n  { "key": "cmd+k", "command": "clear" }, // trailing\n]\n'
    yield b"{}"


def holder_frame(kind: int, chan: int, payload: bytes, flags: int = 0) -> bytes:
    # cmux-holder wire.rs encode_parts: magic, kind u16, flags u16, chan u32,
    # payload length u32 (LE).
    return b"CMHX" + struct.pack("<HHII", kind, flags, chan, len(payload)) + payload


def holder_string(value: bytes) -> bytes:
    return struct.pack("<I", len(value)) + value


def holder(_repo: Path) -> Iterable[bytes]:
    spawn = (bytes(range(16)) + struct.pack("<HHHH", 80, 24, 640, 480) + holder_string(b"/tmp")
             + struct.pack("<I", 2) + holder_string(b"/bin/sh") + holder_string(b"-l")
             + struct.pack("<I", 1) + holder_string(b"TERM=xterm-256color"))
    yield spawn
    yield holder_frame(3, 0, spawn)
    yield holder_frame(1, 0, struct.pack("<H", 5) + bytes(32)) + holder_frame(2, 0, struct.pack("<HI", 5, 0))
    yield b"cmux-holder wire 1-5\n"


TARGETS: dict[str, Callable[[Path], Iterable[bytes]]] = {
    "ghostty_vt_output": terminal_corpus,
    "terminal_host_read_frame": terminal_host_frames,
    "pane_protocol_frame": pane_protocol,
    "remote_protocol": remote_protocol,
    "config_jsonc": config_jsonc,
    "holder_decode": holder,
}


def corpus_roots(repo: Path, extra: Iterable[Path]) -> list[Path]:
    roots = [repo / "cmux-tui/fuzz/corpus"]
    roots.extend(path for path in extra if path.resolve() != roots[0].resolve())
    return roots


def checked_in(roots: Iterable[Path], target: str) -> Iterable[bytes]:
    for root in roots:
        directory = root / target
        if directory.is_dir():
            for path in sorted(directory.iterdir()):
                if path.is_file():
                    yield path.read_bytes()


def write_seeds(repo: Path, out: Path, target: str, roots: list[Path]) -> int:
    directory = out / target
    directory.mkdir(parents=True, exist_ok=True)
    written = 0
    built = TARGETS[target](repo) if target in TARGETS else ()
    for seed in (*built, *checked_in(roots, target)):
        seed = seed[:MAX_SEED_BYTES]
        path = directory / hashlib.sha1(seed).hexdigest()
        if not path.exists():
            path.write_bytes(seed)
            written += 1
    return written


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--corpus-dir", type=Path, action="append", default=[],
                        help="another root of checked-in seeds, one subdirectory per target")
    parser.add_argument("--list", action="store_true", help="print the seeded targets")
    parser.add_argument("targets", nargs="*")
    args = parser.parse_args(argv)
    if args.list:
        print("\n".join(TARGETS))
        return 0
    roots = corpus_roots(args.repo, args.corpus_dir)
    for target in args.targets or list(TARGETS):
        written = write_seeds(args.repo, args.out, target, roots)
        if target in TARGETS or any((root / target).is_dir() for root in roots):
            print(f"{target}: {written} new seeds")
        else:
            # A target added without seeds starts from an empty corpus.
            print(f"{target}: no seeds", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
