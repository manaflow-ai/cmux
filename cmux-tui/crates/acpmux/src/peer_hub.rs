//! A peer reached through the hub carrier (`hub_carrier.rs`): the daemon's one carrier dials the
//! peer's machine through the platform's relay, and this link speaks the same authenticated
//! WebSocket over the stream it returns, so `serve_heard`, its liveness and its `afterSeq` replay
//! run unchanged. `connect_once` asks here after WireGuard and before ssh or the configured URL;
//! a dial that fails falls through to them.

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

    /// The carrier and the daemon id to dial, when both are known.
    fn hub_route(&self) -> Option<(Arc<crate::hub_carrier::HubCarrier>, String)> {
        let (slot, daemon) = self.hub_carrier.get()?;
        let carrier = slot.get()?.clone();
        let daemon = daemon.clone().or_else(|| carrier.route(&self.name))?;
        Some((carrier, daemon))
    }

    /// One attempt over the hub carrier: None when there is no route or the stream or its
    /// WebSocket upgrade did not open in `timings.connect`, else how the link ended.
    pub(super) async fn connect_hub(
        self: &Arc<Self>,
        token: &str,
        peer_token: Option<&str>,
        out_rx: &mut mpsc::Receiver<Outbound>,
    ) -> Option<Result<LinkEnd, String>> {
        let (carrier, daemon) = self.hub_route()?;
        // The far end bridges to its own loopback listener, as a WireGuard stream does.
        let req = match self.ws_request("ws://localhost/", Some(token), peer_token) {
            Ok(req) => req,
            Err(e) => return Some(Err(e)),
        };
        let heard = crate::peer_link::Heard::default();
        let opening = async {
            let stream = carrier.dial(&daemon).await?;
            tokio_tungstenite::client_async_with_config(
                req,
                heard.wrap(stream),
                Some(crate::server::ws_config()),
            )
            .await
            .map_err(|e| e.to_string())
        };
        let opened = tokio::select! {
            biased;
            _ = self.stop_signal.notified() => return Some(Err("peer stopped".to_owned())),
            result = tokio::time::timeout(self.timings.connect, opening) => result,
        };
        match opened {
            Ok(Ok((ws, _))) => {
                *self.presented.lock().unwrap_or_else(|e| e.into_inner()) =
                    peer_token.map(str::to_owned);
                tracing::info!(peer = %self.name, "connected over the hub carrier");
                Some(self.serve_heard(ws, out_rx, Some(heard)).await)
            }
            Ok(Err(e)) => {
                tracing::debug!(peer = %self.name, "hub carrier unavailable: {e}");
                None
            }
            Err(_) => {
                tracing::debug!(peer = %self.name, "hub carrier timed out");
                None
            }
        }
    }
}
