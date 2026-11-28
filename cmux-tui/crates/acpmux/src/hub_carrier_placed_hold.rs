//! Holding this machine's slot on the placed relays (`hub_carrier_placed.rs`), leaving a full
//! one for the next nearest.

use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::Arc;

use cmux_remote::provider::RegistrationState;

use super::{CarrierAnswer, HubCarrier, placed, rehome};

impl HubCarrier {
    /// Keeps this machine's slot registered on the nearest of the placed `ranked` relays that
    /// takes it. A placed relay that answers busy (503, 429: its WebSocket limit) is left at
    /// once for the next nearest, and not asked again before its `Retry-After`; the one
    /// registration's own retries honour that word too (cmux-remote). With one placed relay it
    /// stays on it and waits. Dropping the guard unregisters.
    pub(super) fn hold_placed(
        self: Arc<Self>,
        websocket: SocketAddr,
        ranked: Vec<String>,
        answer: CarrierAnswer,
    ) -> AbortOnDrop {
        let task = placed::scope().spawn_named("hub carrier placed relay hold", async move {
            let mut full: HashMap<String, tokio::time::Instant> = HashMap::new();
            let mut at = 0_usize;
            loop {
                let relay = ranked[at % ranked.len()].clone();
                if let Some(until) = full.get(&relay).copied() {
                    tokio::time::sleep_until(until).await;
                }
                let Some(registration) = self.clone().register_placed(websocket, &relay, &answer)
                else {
                    // A relay this carrier would not dial: the next one, or nothing more.
                    if ranked.len() < 2 {
                        return;
                    }
                    at += 1;
                    continue;
                };
                let mut state = registration.state();
                loop {
                    let busy = match &*state.borrow_and_update() {
                        RegistrationState::RelayBusy { retry_after, .. } => Some(*retry_after),
                        _ => None,
                    };
                    if let Some(retry_after) = busy
                        && ranked.len() > 1
                    {
                        tracing::warn!(
                            "hub carrier: the placed relay is full; trying the next nearest"
                        );
                        full.insert(
                            relay.clone(),
                            tokio::time::Instant::now()
                                + rehome::busy_wait(retry_after, crate::peer_link::jitter()),
                        );
                        break;
                    }
                    if state.changed().await.is_err() {
                        return;
                    }
                }
                drop(registration);
                at += 1;
            }
        });
        AbortOnDrop(task)
    }
}

/// A task that ends when this drops.
pub(super) struct AbortOnDrop(tokio::task::JoinHandle<()>);

impl Drop for AbortOnDrop {
    fn drop(&mut self) {
        self.0.abort();
    }
}
