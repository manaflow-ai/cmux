//! One WireGuard key per machine: the link adopts the node key (`node.wg.key`
//! in the acpmux home, which the platform already knows as this machine's
//! key) and retires its own `private.key`.
//!
//! A link adopts when its key lock is this machine's acpmux home as the app
//! resolved and recorded it for this link (`key_lock::record_home`, from
//! [`crate::acp::key_lock_home`]: `ACPMUX_HOME`, else the build's home under
//! `~/.acpmux`; `serve`, which launchd starts with none of the app's
//! environment, never resolves it itself), or the directory a committed
//! adoption already serves, and it is not a server-enrolled link. A home
//! copied from another machine is never served from ([`refuse_copied`]). Any other
//! lock directory (its own state directory, or an explicit `--key-lock-dir`
//! elsewhere) keeps the link's own key. Every step runs under the held key
//! lock and the pairing file's lock ([`Pairings::lock`]), so a `link peer
//! add` lands either before the commit (and is told) or after it, when `link
//! show` already names the node key. Each step is safe to be killed after:
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
//! serves it as its own key again. A start that finds the record but not the
//! node key refuses to serve ([`node_key_kept`]): it never makes a fresh key
//! no peer was told.

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
use cmux_link::key_holder::{KeyFile, KeyHolder};
use cmux_link::pairing::{PairingRecord, Pairings};
use serde::{Deserialize, Serialize};
use tokio::io::AsyncWriteExt as _;
use zeroize::Zeroizing;

use super::control::{Peers, RekeyTarget};
use super::lines::read_line;
use super::mesh::MeshOverlay;
use super::state::{self, LinkState};

/// The commit record of an adoption, in the link's state directory.
pub(super) const MARKER: &str = "key-adopted.json";

/// The kept refusal of a link whose acpmux home was copied from another
/// machine ([`refuse_copied`]).
pub(super) const LINK_COPIED: &str = acpmux::cli::mesh_node_key::LINK_COPIED;

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
        // crash-allow: test-only; the migration test's child process stops here to prove each step survives a crash
        std::process::abort();
    }
    let _ = step;
}

fn now_secs() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |since| since.as_secs())
}

/// Whether `state`'s link adopts the node key in `lock_dir`: only when it is
/// `acpmux_home` (this machine's acpmux home as the app recorded it for this
/// link, `key_lock::record_home`), or the directory the link's committed
/// adoption already serves. Any other lock directory, an explicit
/// `--key-lock-dir` included, is not where the platform knows this machine's
/// key from.
pub(super) fn adopts(
    state: &LinkState,
    lock_dir: &Path,
    acpmux_home: Option<&Path>,
) -> io::Result<bool> {
    if state.config()?.server_identity.is_some() {
        return Ok(false);
    }
    let lock_dir = canonical(lock_dir);
    if lock_dir == canonical(state.dir()) {
        return Ok(false);
    }
    if adopted(state)?.is_some_and(|adopted| canonical(&adopted.key_dir) == lock_dir) {
        return Ok(true);
    }
    Ok(acpmux_home.is_some_and(|home| canonical(home) == lock_dir))
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
/// and 4 when nobody is left to tell), else the link's own key. `acpmux_home`
/// is this machine's acpmux home ([`adopts`]). The paired peers to tell are
/// read under the pairing file's lock, never from an earlier snapshot.
pub(super) async fn serve_key(
    state: &LinkState,
    holder: &KeyHolder,
    acpmux_home: Option<&Path>,
) -> anyhow::Result<ServeKey> {
    refuse_copied(state, acpmux_home)?;
    if !adopts(state, holder.dir(), acpmux_home)? {
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
    // Adopted under one lock dir, the link never adopts another dir's key (or makes one).
    if let Some(adopted) = adopted(state)?
        && canonical(&adopted.key_dir) != canonical(holder.dir())
    {
        anyhow::bail!(
            "key_lock_dir: this link serves this machine's node key in {}, not {}; run it with {} {}",
            adopted.key_dir.display(),
            holder.dir().display(),
            super::key_lock::FLAG,
            adopted.key_dir.display()
        );
    }
    adopt(state, holder)
}

/// Refuse to serve `key_adoption.cloned_home` when this link's identity, or
/// the node key it would serve, was copied here from another machine. Three
/// kinds of evidence, each kept where a later start reads it: the link's own
/// stamp ([`STAMP`], the box its state directory was set up on, compared by
/// acpmux's `mesh_node_key::stamped_here`); a node key recorded as copied in
/// the acpmux home (`mesh_node_key::serves_copied_key`, recorded by whoever
/// found the copy first, a `machine leave` included, before it removed the
/// machine record); and acpmux's own clone check of that home
/// (`mesh_node_key::home_copied`), which records what it finds. An adopted
/// link with no stamp fails closed (`key_adoption.unstamped`). The link's state directory came with it: its key,
/// its paired peers and its adoption are that machine's, and so may the node
/// key be (acpmux cannot replace a key an adoption names). Serving any of them
/// would answer that machine's peers from here, and an adoption would even
/// move them to this copy's key. The refusal is kept in the state directory
/// ([`LINK_COPIED`]): a new join of the home does not make the link's copied
/// pairings this machine's.
fn refuse_copied(state: &LinkState, acpmux_home: Option<&Path>) -> anyhow::Result<()> {
    use acpmux::cli::mesh_node_key as node_key;
    if state.config()?.server_identity.is_some() {
        return Ok(());
    }
    let kept = state.dir().join(LINK_COPIED);
    if kept.symlink_metadata().is_ok() {
        let named = std::fs::read(&kept)
            .ok()
            .and_then(|text| serde_json::from_slice::<serde_json::Value>(&text).ok())
            .and_then(|record| record.get("acpmux_home")?.as_str().map(PathBuf::from));
        return Err(copied_identity(state, &named.unwrap_or_else(|| state.dir().to_path_buf())));
    }
    let adopted_dir = adopted(state)?.map(|adopted| adopted.key_dir);
    // The link's own stamp: the box it was set up on travels with its state directory.
    let stamp_home = adopted_dir.as_deref().or(acpmux_home).unwrap_or(state.dir()).to_path_buf();
    match read_stamp(state) {
        Some(Some(stamp)) if !node_key::stamped_here(&stamp_home, &stamp) => {
            return Err(keep_copied(state, &stamp_home));
        }
        Some(_) => {}
        // No evidence left that this box is the one that adopted: fail closed (only builds
        // before the stamp adopted without one).
        None if adopted_dir.is_some() => anyhow::bail!(
            "key_adoption.unstamped: this link serves the node key in {home}, and nothing records \
             that this machine is the one it was adopted on: its state directory {dir} may have \
             been copied from another machine, so it does not serve. On the machine that set \
             it up, or to pair this one as a machine of its own: move {dir} aside, restart \
             cmux, and pair this machine with its peers again",
            home = stamp_home.display(),
            dir = state.dir().display(),
        ),
        None => write_stamp(state)?,
    }
    for home in acpmux_home.map(Path::to_path_buf).into_iter().chain(adopted_dir.clone()) {
        // Asked live (a copy of a copy carries a record of an older copy only), and it
        // records a copy it finds (`record_copied_key`) before it answers.
        if !node_key::home_copied(&home) {
            continue;
        }
        if adopted_dir.as_deref().is_some_and(|dir| canonical(dir) == canonical(&home)) {
            return Err(keep_copied(state, &home));
        }
        // A link of this box's own that would adopt the copied key: refused, not kept.
        anyhow::bail!(
            "key_adoption.cloned_home: the node key in {home} was copied here from another \
             machine, so this link does not adopt or serve it. Restart cmux: acpmux then gives \
             this machine its own node key, which this link adopts",
            home = home.display(),
        );
    }
    Ok(())
}

/// The link's stamp file: the box it was set up on (`mesh_node_key::box_stamp`).
pub(super) const STAMP: &str = "host-stamp.json";

/// The stamp in `state`'s directory: `None` when there is none, `Some(None)` for a box that
/// names no machine. A stamp that cannot be read is no stamp.
fn read_stamp(state: &LinkState) -> Option<Option<String>> {
    let text = std::fs::read(state.dir().join(STAMP)).ok()?;
    let record = serde_json::from_slice::<serde_json::Value>(&text).ok()?;
    Some(record.get("fingerprint")?.as_str().map(str::to_owned))
}

fn write_stamp(state: &LinkState) -> anyhow::Result<()> {
    stamp_once(state).context("stamp the link with this machine")
}

/// Stamp `state`'s link with this box when it has no stamp yet (`link init`, and a link set
/// up before stamps at its first start). An existing stamp is never rewritten.
pub(super) fn stamp_once(state: &LinkState) -> io::Result<()> {
    let path = state.dir().join(STAMP);
    if path.symlink_metadata().is_ok() {
        return Ok(());
    }
    let record = serde_json::json!({ "fingerprint": acpmux::cli::mesh_node_key::box_stamp() });
    state::write_private_synced(&path, record.to_string().as_bytes())
}

/// The link's name for the node key it adopted, standard base64 (`{"public_key": ...}`), written
/// before the adoption is committed and at every start that serves it. It travels with the
/// state directory, so a copy of the link names exactly the key that came with it
/// ([`keep_copied`]).
pub(super) const ADOPTED_KEY: &str = "adopted-node-key.json";

fn name_adopted_key(state: &LinkState, public: &[u8; 32]) -> anyhow::Result<()> {
    if named_adopted_key(state).as_ref() == Some(public) {
        return Ok(());
    }
    let record = serde_json::json!({ "public_key": STANDARD.encode(public) });
    state::write_private_synced(&state.dir().join(ADOPTED_KEY), record.to_string().as_bytes())
        .context("name the adopted node key")
}

/// The node key this link's state directory names as the one it adopted ([`ADOPTED_KEY`]);
/// `None` for one adopted by an older build, or never.
fn named_adopted_key(state: &LinkState) -> Option<[u8; 32]> {
    let text = std::fs::read(state.dir().join(ADOPTED_KEY)).ok()?;
    let record = serde_json::from_slice::<serde_json::Value>(&text).ok()?;
    let key = STANDARD.decode(record.get("public_key")?.as_str()?).ok()?;
    key.try_into().ok()
}

/// Keep the refusal ([`LINK_COPIED`]) and record as copied the node key this link proves was
/// copied with it, then the refusal itself. Only a key the copy's own evidence names is
/// marked: the one its state directory adopted ([`ADOPTED_KEY`]). The key now in the home may
/// be one acpmux settled and joined again here, registered, which is never marked (the next
/// start would delete it). A link adopted by an older build names none: the key in place is
/// marked unless it is provably this box's own (`mesh_node_key::node_key_own_here`).
fn keep_copied(state: &LinkState, home: &Path) -> anyhow::Error {
    use acpmux::cli::mesh_node_key as node_key;
    let record = serde_json::json!({ "acpmux_home": home });
    if let Err(error) =
        state::write_private_synced(&state.dir().join(LINK_COPIED), record.to_string().as_bytes())
    {
        eprintln!("cmux link: could not keep the copied-home refusal: {error}");
    }
    let recorded = match named_adopted_key(state) {
        Some(named) => node_key::record_copied_public_key(home, &named),
        None if home.join(KeyFile::Node.file_name()).exists()
            && !node_key::node_key_own_here(home) =>
        {
            node_key::record_copied_key(home)
        }
        None => Ok(()),
    };
    if let Err(error) = recorded {
        eprintln!("cmux link: could not record the copied node key: {error:#}");
    }
    copied_identity(state, home)
}

fn copied_identity(state: &LinkState, home: &Path) -> anyhow::Error {
    anyhow::anyhow!(
        "key_adoption.cloned_home: the acpmux home {home} was copied here from another machine, \
         and with it this link's WireGuard identity in {dir} (its key, its paired peers and the \
         node key it serves): that machine's. This copy never serves it, so that machine's \
         peers are never answered from here. To pair this copy as a machine of its own: move \
         {dir} aside, restart cmux (acpmux then gives this machine its own node key), paste a \
         new join line (`cmux host join`; `cmux machine add` on a signed-in machine makes one), \
         and pair this machine with its peers again",
        home = home.display(),
        dir = state.dir().display(),
    )
}

fn canonical(path: &Path) -> PathBuf {
    std::fs::canonicalize(path).unwrap_or_else(|_| path.to_owned())
}

/// Test hooks around the pairing file's lock in [`adopt`]: what runs just
/// before it is taken, and while it is held.
#[cfg(test)]
pub(super) mod hooks {
    use std::cell::RefCell;
    use std::thread::LocalKey;

    type Hook = RefCell<Option<Box<dyn FnOnce()>>>;

    thread_local! {
        pub(super) static BEFORE_PAIRINGS_LOCK: Hook = const { RefCell::new(None) };
        pub(super) static PAIRINGS_LOCKED: Hook = const { RefCell::new(None) };
    }

    pub(super) fn run(hook: &'static LocalKey<Hook>) {
        if let Some(hook) = hook.with(|hook| hook.borrow_mut().take()) {
            hook();
        }
    }
}

fn adopt(state: &LinkState, holder: &KeyHolder) -> anyhow::Result<ServeKey> {
    #[cfg(test)]
    hooks::run(&hooks::BEFORE_PAIRINGS_LOCK);
    // The paired peers, the record and the link key are read and written under the pairing
    // file's lock (`link peer add|remove`, inbound rekeys and install switches take it too): a
    // peer added concurrently is either in `pending` or added after the commit, when this
    // link's public key (`link show`) is already the node key.
    let _pairings_lock =
        Pairings::lock(&state.peers_path()).context("lock the pairing file to adopt")?;
    #[cfg(test)]
    hooks::run(&hooks::PAIRINGS_LOCKED);
    let earlier = adopted(state)?;
    if earlier.is_some() {
        node_key_kept(holder.dir())?;
    } else if acpmux::cli::mesh_node_key::rekey_pending(holder.dir()) {
        // A rotation whose answer was lost: the platform may hold the candidate, not the key
        // in place. The first adoption waits until acpmux finishes or drops it (its next
        // attach, with this link stopped); this link serves its own key meanwhile. Asked under
        // the key lock, held for this link's life, so no rekey begins before the commit.
        eprintln!(
            "cmux link: a rekey of this machine's node key is pending in {}; this link keeps its \
             own key and adopts the node key at a start after the rekey is finished",
            holder.dir().display()
        );
        return Ok(ServeKey { key: state.private_key(holder)?, retiring: None });
    }
    let (_, node) = acpmux::cli::mesh_node_key::load_or_create_held(holder.dir(), holder)
        .context("the node key this link adopts")?;
    finished(Step::NodeKey);
    let node_public = state::public_key(&node);
    name_adopted_key(state, &node_public)?;
    let old = if state.has_link_key() { Some(state.private_key(holder)?) } else { None };
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
    let paired: BTreeSet<String> = Pairings::load(&state.peers_path())?
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

/// Refuse to serve when the node key a committed adoption serves is gone from
/// `key_dir`. Every peer that was told knows this link by that key, and the
/// commit names no other key to tell them over: a fresh key would reach none
/// of them and tell none of them, so none is made. (acpmux never deletes,
/// replaces or rotates a node key an adoption record names, current or
/// archived with a signed-out install: `machine leave`, a copied home's new
/// key and `machine.tunnel.rekey` all ask `mesh_node_key::adoption_depends`
/// under the key lock.)
fn node_key_kept(key_dir: &Path) -> anyhow::Result<()> {
    let path = KeyFile::Node.path_in(key_dir);
    match std::fs::symlink_metadata(&path) {
        Ok(_) => Ok(()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => anyhow::bail!(
            "key_adoption.node_key_missing: this link serves this machine's node key, and {} is \
             gone; its paired peers know this link by that key only, so no new one is made. Put \
             the key back, or remove {} and pair this link's peers again",
            path.display(),
            MARKER
        ),
        Err(error) => Err(anyhow::Error::from(error).context("the adopted node key")),
    }
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
    /// Woken when an inbound rekey from one of them was answered.
    answered: tokio::sync::Notify,
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

    /// The node key, for an answer to `install` while it is kept on the
    /// retired key. It stays there until this link's own tell reaches it
    /// (on either key): a lost answer is asked for again, and the retired
    /// key still answers for it.
    pub(super) fn answer_for(&self, install: &str) -> Option<[u8; 32]> {
        let node_public = *self.node_public.get()?;
        if !super::locked(&self.installs).contains(install) {
            return None;
        }
        self.answered.notify_one();
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
        // On the retired key first. A peer no stream reached there may already have taken
        // the node key (its answer lost): a handshake from the current key is tried next to
        // the retired session, which keeps carrying the peer until that one is answered
        // (`WgMesh::probe_current`). A peer that said no keeps its session as it is; the
        // backoff below spaces the next try.
        let mut told = tell_each(overlay, node_public, &left, retry.tell_for).await;
        let target = peers.rekey_target();
        apply_answers(&target, &told).await;
        let unreached: Vec<PairingRecord> = told
            .iter()
            .filter(|(_, tell)| *tell == Tell::Unreached)
            .map(|(record, _)| record.clone())
            .collect();
        let mut moved_to_current = Vec::new();
        for record in &unreached {
            if overlay.probe_current(record, retry.tell_for).await {
                moved_to_current.push(record.clone());
            }
        }
        if !moved_to_current.is_empty() {
            let on_current = Pairings { peers: moved_to_current };
            let also = tell_each(overlay, node_public, &on_current, retry.tell_for).await;
            apply_answers(&target, &also).await;
            told.retain(|(record, _)| on_current.by_install(&record.install).is_none());
            told.extend(also);
        }
        let told: BTreeSet<String> = told
            .into_iter()
            .filter_map(|(record, tell)| matches!(tell, Tell::Took(_)).then_some(record.install))
            .collect();
        let Settled { moved, expired } = match settle(state, &record, &retiring, &told) {
            Ok(Some(settled)) => settled,
            // The record went or names another retired key (an install switch moved it).
            Ok(None) => return,
            Err(error) => {
                eprintln!(
                    "cmux link: could not record the peers told this link's new key: {error}"
                );
                return;
            }
        };
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
            () = retiring.answered.notified() => {}
        }
        wait = (wait * 2).min(retry.cap);
    }
}

/// What [`settle`] changed: the pending peers, or the end of the retirement.
struct Settled {
    moved: bool,
    expired: bool,
}

/// Step 3's record, or step 4, after the tells: from a fresh read of the
/// record and the pairing file, both under the pairing file's lock, so a
/// `link peer add|remove` or an install switch in the meantime is seen
/// before anything is written. `seen` is the record the tells were made
/// from; `None` when the record is gone or retires another key now.
fn settle(
    state: &LinkState,
    seen: &Adopted,
    retiring: &RetiringPeers,
    told: &BTreeSet<String>,
) -> io::Result<Option<Settled>> {
    let _pairings_lock = Pairings::lock(&state.peers_path())?;
    let Some(record) = adopted(state)? else { return Ok(None) };
    if record.retired_public_key != seen.retired_public_key {
        return Ok(None);
    }
    let pairings = Pairings::load(&state.peers_path())?;
    let still = retiring.installs();
    let pending: BTreeSet<String> = record
        .pending
        .iter()
        .filter(|install| pairings.by_install(install).is_some())
        .filter(|install| still.contains(*install))
        .filter(|install| !told.contains(*install))
        .cloned()
        .collect();
    let expired = now_secs() >= record.retire_after.unwrap_or(0);
    let moved = pending != record.pending;
    if pending.is_empty() || expired {
        retiring.retain(&BTreeSet::new());
        retire(state, Adopted { pending, ..record })?;
    } else if moved {
        retiring.retain(&pending);
        commit(state, &Adopted { pending, ..record })?;
    }
    Ok(Some(Settled { moved, expired }))
}

/// How one peer took a tell ([`tell_each`]).
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum Tell {
    /// It took the key; with the new key it named back when it adopted too.
    Took(Option<[u8; 32]>),
    /// A session reached it and it said no (a link without rekeys, or a
    /// refusal): the session works, so nothing about it changes.
    Refused,
    /// No stream reached it on this key in time.
    Unreached,
}

/// Apply the new keys peers named in their answers (they adopted too), each
/// only while the peer's stored record is still the one that was told.
async fn apply_answers(target: &RekeyTarget, told: &[(PairingRecord, Tell)]) {
    for (record, tell) in told {
        if let Tell::Took(Some(key)) = tell
            && let Some(from_key) = record.key()
            && let Err(error) = target.apply(&record.peer(), &from_key, key).await
        {
            eprintln!("cmux link: {}'s new key in its answer was refused: {error}", record.install);
        }
    }
}

/// Tell every peer of `pairings` the key `new_public`, at once, each within
/// `budget`: how each took it.
pub(super) async fn tell_each<O: super::dial::Overlay>(
    overlay: &O,
    new_public: &[u8; 32],
    pairings: &Pairings,
    budget: Duration,
) -> Vec<(PairingRecord, Tell)> {
    let request = line(&RekeyRequest { public_key: STANDARD.encode(new_public) });
    let tells = pairings.peers.iter().map(|record| {
        let request = request.clone();
        let remote = SocketAddr::new(IpAddr::V6(record.overlay_address()), LINK_PORT);
        async move {
            let told = async {
                let mut stream = match overlay.connect(remote).await {
                    Ok(stream) => stream,
                    Err(_) => return Tell::Unreached,
                };
                let asked = async {
                    let hello = line(&ServiceHello::paired(Service::Rekey));
                    stream.write_all(hello.as_bytes()).await?;
                    stream.write_all(request.as_bytes()).await?;
                    let answer = read_line(&mut stream, cmux_link::dial::MAX_LINE_BYTES).await?;
                    // Close at once: the receiver reloads (and drops this session) once it sees it.
                    let _ = stream.shutdown().await;
                    serde_json::from_str::<RekeyReply>(answer.trim())
                        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))
                };
                match asked.await {
                    Ok(reply) if reply.ok => Tell::Took(
                        reply
                            .public_key
                            .as_deref()
                            .and_then(super::inbound::rekey_key)
                            .filter(|theirs| theirs != new_public),
                    ),
                    _ => Tell::Refused,
                }
            };
            let tell = tokio::time::timeout(budget, told).await.unwrap_or(Tell::Unreached);
            (record.clone(), tell)
        }
    });
    futures_util::future::join_all(tells).await
}

/// [`tell_each`], keeping the installs that took the key (the tests read it this way).
#[cfg(test)]
pub(super) async fn tell_all<O: super::dial::Overlay>(
    overlay: &O,
    new_public: &[u8; 32],
    pairings: &Pairings,
    budget: Duration,
) -> Vec<(String, Option<[u8; 32]>)> {
    tell_each(overlay, new_public, pairings, budget)
        .await
        .into_iter()
        .filter_map(|(record, tell)| match tell {
            Tell::Took(theirs) => Some((record.install, theirs)),
            _ => None,
        })
        .collect()
}

#[cfg(test)]
#[path = "key_adoption_tests.rs"]
mod tests;
