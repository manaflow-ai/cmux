#!/usr/bin/env python3
"""Digest a cmux NEXT registry's journal, per sequence range, read-only.

Prints one JSON object: for every range of RANGE sequences, the count of
records other than terminal output and a SHA-256 over them (sequence, event
id, kind, canonical payload and subjects), whether a record is a live
`session_journal` row or inside a sealed segment (gzip-json-v1 or
zstd-json-v1). Two registries hold the same history when their ranges match:
run it on a copy before and after a migration (sealing, the output cleanup's
swap) and compare with --compare, which reads only through the first run's
journal head (a daemon appends records of its own when it starts).

    registry-journal-digest.py REGISTRY.sqlite3 > before.json
    registry-journal-digest.py REGISTRY.sqlite3 --compare before.json

zstd segments need Python 3.14 (compression.zstd), the `zstandard` module or
a `zstd` binary on PATH.
"""

import argparse
import gzip
import hashlib
import json
import shutil
import sqlite3
import subprocess
import sys

OUTPUT_KIND = "terminal.output"


def zstd_decompress(data):
    try:
        from compression import zstd  # Python 3.14

        return zstd.decompress(data)
    except ImportError:
        pass
    try:
        import zstandard

        return zstandard.ZstdDecompressor().decompressobj().decompress(data)
    except ImportError:
        pass
    if shutil.which("zstd") is None:
        sys.exit("a zstd-json-v1 segment needs compression.zstd, zstandard or a zstd binary")
    return subprocess.run(["zstd", "-dcq"], input=data, capture_output=True, check=True).stdout


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def line(sequence, event_id, kind, payload, subjects):
    return f"{sequence}\t{event_id}\t{kind}\t{canonical(payload)}\t{canonical(subjects)}\n".encode()


class Ranges:
    def __init__(self, size):
        self.size = size
        self.ranges = {}

    def add(self, sequence, data):
        start = (sequence - 1) // self.size * self.size + 1
        entry = self.ranges.get(start)
        if entry is None:
            entry = self.ranges[start] = [0, hashlib.sha256()]
        entry[0] += 1
        entry[1].update(data)

    def result(self):
        return {
            str(start): {"count": count, "sha256": digest.hexdigest()}
            for start, (count, digest) in sorted(self.ranges.items())
        }


def digest(path, size, through=None):
    db = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    ranges = Ranges(size)
    segments = 0
    # Segments first, in sequence order; their records come before every live row.
    for segment_id, codec, content, uncompressed, sha in db.execute(
        "SELECT segment_id, codec, content, uncompressed_bytes, sha256 FROM journal_segments"
        " ORDER BY start_sequence"
    ):
        if codec == "gzip-json-v1":
            raw = gzip.decompress(content)
        elif codec == "zstd-json-v1":
            raw = zstd_decompress(content)
        else:
            sys.exit(f"segment {segment_id}: unknown codec {codec}")
        if len(raw) != uncompressed or hashlib.sha256(raw).digest() != bytes(sha):
            sys.exit(f"segment {segment_id}: length or digest does not match")
        segments += 1
        for record in json.loads(raw):
            if record["kind"] == OUTPUT_KIND or (through and record["sequence"] > through):
                continue
            ranges.add(
                record["sequence"],
                line(record["sequence"], record["event_id"], record["kind"], record["payload"], record["subjects"]),
            )
    live = 0
    for sequence, event_id, kind, payload, subjects in db.execute(
        "SELECT sequence, event_id, kind, payload_json, subjects_json FROM session_journal"
        " WHERE kind != ? AND sequence <= ? ORDER BY sequence",
        (OUTPUT_KIND, through or 2**63 - 1),
    ):
        live += 1
        ranges.add(sequence, line(sequence, event_id, kind, json.loads(payload), json.loads(subjects)))
    head = db.execute(
        "SELECT MAX(COALESCE((SELECT MAX(sequence) FROM session_journal), 0),"
        " COALESCE((SELECT MAX(end_sequence) FROM journal_segments), 0))"
    ).fetchone()[0]
    return {
        "range": size,
        "head": head,
        "segments": segments,
        "live_rows": live,
        "ranges": ranges.result(),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("registry")
    parser.add_argument("--range", type=int, default=100_000)
    parser.add_argument("--compare", help="a digest from an earlier run; exit 1 on any difference")
    args = parser.parse_args()
    before = None
    if args.compare:
        with open(args.compare) as handle:
            before = json.load(handle)
    # Records the daemon appended after the first digest are not compared.
    result = digest(args.registry, before["range"] if before else args.range, before and before["head"])
    if not args.compare:
        json.dump(result, sys.stdout, indent=1)
        print()
        return 0
    differ = [
        start
        for start in sorted(set(before["ranges"]) | set(result["ranges"]), key=int)
        if before["ranges"].get(start) != result["ranges"].get(start)
    ]
    count = lambda digest: sum(entry["count"] for entry in digest["ranges"].values())
    print(
        json.dumps(
            {
                "ranges": len(result["ranges"]),
                "records_before": count(before),
                "records_after": count(result),
                "differing_ranges": differ[:20],
                "differing_count": len(differ),
            }
        )
    )
    return 1 if differ else 0


if __name__ == "__main__":
    sys.exit(main())
