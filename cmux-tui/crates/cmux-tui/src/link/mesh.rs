//! The overlay of a running link: one `cmux_wg::WgMesh` (one key, one UDP
//! socket, one WireGuard session per paired peer).

use std::collections::HashSet;
use std::io;
use std::net::{IpAddr, SocketAddr};
use std::sync::Mutex;

use cmux_link::pairing::Pairings;
use cmux_wg::{IpNetwork, WgMesh, WgMeshListener, WgPeer, WgStream};

use super::control::OverlayListener;
use super::dial::Overlay;

/// Keepalives hold NAT mappings open on direct paths.
const KEEPALIVE_SECONDS: u16 = 25;

pub(super) struct MeshOverlay {
    mesh: WgMesh,
    peers: Mutex<HashSet<[u8; 32]>>,
}

impl MeshOverlay {
    pub(super) fn new(mesh: WgMesh) -> Self {
        Self { mesh, peers: Mutex::new(HashSet::new()) }
    }

    pub(super) async fn listen(&self, port: u16) -> io::Result<WgMeshListener> {
        self.mesh.listen(port).await.map_err(io::Error::other)
    }

    pub(super) fn local_addr(&self) -> io::Result<SocketAddr> {
        self.mesh.local_addr()
    }
}

impl Overlay for MeshOverlay {
    type Stream = WgStream;

    async fn connect(&self, remote: SocketAddr) -> io::Result<WgStream> {
        self.mesh.connect(remote).await.map_err(io::Error::other)
    }

    async fn sync_peers(&self, pairings: &Pairings) -> io::Result<()> {
        let mut wanted = HashSet::new();
        for record in &pairings.peers {
            let Some(public_key) = record.key() else { continue };
            let network = IpNetwork::new(IpAddr::V6(record.overlay_address()), 128)
                .map_err(io::Error::other)?;
            let peer = WgPeer {
                public_key,
                preshared_key: None,
                allowed_ips: vec![network],
                endpoint: record.endpoint,
                persistent_keepalive: Some(KEEPALIVE_SECONDS),
            };
            self.mesh.add_peer(peer).await.map_err(io::Error::other)?;
            wanted.insert(public_key);
        }
        let stale: Vec<[u8; 32]> =
            self.peers.lock().unwrap().difference(&wanted).copied().collect();
        for key in stale {
            self.mesh.remove_peer(key).await.map_err(io::Error::other)?;
        }
        *self.peers.lock().unwrap() = wanted;
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
