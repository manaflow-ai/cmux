//! Part of `Transport` (`wireguard.rs`). WireGuard routes the daemon finds at runtime, so two
//! machines that both run the transport reach each other over it with no hand-written
//! `peers.NAME.wireguard` block (what `wgcfg.py` wrote for the fleet on 2026-11-23).
//!
//! - **Found.** A plain `ssh://` peer's `_acpmux/host_health` names its node key and, while its
//!   transport runs, its WireGuard port and service address (`node.wireguard`). The origin asks
//!   the peer to admit its own key (`_acpmux/wireguard_admit`, over the live, token-checked
//!   link), then adds the peer to its mesh with the ssh host as the UDP endpoint
//!   ([`Transport::learn`]). `Via::Wireguard` joins the peer's paths (`peer_wg_learn.rs`).
//! - **Admitted.** The peer adds the origin's key as an inbound-only mesh peer: no route, the
//!   endpoint learned from the first authenticated datagram ([`Transport::admit`]).
//! - **Kept.** Both ends write what they found to `<state dir>/wireguard-learned.json` and add it
//!   to the mesh at the next start, so a restarted daemon's cold dial goes straight over
//!   WireGuard (with the tokens kept by `peer_tokens.rs`, no ssh read).
//!
//! Admitting a key grants bytes, not rights: the mesh forwards only to the loopback WebSocket
//! listener, which still checks the token and the peer proof. A configured peer always wins:
//! nothing learned replaces a key or name the config names. The transport itself stays the
//! Labs opt-in it was (`transport.wireguard`); nothing here runs where it is off.

use super::*;
use std::collections::BTreeSet;

/// The file both lists live in, in the daemon's state directory.
pub(super) const FILE: &str = "wireguard-learned.json";
/// The most routes and the most admitted keys each; a fleet is a few dozen machines.
pub(super) const MAX_ENTRIES: usize = 256;
/// The largest file read back; 256 entries are well under it.
const MAX_FILE_BYTES: u64 = 256 * 1024;

#[derive(Default, Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct Saved {
    /// Peer name (as this daemon's config names it) to the route found for it.
    #[serde(default)]
    pub routes: BTreeMap<String, StaticPeer>,
    /// A key that asked to be admitted (standard base64) to its service address.
    #[serde(default)]
    pub admitted: BTreeMap<String, SocketAddr>,
}

/// What is learned now: the saved lists, and the mesh peers they made (by key), which a rekey
/// adds to the new mesh again.
#[derive(Default)]
pub(super) struct Learned {
    pub saved: Saved,
    pub peers: BTreeMap<[u8; 32], WgPeer>,
}

/// An inbound-only mesh peer: no route, its endpoint learned from its first datagram.
fn inbound_peer(public_key: [u8; 32], address: SocketAddr) -> Result<WgPeer> {
    Ok(WgPeer {
        public_key,
        preshared_key: None,
        allowed_ips: vec![IpNetwork::new(address.ip(), host_prefix(address.ip()))?],
        route: None,
        candidates: Vec::new(),
        persistent_keepalive: None,
    })
}

pub(super) fn load(state_dir: &Path) -> Saved {
    let path = state_dir.join(FILE);
    let Ok(meta) = std::fs::symlink_metadata(&path) else { return Saved::default() };
    if !meta.is_file() || meta.len() > MAX_FILE_BYTES {
        tracing::warn!(path = %path.display(), "learned WireGuard routes not read: not a small file");
        return Saved::default();
    }
    match std::fs::read(&path)
        .map_err(anyhow::Error::from)
        .and_then(|bytes| serde_json::from_slice::<Saved>(&bytes).map_err(anyhow::Error::from))
    {
        Ok(saved) => saved,
        Err(error) => {
            tracing::warn!(path = %path.display(), "learned WireGuard routes not read: {error:#}");
            Saved::default()
        }
    }
}

fn save(state_dir: &Path, saved: &Saved) {
    let bytes = match serde_json::to_vec_pretty(saved) {
        Ok(bytes) => bytes,
        Err(error) => return tracing::warn!("learned WireGuard routes not saved: {error}"),
    };
    if let Err(error) = crate::config::write_atomic(&state_dir.join(FILE), &bytes) {
        tracing::warn!("learned WireGuard routes not saved: {error:#}");
    }
}

impl Learned {
    /// What was saved, added to the freshly started `mesh` beside the `configured` peers
    /// (already in it): an entry whose name or key the config names, or that the mesh
    /// refuses, is dropped. Never fails the start.
    pub(super) async fn start(
        state_dir: &Path,
        mesh: &WgMesh,
        local: SocketAddr,
        settings: &StaticConfig,
        configured_peers: &[WgPeer],
        configured: &BTreeMap<String, crate::config::PeerConfig>,
    ) -> Self {
        let saved = load(state_dir);
        let taken: BTreeSet<[u8; 32]> = configured_peers.iter().map(|p| p.public_key).collect();
        let mut learned = Self::default();
        for (name, route) in saved.routes.into_iter().take(MAX_ENTRIES) {
            if configured.get(&name).is_some_and(|pc| pc.wireguard.is_some()) {
                continue;
            }
            let Ok(key) = check_peer(settings, &route) else { continue };
            if taken.contains(&key) || learned.peers.contains_key(&key) {
                continue;
            }
            match resolve_peer(local, &route, key).await {
                Ok(peer) => match mesh.add_peer(peer.clone()).await {
                    Ok(()) => {
                        learned.peers.insert(key, peer);
                        learned.saved.routes.insert(name, route);
                    }
                    Err(error) => {
                        tracing::warn!(peer = %name, "learned WireGuard route dropped: {error}")
                    }
                },
                Err(error) => {
                    tracing::warn!(peer = %name, "learned WireGuard route dropped: {error:#}")
                }
            }
        }
        for (text, address) in saved.admitted.into_iter().take(MAX_ENTRIES) {
            let Ok(key) = check_admit(settings, &text, address) else { continue };
            // A key with a route of its own already takes its datagrams.
            if taken.contains(&key) || learned.peers.contains_key(&key) {
                continue;
            }
            let Ok(peer) = inbound_peer(key, address) else { continue };
            match mesh.add_peer(peer.clone()).await {
                Ok(()) => {
                    learned.peers.insert(key, peer);
                    learned.saved.admitted.insert(text, address);
                }
                Err(error) => tracing::warn!("admitted WireGuard key dropped: {error}"),
            }
        }
        learned
    }
}

/// An admitted key and service address, checked as a configured peer's would be.
fn check_admit(settings: &StaticConfig, public_key: &str, address: SocketAddr) -> Result<[u8; 32]> {
    check_peer(
        settings,
        &StaticPeer { public_key: public_key.to_owned(), endpoint: String::new(), address },
    )
}

impl Transport {
    fn settings(&self) -> StaticConfig {
        StaticConfig { listen: self.local, address: self.service }
    }

    fn learned_lock(&self) -> std::sync::MutexGuard<'_, Learned> {
        self.learned.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// The learned mesh peers, for a rekey's new mesh (`Transport::restart`).
    pub(super) fn learned_peers(&self) -> Vec<WgPeer> {
        self.learned_lock().peers.values().cloned().collect()
    }

    /// This machine's node public key (standard base64), as the mesh runs with it.
    pub(crate) fn public_key_b64(&self) -> String {
        self.public_key.lock().unwrap_or_else(std::sync::PoisonError::into_inner).clone()
    }

    /// What `host_health` says about this transport (`node.wireguard`): the key the mesh runs
    /// with, the UDP port it listens on and its service address, for an origin to learn a route
    /// from. The same object is what an origin sends to be admitted.
    pub(crate) fn advert(&self) -> serde_json::Value {
        serde_json::json!({
            "publicKey": self.public_key_b64(),
            "port": self.local.port(),
            "address": self.service.to_string(),
        })
    }

    /// The route learned for peer `name` (on this or an earlier run): its service address.
    pub(crate) fn learned_route(&self, name: &str) -> Option<StaticPeer> {
        self.learned_lock().saved.routes.get(name).cloned()
    }

    /// Admit `public_key` (an origin that learned a route to this machine) as an inbound-only
    /// peer at service address `address`, and keep it. False when nothing changed: the key is
    /// configured, already has a route here, or is admitted at that address.
    pub(crate) async fn admit(&self, public_key: &str, address: SocketAddr) -> Result<bool> {
        let _update = self.learned_update.lock().await;
        let key = check_admit(&self.settings(), public_key, address)?;
        if self.peers.iter().any(|peer| peer.public_key == key) {
            return Ok(false);
        }
        {
            let learned = self.learned_lock();
            if let Some(existing) = learned.peers.get(&key) {
                if existing.route.is_some()
                    || learned.saved.admitted.get(public_key) == Some(&address)
                {
                    return Ok(false);
                }
            } else {
                ensure!(
                    learned.saved.admitted.len() < MAX_ENTRIES,
                    "too many admitted WireGuard keys"
                );
            }
        }
        let peer = inbound_peer(key, address)?;
        {
            let mesh = self.mesh.read().await;
            let mesh = mesh.as_ref().context("WireGuard transport stopped")?;
            mesh.add_peer(peer.clone()).await?;
        }
        let saved = {
            let mut learned = self.learned_lock();
            learned.peers.insert(key, peer);
            learned.saved.admitted.insert(public_key.to_owned(), address);
            learned.saved.clone()
        };
        save(&self.state_dir, &saved);
        tracing::info!(address = %address, "admitted a peer's WireGuard key (inbound only)");
        Ok(true)
    }

    /// Add `route` to the mesh as peer `name`'s and keep it: its service address, which the
    /// peer's `Via::Wireguard` dials. Refused for a name or key the config names.
    pub(crate) async fn learn(&self, name: &str, route: StaticPeer) -> Result<SocketAddr> {
        let _update = self.learned_update.lock().await;
        let key = check_peer(&self.settings(), &route)?;
        ensure!(!self.routes.contains_key(name), "peer {name} has a configured WireGuard route");
        ensure!(
            !self.peers.iter().any(|peer| peer.public_key == key),
            "that WireGuard key is a configured peer's"
        );
        {
            let learned = self.learned_lock();
            if learned.saved.routes.get(name) == Some(&route) {
                return Ok(route.address);
            }
            ensure!(
                learned.saved.routes.contains_key(name) || learned.saved.routes.len() < MAX_ENTRIES,
                "too many learned WireGuard routes"
            );
        }
        let peer = resolve_peer(self.local, &route, key).await?;
        {
            let mesh = self.mesh.read().await;
            let mesh = mesh.as_ref().context("WireGuard transport stopped")?;
            // A key found again under a new name or endpoint replaces its old session.
            let old = self.learned_lock().saved.routes.get(name).map(|old| old.public_key.clone());
            if let Some(old) = old.filter(|old| *old != route.public_key)
                && let Ok(old) = public_key(&old)
            {
                let _ = mesh.remove_peer(old).await;
                self.learned_lock().peers.remove(&old);
            }
            mesh.add_peer(peer.clone()).await?;
        }
        let saved = {
            let mut learned = self.learned_lock();
            learned.peers.insert(key, peer);
            learned.saved.routes.insert(name.to_owned(), route.clone());
            learned.saved.clone()
        };
        save(&self.state_dir, &saved);
        Ok(route.address)
    }
}

#[cfg(test)]
#[path = "wireguard_learned_tests.rs"]
mod tests;
