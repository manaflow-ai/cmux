//! The daemon's start, for the deterministic simulation (feature `sim`, `tests/sim/`): a hub
//! over a log a crashed daemon left reads it as `daemon.rs` does at start, so a simulated restart
//! runs the real restore (cut turns and their continuations, lost starts, the queue) instead of a
//! copy. The order is `daemon.rs`'s startup task, without the parts the simulation has no
//! counterpart for (agent hosts to adopt, workflows, the login environment and the catalog).

use super::Hub;
use std::sync::Arc;

impl Hub {
    /// The restore a daemon runs at start over the chats its store holds.
    pub async fn sim_startup(self: &Arc<Self>) {
        self.load_store_async().await;
        self.wait_store().await;
        self.load_live_logs_async().await;
        self.settle_unadopted().await;
        self.load_logs_async().await;
        self.resume_queues();
    }
}
