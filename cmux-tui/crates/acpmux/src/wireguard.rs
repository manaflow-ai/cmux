//! Labs-only WireGuard transport for acpmux's authenticated WebSocket streams.
//!
//! One boringtun/smoltcp mesh owns one UDP socket. Incoming streams can reach
//! only this daemon's loopback WebSocket listener, which still checks tokens,
//! peer proofs and policy. They never reach the privileged local socket.
//!
//! The transport runs only while it holds its key's lock (`cmux_link::key_holder`).
//! Which lock depends on the key the cmux link serves ([`key_lock_dir`]): when
//! the link serves this same node key, the machine's lock in the acpmux home,
//! and while the link holds it the transport steps down for the run (peers
//! with a link route dial through the link; the others go on over their URL or
//! ssh). Until the one-key migration the link serves a key of its own, so the
//! two never share a key: the transport locks only its own key and runs as
//! before, next to a serving link.

use std::collections::{BTreeMap, BTreeSet};
use std::net::{IpAddr, SocketAddr};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::{Context, Result, anyhow, ensure};
use base64::Engine;
use cmux_link::key_holder::{self, KeyFile, KeyHolder, KeyHolderError};
use cmux_wg::{
    InterfaceAddress, IpNetwork, PeerCandidate, WgMesh, WgMeshConfig, WgMeshListener, WgPeer,
    WgStream,
};
use serde::{Deserialize, Serialize};
use tokio::net::{TcpStream, UdpSocket};
use tokio::sync::{RwLock, watch};
use tokio::task::{JoinHandle, JoinSet};
use zeroize::Zeroizing;

const CONNECT_BOUND: Duration = Duration::from_secs(10);
const MAX_BRIDGES: usize = 64;

/// Static interface settings. `address` is virtual: it creates no system route.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct StaticConfig {
    pub listen: SocketAddr,
    pub address: SocketAddr,
}

/// A peer's key, UDP endpoint and virtual service address. No private material.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct StaticPeer {
    pub public_key: String,
    pub endpoint: String,
    pub address: SocketAddr,
}

/// The daemon owns this shared transport; peers borrow it across reconnects.
/// Stop cancels pending connects and bridges before closing the mesh driver.
pub struct Transport {
    mesh: RwLock<Option<WgMesh>>,
    routes: BTreeMap<String, StaticPeer>,
    stop: watch::Sender<bool>,
    bridge: Mutex<Option<JoinHandle<()>>>,
    local: SocketAddr,
    /// This machine's WireGuard key lock, released when the transport stops.
    key: Mutex<Option<Arc<KeyHolder>>>,
    /// What [`Self::restart`] starts the mesh again with: the service address, the
    /// configured peers and the listener the bridge forwards to.
    service: SocketAddr,
    peers: Vec<WgPeer>,
    websocket: SocketAddr,
    /// The daemon's other users of the node key this lock guards (the hub carrier): each takes a
    /// rotated key as [`Self::put_key`] puts it in place.
    key_users: Mutex<Vec<KeyUser>>,
}

/// Another user of the node key: given the new private key and `write` (which makes it the
/// machine's node key on disk), it runs `write` and takes the key, both or neither.
pub(crate) type KeyUser =
    Arc<dyn Fn(&[u8; 32], &mut dyn FnMut() -> Result<()>) -> Result<()> + Send + Sync>;

/// Where acpmux takes the lock for its node key, beside the cmux link whose state directory is
/// `link_dir`. The link holds the machine's lock (`state_dir`) for its whole life. When the key
/// the link serves is this node key (one key on the machine), the transport takes that same lock
/// and steps down while the link holds it: one key never runs in two tunnels. While the link
/// serves a key of its own (its `private.key`, before the one-key migration), the two keys never
/// meet: the transport locks only its own key, in [`OWN_KEY_LOCK`], and runs next to the link.
pub(crate) fn key_lock_dir(state_dir: &Path, link_dir: Option<&Path>) -> PathBuf {
    if link_dir.is_some_and(|link_dir| link_serves_node_key(state_dir, link_dir)) {
        state_dir.to_path_buf()
    } else {
        state_dir.join(OWN_KEY_LOCK)
    }
}

/// The lock directory of a node key the cmux link does not serve.
pub(crate) const OWN_KEY_LOCK: &str = "node-key-lock";

/// Whether the link in `link_dir` serves the node key in `state_dir`: both are there and are the
/// same key. Only their public halves are compared.
fn link_serves_node_key(state_dir: &Path, link_dir: &Path) -> bool {
    let node = key_holder::open_for_public_key(KeyFile::Node, state_dir, |path| {
        std::fs::read(path).map(zeroize::Zeroizing::new)
    });
    let link = key_holder::open_for_public_key(KeyFile::Link, link_dir, |path| {
        std::fs::read_to_string(path).map(zeroize::Zeroizing::new)
    });
    let (Ok(node), Ok(link)) = (node, link) else { return false };
    let Ok(link) = base64::engine::general_purpose::STANDARD.decode(link.trim()) else {
        return false;
    };
    let link = zeroize::Zeroizing::new(link);
    let (Ok(node), Ok(link)) = (<[u8; 32]>::try_from(&node[..]), <[u8; 32]>::try_from(&link[..]))
    else {
        return false;
    };
    let public = |key: [u8; 32]| {
        let secret = x25519_dalek::StaticSecret::from(key);
        x25519_dalek::PublicKey::from(&secret).to_bytes()
    };
    public(node) == public(link)
}

/// This machine's cmux link state directory (`<daemon state dir>/link`).
pub(crate) fn link_state_dir() -> Option<PathBuf> {
    cmux_tui_platform::platform::workspace_state_dir().map(|dir| dir.join("link"))
}

/// The install the link in `link_dir` paired with `wireguard_key`, if it did.
pub(crate) fn paired_install_in(link_dir: &Path, wireguard_key: &str) -> Option<String> {
    let pairings = cmux_link::pairing::Pairings::load(&link_dir.join("peers.json")).ok()?;
    pairings
        .peers
        .iter()
        .find(|record| record.public_key == wireguard_key && record.is_valid())
        .map(|record| record.install.clone())
}

impl Transport {
    /// Disabled means no key access, DNS lookup, UDP bind or background task.
    /// So does a key lock another process holds: the transport steps down.
    pub async fn start(
        config: &crate::config::Config,
        state_dir: &Path,
        websocket: SocketAddr,
    ) -> Result<Option<Arc<Self>>> {
        Self::start_with_link(config, state_dir, link_state_dir().as_deref(), websocket).await
    }

    /// [`Transport::start`] beside the cmux link whose state directory is `link_dir` (none:
    /// no link on this machine).
    pub async fn start_with_link(
        config: &crate::config::Config,
        state_dir: &Path,
        link_dir: Option<&Path>,
        websocket: SocketAddr,
    ) -> Result<Option<Arc<Self>>> {
        if !config.transport.wireguard {
            return Ok(None);
        }
        let settings = config
            .transport
            .wireguard_static
            .as_ref()
            .context("transport.wireguard requires wireguardStatic settings")?;
        let target = local_websocket(websocket)?;
        let key = match KeyHolder::acquire(&key_lock_dir(state_dir, link_dir)) {
            Ok(key) => key,
            Err(KeyHolderError::KeyHeld { pid }) => {
                tracing::warn!(
                    holder_pid = ?pid,
                    "WireGuard transport off for this run: another process holds this machine's WireGuard key; peers with a link route use the cmux link, the others their URL or ssh"
                );
                for (name, peer) in &config.peers {
                    if let Some(wg) = &peer.wireguard
                        && peer.link_host.is_none()
                        && link_dir.and_then(|dir| paired_install_in(dir, &wg.public_key)).is_none()
                    {
                        tracing::warn!(
                            peer = %name,
                            "the cmux link serves this node's WireGuard key and has no route to this peer: it goes on over its URL or ssh"
                        );
                    }
                }
                return Ok(None);
            }
            Err(KeyHolderError::Io(error)) => {
                return Err(anyhow::Error::from(error).context("take the WireGuard key lock"));
            }
        };
        let socket = UdpSocket::bind(settings.listen).await.context("bind WireGuard UDP")?;
        Self::from_socket(settings, &config.peers, state_dir, target, socket, key).await.map(Some)
    }

    async fn from_socket(
        settings: &StaticConfig,
        configured: &BTreeMap<String, crate::config::PeerConfig>,
        state_dir: &Path,
        websocket: SocketAddr,
        socket: UdpSocket,
        key: KeyHolder,
    ) -> Result<Arc<Self>> {
        ensure!(settings.address.port() != 0, "WireGuard service port must be nonzero");
        ensure!(
            !settings.address.ip().is_unspecified() && !settings.address.ip().is_multicast(),
            "WireGuard service address must be unicast"
        );
        let websocket = local_websocket(websocket)?;
        let local = socket.local_addr()?;
        let (_, private_key) = crate::cli::mesh_node_key::load_or_create_held(state_dir, &key)?;
        let mesh = WgMesh::start(mesh_config(private_key, settings.address), socket)?;
        let mut routes = BTreeMap::new();
        let mut peers = Vec::new();
        let mut identities = BTreeSet::new();
        for (name, peer) in configured {
            let Some(peer) = &peer.wireguard else { continue };
            let public_key = public_key(&peer.public_key)?;
            ensure!(identities.insert(public_key), "duplicate WireGuard peer key");
            ensure!(
                peer.address.port() != 0
                    && peer.address.ip() != settings.address.ip()
                    && peer.address.is_ipv4() == settings.address.is_ipv4()
                    && !peer.address.ip().is_unspecified()
                    && !peer.address.ip().is_multicast(),
                "invalid WireGuard peer service address"
            );
            let endpoints = tokio::time::timeout(
                CONNECT_BOUND,
                tokio::net::lookup_host(peer.endpoint.as_str()),
            )
            .await
            .context("WireGuard endpoint lookup timed out")??;
            // Every address the name resolves to is a path: the mesh probes
            // each one and the path selector picks (LAN before routed).
            let mut usable: Vec<SocketAddr> = Vec::new();
            for address in endpoints {
                if address.is_ipv4() == local.is_ipv4()
                    && address.port() != 0
                    && !usable.contains(&address)
                {
                    usable.push(address);
                }
            }
            let endpoint = *usable
                .first()
                .context("WireGuard endpoint has no address matching the UDP socket family")?;
            let wg_peer = WgPeer {
                public_key,
                preshared_key: None,
                allowed_ips: vec![IpNetwork::new(
                    peer.address.ip(),
                    host_prefix(peer.address.ip()),
                )?],
                route: Some(endpoint.into()),
                candidates: usable.into_iter().map(PeerCandidate::from).collect(),
                persistent_keepalive: None,
            };
            mesh.add_peer(wg_peer.clone()).await?;
            peers.push(wg_peer);
            routes.insert(name.clone(), peer.clone());
        }
        let listener = mesh.listen(settings.address.port()).await?;
        let (stop, stopped) = watch::channel(false);
        let bridge = tokio::spawn(bridge(listener, websocket, stopped));
        Ok(Arc::new(Self {
            mesh: RwLock::new(Some(mesh)),
            routes,
            stop,
            bridge: Mutex::new(Some(bridge)),
            local,
            key: Mutex::new(Some(Arc::new(key))),
            service: settings.address,
            peers,
            websocket,
            key_users: Mutex::new(Vec::new()),
        }))
    }

    /// `f` with this transport's key lock, while it holds it (until [`Self::shutdown`]).
    pub(crate) fn with_key<R>(&self, f: impl FnOnce(&KeyHolder) -> R) -> Option<R> {
        self.key.lock().unwrap_or_else(std::sync::PoisonError::into_inner).as_deref().map(f)
    }

    /// `user` takes every key a rekey puts in place from now on ([`Self::put_key`]).
    #[cfg_attr(not(feature = "hub-carrier"), allow(dead_code))]
    pub(crate) fn add_key_user(&self, user: KeyUser) {
        self.key_users.lock().unwrap_or_else(std::sync::PoisonError::into_inner).push(user);
    }

    /// A rekey's new key in place: `write` (the key file's rename) runs inside each key user's
    /// own rotation, so every one takes the key with the file or none does. The mesh itself
    /// starts again with it in [`Self::restart`].
    pub(crate) fn put_key(
        &self,
        private: &[u8; 32],
        write: &mut dyn FnMut() -> Result<()>,
    ) -> Result<()> {
        fn nest(
            users: &[KeyUser],
            private: &[u8; 32],
            write: &mut dyn FnMut() -> Result<()>,
        ) -> Result<()> {
            match users.split_first() {
                None => write(),
                Some((user, rest)) => user(private, &mut || nest(rest, private, &mut *write)),
            }
        }
        let users =
            self.key_users.lock().unwrap_or_else(std::sync::PoisonError::into_inner).clone();
        nest(&users, private, write)
    }

    /// Start the mesh again with `private_key` on the same UDP port, peers and service
    /// address: what a rekey (`machine_tunnel.rs`) does once the new key is on disk. Open
    /// tunnel streams and bridges end; peers handshake again with the new key.
    pub(crate) async fn restart(&self, private_key: Zeroizing<[u8; 32]>) -> Result<()> {
        let mut mesh = self.mesh.write().await;
        ensure!(!*self.stop.borrow() && mesh.is_some(), "WireGuard transport stopped");
        let old_bridge =
            self.bridge.lock().unwrap_or_else(std::sync::PoisonError::into_inner).take();
        if let Some(old_bridge) = old_bridge {
            old_bridge.abort();
            let _ = old_bridge.await;
        }
        if let Some(old) = mesh.take() {
            old.shutdown().await;
        }
        let socket = UdpSocket::bind(self.local).await.context("bind WireGuard UDP again")?;
        let fresh = WgMesh::start(mesh_config(private_key, self.service), socket)?;
        for peer in &self.peers {
            fresh.add_peer(peer.clone()).await?;
        }
        let listener = fresh.listen(self.service.port()).await?;
        let task = tokio::spawn(bridge(listener, self.websocket, self.stop.subscribe()));
        *self.bridge.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = Some(task);
        *mesh = Some(fresh);
        Ok(())
    }

    /// This machine's WireGuard key lock while the transport runs: the daemon's other user of
    /// the node key (the hub carrier) shares it, since a second lock in one process is refused.
    #[cfg(feature = "hub-carrier")]
    pub(crate) fn key_holder(&self) -> Option<Arc<KeyHolder>> {
        self.key.lock().unwrap_or_else(std::sync::PoisonError::into_inner).clone()
    }

    pub fn local_addr(&self) -> SocketAddr {
        self.local
    }

    pub fn route(&self, name: &str) -> Option<SocketAddr> {
        self.routes.get(name).map(|peer| peer.address)
    }

    /// A config reload cannot reuse a route whose key or endpoint changed.
    pub(crate) fn route_for(&self, name: &str, configured: &StaticPeer) -> Option<SocketAddr> {
        self.routes.get(name).filter(|peer| *peer == configured).map(|peer| peer.address)
    }

    /// Caller bounds the whole TCP + WebSocket handshake with one deadline.
    pub async fn connect(&self, remote: SocketAddr) -> Result<WgStream> {
        let mut stopped = self.stop.subscribe();
        let mesh = self.mesh.read().await;
        let mesh = mesh.as_ref().context("WireGuard transport stopped")?;
        tokio::select! {
            biased;
            _ = stopping(&mut stopped) => Err(anyhow!("WireGuard transport stopped")),
            stream = mesh.connect(remote) => Ok(stream?),
        }
    }

    /// Stop by `deadline`, delivering first what this daemon's listener sent each peer before
    /// it closed (the WebSocket close 1012 of a restart): each bridge forwards its listener's
    /// side to its end, and the mesh closes each tunnel connection after those bytes
    /// (`WgMesh::close`). Only what is left at `deadline` is reset.
    pub async fn shutdown(&self, deadline: tokio::time::Instant) {
        self.stop.send_replace(true);
        let bridge = self.bridge.lock().unwrap_or_else(std::sync::PoisonError::into_inner).take();
        if let Some(mut bridge) = bridge
            && tokio::time::timeout_at(deadline, &mut bridge).await.is_err()
        {
            tracing::warn!("WireGuard bridges did not finish before the shutdown deadline");
            bridge.abort();
            let _ = bridge.await;
        }
        let mesh = self.mesh.write().await.take();
        if let Some(mesh) = mesh {
            mesh.close(deadline).await;
        }
        // The mesh no longer runs with the key: another process may take it.
        drop(self.key.lock().unwrap_or_else(std::sync::PoisonError::into_inner).take());
    }
}

impl Drop for Transport {
    fn drop(&mut self) {
        self.stop.send_replace(true);
        if let Some(task) =
            self.bridge.get_mut().unwrap_or_else(std::sync::PoisonError::into_inner).take()
        {
            task.abort();
        }
    }
}

fn mesh_config(private_key: Zeroizing<[u8; 32]>, service: SocketAddr) -> WgMeshConfig {
    WgMeshConfig {
        private_key,
        addresses: vec![InterfaceAddress {
            address: service.ip(),
            prefix: host_prefix(service.ip()),
        }],
        mtu: cmux_wg::DEFAULT_MTU,
    }
}

fn host_prefix(ip: IpAddr) -> u8 {
    if ip.is_ipv4() { 32 } else { 128 }
}

fn public_key(text: &str) -> Result<[u8; 32]> {
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(text)
        .map_err(|_| anyhow!("WireGuard public key must be standard padded base64"))?;
    let key: [u8; 32] =
        bytes.try_into().map_err(|_| anyhow!("WireGuard public key must decode to 32 bytes"))?;
    ensure!(
        base64::engine::general_purpose::STANDARD.encode(key) == text,
        "WireGuard public key must be canonical padded base64"
    );
    Ok(key)
}

pub(crate) fn local_websocket(mut address: SocketAddr) -> Result<SocketAddr> {
    if address.ip().is_unspecified() {
        address.set_ip(if address.is_ipv4() {
            IpAddr::V4(std::net::Ipv4Addr::LOCALHOST)
        } else {
            IpAddr::V6(std::net::Ipv6Addr::LOCALHOST)
        });
    }
    ensure!(
        address.ip().is_loopback() && address.port() != 0,
        "WireGuard requires this daemon's WebSocket listener on loopback or a wildcard address"
    );
    Ok(address)
}

async fn stopping(stop: &mut watch::Receiver<bool>) {
    let _ = stop.wait_for(|stopped| *stopped).await;
}

async fn bridge(mut listener: WgMeshListener, target: SocketAddr, mut stop: watch::Receiver<bool>) {
    let mut connections = JoinSet::new();
    loop {
        tokio::select! {
            biased;
            _ = stopping(&mut stop) => break,
            Some(_) = connections.join_next(), if !connections.is_empty() => {},
            accepted = listener.accept() => {
                let Some((stream, _authenticated_key)) = accepted else { break };
                if connections.len() >= MAX_BRIDGES { continue; }
                let stop = stop.clone();
                connections.spawn(async move {
                    let Ok(Ok(local)) = tokio::time::timeout(CONNECT_BOUND, TcpStream::connect(target)).await
                        else { return };
                    let _ = local.set_nodelay(true);
                    // This is the authenticated WS listener, never the local RPC socket.
                    bridge_one(stream, local, stop).await;
                });
            }
        }
    }
    // Each connection forwards the rest its listener sent; `Transport::shutdown` bounds this.
    drop(listener);
    while connections.join_next().await.is_some() {}
}

/// One tunnel connection to the listener, both ways, until both ends finished. Once the
/// transport stops, only the listener's side goes on: the daemon's listener closed its clients
/// before the transport stops (`daemon.rs`), and its last bytes (a close frame) must reach the
/// peer before the tunnel's end; what the peer still sends has no reader left.
async fn bridge_one(stream: WgStream, local: TcpStream, mut stop: watch::Receiver<bool>) {
    use tokio::io::AsyncWriteExt;
    let (mut from_peer, mut to_peer) = tokio::io::split(stream);
    let (mut from_local, mut to_local) = local.into_split();
    let to_peer = async move {
        let _ = tokio::io::copy(&mut from_local, &mut to_peer).await;
        let _ = to_peer.shutdown().await;
    };
    let to_local = async move {
        let _ = tokio::io::copy(&mut from_peer, &mut to_local).await;
        let _ = to_local.shutdown().await;
    };
    tokio::pin!(to_peer, to_local);
    let (mut peer_done, mut local_done) = (false, false);
    while !(peer_done && local_done) {
        tokio::select! {
            () = &mut to_peer, if !peer_done => peer_done = true,
            () = &mut to_local, if !local_done => local_done = true,
            // The peer's side is given up; the listener's goes on to its end.
            _ = stopping(&mut stop), if !local_done => local_done = true,
        }
    }
}

#[cfg(test)]
#[path = "wireguard_tests.rs"]
mod tests;
