//! A bound on the ssh logins peer links make on this host at once.
//!
//! Every `ssh://` peer's link logs in over ssh: the tunnel (`ssh -W 127.0.0.1:PORT -- HOST`), the
//! read of the remote's tokens beside it, and a path probe's own tunnel. The dial gate
//! (`peer_dial_gate.rs`) spreads the dials themselves, but it gives a slot back after
//! `peer_dial_gate::HOLD` (2 s), so on a host too loaded for a login to finish in 2 s it let the
//! next dials through every 2 s while the earlier ssh were still logging in. A daemon starting
//! with its peers on a Mac right after a reboot (load over 200) had 130 ssh processes 12 s after
//! the person logged in (2026-11-24), on a Mac that had just run out of memory.
//!
//! Through [`login`], at most [`LOGINS`] logins are in flight host-wide, each up to two ssh
//! processes (the tunnel and the token read that runs beside it on a first connect), so a daemon
//! never has more than `2 * LOGINS` ssh children logging in, however many peers it has. A login
//! a client waits on (`Peer::is_wanted`) takes the next free slot ahead of background ones. A
//! slot goes back when the login ends (the WebSocket opened over the tunnel, or it failed) or
//! after [`LOGIN_HOLD`], so one host whose ssh hangs cannot keep the others waiting for long.
//! A login inside a login (the token read made inside the link's ssh dial) shares its slot.
//!
//! A tunnel that has logged in stays open while its link lives: the bound is on logins, the
//! moment ssh costs the most (key exchange, ProxyCommand children, a resumed VM), not on the
//! links themselves.

use crate::peer_dial_gate::DialGate;
use std::future::Future;
use std::sync::OnceLock;
use std::time::Duration;

/// ssh logins in flight at once on this host.
pub const LOGINS: usize = 8;
/// The longest one login holds its slot: past ssh's slow ConnectTimeout (20 s), so the bound
/// holds for a loaded host's logins too.
pub const LOGIN_HOLD: Duration = Duration::from_secs(25);

/// The daemon's login gate.
pub fn global() -> &'static DialGate {
    static GATE: OnceLock<DialGate> = OnceLock::new();
    GATE.get_or_init(|| DialGate::new(LOGINS, Duration::ZERO, LOGIN_HOLD))
}

tokio::task_local! {
    /// Set while a task's login holds (or held) its slot: a login nested in it shares that slot.
    static IN_LOGIN: ();
}

/// Run `login` (a step that spawns ssh to a peer and waits for it to log in) through the
/// daemon's gate ([`global`]).
pub async fn login<F: Future>(wanted: bool, login: F) -> F::Output {
    login_through(global(), wanted, login).await
}

/// [`login`] through `gate`.
pub async fn login_through<F: Future>(gate: &DialGate, wanted: bool, login: F) -> F::Output {
    if IN_LOGIN.try_with(|()| ()).is_ok() {
        return login.await;
    }
    gate.hold(wanted, IN_LOGIN.scope((), login)).await
}

impl crate::peer::Peer {
    /// Run one of this peer's ssh logins (its link's ssh dial, the token read inside it, a path
    /// probe's tunnel) through the daemon's gate, ahead of background ones while a client waits
    /// on the peer.
    pub(crate) async fn ssh_login<F: Future>(&self, login: F) -> F::Output {
        self::login(self.is_wanted(), login).await
    }
}

#[cfg(test)]
#[path = "peer_ssh_logins_tests.rs"]
mod tests;
