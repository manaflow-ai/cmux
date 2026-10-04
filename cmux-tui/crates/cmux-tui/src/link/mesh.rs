//! The overlay of a running link: one `cmux_wg::WgMesh` (one key, one UDP
//! socket, one WireGuard session per paired peer or Cloud VM endpoint, and
//! this install's Freestyle tunnels as gateways).

use std::collections::HashMap;
use std::io;
use std::net::{IpAddr, SocketAddr};
use std::sync::Mutex;

use cmux_link::connect_info::{ConnectInfo, Gateway};
use cmux_link::dial::PathState;
use cmux_link::pairing::Pairings;
use cmux_wg::{GatewayId, IpNetwork, PeerRoute, WgMesh, WgMeshListener, WgNet, WgPeer, WgStream};
use zeroize::Zeroizing;

use super::control::OverlayListener;
use super::dial::Overlay;
use super::mesh_cloud::{CloudRoute, choose_route, cloud_networks, start_gateway};

/// Keepalives hold NAT mappings open on direct paths.
const KEEPALIVE_SECONDS: u16 = 25;

/// What the mesh was given for one peer, to skip unchanged peers on reload.
type PeerShape = (Vec<IpNetwork>, Option<SocketAddr>);

pub(super) struct MeshOverlay {
    mesh: WgMesh,
    /// The peers the mesh holds now, updated after each step so a failed
    /// sync never forgets a peer it added.
    peers: Mutex<HashMap<[u8; 32], PeerShape>>,
    /// Cloud VM endpoints by host id (connect_info), apart from the paired
    /// peers so a pairing reload never removes them.
    cloud: Mutex<HashMap<String, ([u8; 32], CloudShape)>>,
    /// This install's Freestyle tunnels, attached as gateways.
    gateways: Mutex<HashMap<Gateway, (GatewayId, WgNet)>>,
    /// Serializes Cloud peer changes (dials and events).
    cloud_ops: tokio::sync::Mutex<()>,
    /// The link's WireGuard key, for its own tunnels.
    private_key: Zeroizing<[u8; 32]>,
}

/// What the mesh was given for one Cloud peer.
type CloudShape = (Vec<IpNetwork>, Option<PeerRoute>);

impl MeshOverlay {
    pub(super) fn new(mesh: WgMesh, private_key: Zeroizing<[u8; 32]>) -> Self {
        Self {
            mesh,
            peers: Mutex::new(HashMap::new()),
            cloud: Mutex::new(HashMap::new()),
            gateways: Mutex::new(HashMap::new()),
            cloud_ops: tokio::sync::Mutex::new(()),
            private_key,
        }
    }

    pub(super) async fn listen(&self, port: u16) -> io::Result<WgMeshListener> {
        self.mesh.listen(port).await.map_err(io::Error::other)
    }

    pub(super) fn local_addr(&self) -> io::Result<SocketAddr> {
        self.mesh.local_addr()
    }
}

/// The mesh shape of every paired peer.
fn wanted(pairings: &Pairings) -> io::Result<HashMap<[u8; 32], PeerShape>> {
    let mut wanted = HashMap::new();
    for record in &pairings.peers {
        let Some(public_key) = record.key() else { continue };
        let network =
            IpNetwork::new(IpAddr::V6(record.overlay_address()), 128).map_err(io::Error::other)?;
        wanted.insert(public_key, (vec![network], record.endpoint));
    }
    Ok(wanted)
}

impl Overlay for MeshOverlay {
    type Stream = WgStream;

    async fn connect(&self, remote: SocketAddr) -> io::Result<WgStream> {
        self.mesh.connect(remote).await.map_err(io::Error::other)
    }

    /// Remove stale and changed peers first (a rotated key keeps its
    /// install's `/128`, which would overlap), then add new and changed
    /// ones. Unchanged peers keep their sessions.
    async fn sync_peers(&self, pairings: &Pairings) -> io::Result<()> {
        let wanted = wanted(pairings)?;
        let current = self.peers.lock().unwrap_or_else(std::sync::PoisonError::into_inner).clone();
        for (key, shape) in &current {
            if wanted.get(key) != Some(shape) {
                self.mesh.remove_peer(*key).await.map_err(io::Error::other)?;
                self.peers.lock().unwrap_or_else(std::sync::PoisonError::into_inner).remove(key);
            }
        }
        for (key, shape) in wanted {
            if self.peers.lock().unwrap_or_else(std::sync::PoisonError::into_inner).get(&key)
                == Some(&shape)
                || self.is_cloud_key(&key)
            {
                continue;
            }
            let peer = WgPeer {
                public_key: key,
                preshared_key: None,
                allowed_ips: shape.0.clone(),
                route: shape.1.map(PeerRoute::from),
                persistent_keepalive: Some(KEEPALIVE_SECONDS),
            };
            self.mesh.add_peer(peer).await.map_err(io::Error::other)?;
            self.peers.lock().unwrap_or_else(std::sync::PoisonError::into_inner).insert(key, shape);
        }
        Ok(())
    }

    async fn set_cloud_peer(
        &self,
        host: &str,
        key: [u8; 32],
        info: &ConnectInfo,
    ) -> io::Result<()> {
        // One change at a time, so two dials or a dial and an event never
        // interleave their remove and add steps.
        let _change = self.cloud_ops.lock().await;
        if self.peers.lock().unwrap_or_else(std::sync::PoisonError::into_inner).contains_key(&key) {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "a Cloud host names the key of a paired peer",
            ));
        }
        let route = match choose_route(info) {
            CloudRoute::Tunnel { gateway, vpc } => {
                Some(PeerRoute::Gateway { gateway: self.gateway(&gateway).await?, address: vpc })
            }
            CloudRoute::Udp(address) => Some(PeerRoute::Udp(address)),
            CloudRoute::None => {
                return Err(io::Error::new(io::ErrorKind::NotConnected, "no route to this host"));
            }
        };
        let shape = (cloud_networks(info)?, route);
        let previous =
            self.cloud.lock().unwrap_or_else(std::sync::PoisonError::into_inner).get(host).cloned();
        if previous.as_ref() == Some(&(key, shape.clone())) {
            return Ok(());
        }
        if let Some((old_key, _)) = previous {
            self.mesh.remove_peer(old_key).await.map_err(io::Error::other)?;
            self.cloud.lock().unwrap_or_else(std::sync::PoisonError::into_inner).remove(host);
        }
        let peer = WgPeer {
            public_key: key,
            preshared_key: None,
            allowed_ips: shape.0.clone(),
            route: shape.1,
            persistent_keepalive: Some(KEEPALIVE_SECONDS),
        };
        self.mesh.add_peer(peer).await.map_err(io::Error::other)?;
        self.cloud
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .insert(host.to_string(), (key, shape));
        self.drop_unused_gateways().await;
        Ok(())
    }

    async fn forget_cloud_peer(&self, host: &str) -> io::Result<()> {
        let _change = self.cloud_ops.lock().await;
        let removed =
            self.cloud.lock().unwrap_or_else(std::sync::PoisonError::into_inner).remove(host);
        if let Some((key, _)) = removed {
            self.mesh.remove_peer(key).await.map_err(io::Error::other)?;
        }
        self.drop_unused_gateways().await;
        Ok(())
    }

    async fn path_state(&self, key: &[u8; 32]) -> PathState {
        match self.mesh.peer_route(*key).await {
            Ok(Some(PeerRoute::Udp(_))) => PathState::Direct,
            Ok(Some(PeerRoute::Gateway { .. })) => PathState::Tunnel,
            _ => PathState::Unreachable,
        }
    }
}

impl MeshOverlay {
    fn is_cloud_key(&self, key: &[u8; 32]) -> bool {
        self.cloud
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .values()
            .any(|(cloud_key, _)| cloud_key == key)
    }

    /// The mesh gateway for this install's tunnel `gateway` (keyed by its
    /// full value, so a changed endpoint or server key starts a new tunnel).
    /// Called with `cloud_ops` held.
    async fn gateway(&self, gateway: &Gateway) -> io::Result<GatewayId> {
        if let Some((id, _)) =
            self.gateways.lock().unwrap_or_else(std::sync::PoisonError::into_inner).get(gateway)
        {
            return Ok(*id);
        }
        let started =
            tokio::time::timeout(GATEWAY_START_TIMEOUT, start_gateway(gateway, &self.private_key))
                .await
                .map_err(|_| {
                    io::Error::new(io::ErrorKind::TimedOut, "the tunnel did not start")
                })??;
        let (net, socket) = started;
        let id = self.mesh.add_gateway(socket).await.map_err(io::Error::other)?;
        self.gateways
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .insert(gateway.clone(), (id, net));
        Ok(id)
    }

    /// Detach and stop every tunnel that no Cloud peer routes through.
    /// Called with `cloud_ops` held.
    async fn drop_unused_gateways(&self) {
        let used: Vec<GatewayId> = self
            .cloud
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .values()
            .filter_map(|(_, (_, route))| match route {
                Some(PeerRoute::Gateway { gateway, .. }) => Some(*gateway),
                _ => None,
            })
            .collect();
        let unused: Vec<(Gateway, GatewayId)> = self
            .gateways
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .iter()
            .filter(|(_, (id, _))| !used.contains(id))
            .map(|(gateway, (id, _))| (gateway.clone(), *id))
            .collect();
        for (gateway, id) in unused {
            let _ = self.mesh.remove_gateway(id).await;
            let tunnel = self
                .gateways
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .remove(&gateway);
            if let Some((_, net)) = tunnel {
                net.shutdown().await;
            }
        }
    }
}

/// How long this install's tunnel may take to start (endpoint lookup,
/// socket); a dial then reports `unreachable`.
const GATEWAY_START_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(10);

impl OverlayListener for WgMeshListener {
    type Stream = WgStream;

    async fn accept(&mut self) -> Option<(WgStream, [u8; 32], SocketAddr)> {
        let (stream, key) = WgMeshListener::accept(self).await?;
        let address = stream.peer_addr();
        Some((stream, key, address))
    }
}
