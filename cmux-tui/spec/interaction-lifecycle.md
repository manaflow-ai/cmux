# Interaction lifecycle

How a user intent becomes visible state, and where the daemon is allowed to
wait. This is the contract behind "the user feels zero blocking". The design
rationale, baselines, and full PR order live in the cmuxterm-hq working doc
`plans/cmux-tui-zero-wait-interaction.md`; this file is the normative slice that
IX2 makes true.

## Three laws

1. **Frame.** A frontend's render loop never waits on another process. Any wait
   longer than one frame is represented as state (a lifecycle badge, a status
   line, a local gesture preview), never as the absence of a response. One frame
   is the TUI paint cadence, 16 ms.
2. **Accept-first.** The daemon acknowledges a mutation once it has validated it
   against in-memory state, given it a revision, applied it, and published its
   tree delta. Durability and settlement are named stages a caller can wait for;
   they are not the gate on the acknowledgement. IX2 delivers this for terminal
   placement (bound at reservation, before the host launches); the writer-level
   accept stage that also moves the fsync off the reply is IX3.
3. **Order.** The user's intent order is the tree order. Input to a terminal
   that is known not to have started yet (`launching`) is queued, bounded, and
   delivered in order once its host attaches. Input to a terminal whose state is
   unknown (a lost tap, a reconnect) is dropped. Queue when the peer is
   known-not-started; drop when the peer's state is unknown.

## Terminal lifecycle

A terminal moves through `launching → running → exited` publicly. `closing` and
`tombstoned` are internal cleanup states, and `adopting` maps to `launching`
publicly. The lifecycle is tree-visible: a
placement is bound at reservation with lifecycle `launching`, so a new pane, tab,
split, or workspace appears in the tree within a frame of the keypress, before
its host process exists.

- **launching**: the placement is in the tree, the host has not attached. The
  mirror renders empty at the creation size. Input is buffered as typeahead.
- **running**: the host has attached, `Activate` has been sent, PTY bytes flow.
- **exited**: the child ended, or the launch never produced a process. A failed
  launch keeps the placement and records the stable reason
  `launch-failed: host-launch-failed`. Detailed spawn errors stay in internal
  diagnostics. The pane shows the stable reason where its content would be.
- **tombstoned**: catalog removal by an explicit `terminal.close`; never in the
  tree.

## Deferred versus synchronous launch

A **default-shell create** (`new-workspace`, `new-tab`, `pane.split`,
`pane.create` with no command) binds its placement at reservation and launches
the host on the session effect executor after the request has replied. Its
control response therefore precedes the host's `Ready`; the host launch barrier
(see `terminal-host.md`, Handshakes) is preserved because `Activate` is sent only
after the created topology is durable.

A **command-bearing create** (`run`, `pane.run`, `workspace.run`, with an
explicit `argv`/`shell`) launches its host synchronously. A command that cannot
start (for example a missing executable) fails the request and rolls the creation
back, its long-standing contract; a command that runs and exits returns a
`running` or `exited` result with the exit outcome. `run` is not idempotent.

Terminal close and terminate also run on the effect executor: the request commits
the tombstone, detaches every view, and replies, while the host `Terminate` and
its bounded exit wait (`terminal.close_wait`, 4 s) happen off the request thread.

## `terminal-lifecycle` event

Delivered only to a `tree_events:"deltas"` subscription (a coarse subscriber
receives nothing; the tree it refetches already carries the lifecycle). The
daemon commits the durable transition before publishing, as with the other tree
deltas.

```json
{
  "event": "terminal-lifecycle",
  "terminal_id": "<public id or null while launching before first projection>",
  "registry_terminal_id": "<internal host id>",
  "surface": 12,
  "from": "launching",
  "to": "running",
  "elapsed_ms": 41,
  "cause": null,
  "discarded_input_bytes": 0
}
```

`cause` is the stable string `launch-failed: host-launch-failed` on a failed
launch. Detailed spawn errors stay in internal diagnostics.
`discarded_input_bytes` reports typeahead dropped when a launch fails; that input
is never replayed to any other terminal.

`registry_terminal_id` is an internal host identity. Trusted local subscribers
receive its value; remote delta subscribers receive `<redacted>`.

## Typeahead

A `launching` terminal buffers input up to the `input.typeahead_bytes` budget
(64 KiB) and delivers it, in order, to the host once it attaches. This is kernel
tty typeahead extended across the launch window. Overflow refuses the write with
an error that names the budget; it never drops silently. A `closing` or `exited`
terminal refuses input; an unknown-state terminal drops it.

## Observability (pending)

The daemon tracks launching/closing terminals, their queued typeahead, and the
effect-executor queue internally. A `diag inflight` verb that exposes this over
the control protocol is a follow-up (it needs the SDK-schema and seven-language
count plumbing that a new command requires); this PR ships the tracking and the
`terminal-lifecycle` event, not the verb.

## Pending

- **IX3**: the writer-level accept stage (tree deltas published before the fsync,
  receipts after), `--wait accepted|durable|settled` on the CLI with per-verb
  defaults, and `session.degraded`.
- **IX6**: startup ordering of restore against the first control connection.
