//! This Mac's copy of the sync record (the [`Manifest`]) a push left on a
//! machine, kept in this Mac's state folder by local folder and machine
//! folder. A pull's three-way merge takes its base from this copy only: a
//! machine that claims the push sent a file it never sent would otherwise
//! choose which files here a pull overwrites or deletes. A pull with no copy
//! here, or whose machine's record differs from it, brings nothing back.
//!
//! The copy is a synced revision in a content-addressed store
//! ([`cmux_sync::two_way::Store`], RFD 0140 item 5): the record's bytes at
//! `<state>/link-sync/revisions/<sha256 of the bytes>`, and the pair's head,
//! `<state>/link-sync/<sha256 of folder NUL machine folder>.head`, naming the
//! revision. The revision is written before the head moves, so a crash or a
//! daemon restart between the two leaves the previous base whole; a head whose
//! revision is missing or whose bytes no longer hash to its name is an error,
//! never an empty base. A pair kept before the store (its record at
//! `<...>.json`) reads from there until its next save. Every file is 0600, its
//! folder 0700, written to a temporary name and renamed.

use std::io::Write as _;
use std::os::unix::fs::{DirBuilderExt as _, OpenOptionsExt as _};
use std::path::{Path, PathBuf};

use anyhow::{Context as _, bail};
use sha2::{Digest as _, Sha256};

use super::Manifest;

/// No copy of the record is kept here for this folder and machine folder.
#[derive(Debug)]
pub(super) struct NoBase;

impl std::fmt::Display for NoBase {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("no sync push from this Mac left this folder on the machine")
    }
}

impl std::error::Error for NoBase {}

/// The machine's record differs from the copy kept here.
#[derive(Debug)]
pub(super) struct Mismatch;

impl std::fmt::Display for Mismatch {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(
            "the machine's sync record differs from the one this Mac kept; nothing was brought back",
        )
    }
}

impl std::error::Error for Mismatch {}

/// The name this Mac keeps `local` synced to `remote_root` under: the
/// SHA-256 of the folder, a NUL and the machine folder.
pub(super) fn key(local: &Path, remote_root: &str) -> String {
    let mut key = Sha256::new();
    key.update(local.as_os_str().as_encoded_bytes());
    key.update([0]);
    key.update(remote_root.as_bytes());
    key.finalize().iter().map(|byte| format!("{byte:02x}")).collect()
}

fn path_of(local: &Path, remote_root: &str) -> anyhow::Result<PathBuf> {
    let Some(state) = cmux_tui_core::platform::workspace_state_dir() else {
        bail!("this Mac has no state folder to keep the sync record in");
    };
    let name = key(local, remote_root);
    Ok(state.join("link-sync").join(format!("{name}.json")))
}

/// The folder this Mac keeps the packs a push of `local` to `remote_root`
/// made in ([`super::packs`]): next to the record, as `<...>.packs`.
pub(super) fn packs_dir(local: &Path, remote_root: &str) -> anyhow::Result<PathBuf> {
    Ok(path_of(local, remote_root)?.with_extension("packs"))
}

/// Whether a push from this Mac left `local` at `remote_root` before (a base is kept for it): a
/// copy then is a re-push, never a fresh one. No state folder reads as kept, the safe side.
pub(super) fn kept(local: &Path, remote_root: &str) -> bool {
    let Ok(store) = Revisions::open() else { return true };
    use cmux_sync::two_way::Store as _;
    store.head(&key(local, remote_root)).is_some()
        || path_of(local, remote_root).map_or(true, |path| path.exists())
}

/// The store the bases are kept in: `<state>/link-sync`, revisions by id, one head per pair.
struct Revisions {
    dir: PathBuf,
    /// The first write that failed: the trait's writes return nothing.
    error: Option<anyhow::Error>,
}

impl Revisions {
    fn open() -> anyhow::Result<Self> {
        let Some(state) = cmux_tui_core::platform::workspace_state_dir() else {
            bail!("this Mac has no state folder to keep the sync record in");
        };
        Ok(Self { dir: state.join("link-sync"), error: None })
    }

    fn revision(&self, id: &str) -> PathBuf {
        self.dir.join("revisions").join(id)
    }

    fn head_path(&self, pair: &str) -> PathBuf {
        self.dir.join(format!("{pair}.head"))
    }

    fn fail(&mut self, error: anyhow::Error) {
        self.error.get_or_insert(error);
    }

    /// The base kept for `pair`: its head's revision, checked against its name, else a record
    /// kept before the store. None when neither is kept.
    fn read(&self, pair: &str, legacy: &Path) -> anyhow::Result<Option<Vec<u8>>> {
        use cmux_sync::two_way::Store as _;
        if let Some(id) = self.head(pair) {
            let Some(bytes) = self.get(&id) else {
                bail!("the sync record {id} this folder's head names is missing on this Mac");
            };
            if sha256_hex(&bytes) != id {
                bail!("the sync record {id} on this Mac is damaged");
            }
            return Ok(Some(bytes));
        }
        match std::fs::read(legacy) {
            Ok(bytes) => Ok(Some(bytes)),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(error) => Err(error).with_context(|| format!("cannot read {}", legacy.display())),
        }
    }
}

impl cmux_sync::two_way::Store for Revisions {
    fn put(&mut self, id: &str, bytes: Vec<u8>) {
        let path = self.revision(id);
        // Content-addressed: one already there under this name holds these bytes.
        if self.get(id).is_some_and(|there| there == bytes) {
            return;
        }
        if let Err(error) = write_atomic(&path, &bytes) {
            self.fail(error);
        }
    }

    fn get(&self, id: &str) -> Option<Vec<u8>> {
        std::fs::read(self.revision(id)).ok()
    }

    fn head(&self, pair: &str) -> Option<String> {
        let text = std::fs::read_to_string(self.head_path(pair)).ok()?;
        Some(text.trim().to_owned()).filter(|id| !id.is_empty())
    }

    fn set_head(&mut self, pair: &str, id: &str) {
        if self.error.is_some() {
            return;
        }
        let path = self.head_path(pair);
        if let Err(error) = write_atomic(&path, format!("{id}\n").as_bytes()) {
            self.fail(error);
        }
    }
}

fn sha256_hex(bytes: &[u8]) -> String {
    Sha256::digest(bytes).iter().map(|byte| format!("{byte:02x}")).collect()
}

/// The base kept for `local` synced to `remote_root`, as bytes: None when none is kept.
fn read_kept(local: &Path, remote_root: &str) -> anyhow::Result<Option<Vec<u8>>> {
    Revisions::open()?.read(&key(local, remote_root), &path_of(local, remote_root)?)
}

/// Keeps `manifest` as the base of `local` synced to `remote_root`: a new revision, then the
/// pair's head ([`cmux_sync::two_way::Store`]).
pub(super) fn save(local: &Path, remote_root: &str, manifest: &Manifest) -> anyhow::Result<()> {
    use cmux_sync::two_way::Store as _;
    let bytes = serde_json::to_vec(manifest)?;
    let id = sha256_hex(&bytes);
    let mut store = Revisions::open()?;
    store.put(&id, bytes);
    store.set_head(&key(local, remote_root), &id);
    match store.error {
        Some(error) => Err(error),
        None => Ok(()),
    }
}

/// Writes `bytes` at `path` (0600, its folder 0700) by a temporary name and a rename.
fn write_atomic(path: &Path, bytes: &[u8]) -> anyhow::Result<()> {
    let dir = path.parent().context("no state folder")?;
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(dir)
        .with_context(|| format!("cannot make {}", dir.display()))?;
    let part = path.with_extension(format!("{}.part", std::process::id()));
    let _ = std::fs::remove_file(&part);
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(&part)
        .with_context(|| format!("cannot write {}", part.display()))?;
    file.write_all(bytes)?;
    file.sync_all()?;
    std::fs::rename(&part, path).with_context(|| format!("cannot write {}", path.display()))
}

/// A folder that moved machine to machine (`cmux link sync relay`, which copies the machine's own
/// record with it): the base kept for `from_root` is the base for `to_root` too. Nothing when no
/// push left one.
pub(super) fn carry(local: &Path, from_root: &str, to_root: &str) -> anyhow::Result<bool> {
    let Some(kept) = read_kept(local, from_root)? else { return Ok(false) };
    let kept: Manifest =
        serde_json::from_slice(&kept).context("the kept sync record is not a sync record")?;
    save(local, to_root, &kept)?;
    Ok(true)
}

/// The base of `local` synced to `remote_root`, checked against the
/// machine's own record (`machine`, None when it has none).
pub(super) fn trusted(
    local: &Path,
    remote_root: &str,
    machine: Option<&[u8]>,
) -> anyhow::Result<Manifest> {
    let Some(kept) = read_kept(local, remote_root)? else { return Err(NoBase.into()) };
    let kept: Manifest =
        serde_json::from_slice(&kept).context("the kept sync record is not a sync record")?;
    // A projected folder's base was made here when it was projected: the machine has no record of
    // it until its first Bring Back writes one there.
    if machine.is_none() && kept.projected {
        return Ok(kept);
    }
    let machine: Option<Manifest> = machine.and_then(|bytes| serde_json::from_slice(bytes).ok());
    if machine.as_ref() != Some(&kept) {
        return Err(Mismatch.into());
    }
    Ok(kept)
}

/// The machine's record of the push a pull merges against: its path, the record, and whether it is
/// the plain record (`.cmux-sync.json`) of a git folder here. A git folder's push records in
/// `.git/cmux-sync.json`, except a first pass of one past the copy's limits (`size_cap`), which
/// sends no history and records as a plain copy: with no `.git` record on the machine, the plain
/// one is read (cmuxterm-hq#11697: Bring Back Local after a first pass stopped on a record
/// mismatch, and the chat's edits never came back). Either is trusted only as this Mac kept it
/// ([`trusted`]). A plain record of a git folder brings back files only: no branch or index, and
/// one this Mac kept with git state is a mismatch.
pub(super) fn machine_record(
    remote: &mut super::remote::Remote,
    local: &Path,
    remote_root: &str,
    in_git: bool,
) -> anyhow::Result<(String, Manifest, bool)> {
    let (path, record, plain_in_git) = record_of(remote, remote_root, in_git)?;
    let manifest = trusted(local, remote_root, record.as_deref())?;
    if plain_in_git && manifest.git.is_some() {
        return Err(Mismatch.into());
    }
    Ok((path, manifest, plain_in_git))
}

/// [`machine_record`]'s read: the record's path and bytes, and whether it is the plain one in git.
fn record_of(
    remote: &mut super::remote::Remote,
    remote_root: &str,
    in_git: bool,
) -> anyhow::Result<(String, Option<Vec<u8>>, bool)> {
    let plain = format!("{remote_root}/.cmux-sync.json");
    if !in_git {
        let record = remote.read(&plain)?;
        return Ok((plain, record, false));
    }
    let git = format!("{remote_root}/.git/cmux-sync.json");
    if let Some(record) = remote.read(&git)? {
        return Ok((git, Some(record), false));
    }
    match remote.read(&plain)? {
        Some(record) => Ok((plain, Some(record), true)),
        None => Ok((git, None, false)),
    }
}
