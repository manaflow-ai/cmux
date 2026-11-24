//! A peer link's serving end of the v2 list stream (`link_v2.rs`): the one connection a
//! `hello` starts on the link, served with [`Role::Peer`]. Moved from `link_v2.rs`
//! (`link_v2::Link`): it runs the connection on the hub, which that lower module does not reach.

use std::sync::Arc;
use std::sync::atomic::Ordering;

use acpmux_core::conn::{HubSource, Role};

use crate::hub::Hub;
use crate::link_v2::{Adapter, Counters, Slot, parse};

/// A link's serving end: its one connection, started by a `hello`.
pub struct Link {
    hub: Arc<Hub>,
    v2: Arc<acpmux_core::life::V2>,
    slot: Arc<Slot>,
    running: Option<(Adapter, tokio::task::JoinHandle<Option<()>>)>,
}

impl Link {
    /// The serving end of a link whose writer drains `slot`, when links serve the stream.
    /// The slot this link's connection writes to.
    pub fn slot(&self) -> Arc<Slot> {
        self.slot.clone()
    }

    pub fn serving(hub: &Arc<Hub>, slot: Arc<Slot>) -> Option<Self> {
        let v2 = hub.link_v2.v2()?.clone();
        Some(Self { hub: hub.clone(), v2, slot, running: None })
    }

    fn counters(&self) -> &Counters {
        &self.hub.link_v2.counters
    }

    /// One frame line from the peer. Waits, when a connection runs, until it has read the
    /// frame before; any wait ends when the connection does.
    pub async fn take(&mut self, line: &str) {
        let Some(frame) = parse(line) else {
            self.counters().drop_one();
            return;
        };
        // Its reader gone, a link starts no connection and hands it nothing.
        if self.slot.is_reader_ended() {
            self.end();
            self.counters().drop_one();
            return;
        }
        let running = self.running.as_ref().is_some_and(|(adapter, _)| !adapter.closed());
        if frame.is_hello() {
            if running {
                self.counters().second_hello.fetch_add(1, Ordering::Relaxed);
            }
            self.end();
            self.start();
        } else if !running {
            self.counters().drop_one();
            return;
        }
        let Some((adapter, _)) = &self.running else { return };
        if !adapter.deliver(&frame).await {
            self.counters().drop_one();
        }
    }

    fn start(&mut self) {
        let (adapter, reader, writer) = Adapter::new(self.slot.clone());
        let source = Arc::new(HubSource::for_peer(self.v2.hub()));
        let daemon_id = self.hub.run_id();
        let inbound = adapter.inbound.clone();
        // It ends when its stream does (`end`), or with the daemon.
        let task = self.hub.scope.spawn_until_cancelled("v2 peer link connection", async move {
            // The role is this link's, fixed here: nothing a frame says changes it.
            let surfaces = ["list".to_owned()];
            let result =
                acpmux_core::conn::run(reader, writer, source, daemon_id, &surfaces, Role::Peer)
                    .await;
            if let Err(error) = result {
                tracing::debug!(%error, "a v2 connection on a peer link ended");
            }
            inbound.close();
        });
        self.running = Some((adapter, task));
    }

    /// The link's connection ends: its reader reads the end of the stream, and its writer's
    /// next write fails. A connection that stopped reading (its requests wait on a write) still
    /// sees the end at the write, so its task returns and its subscriptions are cleaned up.
    pub fn end(&mut self) {
        if let Some((adapter, _task)) = self.running.take() {
            adapter.close();
            adapter.slot.retire();
        }
    }
}

impl Drop for Link {
    fn drop(&mut self) {
        self.end();
    }
}
