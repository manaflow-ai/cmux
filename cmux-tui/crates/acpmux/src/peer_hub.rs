//! A peer's hub path (`Via::Hub`, `hub_carrier.rs`): the daemon's one carrier dials the peer's
//! machine through the platform's relay, and the link speaks the same authenticated WebSocket
//! over the stream it returns, so `serve_heard`, its liveness and its `afterSeq` replay run
//! unchanged. It is one more of the peer's paths (`peer_carriers.rs`), in the relayed class
//! (`peer_paths.rs`): relay first, it is dialed at once beside the remembered path and carries
//! the link until a direct path proved itself on its probes.

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

    /// Whether this peer has a hub path: the daemon runs the carrier or may start it (joined,
    /// and the node key is not the cmux link's: `HubCarrierSlot::for_daemon`), and
    /// the peer names a hub `daemonId` or the running carrier has a route for it.
    pub(crate) fn has_hub_path(&self) -> bool {
        self.hub_carrier.get().is_some_and(|(slot, daemon)| {
            slot.expected()
                && (daemon.is_some()
                    || slot.get().is_some_and(|carrier| carrier.route(&self.name).is_some()))
        })
    }

    /// A raw stream to the peer's listener over the hub carrier. The far end bridges to its own
    /// loopback listener, as a WireGuard stream does.
    pub(crate) async fn hub_stream(&self) -> Result<crate::hub_carrier::HubStream, String> {
        let (slot, daemon) = self.hub_carrier.get().ok_or_else(|| "no hub route".to_owned())?;
        let carrier = slot.get().ok_or_else(|| "the hub carrier is off".to_owned())?;
        let daemon = daemon
            .clone()
            .or_else(|| carrier.route(&self.name))
            .ok_or_else(|| "no hub route".to_owned())?;
        carrier.dial(&daemon).await
    }

    /// This peer's link over the hub carrier ended after `silent` with no byte in: the carrier
    /// closes the kept circuit it rode if that circuit heard nothing either
    /// (`HubCarrier::close_kept_silent_for`), so the redial does not wait on a dead one.
    pub(crate) async fn hub_link_ended_silent(&self, silent: std::time::Duration) {
        let Some((slot, daemon)) = self.hub_carrier.get() else { return };
        let Some(carrier) = slot.get() else { return };
        let Some(daemon) = daemon.clone().or_else(|| carrier.route(&self.name)) else { return };
        carrier.close_kept_silent_for(&daemon, silent).await;
    }
}
