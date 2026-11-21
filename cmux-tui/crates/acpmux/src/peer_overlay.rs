//! Part of `Peer` (`peer.rs`). The cmux link's WireGuard overlay as a backup path of a plain
//! `ssh://` machine (ask c-ac4a1ef0a0, "Add cmux wireguard route as backup SSH path").
//!
//! A machine added over ssh has one path, ssh, unless its config names an overlay route
//! (`wireguard`, `linkHost`). When that machine is also a paired install of this machine's
//! cmux link, the link reaches it too. Nobody has to say so:
//!
//! - **Found.** The machine's `_acpmux/host_health` (asked over the live link every minute,
//!   `peer_health.rs`) names its own link install (`link.install`) and its node key
//!   (`node.wgPublicKey`). When either is a pairing of this machine's link (`peers.json`), that
//!   install becomes the peer's link host: [`Via::Link`] joins its paths, is probed like every
//!   other path and is raced at the next cold connect (`peer_carriers.rs`). A link already on
//!   ssh moves only by the selector's usual rules.
//! - **Kept.** The install goes into `peer-paths.json` beside the URL it was found for
//!   (`Endpoints::link`). A restarted daemon takes it back for that same URL, while the pairing
//!   still exists ([`remembered_install_in`]), so an ssh that is down at start no longer leaves
//!   the machine unreachable.
//! - **Never more.** Nothing is learned for a peer whose config names its own route, for a peer
//!   that is not `ssh://`, or from an install this link is not paired with. The Labs WireGuard
//!   transport and every default are unchanged. With no pairing, ssh is the only path and its
//!   failure is reported as before.
//!
//! A machine that claims another paired install's id only points this daemon at one of the
//! person's own paired machines, whose acpmux checks the token as always: the link carries
//! bytes, it grants nothing.

use super::Peer;
use crate::peer_last_good::Entry;
use crate::peer_paths::Via;
use cmux_link::pairing::Pairings;
use serde_json::Value;
use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::Ordering;

/// The most bytes a link `config.json` may have; it is a few dozen.
const MAX_LINK_CONFIG_BYTES: u64 = 16 * 1024;

/// The paired install of the link whose state directory is `link_dir` that the machine's
/// `host_health` reply names: its link install, else the pairing with its node key.
pub(crate) fn overlay_install_in(link_dir: &Path, health: &Value) -> Option<String> {
    let pairings = Pairings::load(&link_dir.join("peers.json")).ok()?;
    if let Some(install) = health.pointer("/link/install").and_then(Value::as_str)
        && let Some(record) = pairings.by_install(install).filter(|record| record.is_valid())
    {
        return Some(record.install.clone());
    }
    let key = health.pointer("/node/wgPublicKey").and_then(Value::as_str)?;
    pairings
        .peers
        .iter()
        .find(|record| record.public_key == key && record.is_valid())
        .map(|record| record.install.clone())
}

/// Whether `install` is still a pairing of the link in `link_dir`.
fn is_paired_in(link_dir: &Path, install: &str) -> bool {
    Pairings::load(&link_dir.join("peers.json"))
        .ok()
        .and_then(|pairings| pairings.by_install(install).map(|record| record.is_valid()))
        .unwrap_or(false)
}

/// The link install remembered for this peer (`entry`), when it was found for this same
/// `url` and the link in `link_dir` is still paired with it.
pub(crate) fn remembered_install_in(
    link_dir: &Path,
    entry: Option<&Entry>,
    url: &str,
) -> Option<String> {
    let endpoints = &entry?.endpoints;
    let install = endpoints.link.as_deref()?;
    (endpoints.url.as_deref() == Some(url)
        && cmux_link::stamp::valid_id(install)
        && is_paired_in(link_dir, install))
    .then(|| install.to_owned())
}

/// The install id of the link whose state directory is `link_dir` (its `config.json`), for
/// this machine's own `host_health`. None without a link or with a bad file.
pub(crate) fn own_install_in(link_dir: &Path) -> Option<String> {
    let path = link_dir.join("config.json");
    let meta = std::fs::symlink_metadata(&path).ok()?;
    if !meta.is_file() || meta.len() > MAX_LINK_CONFIG_BYTES {
        return None;
    }
    let config: Value = serde_json::from_slice(&std::fs::read(&path).ok()?).ok()?;
    config
        .get("install")
        .and_then(Value::as_str)
        .filter(|install| cmux_link::stamp::valid_id(install))
        .map(str::to_owned)
}

impl Peer {
    /// Whether this peer may get an overlay path found for it: a plain `ssh://` peer whose
    /// config names no route of its own ([`Peer::set_explicit_route`]) and that has no link
    /// host yet. A configured WireGuard peer stays excluded whether or not its transport runs.
    fn overlay_wanted(&self) -> bool {
        !self.explicit_route.load(Ordering::SeqCst)
            && self.link_host.get().is_none()
            && self.ssh_parts().is_some()
    }

    /// The peer's config names its own route (`PeerConfig::wireguard` or `link_host`), set by
    /// `Hub::spawn_peer` before the first dial.
    pub(crate) fn set_explicit_route(&self, explicit: bool) {
        self.explicit_route.store(explicit, Ordering::SeqCst);
    }

    /// Take back the link install remembered for this peer's URL (`Hub::spawn_peer`, before
    /// the first dial).
    pub(crate) fn recall_overlay(&self) {
        let Some(dir) = crate::wireguard::link_state_dir() else { return };
        self.recall_overlay_in(&dir);
    }

    pub(super) fn recall_overlay_in(&self, link_dir: &Path) {
        if !self.overlay_wanted() {
            return;
        }
        let entry = self.last_good.get().and_then(|book| book.get(&self.name));
        let url = super::lift_query_token(&self.url).0;
        if let Some(install) = remembered_install_in(link_dir, entry.as_ref(), &url) {
            tracing::info!(peer = %self.name, "the cmux link is this machine's backup path to ssh (remembered)");
            self.set_link_host(install);
        }
    }

    /// Learn the overlay path from the machine's `host_health` reply (`peer_health.rs`).
    pub(super) fn learn_overlay(self: &Arc<Self>, health: &Value) {
        let Some(dir) = crate::wireguard::link_state_dir() else { return };
        self.learn_overlay_in(&dir, health);
    }

    /// [`Peer::learn_overlay`] against the link in `link_dir`. True when the link path was
    /// added.
    pub(super) fn learn_overlay_in(self: &Arc<Self>, link_dir: &Path, health: &Value) -> bool {
        if !self.overlay_wanted() {
            return false;
        }
        let Some(install) = overlay_install_in(link_dir, health) else { return false };
        self.set_link_host(install);
        if self.link_host.get().is_none() {
            return false;
        }
        // Paths made before now gain the link; paths made from here on have it already
        // (`path_vias` reads the link host).
        self.with_paths(|paths| paths.add(Via::Link));
        if !self.with_paths(|paths| paths.vias().any(|via| via == Via::Link)) {
            return false;
        }
        tracing::info!(peer = %self.name, "the cmux link reaches this machine too: a backup path to ssh");
        if self.link().is_ready() {
            // Probes start once a link is ready; with ssh alone there were none.
            if self.probing.load(Ordering::SeqCst) {
                tokio::spawn(self.clone().probe(Via::Link));
            } else {
                self.start_probes();
            }
            self.note_ready_path();
        }
        true
    }
}

#[cfg(test)]
#[path = "peer_overlay_tests.rs"]
mod tests;
