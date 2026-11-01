#!/usr/bin/env python3
"""Copy a projection of an acpmux home's chats into a dev slot (`dev-slot.sh up N --from HOME`).

The slot's daemon then serves the person's own chats to the hot-reloading pane, while the source
home is only read. A copy must never start an agent: a chat whose log still holds work for the
next daemon (an unfinished turn, a prompt waiting in its queue, a move or an agent pair in flight,
a failed last turn a retry may continue) is skipped, and dev-slot.sh also writes
`autoResumeDelaysMs: []` into the slot's config. Agent hosts (`hosts/`) are never copied, so
nothing is adopted.

Store layout (cmux-tui/crates/acpmux/src/store.rs): `sessions/<id>/session.json` and
`sessions/<id>/events/*.ndjson`, one EventRecord per line. Queue kinds: hub/queue.rs QUEUE_KINDS.

    dev_slot_project.py SOURCE_HOME SLOT_HOME [--sessions N]
"""

import argparse
import json
import os
import shutil
import sys
import tempfile
from pathlib import Path

# The kinds that open or close work the next daemon would act on. serde writes `"kind":"x"`.
OPENS = {"queued", "turn_started"}
CLOSES = {"turn_result", "queue_removed", "queue_declined"}
# A prompt joined into a running turn (`joinedTurnId`) left the queue; that turn is tracked itself.
# A plain `dequeued` is followed by its own `turn_started`, and one taken into an inbox digest waits.
JOINED = "dequeued"
MOVES = {"transfer_out": True, "transfer_aborted": False, "imported": False}
PAIRS = {
    "agent_pair_held": True,
    "agent_pair_paused": True,
    "agent_pair_resumed": True,
    "agent_pair_released": False,
    "agent_pair_dropped": False,
}
NEEDLES = tuple(f'"kind":"{k}"'.encode() for k in OPENS | CLOSES | {JOINED} | set(MOVES) | set(PAIRS))


def segments(session: Path) -> list[Path]:
    events = session / "events"
    if not events.is_dir():
        return []
    return sorted(p for p in events.iterdir() if p.suffix == ".ndjson" and p.is_file())


def last_change(session: Path) -> float:
    files = [session / "session.json", *segments(session)]
    return max((p.stat().st_mtime for p in files if p.exists()), default=0.0)


def pending_work(session: Path) -> str | None:
    """Why the next daemon would act on this chat, or None when it is quiet."""
    open_turns: set[str] = set()
    moving = paired = False
    last_status = None
    for segment in segments(session):
        with segment.open("rb") as f:
            for line in f:
                if not any(n in line for n in NEEDLES):
                    continue
                try:
                    record = json.loads(line)
                except ValueError:
                    continue  # a torn last line of a log being written
                if record.get("dir") != "mux":
                    continue  # an agent's update may carry any kind
                kind, msg = record.get("kind"), record.get("msg") or {}
                turn = msg.get("turnId") if isinstance(msg, dict) else None
                if kind in OPENS and turn:
                    open_turns.add(turn)
                elif kind == JOINED and turn and msg.get("joinedTurnId"):
                    open_turns.discard(turn)
                elif kind in CLOSES and turn:
                    open_turns.discard(turn)
                    if kind == "turn_result":
                        last_status = msg.get("status")
                elif kind in MOVES:
                    moving = MOVES[kind]
                elif kind in PAIRS:
                    paired = PAIRS[kind]
    if open_turns:
        return f"{len(open_turns)} unfinished or queued turn(s)"
    if moving:
        return "a move in flight"
    if paired:
        return "an agent pair in flight"
    if last_status == "failed":
        return "a failed last turn a retry may continue"
    return None


def project(source: Path, slot: Path, limit: int) -> tuple[list[str], list[tuple[str, str]]]:
    root = source / "sessions"
    if not root.is_dir():
        raise SystemExit(f"no chats in {source}: {root} is not a folder")
    # A symlinked chat folder is refused by the store (store.rs), so it is not copied either.
    chats = [p for p in root.iterdir() if p.is_dir() and not p.is_symlink() and (p / "session.json").is_file()]
    chats.sort(key=last_change, reverse=True)
    taken: list[str] = []
    skipped: list[tuple[str, str]] = []
    staging = Path(tempfile.mkdtemp(prefix=".sessions-", dir=slot))
    try:
        for chat in chats:
            if len(taken) >= limit:
                break
            why = pending_work(chat)
            if why:
                skipped.append((chat.name, why))
                continue
            shutil.copytree(chat, staging / chat.name, symlinks=True)
            # Read again after the copy: work that began while it ran is not projected.
            why = pending_work(staging / chat.name)
            if why:
                shutil.rmtree(staging / chat.name)
                skipped.append((chat.name, why))
                continue
            taken.append(chat.name)
        os.chmod(staging, 0o700)
        target = slot / "sessions"
        if target.exists():
            shutil.rmtree(target)
        staging.rename(target)
    except BaseException:
        shutil.rmtree(staging, ignore_errors=True)
        raise
    return taken, skipped


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("source", type=Path)
    parser.add_argument("slot", type=Path)
    parser.add_argument("--sessions", type=int, default=30, help="newest quiet chats to copy (default 30)")
    args = parser.parse_args()
    source, slot = args.source.resolve(), args.slot.resolve()
    if source == slot:
        raise SystemExit("the source and the slot are the same folder")
    slot.mkdir(parents=True, exist_ok=True)
    taken, skipped = project(source, slot, max(args.sessions, 0))
    print(f"projection: {len(taken)} chat(s) from {source}", file=sys.stderr)
    for chat, why in skipped:
        print(f"  skipped {chat}: {why}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
