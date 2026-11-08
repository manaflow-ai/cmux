# Relay cleanup and child-task cancellation

This note defines the shutdown contract for the Tokio relay service. It is a
design boundary, not an implementation change.

## Contract

- A relay shutdown request stops new upgrades before cancelling existing work.
- The cleanup task exits after cancellation. Dropping a `JoinHandle` is not
  sufficient because Tokio detaches the task when the handle is dropped.
- Each upgraded socket owns one child writer task and one admission permit.
  Cancellation must release both, even if the writer is waiting on the
  bounded outbound queue.
- A socket close sends queued protocol frames before the final error and close
  frame. This ordering is part of the wire contract.
- State removal happens under the relay state lock. Network sends and task
  joins happen after releasing that lock.

## Proposed implementation boundary

Give `spawn_cleanup` a cancellation token (or an abort handle) owned by the
server lifecycle. On shutdown, stop admission, signal the token, and await the
cleanup task. Keep per-socket shutdown on the existing watch channel. Do not
replace the bounded mpsc queue with an unbounded channel.

## Acceptance tests

1. Shutdown causes the cleanup task to terminate within a bounded test timeout.
2. A new upgrade is rejected after shutdown starts.
3. An attached circuit receives its final error and close frame in queue order.
4. Cancelling a socket releases the global connection permit exactly once.
5. Cleanup never holds the state lock while awaiting a socket send or task join.
6. Replacing a daemon registration does not remove a newer registration for
   the same slot.

## Non-goals

- Do not merge native and Cloudflare admission limits. Their windows and
  capacity semantics currently differ.
- Do not change ticket validation, circuit lease durations, or queue limits.
- Do not make socket sends awaitable. Backpressure remains an explicit
  capacity error.

Tokio documents that dropping a `JoinHandle` detaches its task, while `abort`
only schedules cancellation and should be followed by awaiting the handle:
[JoinHandle](https://docs.rs/tokio/latest/tokio/task/struct.JoinHandle.html).
Tokio also recommends keeping synchronous shared-state critical sections free
of awaits and treating `select!` cancellation behavior explicitly:
[shared state](https://tokio.rs/tokio/tutorial/shared-state),
[select](https://tokio.rs/tokio/tutorial/select).
