# Canonical Session Persistence

Status: implemented daemon storage contract. It is not a client wire format.

## Ownership and scope

The cmux-tui daemon owns the canonical session checkpoint and mutation
journal. The Swift app does not read or write either file. A daemon restart
reconstructs topology and launches new terminal runtimes. A Swift restart does
not restart the daemon, so its existing PTYs, PIDs, TTYs, terminal state, and
scrollback remain live.

A daemon crash still terminates PTYs owned by that daemon. The persisted
launch recipe restores a new process under the same terminal UUID. Its PID,
TTY, and terminal runtime epoch are new. Live PTY survival across daemon death
requires a separate PTY broker and descriptor handoff and is outside this
format.

The projection-state registry is also outside this format. It retains stable
frontend-window to workspace and selected-screen mappings only while the same
daemon process lives. A Swift frontend disconnect releases its claim but keeps
the mapping for a later process with the same registered client UUID. An
explicit window close deletes the mapping. Renderer presentations and terminal
control leases are always released with their connection. A daemon restart
starts with an empty projection-state registry even when canonical topology is
restored from disk.

## Files and lock

One session key deterministically maps to three private paths beneath the
state directory:

- an atomic JSON checkpoint;
- an append-only newline-delimited JSON journal;
- an exclusive startup lock held for the full daemon lifetime.

Directories use the platform private-directory policy and files use the
private-file policy. A second daemon cannot open the same session while the
first owns the lock. First-use directory creation syncs each new directory's
parent before checkpoint or journal acknowledgement, including the state
directory entry that owns `sessions/`.

The checkpoint and every journal record contain a format marker, format
version, session identity, epoch, sequence, body, and CRC32 checksum over the
compact JSON body. Unknown fields, unsupported versions, duplicate UUIDs,
invalid references, nil UUIDs, and values beyond hard limits fail validation.

## Canonical checkpoint

The checkpoint stores only stable identities and ordered canonical values:

- `session_id` and `topology_revision`;
- active workspace UUID;
- ordered workspaces and screens;
- each screen's UUID split tree, active pane UUID, and zoomed pane UUID;
- panes, ordered terminal UUID tabs, active tab, and activation order;
- terminal UUID, user name, retention policy, and safe launch recipe;
- browser placement UUID and user name without URL or browser engine state;
- bounded deletion tombstones;
- bounded idempotency results.
- a globally monotonic terminal activity sequence, the latest content-free fact per live terminal, and bounded per-reader receipts.

Legacy numeric workspace, screen, pane, surface, and process aliases are not
serialized. Terminal output, VT state, scrollback bytes, pasted text, browser
URLs, image bytes, PID, TTY, daemon instance ID, client state, presentation
state, leases, and renderer state are not serialized. Activity facts never contain notification titles or bodies.

Browser URLs are deliberately omitted because user-info, query, and fragment
components can carry credentials or private content. Browser placements
currently recover as `about:blank` under the same surface UUID.

## Terminal launch recipe

The terminal recipe contains exact argv items, an absolute cwd, dimensions,
scrollback capacity, and `wait_after_command`. It is executed as argv, never
reconstructed as a shell string.

Only these environment names may enter the durable recipe:

- `TERM`, `COLORTERM`, `LANG`, `LC_ALL`, `LC_CTYPE`, and `TZ`;
- standard locale-category variables such as `LC_MESSAGES`, `LC_TIME`, and
  `LC_NUMERIC`.

Tokens, passwords, socket capabilities, authentication-agent paths, arbitrary
`CMUX_*` values, and other inherited or request environment values remain
runtime-only. The daemon injects its current socket paths again when it
respawns a terminal.

## Mutation ordering and acknowledgement

Every canonical mutation computes the complete post-mutation persisted state
while holding the canonical state mutex. Before the topology revision is
published or the command handler can return success, the daemon:

1. assigns the next journal sequence in the current epoch;
2. serializes and validates the record;
3. appends one complete newline-terminated record;
4. calls `fsync` on the journal file.

An append or sync failure terminates the daemon process before acknowledgement.
This releases its socket and daemon-lifetime lock instead of leaving a live
service whose canonical mutex is poisoned. The installed launchd service uses
`KeepAlive` and restarts the backend after the process exits; a persistent disk
failure remains visible as a throttled restart failure rather than an
undurable live daemon.

Topology transactions currently mint an internal idempotency key and retain a
stable UUID-only result. The Mux exposes the retained-result lookup and keyed
commit seam for the protocol transaction lane. Protocol commands do not yet
accept caller-supplied idempotency keys, so reconnect retry plumbing remains a
separate protocol change.

## Startup replay

Startup acquires the lock before reading state. It validates the checkpoint,
then replays later records with exactly monotonic epoch and sequence values.
The replay validates each checksum, session identity, topology revision, full
snapshot, idempotency key, and retained result.

The same idempotency key may occur again only with the exact original result
and unchanged state. Replay advances its journal cursor without applying a
second mutation. A different result or state is corruption.

A malformed, torn, oversized, or checksum-invalid final record is copied to a
unique `invalid-tail` archive, then only that trailing byte range is truncated
and synced. Corruption followed by another record is interior corruption and
fails closed without changing the journal. Sequence gaps and backwards
revisions always fail closed.

## Compaction and bounds

Journal records and bytes have independent hard bounds. Before the next append
would cross either bound, the daemon atomically writes and syncs a checkpoint
for the latest acknowledged state under the next epoch, renames it, syncs the
directory, and atomically replaces the journal with an empty file. The new
mutation is then record 1 of that epoch.

A crash after checkpoint rename but before journal replacement can leave old
epoch records. Replay ignores records already covered by the newer checkpoint.
A crash after a journal append but before the next compaction replays that
synced record from the older checkpoint.

Tombstones and idempotency results each retain at most 1,024 entries and evict
the oldest entry first. Checkpoint, journal, record, entity, string, argv,
environment, and topology sizes are validated before allocation or mutation.
Activity keeps at most 16,384 latest facts, 1,024 reader UUIDs, and 65,536 stable-reader receipts. Capacity or sequence exhaustion rejects the mutation without eviction. Closing a surface removes its fact and receipts while retaining the global sequence high-water mark.

## Recovery behavior

Version-1 identity-only state migrates atomically through the canonical schema. Version-2 topology checkpoints and their synced journals migrate atomically to version 3 with empty activity state without changing `session_id`. Unsupported versions and
corrupt checkpoints fail closed. Explicit `--recover-state` archives corrupt
checkpoint and journal bytes before creating a new session identity.

On normal restart, the daemon allocates new process-local numeric aliases,
rebuilds the exact UUID topology and ordering, and respawns every retained
terminal recipe under its original terminal UUID. The new process reports
only its new PID, TTY, and runtime epoch. No old PID is present in durable
state or copied into the recovered runtime.

Terminal restore failures are isolated per surface. If a saved cwd no longer
exists, the daemon retries the exact saved argv from the account's native home
directory and writes a fixed recovery notice directly into canonical VT state.
If the saved argv cannot start, the daemon opens the platform default shell
from native home under the same terminal UUID. A fallback surface receives a
recovery label only when it has no user name. Notices and errors never include
the saved argv, environment, or cwd. The durable recipe remains unchanged so a
later daemon restart retries the user's original command. Failure to create
even the fallback shell or PTY still fails startup.
