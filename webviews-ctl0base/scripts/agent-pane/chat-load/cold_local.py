#!/usr/bin/env python3
"""Process-cold local first-page samples, never browser/native paint timings.

Usage: cold_local.py ACPMUX_BIN OUT_DIR [--turns 10000] [--runs 3]
Each sample starts a new daemon. OS file caches are deliberately not flushed.
The synthetic log contains 8 KiB assistant messages and no tools or noise.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile


def write_fixture(home, turns, message_bytes=8192, segment_bytes=8 * 1024 * 1024):
    sid = "0190a000-0000-7000-8000-00000000fc01"
    created = 1791000000000
    directory = home / "sessions" / sid
    events = directory / "events"
    events.mkdir(parents=True, mode=0o700)
    seq, total, segment, size = 0, 0, 0, 0
    stream = None

    def write(direction, kind, msg, at):
        nonlocal seq, total, segment, size, stream
        seq += 1
        line = (json.dumps(dict(seq=seq, at=at, dir=direction, kind=kind, msg=msg),
                           separators=(",", ":")) + "\n").encode()
        if stream is None or size >= segment_bytes:
            if stream is not None:
                stream.close()
            segment += 1
            path = events / f"{segment:06}.ndjson"
            stream = path.open("xb")
            path.chmod(0o600)
            size = 0
        stream.write(line)
        size += len(line)
        total += len(line)

    def update(value, at):
        write("in", value["sessionUpdate"], {"jsonrpc": "2.0", "method": "session/update",
              "params": {"sessionId": f"agent-{sid}", "update": value}}, at)

    commands = {"sessionUpdate": "available_commands_update",
                "availableCommands": [{"name": "compact", "description": "Compact chat"}]}
    try:
        update(commands, created - 1)
        for turn in range(turns):
            at = created + turn * 60000
            ids = {"promptId": f"p-{turn}", "turnId": f"t-{turn}"}
            write("mux", "user_message", {"text": f"Turn {turn}", "promptId": ids["promptId"]}, at)
            write("mux", "turn_started", ids, at + 1)
            text = f"TAIL {turn}: " + "x" * message_bytes
            update({"sessionUpdate": "agent_message_chunk",
                    "content": {"type": "text", "text": text}}, at + 2)
            write("mux", "turn_result", {**ids, "status": "completed", "stopReason": "end_turn"}, at + 3)
    finally:
        if stream is not None:
            stream.close()
    meta = dict(schema="acpmux.session.v1", id=sid, name="Cold local tail", title="Cold local tail",
                harness="fc", harnessArgv=["false"], cwd="/tmp", agentSessionId=f"agent-{sid}",
                status="closed", createdAt=created, updatedAt=created + turns * 60000,
                lastSeq=seq, eventCount=seq, turnCount=turns, availableCommands=commands)
    metadata = directory / "session.json"
    metadata.write_text(json.dumps(meta))
    metadata.chmod(0o600)
    return {"home": str(home), "sessions": [{"id": sid, "turns": turns, "records": seq,
            "bytes": total, "segments": segment, "lastMarker": f"TAIL {turns - 1}: "}]}


def positive(value):
    number = int(value)
    if number < 1:
        raise argparse.ArgumentTypeError("must be positive")
    return number


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("out", type=Path)
    parser.add_argument("--turns", type=positive, default=10000)
    parser.add_argument("--runs", type=positive, default=3)
    args = parser.parse_args()
    binary = args.binary.resolve(strict=True)
    args.out.mkdir(parents=True, exist_ok=True)
    # Short owned scratch paths also keep the Unix socket below sun_path's limit.
    with tempfile.TemporaryDirectory(prefix="tail-cold-") as scratch:
        fixture = write_fixture(Path(scratch) / "home", args.turns)
        fixture_path = Path(scratch) / "fixture.json"
        fixture_path.write_text(json.dumps(fixture))
        results = []
        for sample in range(args.runs):
            output = args.out.resolve() / f"sample-{sample + 1}.json"
            subprocess.run([sys.executable, "-I", str(Path(__file__).with_name("daemon_bench.py")),
                            str(binary), str(fixture_path), str(output), "--repeat", "1", "--scroll", "0"],
                           check=True)
            results.append(json.loads(output.read_text()))
        with binary.open("rb") as stream:
            digest = hashlib.file_digest(stream, "sha256").hexdigest()
        result = {"scope": "process-cold daemon; OS cache not flushed; no browser or native paint",
                  "fixture": fixture["sessions"][0], "binary_sha256": digest,
                  "head": subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
                  "samples": results}
        (args.out / "cold-local.json").write_text(json.dumps(result, indent=2) + "\n")


if __name__ == "__main__":
    main()
