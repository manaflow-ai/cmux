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
//! 2. Commit: [`MARKER`] names where the node key is, the link key it
//!    retires, the paired peers still to tell, and when the retired key is
//!    dropped regardless (synced temporary file, rename, synced directory).
//!    From here the link serves the node key.
//! 3. Tell (while serving, [`finish_retiring`]): the mesh still answers the
//!    retired key, for the peers not told yet only (`WgMesh::start_retiring`),
//!    so a peer that knows this link by its old key keeps working. Each one is
//!    told the new key over that session ([`Service::Rekey`]) when it is
//!    reachable, retried with backoff; a told peer moves to the node key and
//!    leaves the record. A peer that was offline is told when it is back; two
//!    links that adopted at once meet on their retired keys and tell each
//!    other. Nobody pairs again.
//! 4. Retire: once every peer was told, or [`RETIRED_KEY_KEPT_FOR`] after
//!    the commit, `private.key` is removed and the directory synced.
//!
//! A start that finds `private.key` still there (killed after 1 or 2, or
//! still telling) goes on from the record. The machine's key is never
//! rekeyed here: a team refuses a key any of its machines has used
//! (cmux-platform#1037), and adoption only ever moves to the registered node
//! key. The retired key only answers peers that still name it; the link never
//! serves it as its own key again.

use std::collections::BTreeSet;
use std::io;
use std::net::{IpAddr, SocketAddr};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use anyhow::Context as _;
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use cmux_link::LINK_PORT;
use cmux_link::dial::{RekeyReply, RekeyRequest, Service, ServiceHello, line};
use cmux_link::key_holder::KeyHolder;
use cmux_link::pairing::Pairings;
use serde::{Deserialize, Serialize};
use tokio::io::AsyncWriteExt as _;
use zeroize::Zeroizing;

use super::control::Peers;
use super::lines::read_line;
use super::mesh::MeshOverlay;
use super::state::{self, LinkState};

/// The commit record of an adoption, in the link's state directory.
pub(super) const MARKER: &str = "key-adopted.json";

/// How long the retired key still answers peers that were not told.
pub(super) const RETIRED_KEY_KEPT_FOR: Duration = Duration::from_secs(14 * 24 * 60 * 60);

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Adopted {
    /// Where the node key is: the key lock directory (the acpmux home).
    pub key_dir: PathBuf,
    /// The link key the adoption retired, standard base64, when there was one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub retired_public_key: Option<String>,
    /// The paired installs not told the new key yet.
    #[serde(default, skip_serializing_if = "BTreeSet::is_empty")]
    pub pending: BTreeSet<String>,
    /// When the retired key goes regardless (seconds since the epoch), while
    /// `private.key` is kept.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub retire_after: Option<u64>,
}

/// What `serve` runs with.
pub(super) struct ServeKey {
    pub key: Zeroizing<[u8; 32]>,
    /// The retired key and the peers it still answers, while any is left.
    pub retiring: Option<Retiring>,
}

pub(super) struct Retiring {
    pub key: Zeroizing<[u8; 32]>,
    pub pending: BTreeSet<String>,
}

/// The step an adoption just finished (the migration test stops a process after each).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Step {
    NodeKey,
    Committed,
    Retired,
}

impl Step {
    #[cfg(test)]
    pub(super) const ALL: [Self; 3] = [Self::NodeKey, Self::Committed, Self::Retired];

    #[cfg(test)]
    pub(super) fn name(self) -> &'static str {
        match self {
            Self::NodeKey => "node_key",
            Self::Committed => "committed",
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

fn now_secs() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |since| since.as_secs())
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

fn commit(state: &LinkState, record: &Adopted) -> io::Result<()> {
    if adopted(state)?.as_ref() == Some(record) {
        return Ok(());
    }
    let text = serde_json::to_vec_pretty(record).map_err(io::Error::other)?;
    state::write_private_synced(&state.dir().join(MARKER), &text)
}

/// Step 4: the record first (nothing left to tell), then the key.
fn retire(state: &LinkState, mut record: Adopted) -> io::Result<()> {
    if !record.pending.is_empty() {
        eprintln!(
            "cmux link: dropped the retired key {RETIRED_KEY_KEPT_FOR:?} after adopting this \
             machine's node key; these paired peers never came back to take the new one: {}",
            record.pending.iter().cloned().collect::<Vec<_>>().join(", ")
        );
    }
    record.pending.clear();
    record.retire_after = None;
    commit(state, &record)?;
    state.retire_link_key()?;
    finished(Step::Retired);
    Ok(())
}

/// The key `serve` runs with: the node key once adopted (steps 1 and 2 above,
/// and 4 when nobody is left to tell), else the link's own key.
pub(super) async fn serve_key(
    state: &LinkState,
    holder: &KeyHolder,
    pairings: &Pairings,
) -> anyhow::Result<ServeKey> {
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
        return Ok(ServeKey { key: state.private_key(holder)?, retiring: None });
    }
    adopt(state, holder, pairings)
}

fn adopt(state: &LinkState, holder: &KeyHolder, pairings: &Pairings) -> anyhow::Result<ServeKey> {
    let (_, node) = acpmux::cli::mesh_node_key::load_or_create_held(holder.dir(), holder)
        .context("the node key this link adopts")?;
    finished(Step::NodeKey);
    let node_public = state::public_key(&node);
    let old = if state.has_link_key() { Some(state.private_key(holder)?) } else { None };
    let earlier = adopted(state)?;
    let Some(old) = old.filter(|old| state::public_key(old) != node_public) else {
        let record = Adopted {
            key_dir: holder.dir().to_path_buf(),
            retired_public_key: earlier.and_then(|earlier| earlier.retired_public_key),
            pending: BTreeSet::new(),
            retire_after: None,
        };
        commit(state, &record)?;
        finished(Step::Committed);
        if state.has_link_key() {
            state.retire_link_key()?;
        }
        finished(Step::Retired);
        return Ok(ServeKey { key: node, retiring: None });
    };
    let retired = STANDARD.encode(state::public_key(&old));
    let paired: BTreeSet<String> = pairings
        .peers
        .iter()
        .filter(|record| record.key().is_some())
        .map(|record| record.install.clone())
        .collect();
    // The same retired key: go on from the record (who is left, when it ends).
    let record = match earlier
        .filter(|earlier| earlier.retired_public_key.as_deref() == Some(retired.as_str()))
    {
        Some(earlier) => Adopted {
            key_dir: holder.dir().to_path_buf(),
            pending: earlier.pending.intersection(&paired).cloned().collect(),
            retire_after: earlier
                .retire_after
                .or_else(|| Some(now_secs() + RETIRED_KEY_KEPT_FOR.as_secs())),
            retired_public_key: Some(retired),
        },
        None => Adopted {
            key_dir: holder.dir().to_path_buf(),
            retired_public_key: Some(retired),
            pending: paired,
            retire_after: Some(now_secs() + RETIRED_KEY_KEPT_FOR.as_secs()),
        },
    };
    commit(state, &record)?;
    finished(Step::Committed);
    if record.pending.is_empty() || record.retire_after.is_some_and(|after| now_secs() >= after) {
        retire(state, record)?;
        return Ok(ServeKey { key: node, retiring: None });
    }
    let pending = record.pending;
    Ok(ServeKey { key: node, retiring: Some(Retiring { key: old, pending }) })
}

/// How often [`finish_retiring`] tries the peers left (`first`, doubling to
/// `cap`) and how long one try at a peer may take (`tell_for`).
#[derive(Debug, Clone, Copy)]
pub(super) struct Retry {
    pub first: Duration,
    pub cap: Duration,
    pub tell_for: Duration,
}

pub(super) const RETRY: Retry = Retry {
    first: Duration::from_secs(15),
    cap: Duration::from_secs(5 * 60),
    tell_for: Duration::from_secs(5),
};

/// The paired installs a running link still keeps on its retired key, and
/// its node key, which an inbound rekey from one of them gets back.
#[derive(Default)]
pub(super) struct RetiringPeers {
    installs: std::sync::Mutex<BTreeSet<String>>,
    node_public: std::sync::OnceLock<[u8; 32]>,
    /// Woken when an inbound rekey took an install off the retired key.
    confirmed: tokio::sync::Notify,
}

impl RetiringPeers {
    pub(super) fn set(&self, installs: BTreeSet<String>) {
        *super::locked(&self.installs) = installs;
    }

    pub(super) fn installs(&self) -> BTreeSet<String> {
        super::locked(&self.installs).clone()
    }

    pub(super) fn answer_with(&self, node_public: [u8; 32]) {
        let _ = self.node_public.set(node_public);
    }

    /// Take `install` off the retired key; the node key, when it was on it.
    pub(super) fn confirm(&self, install: &str) -> Option<[u8; 32]> {
        let node_public = *self.node_public.get()?;
        if !super::locked(&self.installs).remove(install) {
            return None;
        }
        self.confirmed.notify_one();
        Some(node_public)
    }

    /// Keep only the installs in `pending`; never adds one.
    fn retain(&self, pending: &BTreeSet<String>) {
        super::locked(&self.installs).retain(|install| pending.contains(install));
    }
}

/// Step 3 and 4 while the link serves: tell each peer left the node key, move
/// the told ones to it, and retire the old key once nobody is left or its
/// time is up. A peer counts as told when it took the key, or when it named
/// its own new key to this link first (it adopted too, and got this link's
/// key in the answer, `inbound.rs`). Returns then (or on an error it
/// logged); the caller keeps serving.
pub(super) async fn finish_retiring(
    state: &LinkState,
    overlay: &MeshOverlay,
    peers: &Peers,
    node_public: &[u8; 32],
    retry: Retry,
) {
    let retiring = overlay.retiring();
    let mut wait = retry.first;
    loop {
        let record = match adopted(state) {
            Ok(Some(record)) => record,
            Ok(None) => return,
            Err(error) => {
                eprintln!("cmux link: could not read {MARKER}: {error}");
                return;
            }
        };
        let deadline = record.retire_after.unwrap_or(0);
        let pairings = peers.snapshot();
        let still = retiring.installs();
        let left = Pairings {
            peers: pairings
                .peers
                .iter()
                .filter(|peer| record.pending.contains(&peer.install))
                .filter(|peer| still.contains(&peer.install))
                .cloned()
                .collect(),
        };
        let told = tell_all(overlay, node_public, &left, retry.tell_for).await;
        // A peer that adopted too names its new key in the answer.
        let target = peers.rekey_target();
        for (install, key) in &told {
            if let Some(key) = key
                && let Err(error) = target.apply(install, key)
            {
                eprintln!("cmux link: {install}'s new key in its answer was refused: {error}");
            }
        }
        let still = retiring.installs();
        let pending: BTreeSet<String> = record
            .pending
            .iter()
            .filter(|install| pairings.by_install(install).is_some())
            .filter(|install| still.contains(*install))
            .filter(|install| !told.iter().any(|(told, _)| told == *install))
            .cloned()
            .collect();
        let expired = now_secs() >= deadline;
        let moved = pending != record.pending;
        let result = if pending.is_empty() || expired {
            let record = Adopted { pending, ..record };
            retiring.retain(&BTreeSet::new());
            retire(state, record)
        } else if moved {
            let record = Adopted { pending: pending.clone(), ..record };
            retiring.retain(&pending);
            commit(state, &record)
        } else {
            Ok(())
        };
        if let Err(error) = result {
            eprintln!("cmux link: could not record the peers told this link's new key: {error}");
            return;
        }
        if moved || expired {
            // The told peers (or all, at the end) move to the node key.
            if let Err(error) = peers.reload(overlay).await {
                eprintln!("cmux link: moving told peers to the new key failed: {error}");
            }
        }
        if !state.has_link_key() {
            return;
        }
        let until_deadline = Duration::from_secs(deadline.saturating_sub(now_secs()));
        tokio::select! {
            () = tokio::time::sleep(wait.min(until_deadline)) => {}
            () = retiring.confirmed.notified() => {}
        }
        wait = (wait * 2).min(retry.cap);
    }
}

/// Tell every peer of `pairings` the key `new_public`, at once, each within
/// `budget`; the installs that took it, each with the new key it named back
/// when it adopted one too.
pub(super) async fn tell_all<O: super::dial::Overlay>(
    overlay: &O,
    new_public: &[u8; 32],
    pairings: &Pairings,
    budget: Duration,
) -> Vec<(String, Option<[u8; 32]>)> {
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
                io::Result::Ok(reply)
            };
            match tokio::time::timeout(budget, told).await {
                Ok(Ok(reply)) if reply.ok => {
                    let theirs = reply
                        .public_key
                        .as_deref()
                        .and_then(super::inbound::rekey_key)
                        .filter(|theirs| theirs != new_public);
                    Some((record.install.clone(), theirs))
                }
                _ => None,
            }
        }
    });
    futures_util::future::join_all(tells).await.into_iter().flatten().collect()
}

#[cfg(test)]
#[path = "key_adoption_tests.rs"]
mod tests;
