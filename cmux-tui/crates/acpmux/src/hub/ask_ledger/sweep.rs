//! The never-drops sweep (RFD 0010, piece 4): an ask open past [`BOUND_MS`] with no
//! `routed`, `picked` or `answered` gets a `stalled` event, so the board shows it and "dropped"
//! is a number, not something an audit finds.
//!
//! Constant cost at any ledger size: open asks wait in a queue in the order they opened, and a
//! pass reads only its front. Each entry leaves the queue once (picked up, purged, or stalled),
//! and one pass looks at no more than [`PASS_MAX`] entries. A ledger nobody opted into is empty,
//! so its pass reads nothing and writes nothing.

use super::{AskLedger, Hub, Kind, Line, State, store};
use serde_json::{Value, json};
use std::sync::Arc;
use std::time::Duration;

/// How long an ask may sit open with no pickup before the sweep surfaces it.
pub(crate) const BOUND_MS: u64 = 2 * 60 * 60 * 1000;
/// How often the daemon sweeps.
const EVERY: Duration = Duration::from_secs(60);
/// Queue entries one pass looks at, at most: the rest wait for the next minute.
pub(super) const PASS_MAX: usize = 256;
/// The sweep, as an event's `by`.
const BY: &str = "ask-ledger-sweep";

impl State {
    /// The bound and how the sweep has done: shown with every page.
    pub(super) fn sweep_numbers(&self) -> Value {
        json!({
            "boundMs": BOUND_MS,
            "stalled": self.stalled,
            "pickedUpAfterStall": self.rescued,
        })
    }
}

impl AskLedger {
    /// One pass at `now`: records `stalled` for each ask open past `bound_ms` with no pickup,
    /// oldest first. Returns how many it recorded.
    pub(crate) fn sweep(&self, now: u64, bound_ms: u64) -> usize {
        let mut state = self.lock();
        let mut stalled = 0;
        for _ in 0..PASS_MAX {
            let Some((id, since)) = state.waiting.front().cloned() else { break };
            let open =
                state.asks.get(&id).is_some_and(|ask| ask.since == since && ask.status() == "open");
            if !open {
                // Picked up, answered, purged, or reopened later (a newer entry waits for it).
                state.waiting.pop_front();
                continue;
            }
            let after_ms = now.saturating_sub(since);
            if after_ms < bound_ms {
                // The queue is in opening order: everything behind it opened later still.
                break;
            }
            state.waiting.pop_front();
            let Some(sid) = state.asks.get(&id).map(|ask| ask.sid.clone()) else { continue };
            let line = Line::Event {
                ask: id,
                sid,
                ts: now,
                by: BY.into(),
                kind: Kind::Stalled { after_ms },
            };
            state.apply(line.clone());
            self.send(store::Work::Line(Box::new(line)));
            stalled += 1;
        }
        stalled
    }
}

impl Hub {
    /// Every minute from now, surfaces asks with no pickup past the bound.
    pub(crate) fn sweep_stalled_asks(self: &Arc<Self>) {
        let hub = Arc::downgrade(self);
        self.scope.spawn_until_cancelled("ask-ledger-sweep", async move {
            let mut every = tokio::time::interval(EVERY);
            every.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
            loop {
                every.tick().await;
                let Some(hub) = hub.upgrade() else { return };
                let stalled = hub.ask_ledger.sweep(crate::store::now_ms(), BOUND_MS);
                if stalled > 0 {
                    tracing::info!(stalled, "asks with no pickup past the bound surfaced");
                }
            }
        });
    }
}
