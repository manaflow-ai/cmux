//! The overlay of a running link: one `cmux_wg::WgMesh` (one key, one UDP
//! socket, one WireGuard session per paired peer).

use std::collections::HashMap;
use std::io;
use std::net::{IpAddr, SocketAddr};
use std::sync::Mutex;

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
}

impl MeshOverlay {
    pub(super) fn new(mesh: WgMesh) -> Self {
        Self { mesh, peers: Mutex::new(HashMap::new()) }
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
}

impl OverlayListener for WgMeshListener {
    type Stream = WgStream;

    async fn accept(&mut self) -> Option<(WgStream, [u8; 32], SocketAddr)> {
        let (stream, key) = WgMeshListener::accept(self).await?;
        let address = stream.peer_addr();
        Some((stream, key, address))
    }
}
