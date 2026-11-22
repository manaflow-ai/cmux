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
//!   late. It heals by itself and the person has nothing to do: the pane draws nothing, however
//!   long it lasts, and never offers Restart.
//! - [`WaitState::Starting`]: the daemon's process runs but nothing accepts on its socket yet (a start
//!   that loads its chats). Likewise nothing, never Restart.
//! - [`WaitState::Down`]: no daemon process, and nothing accepts on the socket: one calm line with
//!   Restart agent service, the one button that fixes it, once the wait has lasted the shared bound
//!   ([`CONNECTION_QUIET_MS`]).
//!
//! Leo, 2026-11-22: "entire classes of bullshit fucking error/status bullshit. fuck em. remove them
//! all." Leo, 2026-11-14: "i also want all our connectivity stuff to shut the fuck up and load
//! faster/percievably load faster / whatever it takes". No counter and no timer on the line.
//!
//! The host probes (the pid file's process, a connect to the socket) and says how long the pane has
//! waited; this module only decides. No I/O, no clock.

use serde_json::{Value, json};

/// How long a state the person can do nothing about stays out of sight: the copy of
/// schemas/notice-timing/notice-timing.json `connectionQuietMs`, checked against it by
/// scripts/cmux-next/check-connection-notices.py.
pub const CONNECTION_QUIET_MS: u64 = 10_000;

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

/// Whether the pane draws its line after waiting `waited_ms` on a daemon judged `verdict`: only a
/// daemon that is down, the one state with an action (Restart agent service), and only once the
/// wait has lasted [`CONNECTION_QUIET_MS`]. A busy or starting daemon draws nothing at all: the
/// pane keeps its transcript and composer while it heals.
pub fn shows_line(verdict: Verdict, waited_ms: u64) -> bool {
    verdict.offers_restart && waited_ms >= CONNECTION_QUIET_MS
}

/// The `service_wait` op: `{process_alive, socket_accepts, waited_ms?}` to
/// `{"state": "busy"|"starting"|"down", "restart": bool, "line": bool}`; `line` ([`shows_line`])
/// reads a missing `waited_ms` as a wait that just began. None for a request missing a flag or with
/// a key of another type.
pub fn call(request: &Value) -> Option<Value> {
    let flag = |key: &str| request.get(key).and_then(Value::as_bool);
    let probe =
        Probe { process_alive: flag("process_alive")?, socket_accepts: flag("socket_accepts")? };
    let waited_ms = match request.get("waited_ms") {
        None => 0,
        Some(value) => value.as_u64()?,
    };
    let verdict = classify(probe);
    Some(json!({
        "state": verdict.state.name(),
        "restart": verdict.offers_restart,
        "line": shows_line(verdict, waited_ms),
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    const ALIVE: Probe = Probe { process_alive: true, socket_accepts: true };
    const STARTING: Probe = Probe { process_alive: true, socket_accepts: false };
    const DOWN: Probe = Probe { process_alive: false, socket_accepts: false };

    #[test]
    fn a_slow_daemon_is_busy_and_never_offers_a_restart() {
        // Leo's case: a daemon that listens and answers late.
        assert_eq!(classify(ALIVE), Verdict { state: WaitState::Busy, offers_restart: false });
    }

    #[test]
    fn a_listener_without_a_pid_file_is_busy() {
        let probe = Probe { process_alive: false, socket_accepts: true };
        assert_eq!(classify(probe), Verdict { state: WaitState::Busy, offers_restart: false });
    }

    #[test]
    fn a_process_whose_socket_refuses_is_starting_without_a_restart() {
        assert_eq!(
            classify(STARTING),
            Verdict { state: WaitState::Starting, offers_restart: false }
        );
    }

    #[test]
    fn no_process_and_no_listener_is_down_and_offers_restart() {
        assert_eq!(classify(DOWN), Verdict { state: WaitState::Down, offers_restart: true });
    }

    #[test]
    fn a_busy_or_starting_daemon_never_draws_a_line_however_long_it_waits() {
        for probe in [ALIVE, STARTING] {
            for waited in [0, CONNECTION_QUIET_MS - 1, CONNECTION_QUIET_MS, 600_000] {
                assert!(!shows_line(classify(probe), waited), "{probe:?} after {waited} ms");
            }
        }
    }

    #[test]
    fn a_down_daemon_draws_nothing_under_the_bound_and_its_line_past_it() {
        let down = classify(DOWN);
        assert!(!shows_line(down, 0));
        assert!(!shows_line(down, CONNECTION_QUIET_MS - 1));
        assert!(shows_line(down, CONNECTION_QUIET_MS));
        assert!(shows_line(down, 600_000));
    }

    #[test]
    fn the_op_answers_json_and_refuses_a_partial_request() {
        let busy = json!({"process_alive": true, "socket_accepts": true, "waited_ms": 600_000});
        assert_eq!(call(&busy).unwrap(), json!({"state": "busy", "restart": false, "line": false}));
        let down = call(&json!({"process_alive": false, "socket_accepts": false})).unwrap();
        assert_eq!(down, json!({"state": "down", "restart": true, "line": false}));
        let long = json!({"process_alive": false, "socket_accepts": false, "waited_ms": 10_000});
        assert_eq!(call(&long).unwrap(), json!({"state": "down", "restart": true, "line": true}));
        assert!(call(&json!({"process_alive": true})).is_none());
        assert!(call(&json!({"process_alive": true, "socket_accepts": "yes"})).is_none());
        let bad_wait =
            json!({"process_alive": false, "socket_accepts": false, "waited_ms": "long"});
        assert!(call(&bad_wait).is_none());
    }
}
