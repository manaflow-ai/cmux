//! `shutdown-daemon` with `if_idle` (`cmux daemon stop --if-idle`, the Rex
//! docs' `server stop --if-idle`): stop only while no other client is
//! connected and no terminal is live. [`check`] runs while the requester
//! holds the handoff reservation, which refuses every new control client
//! (`begin_daemon_handoff`), so no client can connect and start work
//! between the check and the stop. A refusal is [`DaemonBusy`]
//! (`error_code` `daemon_busy`, the users in `error_details`); the caller
//! releases the reservation and the daemon keeps serving.

use std::fmt;
use std::sync::Arc;

use serde_json::{Value, json};

use crate::Mux;
use crate::workspace_registry::TerminalLifecycle;

pub(super) const DAEMON_BUSY_CODE: &str = "daemon_busy";

/// A client other than the one that asked for the stop.
#[derive(Debug)]
pub(super) struct BusyClient {
    pub(super) client: u64,
    pub(super) name: Option<String>,
    pub(super) kind: Option<String>,
}

/// What keeps the daemon from being idle.
#[derive(Debug)]
pub(super) struct DaemonBusy {
    pub(super) clients: Vec<BusyClient>,
    pub(super) terminals: usize,
    /// Of `terminals`, those whose last tab closed: each ends after the reap
    /// grace unless a tab shows it again (Reopen Closed) or it is kept.
    pub(super) closed_tabs: usize,
}

impl fmt::Display for DaemonBusy {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let mut uses = Vec::new();
        if self.terminals > 0 {
            let s = if self.terminals == 1 { "" } else { "s" };
            uses.push(match self.closed_tabs {
                0 => format!("{} live terminal{s}", self.terminals),
                n if n == self.terminals => format!(
                    "{} live terminal{s} of closed tabs, which end after the reap grace unless reopened; run the stop again then",
                    self.terminals
                ),
                n => format!(
                    "{} live terminal{s}, {n} of them of closed tabs, which end after the reap grace unless reopened",
                    self.terminals
                ),
            });
        }
        if !self.clients.is_empty() {
            let names: Vec<String> = self
                .clients
                .iter()
                .map(|c| match (&c.name, &c.kind) {
                    (Some(name), Some(kind)) => format!("{name} ({kind})"),
                    (Some(name), None) => name.clone(),
                    (None, Some(kind)) => kind.clone(),
                    (None, None) => format!("client {}", c.client),
                })
                .collect();
            let s = if self.clients.len() == 1 { "" } else { "s" };
            uses.push(format!(
                "{} other client{s} connected: {}",
                self.clients.len(),
                names.join(", ")
            ));
        }
        write!(f, "the daemon is in use ({}); it keeps running", uses.join("; "))
    }
}

impl std::error::Error for DaemonBusy {}

/// `Err` ([`DaemonBusy`]) with what uses the daemon, unless no other client
/// is connected and no terminal is launching, adopting or running. A
/// terminal registry the daemon cannot read is no proof of idleness: that
/// refuses too. When idle, it raises the registry's idle-stop fence under the
/// same lock it read the terminals with, so no terminal can become live
/// before the stop: any write that would make one live later is refused
/// (`WorkspaceRegistry::set_idle_stop_fence`), and one that committed
/// earlier was counted. Releasing the reservation (a cancel, the
/// requester's disconnect) lowers it (`Mux::settle_idle_stop_fence`).
pub(super) fn check(mux: &Arc<Mux>, requester: u64) -> anyhow::Result<()> {
    let clients = mux.control_clients.other_clients(requester);
    // Only for what a refusal says: read before the registry lock (the
    // state lock is never taken under it here).
    let (unplaced, _) = mux.unplaced_and_placed_terminals();
    let mut registry =
        mux.workspace_registry.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    let snapshot = registry.terminal_snapshot().map_err(|error| {
        anyhow::anyhow!("cannot tell whether the daemon is idle, so it keeps running: {error}")
    })?;
    let live: Vec<&str> = snapshot
        .terminals
        .iter()
        .filter(|t| {
            matches!(
                t.lifecycle,
                TerminalLifecycle::Launching
                    | TerminalLifecycle::Adopting
                    | TerminalLifecycle::Running
            )
        })
        .map(|t| t.terminal_id.as_str())
        .collect();
    let terminals = live.len();
    if clients.is_empty() && terminals == 0 {
        // Raised only while this stop still holds its reservation, checked
        // under the registry lock `Mux::settle_idle_stop_fence` takes: a
        // reservation released before this (its client disconnected) raises
        // no fence; one released after it lowers the fence there.
        if !mux.control_clients.daemon_handoff_pending_for(requester) {
            anyhow::bail!(
                "the stop was cancelled while the daemon checked that it was idle, so it keeps running"
            );
        }
        // No fence, no stop: a terminal could start before it.
        return registry.set_idle_stop_fence(Some(requester)).map_err(|error| {
            anyhow::anyhow!(
                "cannot keep terminals from starting, so the daemon keeps running: {error}"
            )
        });
    }
    // Terminals that end on their own: unplaced, not kept, and a reaper
    // runs (a direct `--headless` owner without a reap grace has none).
    // Unknown keeps: none is said to end on its own.
    let closed_tabs = match (mux.terminal_reaper_running(), registry.kept_terminals()) {
        (true, Ok(kept)) => {
            live.iter().filter(|id| unplaced.contains(**id) && !kept.contains(**id)).count()
        }
        _ => 0,
    };
    Err(DaemonBusy { clients, terminals, closed_tabs }.into())
}

pub(super) fn error_code(error: &anyhow::Error) -> Option<String> {
    error.downcast_ref::<DaemonBusy>().map(|_| DAEMON_BUSY_CODE.to_owned())
}

pub(super) fn error_details(error: &anyhow::Error) -> Option<Value> {
    let busy = error.downcast_ref::<DaemonBusy>()?;
    let clients: Vec<Value> = busy
        .clients
        .iter()
        .map(|c| json!({"client": c.client, "name": c.name, "kind": c.kind}))
        .collect();
    Some(json!({"clients": clients, "terminals": busy.terminals, "closed_tabs": busy.closed_tabs}))
}
