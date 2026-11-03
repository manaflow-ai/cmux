// Whether acpmux runs a turn, read from its session status (acpmux store.rs `SessionStatus`):
// `running` runs a prompt turn and `waiting` is that turn asking the person. `ready`, `idle`,
// `disconnected` and `closed` run none.
//
// The pane folds a turn open from its records (`user_message`, `turn_started`) and closed from its
// end (`turn_end`, `turn_result`). Some ends write no end record: a daemon that hands a running
// turn to the next one on restart (hub/shutdown.rs), a wait a restart cut (hub/log_load.rs), a host
// that could not be adopted (hub/hosts.rs). Each still writes its status, in the log's order, so
// the status is what says the turn is over (https://github.com/manaflow-ai/cmux/issues/32727).

const TURN_STATUSES: ReadonlySet<string> = new Set(["running", "waiting"]);

/// Whether a session status says acpmux runs a turn.
export const runsTurn = (status: unknown): boolean => typeof status === "string" && TURN_STATUSES.has(status);

/// Whether a logged status change ends the turn the pane holds open: the status left a turn
/// (`running` or `waiting`) for one with none. A status that starts an agent (`idle` or
/// `disconnected` to `ready`) while a prompt waits for it to run ends nothing.
export const statusEndsTurn = (previous: unknown, next: unknown): boolean =>
  runsTurn(previous) && typeof next === "string" && next !== "" && !runsTurn(next);
