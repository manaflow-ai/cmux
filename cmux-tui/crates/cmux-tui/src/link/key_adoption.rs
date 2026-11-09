//! One WireGuard key per machine: the link adopts the node key (`node.wg.key`
//! in the acpmux home, which the platform already knows as this machine's
//! key) and retires its own `private.key`.
//!
//! A link adopts when its key lock is not in its own state directory (it
//! shares the app's acpmux home, `key_lock.rs`) and it is not a
//! server-enrolled link. Every step runs under the held lock, and each one is
//! safe to be killed after:
//!
//! 1. The node key exists (`acpmux::cli::mesh_node_key::load_or_create_held`:
//!    a synced temporary file linked into place).
//! 2. Commit: [`MARKER`] names where the node key is and the link key it
//!    retires (synced temporary file, rename, synced directory). From here
//!    the link serves the node key and never the old one again.
//! 3. Republish: each paired peer is told the new key over the old key's
//!    session ([`Service::Rekey`]), for at most [`REPUBLISH_FOR`]. The
//!    platform needs nothing: the node key is already this machine's
//!    registered key, and the link's own key was never sent to it.
//! 4. Retire: `private.key` is removed and the directory synced.
//!
//! A start that finds `private.key` still there (killed after 1, 2 or 3, or
//! an install whose archived key was put back) runs 2 to 4 again. The
//! machine's key is never rekeyed here: a team refuses a key any of its
//! machines has used (cmux-platform#1037), and adoption only ever moves to
//! the registered node key.

use std::io;
use std::net::{IpAddr, Ipv6Addr, SocketAddr};
use std::path::{Path, PathBuf};
use std::time::Duration;

use anyhow::Context as _;
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use cmux_link::LINK_PORT;
use cmux_link::dial::{RekeyReply, RekeyRequest, Service, ServiceHello, line};
use cmux_link::key_holder::KeyHolder;
use cmux_link::pairing::Pairings;
use cmux_wg::{InterfaceAddress, WgMesh, WgMeshConfig};
use serde::{Deserialize, Serialize};
use tokio::io::AsyncWriteExt as _;
use zeroize::Zeroizing;

use super::dial::Overlay as _;
use super::lines::read_line;
use super::mesh::MeshOverlay;
use super::state::{self, LINK_MTU, LinkState};

/// The commit record of an adoption, in the link's state directory.
pub(super) const MARKER: &str = "key-adopted.json";

/// How long the old key's session may take to tell the paired peers.
const REPUBLISH_FOR: Duration = Duration::from_secs(4);

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Adopted {
    /// Where the node key is: the key lock directory (the acpmux home).
    pub key_dir: PathBuf,
    /// The link key the adoption retired, standard base64, when there was one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub retired_public_key: Option<String>,
}

/// The step an adoption just finished (the migration test stops a process after each).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Step {
    NodeKey,
    Committed,
    Republished,
    Retired,
}

impl Step {
    #[cfg(test)]
    pub(super) const ALL: [Self; 4] =
        [Self::NodeKey, Self::Committed, Self::Republished, Self::Retired];

    #[cfg(test)]
    pub(super) fn name(self) -> &'static str {
        match self {
            Self::NodeKey => "node_key",
            Self::Committed => "committed",
            Self::Republished => "republished",
            Self::Retired => "retired",
        }
    }
}

/// Where the test stops its child process ([`Step::name`]).
#[cfg(test)]
pub(super) const ABORT_AFTER: &str = "CMUX_LINK_TEST_ADOPT_ABORT_AFTER";

fn finished(step: Step) {
    #[cfg(test)]
    if std::env::var(ABORT_AFTER).is_ok_and(|name| name == step.name()) {
        std::process::abort();
    }
    let _ = step;
}

/// Whether `state`'s link adopts the node key next to `lock_dir`.
pub(super) fn adopts(state: &LinkState, lock_dir: &Path) -> io::Result<bool> {
    if state.config()?.server_identity.is_some() {
        return Ok(false);
    }
    let canonical = |path: &Path| std::fs::canonicalize(path).unwrap_or_else(|_| path.to_owned());
    Ok(canonical(lock_dir) != canonical(state.dir()))
}

/// The adoption record of `state`, if its link adopted the node key.
pub(super) fn adopted(state: &LinkState) -> io::Result<Option<Adopted>> {
    let text = match std::fs::read(state.dir().join(MARKER)) {
        Ok(text) => text,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error),
    };
    serde_json::from_slice(&text)
        .map(Some)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))
}

/// The key `serve` runs with: the node key once adopted (steps 1 to 4 above,
/// finishing a half-done adoption), else the link's own key.
pub(super) async fn serve_key(
    state: &LinkState,
    holder: &KeyHolder,
    pairings: &Pairings,
) -> anyhow::Result<Zeroizing<[u8; 32]>> {
    if !adopts(state, holder.dir())? {
        // An adopted link serves only the node key, under the lock next to it: never its old
        // key again, and never the node key under another lock.
        if let Some(adopted) = adopted(state)? {
            anyhow::bail!(
                "key_lock_dir: this link serves this machine's node key in {}; run it with {} {}",
                adopted.key_dir.display(),
                super::key_lock::FLAG,
                adopted.key_dir.display()
            );
        }
        return Ok(state.private_key(holder)?);
    }
    adopt(state, holder, pairings).await
}

async fn adopt(
    state: &LinkState,
    holder: &KeyHolder,
    pairings: &Pairings,
) -> anyhow::Result<Zeroizing<[u8; 32]>> {
    let config = state.config()?;
    let (_, node) = acpmux::cli::mesh_node_key::load_or_create_held(holder.dir(), holder)
        .context("the node key this link adopts")?;
    finished(Step::NodeKey);
    let node_public = state::public_key(&node);
    let old = if state.has_link_key() { Some(state.private_key(holder)?) } else { None };
    let retired = old.as_ref().map(|old| state::public_key(old));
    let record = Adopted {
        key_dir: holder.dir().to_path_buf(),
        retired_public_key: match (&retired, adopted(state)?) {
            (Some(retired), _) => Some(STANDARD.encode(retired)),
            (None, Some(earlier)) => earlier.retired_public_key,
            (None, None) => None,
        },
    };
    if adopted(state)?.as_ref() != Some(&record) {
        let text = serde_json::to_vec_pretty(&record)?;
        state::write_private_synced(&state.dir().join(MARKER), &text)?;
    }
    finished(Step::Committed);
    if let Some(old) = old {
        if retired != Some(node_public) {
            let told = republish(old, &node_public, &config, pairings).await;
            let missed: Vec<&str> = pairings
                .peers
                .iter()
                .map(|record| record.install.as_str())
                .filter(|install| !told.iter().any(|told| told == install))
                .collect();
            if !missed.is_empty() {
                eprintln!(
                    "cmux link: adopted this machine's node key; these paired peers did not \
                     answer and need this link's new public key paired again: {}",
                    missed.join(", ")
                );
            }
        }
        finished(Step::Republished);
        state.retire_link_key()?;
    }
    finished(Step::Retired);
    Ok(node)
}

/// Tell each paired peer `new_public` over a session of the `old` key, from
/// this install's overlay address on its port; the installs that took it.
async fn republish(
    old: Zeroizing<[u8; 32]>,
    new_public: &[u8; 32],
    config: &state::LinkConfig,
    pairings: &Pairings,
) -> Vec<String> {
    if pairings.peers.is_empty() {
        return Vec::new();
    }
    let telling = async {
        let socket =
            tokio::net::UdpSocket::bind(SocketAddr::from((Ipv6Addr::UNSPECIFIED, config.port)))
                .await?;
        // The peer checks a stream's source against this install's overlay address.
        let own = cmux_link::overlay_addr::overlay_address(&config.install);
        let mesh = WgMesh::start(
            WgMeshConfig {
                private_key: old,
                addresses: vec![InterfaceAddress { address: IpAddr::V6(own), prefix: 128 }],
                mtu: LINK_MTU,
            },
            socket,
        )
        .map_err(io::Error::other)?;
        let overlay = MeshOverlay::new(mesh);
        overlay.sync_peers(pairings).await?;
        let told = tell_all(&overlay, new_public, pairings, REPUBLISH_FOR).await;
        overlay.shutdown().await;
        io::Result::Ok(told)
    };
    match telling.await {
        Ok(told) => told,
        Err(error) => {
            eprintln!("cmux link: could not tell the paired peers this link's new key: {error}");
            Vec::new()
        }
    }
}

/// [`republish`] on `overlay`: every peer at once, all within `budget`.
pub(super) async fn tell_all<O: super::dial::Overlay>(
    overlay: &O,
    new_public: &[u8; 32],
    pairings: &Pairings,
    budget: Duration,
) -> Vec<String> {
    let request = line(&RekeyRequest { public_key: STANDARD.encode(new_public) });
    let tells = pairings.peers.iter().map(|record| {
        let request = request.clone();
        let remote = SocketAddr::new(IpAddr::V6(record.overlay_address()), LINK_PORT);
        async move {
            let told = async {
                let mut stream = overlay.connect(remote).await?;
                let hello = line(&ServiceHello::paired(Service::Rekey));
                stream.write_all(hello.as_bytes()).await?;
                stream.write_all(request.as_bytes()).await?;
                let answer = read_line(&mut stream, cmux_link::dial::MAX_LINE_BYTES).await?;
                let reply: RekeyReply = serde_json::from_str(answer.trim())
                    .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
                io::Result::Ok(reply.ok)
            };
            match tokio::time::timeout(budget, told).await {
                Ok(Ok(true)) => Some(record.install.clone()),
                _ => None,
            }
        }
    });
    futures_util::future::join_all(tells).await.into_iter().flatten().collect()
}

#[cfg(test)]
#[path = "key_adoption_tests.rs"]
mod tests;
