//! The overlay of a running link: one `cmux_wg::WgMesh` (one key, one UDP
//! socket, one WireGuard session per paired peer).

use std::collections::HashMap;
use std::io;
use std::net::{IpAddr, SocketAddr};
use std::sync::Mutex;

use cmux_link::connect_info::ConnectInfo;
use cmux_link::dial::PathState;
use cmux_link::pairing::Pairings;
use cmux_wg::{IpNetwork, PeerRoute, WgMesh, WgMeshListener, WgPeer, WgStream};

use super::control::OverlayListener;
use super::dial::Overlay;

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
    cloud: Mutex<HashMap<String, ([u8; 32], PeerShape)>>,
}

impl MeshOverlay {
    pub(super) fn new(mesh: WgMesh) -> Self {
        Self { mesh, peers: Mutex::new(HashMap::new()), cloud: Mutex::new(HashMap::new()) }
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
        let current = self.peers.lock().unwrap().clone();
        for (key, shape) in &current {
            if wanted.get(key) != Some(shape) {
                self.mesh.remove_peer(*key).await.map_err(io::Error::other)?;
                self.peers.lock().unwrap().remove(key);
            }
        }
        for (key, shape) in wanted {
            if self.peers.lock().unwrap().get(&key) == Some(&shape) {
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
            self.peers.lock().unwrap().insert(key, shape);
        }
        Ok(())
    }

    async fn set_cloud_peer(
        &self,
        host: &str,
        key: [u8; 32],
        info: &ConnectInfo,
    ) -> io::Result<()> {
        let shape = cloud_shape(info)?;
        let previous = self.cloud.lock().unwrap().get(host).cloned();
        if previous.as_ref() == Some(&(key, shape.clone())) {
            return Ok(());
        }
        if let Some((old_key, _)) = previous {
            self.mesh.remove_peer(old_key).await.map_err(io::Error::other)?;
            self.cloud.lock().unwrap().remove(host);
        }
        let peer = WgPeer {
            public_key: key,
            preshared_key: None,
            allowed_ips: shape.0.clone(),
            endpoint: shape.1,
            persistent_keepalive: Some(KEEPALIVE_SECONDS),
        };
        self.mesh.add_peer(peer).await.map_err(io::Error::other)?;
        self.cloud.lock().unwrap().insert(host.to_string(), (key, shape));
        Ok(())
    }

    async fn forget_cloud_peer(&self, host: &str) -> io::Result<()> {
        let removed = self.cloud.lock().unwrap().remove(host);
        if let Some((key, _)) = removed {
            self.mesh.remove_peer(key).await.map_err(io::Error::other)?;
        }
        Ok(())
    }

    async fn path_state(&self, key: &[u8; 32]) -> PathState {
        let known = self.peers.lock().unwrap().contains_key(key)
            || self.cloud.lock().unwrap().values().any(|(cloud_key, _)| cloud_key == key);
        if known { PathState::Direct } else { PathState::Unreachable }
    }
}

/// The mesh shape of a Cloud VM endpoint: its overlay `/128`, reached on its
/// public IPv6 when it has one, else on its VPC endpoint (a VPC member's
/// direct path). The tunnel route comes with the gateway support.
fn cloud_shape(info: &ConnectInfo) -> io::Result<PeerShape> {
    let network =
        IpNetwork::new(IpAddr::V6(info.peer.overlay_address), 128).map_err(io::Error::other)?;
    let endpoint = info
        .peer
        .public_ipv6
        .map(|address| SocketAddr::new(IpAddr::V6(address), CLOUD_UDP_PORT))
        .or(info.peer.vpc_endpoint);
    Ok((vec![network], endpoint))
}

/// The outer WireGuard port of Cloud VM endpoints (transport.md 3.1).
const CLOUD_UDP_PORT: u16 = 4101;

impl OverlayListener for WgMeshListener {
    type Stream = WgStream;

    async fn accept(&mut self) -> Option<(WgStream, [u8; 32], SocketAddr)> {
        let (stream, key) = WgMeshListener::accept(self).await?;
        let address = stream.peer_addr();
        Some((stream, key, address))
    }
}
