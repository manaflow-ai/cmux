//! Labs-only WireGuard transport for acpmux's authenticated WebSocket streams.
//!
//! One boringtun/smoltcp mesh owns one UDP socket. Incoming streams can reach
//! only this daemon's loopback WebSocket listener, which still checks tokens,
//! peer proofs and policy. They never reach the privileged local socket.

use std::collections::{BTreeMap, BTreeSet};
use std::net::{IpAddr, SocketAddr};
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::{Context, Result, anyhow, ensure};
use base64::Engine;
use cmux_wg::{
    InterfaceAddress, IpNetwork, WgMesh, WgMeshConfig, WgMeshListener, WgPeer, WgStream,
};
use serde::{Deserialize, Serialize};
use tokio::net::{TcpStream, UdpSocket};
use tokio::sync::{RwLock, watch};
use tokio::task::{JoinHandle, JoinSet};

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
}

impl Transport {
    /// Disabled means no key access, DNS lookup, UDP bind or background task.
    pub async fn start(
        config: &crate::config::Config,
        state_dir: &Path,
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
        let socket = UdpSocket::bind(settings.listen).await.context("bind WireGuard UDP")?;
        Self::from_socket(settings, &config.peers, state_dir, target, socket).await.map(Some)
    }

    async fn from_socket(
        settings: &StaticConfig,
        configured: &BTreeMap<String, crate::config::PeerConfig>,
        state_dir: &Path,
        websocket: SocketAddr,
        socket: UdpSocket,
    ) -> Result<Arc<Self>> {
        ensure!(settings.address.port() != 0, "WireGuard service port must be nonzero");
        ensure!(
            !settings.address.ip().is_unspecified() && !settings.address.ip().is_multicast(),
            "WireGuard service address must be unicast"
        );
        let websocket = local_websocket(websocket)?;
        let local = socket.local_addr()?;
        let keys = crate::cli::mesh_node_key::load_or_create_at(state_dir)?;
        let mesh = WgMesh::start(
            WgMeshConfig {
                private_key: keys.private_key(),
                addresses: vec![InterfaceAddress {
                    address: settings.address.ip(),
                    prefix: host_prefix(settings.address.ip()),
                }],
                mtu: cmux_wg::DEFAULT_MTU,
            },
            socket,
        )?;
        let mut routes = BTreeMap::new();
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
            let mut endpoints = tokio::time::timeout(
                CONNECT_BOUND,
                tokio::net::lookup_host(peer.endpoint.as_str()),
            )
            .await
            .context("WireGuard endpoint lookup timed out")??;
            let endpoint = endpoints
                .find(|a| a.is_ipv4() == local.is_ipv4() && a.port() != 0)
                .context("WireGuard endpoint has no address matching the UDP socket family")?;
            mesh.add_peer(WgPeer {
                public_key,
                preshared_key: None,
                allowed_ips: vec![IpNetwork::new(
                    peer.address.ip(),
                    host_prefix(peer.address.ip()),
                )?],
                route: Some(endpoint.into()),
                persistent_keepalive: None,
            })
            .await?;
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
        }))
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

fn local_websocket(mut address: SocketAddr) -> Result<SocketAddr> {
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
