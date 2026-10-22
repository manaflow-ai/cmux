# Workspace registry size: what fills it, and how to shrink it safely

Status: design (2026-10-22). Nothing here has run on a person's registry.

## What we measured

The NIGHTLY owner's registry (`cmux-tui/sessions/cmux-app-…/workspace-registry.sqlite3`) on the
lead developer's Mac. The scan ran read-only on an APFS clone (`cp -c`, then `dbstat` with
`mode=ro&immutable=1`, 5 minutes); the live file was not opened.

| | size |
|---|---|
| File | 41.6 GB (10,165,090 pages of 4 KiB) |
| Free pages (`freelist_count`) | 16.5 GB (4,041,078 pages); `auto_vacuum=0` (a legacy registry) |
| Live data | 24.6 GB |

Live data by table (pages × 4 KiB):

| table or index | size |
|---|---|
| `journal_subject_index` | 7.9 GB |
| `journal_subject_index_by_subject_sequence` | 7.6 GB |
| `journal_segments` (21,592 sealed segments, gzip) | 5.0 GB (31 GB uncompressed) |
| `journal_event_index` and its two unique indexes | 3.0 GB |
| everything else | under 0.5 GB |

The journal holds 22.0 M records. Sealing works: `session_journal` keeps 1,489 rows. But the
subject index and the event index keep a row for each of the 22 M records forever: both are
append-only by design (`journal_subject_index_reject_delete`), and nothing removes the rows of
sealed records. That is 18.5 GB of the 24.6 GB, and it grows with every terminal output chunk.

The free pages come from sealing on a legacy registry: the sealed `session_journal` rows are
freed, and with `auto_vacuum=0` the file never gives the pages back. The owner will not convert a
legacy registry above its live-data bound (`LEGACY_AUTO_VACUUM_MAX_LIVE_BYTES`; a full `VACUUM`
under the registry stalled owners for minutes, cx-4bd8m), so it logs "auto-vacuum conversion
deferred" at every start.

Every query a maintenance tick runs under the registry lock was timed on the clone: 0 to 34 ms
each (`MAX(end_sequence)`, the checkpoint lookup, the receipt counts, the journal head). The
21:28 PDT stall of 2026-10-21 had no checkpoint or seal in its window (the nearest ran at
04:27:21Z, 46 s before). So the size does not by itself explain that stall. The owner now names
any frame that takes 500 ms or more and writes its stderr to the client log, so the next stall
says which request it was.

## Shrink 1: give the free pages back (16.5 GB), with a backup

`cmux-tui server compact-registry --session <session>` exists (cx-ossub, `compact.rs`). It
refuses while an owner runs, writes `VACUUM INTO` a staged file, checks it, and renames it over
the registry with incremental auto-vacuum on. It keeps no copy of the old file. The steps, which
need the person to quit cmux, so they are theirs to schedule:

1. Quit cmux (the owner stops; `server status --session cmux-app` reports none).
2. Back up: `cp -c workspace-registry.sqlite3{,-wal} <backup dir>/`. On APFS a clone costs no
   space until the files differ.
3. `cmux-tui server compact-registry --session cmux-app`. The staged copy needs about 25 GB free
   on the same volume.
4. Start cmux; check the workspaces, then delete the backup after a day of use.

Expected: 41.6 GB to about 24.6 GB, and the owner marks the registry migrated, so later sealing
gives pages back by itself.

Follow-up: `compact-registry --backup <dir>` should do step 2 itself (clone where the volume
can, refuse when it cannot and space is short), so no one runs it without a copy.

## Shrink 2: retention for the journal indexes (18.5 GB and growing)

The subject index answers "records about subject X" and the event index answers "record with
event id E" and the causation and resource-revision checks. For a sealed record both could be
answered from the segment instead. Proposal:

- When a segment seals, store its subject set (as `journal_segment_kinds` already stores its
  kinds) and its event id range.
- Then drop the index rows of the sealed range in bounded batches per maintenance tick, as the
  ledger retention does (`LEDGER_PRUNE_BATCHES_PER_TICK`), each batch under its own lock hold.
- Readers of sealed history go through the segment summary and decompress only the matching
  segments.

This changes the append-only contract of the two indexes (their delete triggers), so it needs
the journal owner's sign-off before any code. Until then the indexes grow by about 850 bytes
per journal record.
