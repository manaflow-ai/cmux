//! Script sessions owned by the daemon (plans/cmux-next/scripting-runtime.md,
//! phase 1).
//!
//! A session is one sandboxed `cmux-app-host --profile script` process
//! (`cmux_app_host::script::Session`). This module owns the sessions of each
//! control connection, ends them when the connection closes, and routes the
//! ops a script calls into this daemon's own `cmux.protocol/2` dispatcher with
//! the rights of the calling CLI: the local user as actor, origin `agent`
//! (the origin every connection without a verified app gets), and only ops
//! this daemon owns. Provider ops (`action.run`), app host ops (`net.fetch`,
//! `app.storage.*`) and connection-scoped ops answer `operation.unsupported`.
//!
//! Wire commands (`server/scripts.rs`): `script-run`, `script-repl-open`,
//! `script-repl-eval`, `script-repl-close`; event `script-log`. Agent-bound
//! connections are refused until agent principals land (phase 3).

#[cfg(unix)]
pub(crate) mod router;
#[cfg(unix)]
mod slot;

#[cfg(unix)]
pub(crate) use slot::{Answer, LogBudget, ScriptsSlot, timeout_from};

/// Stub for platforms without the script host (no Unix sandbox yet).
#[cfg(not(unix))]
#[derive(Default)]
pub(crate) struct ScriptsSlot;

#[cfg(not(unix))]
impl ScriptsSlot {
    pub(crate) fn disconnect(&self, _client: u64) {}
}

/// The error code a daemon without a script host answers.
#[cfg(unix)]
pub(crate) const UNAVAILABLE: &str = "script.unavailable";
/// The error code for a connection that may not run scripts.
#[cfg(unix)]
pub(crate) const FORBIDDEN: &str = "script.forbidden";
