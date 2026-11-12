//! Which `session.snapshot` terminals still run, by their `lifecycle` word
//! (W5-Q follow-up, #39580 review): one allow-list for every CLI path that
//! asks.
//!
//! The daemon's terminal lifecycle (`cmux_tui_core::TerminalLifecycle`) has
//! these words; the public snapshot maps them as shown:
//!
//! | daemon | snapshot | runs |
//! | --- | --- | --- |
//! | `launching` | `launching` | yes: the program starts |
//! | `adopting` | `launching` | yes: a restarted daemon takes a running program back |
//! | `running` | `running` | yes |
//! | `exited` | `exited` | no: kept after its program ended (`--on-exit keep`) |
//! | `tombstoned` | not listed | no: closed |
//!
//! `adopting` is in the list too, so a snapshot that says it stays live. Any
//! other word (a newer daemon's) and a terminal without a `lifecycle` field
//! do not run here: a path that would act on a live terminal leaves it alone.

use serde_json::Value;

/// The lifecycle words of a terminal whose program runs or starts.
const LIVE: [&str; 3] = ["running", "launching", "adopting"];

/// Whether `terminal` (a `session.snapshot` or `terminal.list` record) still
/// runs: its `lifecycle` is one of `running`, `launching` and `adopting`.
pub(in crate::cli) fn is_live(terminal: &Value) -> bool {
    terminal.get("lifecycle").and_then(Value::as_str).is_some_and(|word| LIVE.contains(&word))
}

/// Whether `terminal`'s program ended and the terminal was kept
/// (`lifecycle: exited`): only such a terminal can resume its agent.
pub(in crate::cli) fn is_exited(terminal: &Value) -> bool {
    terminal.get("lifecycle").and_then(Value::as_str) == Some("exited")
}
