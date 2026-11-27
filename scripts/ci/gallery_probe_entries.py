#!/usr/bin/env python3
"""The gallery entries a post-merge bisect probe renders: those of the origin batch run's own red states.

    gallery_probe_entries.py DIR

DIR holds the origin run's `gallery-health-N` artifacts (one folder each: health.json, and base/1, base/2 when the
shard replayed its reds on the base). Prints the entries (`entry` of `entry#variant`) of every state red on the head
and not red the same way on that shard's base, comma-separated. Prints nothing, meaning render every entry, when no
shard ran, when a shard has no whole verdict (a crash or a cut-short render can hide its red anywhere), or when no
own red state is left.

Why (2026-11-27, goal ci-min-per-pr-30): a probe rendered the whole gallery, 22 shards and about 400 runner-minutes,
to ask whether a red of a few states is there at one commit. 8 gallery probes in 3.5 h were most of the post-merge
batch's 12.2 CI minutes per merged PR. The probe's verdict is still judged against its known-good commit, so
rendering the red states' entries answers the same question.
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import test_reds  # noqa: E402


def own_entries(root: Path) -> list[str] | None:
    """The entries of the origin's own reds, or None to render everything."""
    shards = sorted(p for p in root.glob("gallery-health-*") if p.is_dir())
    if not shards:
        return None
    states: set[str] = set()
    for shard in shards:
        head_path = shard / "health.json"
        head_text = head_path.read_text(errors="replace") if head_path.is_file() else None
        head = test_reds.gallery_read(head_text)
        if head.truncated or head.crashes:
            return None
        if not head.failed:
            continue
        bases = [p.read_text(errors="replace") for p in sorted(shard.glob("base/*/health.json"))]
        shared: set[str] = set()
        if bases:
            seen = test_reds.Result()
            for text in bases:
                found = test_reds.gallery_read(text, keep_known=True)
                if found.truncated:
                    seen = None
                    break
                seen.failed |= found.failed
            if seen is not None:
                shared = head.failed & seen.failed
        states |= {name.split(": ", 1)[0] for name in head.failed - shared}
    entries = sorted({s.rsplit("#", 1)[0] for s in states if s})
    return entries or None


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__.strip().splitlines()[2].strip(), file=sys.stderr)
        return 64
    entries = own_entries(Path(argv[1]))
    print(",".join(entries or []))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
