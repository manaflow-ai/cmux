//! Wait edges (RFD 0182 S8, B9): which sessions are in an `_acpmux/wait` on which now, so a
//! session waited on runs at its waiters' class (`class.rs`). A coordinator blocked on a lane
//! keeps that lane from being put to sleep early when the pool sheds (`pool_pressure.rs`),
//! and a lane started while it is waited on asks the gateway at the coordinator's class
//! (`lifecycle.rs` `cold_start`), until the wait ends.
//!
//! An edge lives exactly as long as the wait request: [`WaitEdge`] removes it when the wait
//! answers, times out or its caller leaves. Only a caller that proved its session
//! (`Conn::caller`) and named its targets adds one, as `lane_report_wait` does; a wait on
//! everything in flight inherits nothing, or one coordinator would raise every lane.
//! `ACPMUX_WAIT_INHERIT=0` turns inheritance off.

use std::collections::HashMap;
use std::sync::{Arc, Mutex as StdMutex, Weak};

use super::{Hub, Session};
use crate::class::Class;

/// Off when `0`, `false` or `off`.
pub const ENV: &str = "ACPMUX_WAIT_INHERIT";

fn enabled() -> bool {
    static ON: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *ON.get_or_init(|| {
        !std::env::var(ENV)
            .is_ok_and(|v| matches!(v.trim().to_ascii_lowercase().as_str(), "0" | "false" | "off"))
    })
}

/// Waiters of each session: target id to waiter id to open waits.
#[derive(Default)]
pub(crate) struct WaitEdges {
    by_target: StdMutex<HashMap<String, HashMap<String, usize>>>,
}

/// One wait's edges, removed when it drops.
pub(crate) struct WaitEdge {
    hub: Weak<Hub>,
    edges: Vec<(String, String)>,
}

impl Drop for WaitEdge {
    fn drop(&mut self) {
        if self.edges.is_empty() {
            return;
        }
        let Some(hub) = self.hub.upgrade() else { return };
        let mut by = hub.wait_edges.by_target.lock().unwrap_or_else(|e| e.into_inner());
        for (target, waiter) in &self.edges {
            let Some(waiters) = by.get_mut(target) else { continue };
            if let Some(n) = waiters.get_mut(waiter) {
                *n = n.saturating_sub(1);
                if *n == 0 {
                    waiters.remove(waiter);
                }
            }
            if waiters.is_empty() {
                by.remove(target);
            }
        }
    }
}

impl Hub {
    /// Record that `caller` waits on `ids` until the returned guard drops.
    pub(crate) fn wait_edge(self: &Arc<Self>, caller: Option<&str>, ids: &[String]) -> WaitEdge {
        let mut guard = WaitEdge { hub: Arc::downgrade(self), edges: Vec::new() };
        let Some(caller) = caller.filter(|_| enabled()) else { return guard };
        let mut by = self.wait_edges.by_target.lock().unwrap_or_else(|e| e.into_inner());
        for id in ids {
            if id == caller || guard.edges.iter().any(|(t, _)| t == id) {
                continue;
            }
            *by.entry(id.clone()).or_default().entry(caller.to_owned()).or_default() += 1;
            guard.edges.push((id.clone(), caller.to_owned()));
        }
        guard
    }

    /// The sessions waiting on `id` now.
    pub(crate) fn waiters_of(&self, id: &str) -> Vec<String> {
        let by = self.wait_edges.by_target.lock().unwrap_or_else(|e| e.into_inner());
        by.get(id).map(|w| w.keys().cloned().collect()).unwrap_or_default()
    }

    /// A session's own class, as its next start would send it.
    fn own_class(&self, session: &Session) -> Option<Class> {
        let meta = session.meta();
        // fleet-only-ok: the existing priority module's own value; it is sent only through a gateway (`via_gateway`), so a person's own login sends nothing
        Class::parse(self.subrouter_priority(session, &meta, self.for_a_person(session)))
    }

    /// `own`, the priority `session` would carry by itself, raised to its waiters' class
    /// (`class::inherited`). Costs one lock read when nobody waits on it.
    pub(super) fn inherit_priority(&self, session: &Session, own: &'static str) -> &'static str {
        if self.waiters_of(&session.id).is_empty() {
            return own;
        }
        let mine = Class::parse(own);
        let class = crate::class::inherited(
            &session.id,
            |id| {
                if id == session.id {
                    mine
                } else {
                    self.resolve(id).ok().and_then(|s| self.own_class(&s))
                }
            },
            |id| self.waiters_of(id),
        );
        match class {
            Some(c) if Some(c) > mine => {
                tracing::debug!(session = %session.id, own, inherited = c.wire(), "wait inheritance");
                c.wire()
            }
            _ => own,
        }
    }
}

#[cfg(test)]
#[path = "wait_edges_tests.rs"]
mod tests;
