//! Gateway datagrams and gateway removal (an `impl` block of
//! [`super::MeshDriver`]).

use super::{MeshDriver, RECEIVE_BATCH};
use crate::mesh_gateway::GatewayDatagram;
use crate::mesh_route::{GatewayId, PeerRoute};

impl MeshDriver {
    /// Handle `first` and the gateway datagrams already waiting, up to a
    /// batch, exactly like UDP datagrams: the source route is the gateway and
    /// the address the datagram came from inside its tunnel. A datagram from
    /// a gateway removed since it was queued is dropped.
    pub(super) fn receive_gateways(&mut self, first: Option<GatewayDatagram>) {
        let mut next = first;
        for _ in 0..RECEIVE_BATCH {
            let Some((gateway, datagram, address)) = next else { return };
            if self.out.has_gateway(gateway) {
                let source = PeerRoute::Gateway { gateway, address };
                self.handle_datagram(&datagram, Some(source));
            }
            next = self.gateway_inbox.try_recv().ok();
        }
    }

    /// Detach `gateway`. Peers whose route used it have no route until their
    /// next authenticated datagram arrives on a route that exists.
    pub(super) fn remove_gateway(&mut self, gateway: GatewayId) -> bool {
        if !self.out.detach(gateway) {
            return false;
        }
        for peer in self.table.peers_mut() {
            if matches!(peer.route, Some(PeerRoute::Gateway { gateway: used, .. }) if used == gateway)
            {
                peer.route = None;
            }
        }
        true
    }
}
