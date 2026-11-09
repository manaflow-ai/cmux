//! The overlay of a running link: one `cmux_wg::WgMesh` (one key, one UDP
//! socket, one WireGuard session per paired peer). After the link adopted the
//! node key, the peers not told yet stay on the retired key
//! (`key_adoption.rs`).

use std::collections::{BTreeSet, HashMap};
use std::io;
use std::net::{IpAddr, SocketAddr};
use std::sync::Mutex;

use cmux_link::pairing::Pairings;
use cmux_wg::{IpNetwork, PeerRoute, WgMesh, WgMeshListener, WgPeer, WgStream};

use super::control::OverlayListener;
use super::dial::Overlay;
use super::locked;

/// Keepalives hold NAT mappings open on direct paths.
const KEEPALIVE_SECONDS: u16 = 25;

/// What the mesh was given for one peer, to skip unchanged peers on reload:
/// its networks, its endpoint and whether it is on the retired key.
type PeerShape = (Vec<IpNetwork>, Option<SocketAddr>, bool);

pub(super) struct MeshOverlay {
    mesh: WgMesh,
    /// The peers the mesh holds now, updated after each step so a failed
    /// sync never forgets a peer it added.
    peers: Mutex<HashMap<[u8; 32], PeerShape>>,
    /// The installs whose session stays on the retired key (a mesh started
    /// with `WgMesh::start_retiring`).
    retiring: Mutex<BTreeSet<String>>,
}

impl MeshOverlay {
    pub(super) fn new(mesh: WgMesh) -> Self {
        Self { mesh, peers: Mutex::new(HashMap::new()), retiring: Mutex::new(BTreeSet::new()) }
    }

    /// The installs kept on the retired key from the next sync on.
    pub(super) fn set_retiring(&self, installs: BTreeSet<String>) {
        *locked(&self.retiring) = installs;
    }

    pub(super) async fn listen(&self, port: u16) -> io::Result<WgMeshListener> {
        self.mesh.listen(port).await.map_err(io::Error::other)
    }

    pub(super) fn local_addr(&self) -> io::Result<SocketAddr> {
        self.mesh.local_addr()
    }

    /// Stop the mesh and release its UDP socket before returning.
    pub(super) async fn shutdown(self) {
        self.mesh.shutdown().await;
    }
}

/// The mesh shape of every paired peer.
fn wanted(
    pairings: &Pairings,
    retiring: &BTreeSet<String>,
) -> io::Result<HashMap<[u8; 32], PeerShape>> {
    let mut wanted = HashMap::new();
    for record in &pairings.peers {
        let Some(public_key) = record.key() else { continue };
        let network =
            IpNetwork::new(IpAddr::V6(record.overlay_address()), 128).map_err(io::Error::other)?;
        let retired = retiring.contains(&record.install);
        wanted.insert(public_key, (vec![network], record.endpoint, retired));
    }
    Ok(wanted)
}

impl Overlay for MeshOverlay {
    type Stream = WgStream;

    async fn connect(&self, remote: SocketAddr) -> io::Result<WgStream> {
        self.mesh.connect(remote).await.map_err(io::Error::other)
    }

    /// Remove stale keys and changed address ranges first (a rotated key
    /// keeps its install's `/128`, which would overlap). Replace endpoint-only
    /// changes in place so the stack preserves the same peer's streams.
    async fn sync_peers(&self, pairings: &Pairings) -> io::Result<()> {
        let retiring = locked(&self.retiring).clone();
        let wanted = wanted(pairings, &retiring)?;
        let current = locked(&self.peers).clone();
        for (key, shape) in &current {
            if wanted.get(key).is_none_or(|next| next.0 != shape.0) {
                self.mesh.remove_peer(*key).await.map_err(io::Error::other)?;
                locked(&self.peers).remove(key);
            }
        }
        for (key, shape) in wanted {
            if locked(&self.peers).get(&key) == Some(&shape) {
                continue;
            }
            let peer = WgPeer {
                public_key: key,
                preshared_key: None,
                allowed_ips: shape.0.clone(),
                route: shape.1.map(PeerRoute::from),
                persistent_keepalive: Some(KEEPALIVE_SECONDS),
            };
            let added = if shape.2 {
                self.mesh.add_peer_on_retired_key(peer).await
            } else {
                self.mesh.add_peer(peer).await
            };
            added.map_err(io::Error::other)?;
            locked(&self.peers).insert(key, shape);
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
