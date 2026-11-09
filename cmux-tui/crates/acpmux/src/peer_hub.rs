//! A peer's hub path (`Via::Hub`, `hub_carrier.rs`): the daemon's one carrier dials the peer's
//! machine through the platform's relay, and the link speaks the same authenticated WebSocket
//! over the stream it returns, so `serve_heard`, its liveness and its `afterSeq` replay run
//! unchanged. It is one more of the peer's paths (`peer_carriers.rs`), in the relayed class
//! (`peer_paths.rs`): dialed last, and carrying the link only while no other path answers.

use super::*;

impl Peer {
    /// Use the daemon's hub carrier (once it starts) for this peer, at `daemon`, the hub
    /// `daemonId` its config names; without one, a route the carrier was given by name.
    pub(crate) fn set_hub_carrier(
        &self,
        slot: crate::hub_carrier::HubCarrierSlot,
        daemon: Option<String>,
    ) {
        let _ = self.hub_carrier.set((slot, daemon));
    }

    /// Whether this peer has a hub path: a configured `daemonId`, or a route the running
    /// carrier was given by name.
    pub(crate) fn has_hub_path(&self) -> bool {
        self.hub_carrier.get().is_some_and(|(slot, daemon)| {
            daemon.is_some()
                || slot.get().is_some_and(|carrier| carrier.route(&self.name).is_some())
        })
    }

    /// A raw stream to the peer's listener over the hub carrier. The far end bridges to its own
    /// loopback listener, as a WireGuard stream does.
    pub(crate) async fn hub_stream(&self) -> Result<crate::hub_carrier::HubStream, String> {
        let (slot, daemon) = self.hub_carrier.get().ok_or_else(|| "no hub route".to_owned())?;
        let carrier = slot.get().ok_or_else(|| "the hub carrier is off".to_owned())?.clone();
        let daemon = daemon
            .clone()
            .or_else(|| carrier.route(&self.name))
            .ok_or_else(|| "no hub route".to_owned())?;
        carrier.dial(&daemon).await
    }
}
