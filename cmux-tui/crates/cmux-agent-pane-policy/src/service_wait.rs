//! What the pane's line says while a handshake waits on this app's acpmux, and whether it offers
//! Restart agent service, from what the host saw of the daemon.
//!
//! Leo, 2026-11-18 ~23:10Z, on "Waiting for the agent service (1:10)  Restart agent service": "i
//! cant connect to agent service? something? :(". The daemon was alive and slow (`acpmux daemon
//! status` took 4.9 to 11.8 s), so a restart was the wrong thing to offer: it reloads every chat and
//! a daemon that answers late is not a crash (rule R5). Leo, 2026-11-19 ~00:3xZ: "the gui is still
//! unreliable on this nightly cuz of the agent service and whatnot too coupled to load and size and
//! history". So only a daemon that is really down gets the waiting line and Restart:
//!
//! - [`WaitState::Busy`]: a process listens on the socket and took the connection, but the reply is
//!   late. A quiet busy note, never Restart.
//! - [`WaitState::Starting`]: the daemon's process runs but nothing accepts on its socket yet (a start
//!   that loads its chats). A quiet note, never Restart.
//! - [`WaitState::Down`]: no daemon process, and nothing accepts on the socket: "not running" with
//!   Restart.
//!
//! The host probes (the pid file's process, a connect to the socket); this module only decides.
//! No I/O, no clock.

use serde_json::{Value, json};

/// What the host saw of the daemon a handshake waits on.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Probe {
    /// The home's `daemon.pid` names a running acpmux process.
    pub process_alive: bool,
    /// A connect to the home's socket succeeded (a process listens there).
    pub socket_accepts: bool,
}

/// What the line says.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WaitState {
    /// Alive and listening, the reply is late.
    Busy,
    /// The process runs, its socket does not accept yet.
    Starting,
    /// No process and no listener.
    Down,
}

impl WaitState {
    pub fn name(self) -> &'static str {
        match self {
            WaitState::Busy => "busy",
            WaitState::Starting => "starting",
            WaitState::Down => "down",
        }
    }
}

/// The line's state and whether it offers Restart agent service.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Verdict {
    pub state: WaitState,
    pub offers_restart: bool,
}

/// The verdict for `probe`. A listener on the socket is the daemon answering slowly, whatever the
/// pid file says (a pid file a start has not written yet). Only a daemon that is down is offered a
/// restart, however long the pane has waited on a live one.
pub fn classify(probe: Probe) -> Verdict {
    let state = if probe.socket_accepts {
        WaitState::Busy
    } else if probe.process_alive {
        WaitState::Starting
    } else {
        WaitState::Down
    };
    Verdict { state, offers_restart: state == WaitState::Down }
}

/// The `service_wait` op: `{process_alive, socket_accepts}` (an extra `waited_ms` is ignored) to
/// `{"state": "busy"|"starting"|"down", "restart": bool}`. None for a request missing a key or
/// with a key of another type.
pub fn call(request: &Value) -> Option<Value> {
    let flag = |key: &str| request.get(key).and_then(Value::as_bool);
    let probe =
        Probe { process_alive: flag("process_alive")?, socket_accepts: flag("socket_accepts")? };
    let verdict = classify(probe);
    Some(json!({"state": verdict.state.name(), "restart": verdict.offers_restart}))
}

#[cfg(test)]
#[path = "service_wait_tests.rs"]
mod tests;
