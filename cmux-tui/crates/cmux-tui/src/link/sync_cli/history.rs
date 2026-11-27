//! Snapshots of a synced folder on this Mac, and putting it back
//! (`cmux link sync history|undo|restore LOCAL REMOTE`).
//!
//! After every push and around every pull that changes something here,
//! this Mac keeps a snapshot of the folder's synced paths: a small manifest
//! of each file's SHA-256 and permissions, each symlink's text and, in git,
//! the branch, HEAD commit and staged changes (the index file, kept as a
//! blob). The newest [`KEEP`] are kept per
//! local folder and machine folder in
//! `<state>/link-sync/history/<key>/<seq>.json` (the key is the one the base
//! record uses, [`super::base`]).
//!
//! A snapshot points at file contents by SHA-256 only. The bytes are blobs
//! in `<state>/link-sync/blobs/<aa>/<sha256>` (0600), shared by every folder
//! and named the way the content-addressed store in Cloud names them (a
//! file's lowercase hex SHA-256, `/v1/sync/blobs/<sha256>`), so a snapshot's
//! files can be looked up in either. A blob is kept when a push writes a
//! file, and before and after a pull replaces one; each is checked against
//! its hash before it is renamed into place. Blobs no kept snapshot names
//! go once they are an hour old (younger ones may belong to a sync still
//! going on).
//!
//! Inside git only the working tree is snapshotted: the repository's own
//! files have git's history. Restoring moves the branch back only while it
//! is still where the newest snapshot left it, and the index only while
//! what is staged is still the newest snapshot's. Nothing is written into
//! the repository: a snapshot never changes what the next push sends.
//!
//! A restore changes only paths a sync changed here since the snapshot (a
//! pull or another restore; a push changes nothing here) whose state differs
//! between the snapshot and the newest one, and git only when a sync since
//! moved it: what this Mac changed itself is never put back. Each of those
//! paths must be here still as the newest snapshot says: a file changed here since the last sync stops it
//! and nothing changes (`sync_restore_conflict`). It goes through the same
//! transaction as a pull ([`super::place`]), so a failure puts everything
//! back. `undo` restores the snapshot before the newest one that differs
//! from it; after an undo, the next undo goes one further back. The machine
//! is not touched: the next push sends what the restore put back.

use std::collections::{BTreeMap, BTreeSet};
use std::io::Write as _;
use std::os::unix::fs::{DirBuilderExt as _, OpenOptionsExt as _};
use std::path::{Path, PathBuf};

use anyhow::{Context as _, bail};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest as _, Sha256};

use super::local::GitDirs;
use super::place::{self, Dir, Entry, Expected, Transaction};
use super::{Manifest, base, git_back};

/// Snapshots kept per folder.
pub(super) const KEEP: usize = 10;

/// A blob no snapshot names is removed once it is this old.
const BLOB_GRACE: std::time::Duration = std::time::Duration::from_secs(60 * 60);

/// One path of a snapshot.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub(super) enum Held {
    File { sha256: String, permissions: u32 },
    Link { text: String },
}

/// The git state of a snapshot.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub(super) struct GitAt {
    #[serde(default)]
    pub head_ref: Option<String>,
    #[serde(default)]
    pub head: Option<String>,
    /// SHA-256 of `git ls-files --stage -z`: what is staged.
    #[serde(default)]
    pub staged: String,
    /// The blob of the index file, which a restore puts back.
    #[serde(default)]
    pub index: Option<String>,
}

impl GitAt {
    /// The same branch, commit and staged changes (the index file's bytes
    /// also change with git's own stat refreshes).
    fn same(&self, other: &Self) -> bool {
        self.head_ref == other.head_ref && self.head == other.head && self.staged == other.staged
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub(super) struct Snapshot {
    pub version: u32,
    pub seq: u64,
    /// Seconds since 1970.
    pub at: u64,
    /// `push`, `before_pull`, `pull` or `restore`.
    pub action: String,
    /// For a restore: the snapshot it put back.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub restored: Option<u64>,
    pub paths: BTreeMap<String, Held>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub git: Option<GitAt>,
    /// The paths this sync changed here (a pull or a restore; a push
    /// changes nothing here). Only these are ever put back: a path a sync
    /// never changed is this Mac's own, whatever a snapshot inherited for it.
    #[serde(default, skip_serializing_if = "BTreeSet::is_empty")]
    pub touched: BTreeSet<String>,
    /// Whether this sync moved the branch or the staged changes here.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub moved_git: bool,
}

impl Snapshot {
    /// Whether `other` is the same folder state.
    fn same_state(&self, other: &Self) -> bool {
        self.paths == other.paths
            && match (&self.git, &other.git) {
                (Some(this), Some(that)) => this.same(that),
                (this, that) => this.is_none() && that.is_none(),
            }
    }
}

fn link_sync_dir() -> anyhow::Result<PathBuf> {
    let Some(state) = cmux_tui_core::platform::workspace_state_dir() else {
        bail!("this Mac has no state folder to keep sync snapshots in");
    };
    Ok(state.join("link-sync"))
}

fn history_dir(local: &Path, remote_root: &str) -> anyhow::Result<PathBuf> {
    Ok(link_sync_dir()?.join("history").join(base::key(local, remote_root)))
}

/// Where the blob of `sha256` is kept.
pub(super) fn blob_path(sha256: &str) -> anyhow::Result<PathBuf> {
    if sha256.len() != 64 || !sha256.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        bail!("{sha256} is not a SHA-256");
    }
    let Some(shard) = sha256.get(..2) else { bail!("{sha256} is not a SHA-256") };
    Ok(link_sync_dir()?.join("blobs").join(shard).join(sha256))
}

/// The blob of `sha256`, when this Mac keeps it.
pub(super) fn blob(sha256: &str) -> Option<PathBuf> {
    blob_path(sha256).ok().filter(|path| path.is_file())
}

fn make_dir(path: &Path) -> anyhow::Result<()> {
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(path)
        .with_context(|| format!("cannot make {}", path.display()))
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

/// Keeps the file at `relative` under `root` (read through folder handles,
/// never a symlink) as the blob of `sha256`, when it still has that hash.
/// Whether the blob is there afterwards.
pub(super) fn keep_blob(root: &Dir, relative: &str, sha256: &str) -> bool {
    keep_blob_inner(root, relative, sha256).unwrap_or(false)
}

fn keep_blob_inner(root: &Dir, relative: &str, sha256: &str) -> anyhow::Result<bool> {
    let path = blob_path(sha256)?;
    if path.is_file() {
        // Fresh again, so a sweep running now leaves it.
        let _ = std::fs::File::options()
            .append(true)
            .open(&path)
            .and_then(|file| file.set_modified(std::time::SystemTime::now()));
        return Ok(true);
    }
    let Some((dir, name)) = place::parent_of(root, relative)? else { return Ok(false) };
    if !matches!(dir.entry(&name)?, Entry::File { .. }) {
        return Ok(false);
    }
    let mut source = dir.open_file(&name)?;
    let folder = path.parent().context("no blob folder")?;
    make_dir(folder)?;
    let part = folder.join(format!(".{sha256}.{}.part", std::process::id()));
    let _ = std::fs::remove_file(&part);
    let mut out = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(&part)?;
    let mut hasher = Sha256::new();
    let mut buffer = vec![0u8; 1 << 20];
    loop {
        let read = std::io::Read::read(&mut source, &mut buffer)?;
        if read == 0 {
            break;
        }
        let chunk = buffer.get(..read).context("the read went past its buffer")?;
        hasher.update(chunk);
        out.write_all(chunk)?;
    }
    if hex(&hasher.finalize()) != sha256 {
        drop(out);
        let _ = std::fs::remove_file(&part);
        return Ok(false);
    }
    out.sync_all()?;
    std::fs::rename(&part, &path)?;
    Ok(true)
}

/// Keeps the file at `path` (not a symlink) as a blob; its SHA-256.
fn keep_file(path: &Path) -> Option<String> {
    let mut source =
        std::fs::OpenOptions::new().read(true).custom_flags(libc::O_NOFOLLOW).open(path).ok()?;
    let blobs = link_sync_dir().ok()?.join("blobs");
    make_dir(&blobs).ok()?;
    let part = blobs.join(format!(".file.{}.part", std::process::id()));
    let _ = std::fs::remove_file(&part);
    let mut out = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(&part)
        .ok()?;
    let mut hasher = Sha256::new();
    let mut buffer = vec![0u8; 1 << 20];
    let copied = (|| -> std::io::Result<()> {
        loop {
            let read = std::io::Read::read(&mut source, &mut buffer)?;
            if read == 0 {
                return out.sync_all();
            }
            let chunk = buffer
                .get(..read)
                .ok_or_else(|| std::io::Error::other("the read went past its buffer"))?;
            hasher.update(chunk);
            out.write_all(chunk)?;
        }
    })();
    let sha256 = hex(&hasher.finalize());
    let placed = copied.is_ok()
        && blob_path(&sha256)
            .ok()
            .and_then(|path| {
                make_dir(path.parent()?).ok()?;
                std::fs::rename(&part, path).ok()
            })
            .is_some();
    let _ = std::fs::remove_file(&part);
    placed.then_some(sha256)
}

/// A working-tree path of a record (nothing in the top repository folder,
/// not the record itself).
pub(super) fn is_worktree_path(relative: &str) -> bool {
    relative != ".git"
        && !relative.starts_with(".git/")
        && relative != ".cmux-sync.json"
        && !relative.ends_with(".cmux-sync-part")
}

/// The paths of a record as a snapshot holds them: its working-tree files
/// and symlinks (by this Mac's own text).
pub(super) fn paths_of(manifest: &Manifest) -> BTreeMap<String, Held> {
    let mut paths: BTreeMap<String, Held> = manifest
        .files
        .iter()
        .filter(|(relative, _)| is_worktree_path(relative))
        .map(|(relative, pushed)| {
            (
                relative.clone(),
                Held::File { sha256: pushed.sha256.clone(), permissions: pushed.permissions },
            )
        })
        .collect();
    for (relative, linked) in &manifest.links {
        if is_worktree_path(relative) {
            let text = linked.here.clone().unwrap_or_else(|| linked.target.clone());
            paths.insert(relative.clone(), Held::Link { text });
        }
    }
    paths
}

/// The git state of the working copy at `local` now; None outside git.
pub(super) fn git_now(local: &Path) -> Option<GitAt> {
    if !matches!(GitDirs::of(local), Ok(Some(_))) {
        return None;
    }
    let dirs = GitDirs::of(local).ok().flatten()?;
    let base = git_back::base_of(local).ok()?;
    let index = keep_file(&dirs.own.join("index"));
    Some(GitAt { head_ref: base.head_ref, head: base.head, staged: base.staged, index })
}

/// Every snapshot kept for `local` synced to `remote_root`, oldest first.
pub(super) fn list(local: &Path, remote_root: &str) -> anyhow::Result<Vec<Snapshot>> {
    read_dir_snapshots(&history_dir(local, remote_root)?)
}

fn read_dir_snapshots(dir: &Path) -> anyhow::Result<Vec<Snapshot>> {
    let entries = match std::fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => return Err(error).with_context(|| format!("cannot read {}", dir.display())),
    };
    let mut snapshots = Vec::new();
    for entry in entries.filter_map(Result::ok) {
        let name = entry.file_name().to_string_lossy().into_owned();
        if !name.ends_with(".json") {
            continue;
        }
        let Ok(bytes) = std::fs::read(entry.path()) else { continue };
        if let Ok(snapshot) = serde_json::from_slice::<Snapshot>(&bytes) {
            snapshots.push(snapshot);
        }
    }
    snapshots.sort_by_key(|snapshot| snapshot.seq);
    Ok(snapshots)
}

/// The newest snapshot of `local` synced to `remote_root`.
pub(super) fn newest(local: &Path, remote_root: &str) -> Option<Snapshot> {
    list(local, remote_root).ok().and_then(|mut all| all.pop())
}

/// What a sync changed here: its paths, and whether it moved git.
#[derive(Default)]
pub(super) struct Changed {
    pub paths: BTreeSet<String>,
    pub git: bool,
}

/// Keeps a snapshot of `paths` and `git` for `local` synced to
/// `remote_root`, unless it is the newest one's state again (a `restore`
/// is always kept: it moves the undo point). Older ones beyond [`KEEP`] go,
/// and so do the blobs no snapshot names. Its number, or None when nothing
/// new was kept.
pub(super) fn record(
    local: &Path,
    remote_root: &str,
    action: &str,
    paths: BTreeMap<String, Held>,
    git: Option<GitAt>,
    restored: Option<u64>,
    changed: Changed,
) -> anyhow::Result<Option<u64>> {
    let dir = history_dir(local, remote_root)?;
    make_dir(&dir)?;
    let mut all = read_dir_snapshots(&dir)?;
    let seq = all.last().map_or(1, |last| last.seq + 1);
    let at = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |since| since.as_secs());
    let touched = changed.paths.into_iter().filter(|relative| is_worktree_path(relative)).collect();
    let moved_git = changed.git;
    let snapshot = Snapshot {
        version: 1,
        seq,
        at,
        action: action.into(),
        restored,
        paths,
        git,
        touched,
        moved_git,
    };
    if restored.is_none() && all.last().is_some_and(|last| last.same_state(&snapshot)) {
        return Ok(None);
    }
    let path = dir.join(format!("{seq:016}.json"));
    let part = dir.join(format!(".{seq:016}.{}.part", std::process::id()));
    let _ = std::fs::remove_file(&part);
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(&part)
        .with_context(|| format!("cannot write {}", part.display()))?;
    file.write_all(&serde_json::to_vec(&snapshot)?)?;
    file.sync_all()?;
    std::fs::rename(&part, &path)?;
    all.push(snapshot);
    while all.len() > KEEP {
        let old = all.remove(0);
        let _ = std::fs::remove_file(dir.join(format!("{:016}.json", old.seq)));
    }
    sweep_blobs();
    Ok(Some(seq))
}

/// Removes the blobs no kept snapshot of any folder names, once they are
/// older than [`BLOB_GRACE`].
fn sweep_blobs() {
    let Ok(root) = link_sync_dir() else { return };
    let mut named: BTreeSet<String> = BTreeSet::new();
    let Ok(folders) = std::fs::read_dir(root.join("history")) else { return };
    for folder in folders.filter_map(Result::ok) {
        let Ok(snapshots) = read_dir_snapshots(&folder.path()) else { return };
        for snapshot in snapshots {
            for held in snapshot.paths.values() {
                if let Held::File { sha256, .. } = held {
                    named.insert(sha256.clone());
                }
            }
            if let Some(index) = snapshot.git.and_then(|git| git.index) {
                named.insert(index);
            }
        }
    }
    let Ok(prefixes) = std::fs::read_dir(root.join("blobs")) else { return };
    let now = std::time::SystemTime::now();
    for prefix in prefixes.filter_map(Result::ok) {
        let Ok(blobs) = std::fs::read_dir(prefix.path()) else { continue };
        for blob in blobs.filter_map(Result::ok) {
            let name = blob.file_name().to_string_lossy().into_owned();
            if named.contains(&name) {
                continue;
            }
            let old = blob
                .metadata()
                .and_then(|meta| meta.modified())
                .ok()
                .and_then(|modified| now.duration_since(modified).ok())
                .is_some_and(|age| age > BLOB_GRACE);
            if old {
                let _ = std::fs::remove_file(blob.path());
            }
        }
    }
}

/// What this Mac has at `relative` now, as a snapshot would hold it; Err
/// with the path's name when it is anything else (a folder, a special
/// file, a path through a symlink).
fn held_here(root: &Dir, relative: &str) -> anyhow::Result<Result<Option<Held>, ()>> {
    let (dir, name) = match place::parent_of(root, relative) {
        Ok(Some(found)) => found,
        Ok(None) => return Ok(Ok(None)),
        Err(error) if matches!(error.raw_os_error(), Some(libc::ENOTDIR | libc::ELOOP)) => {
            return Ok(Err(()));
        }
        Err(error) => return Err(error.into()),
    };
    Ok(match dir.entry(&name)? {
        Entry::Missing => Ok(None),
        Entry::File { mode } => {
            let mut file = dir.open_file(&name)?;
            let mut hasher = Sha256::new();
            std::io::copy(&mut file, &mut hasher)?;
            Ok(Some(Held::File {
                sha256: hex(&hasher.finalize()),
                permissions: super::local::permissions_of(mode),
            }))
        }
        Entry::Link => dir.read_link(&name).map(|text| Some(Held::Link { text })).map_err(drop),
        Entry::Dir | Entry::Other => Err(()),
    })
}

/// Which snapshot `which` names: a number, or the undo target.
pub(super) enum Which {
    Undo,
    Seq(u64),
}

/// A restore that changed nothing, and why.
#[derive(Debug)]
pub(super) struct Refused {
    pub code: &'static str,
    pub error: String,
    pub paths: Vec<String>,
}

impl std::fmt::Display for Refused {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.error)
    }
}

impl std::error::Error for Refused {}

fn refused(code: &'static str, error: String, paths: Vec<String>) -> anyhow::Error {
    Refused { code, error, paths }.into()
}

/// What putting `target` back changes, out of `all` (oldest first, ending
/// with the newest): the paths that differ between it and the newest that a
/// sync after it changed here, and whether a sync after it moved git.
fn plan(all: &[Snapshot], target: &Snapshot) -> (Vec<String>, bool) {
    let Some(newest) = all.last() else { return (Vec::new(), false) };
    let since: Vec<&Snapshot> = all.iter().filter(|snapshot| snapshot.seq > target.seq).collect();
    let touched: BTreeSet<&String> = since.iter().flat_map(|snapshot| &snapshot.touched).collect();
    let changing = touched
        .into_iter()
        .filter(|relative| newest.paths.get(*relative) != target.paths.get(*relative))
        .cloned()
        .collect();
    let git = since.iter().any(|snapshot| snapshot.moved_git)
        && match (&newest.git, &target.git) {
            (Some(now), Some(then)) => !now.same(then),
            _ => false,
        };
    (changing, git)
}

/// The snapshot `which` names, out of `all` (oldest first, not empty).
fn target<'a>(all: &'a [Snapshot], which: &Which) -> anyhow::Result<&'a Snapshot> {
    let newest = all.last().context("no snapshot")?;
    match which {
        Which::Seq(seq) => all.iter().find(|snapshot| snapshot.seq == *seq).ok_or_else(|| {
            refused("sync_no_snapshot", format!("no snapshot {seq} is kept"), Vec::new())
        }),
        Which::Undo => {
            // After an undo, the state is the snapshot it put back: the next
            // one goes further back from there. One that would change
            // nothing a sync changed is passed over.
            let from = newest.restored.unwrap_or(newest.seq);
            all.iter()
                .rev()
                .filter(|snapshot| snapshot.seq < from && snapshot.action != "restore")
                .filter(|snapshot| !snapshot.same_state(newest))
                .find(|snapshot| {
                    let (changing, git) = plan(all, snapshot);
                    !changing.is_empty() || git
                })
                .ok_or_else(|| {
                    refused(
                        "sync_no_snapshot",
                        "there is nothing earlier to undo to".into(),
                        vec![],
                    )
                })
        }
    }
}

/// Puts `local` (synced to `remote_root`) back as the snapshot `which`
/// names. Its answer line.
pub(super) fn restore(local: &Path, remote_root: &str, which: &Which) -> anyhow::Result<Value> {
    let local =
        std::fs::canonicalize(local).with_context(|| format!("cannot open {}", local.display()))?;
    let all = list(&local, remote_root)?;
    if all.is_empty() {
        return Err(refused(
            "sync_no_snapshot",
            "no sync of this folder to that machine folder has a snapshot on this Mac".into(),
            Vec::new(),
        ));
    }
    let newest = all.last().context("no snapshot")?.clone();
    let target = target(&all, which)?.clone();
    let root = Dir::open(&local)?;

    // The paths a sync since changed that differ, each here still as the
    // newest snapshot says.
    let (changing, git_changing) = plan(&all, &target);
    let mut changed_here = Vec::new();
    for relative in &changing {
        if held_here(&root, relative)? != Ok(newest.paths.get(relative).cloned()) {
            changed_here.push(relative.clone());
        }
    }
    if !changed_here.is_empty() {
        return Err(refused(
            "sync_restore_conflict",
            format!(
                "{} changed here since the last sync; nothing was put back",
                changed_here.join(", ")
            ),
            changed_here,
        ));
    }
    let missing: Vec<String> = changing
        .iter()
        .filter(|relative| match target.paths.get(*relative) {
            Some(Held::File { sha256, .. }) => blob(sha256).is_none(),
            _ => false,
        })
        .cloned()
        .collect();
    if !missing.is_empty() {
        return Err(refused(
            "sync_restore_missing",
            format!("this Mac no longer keeps {}; nothing was put back", missing.join(", ")),
            missing,
        ));
    }

    let git = GitDirs::of(&local)?;
    let staging = super::pull::Staging::make(git.as_ref().map_or(&local, |dirs| &dirs.own))?;
    let mut transaction = Transaction::new(&local, &staging.0)?;
    let applied = apply(&mut transaction, &staging, &changing, &newest, &target);
    let (written, deleted) = match applied {
        Ok(counts) => counts,
        Err(error) => return Err(rolled_back(transaction, &staging, error)),
    };
    let git_target = if git_changing { target.git.as_ref() } else { None };
    let git_moved = match restore_git(&local, newest.git.as_ref(), git_target) {
        Ok(moved) => moved,
        Err(error) => return Err(rolled_back(transaction, &staging, error)),
    };
    transaction.finish();
    // The folder now: the newest state with the changed paths put back.
    let mut paths = newest.paths.clone();
    for relative in &changing {
        match target.paths.get(relative) {
            Some(held) => paths.insert(relative.clone(), held.clone()),
            None => paths.remove(relative),
        };
    }
    let git_after = if git_moved { git_now(&local) } else { newest.git.clone() };
    let recorded = record(
        &local,
        remote_root,
        "restore",
        paths,
        git_after,
        Some(target.seq),
        Changed { paths: changing.iter().cloned().collect(), git: git_moved },
    )?;
    Ok(json!({
        "ok": true,
        "restored": target.seq,
        "written": written,
        "deleted": deleted,
        "git_moved": git_moved,
        "snapshot": recorded,
    }))
}

/// Changes each of `changing` from `newest`'s state to `target`'s through
/// `transaction`: written and deleted.
fn apply(
    transaction: &mut Transaction,
    staging: &super::pull::Staging,
    changing: &[String],
    newest: &Snapshot,
    target: &Snapshot,
) -> anyhow::Result<(u64, u64)> {
    let (mut written, mut deleted) = (0u64, 0u64);
    for relative in changing {
        let now = newest.paths.get(relative);
        let then = target.paths.get(relative);
        // What is here goes first, unless a file is replaced by a file.
        match (now, then) {
            (Some(Held::Link { text }), _) => transaction.remove_link(relative, text)?,
            (Some(Held::File { sha256, permissions }), None | Some(Held::Link { .. })) => {
                let expected = Expected { sha256: sha256.clone(), permissions: *permissions };
                transaction.delete(relative, &expected)?;
            }
            _ => {}
        }
        match then {
            Some(Held::File { sha256, permissions }) => {
                let blob = blob(sha256).with_context(|| format!("{relative} is gone"))?;
                let staged = staging.copy_in(&blob, sha256, *permissions)?;
                let expected = match now {
                    Some(Held::File { sha256, permissions }) => {
                        Some(Expected { sha256: sha256.clone(), permissions: *permissions })
                    }
                    _ => None,
                };
                transaction.write(relative, &staged, expected.as_ref())?;
                written += 1;
            }
            Some(Held::Link { text }) => {
                transaction.link(relative, text)?;
                written += 1;
            }
            None => deleted += 1,
        }
    }
    Ok((written, deleted))
}

/// Puts back what `transaction` changed after `error`.
fn rolled_back(
    transaction: Transaction,
    staging: &super::pull::Staging,
    error: anyhow::Error,
) -> anyhow::Error {
    if let Err(left) = transaction.roll_back() {
        staging.keep();
        return error.context(format!(
            "cmux could not put back {}; what it moved aside is in {}",
            left.join(", "),
            staging.0.display()
        ));
    }
    if let Some(changed) = error.downcast_ref::<place::Changed>() {
        return refused(
            "sync_restore_conflict",
            format!("{} changed here during the restore; nothing was put back", changed.0),
            vec![changed.0.clone()],
        );
    }
    error
}

/// Moves the branch and staged changes from `now` back to `then`, each
/// only while git is still at `now`. The index is locked (git's own
/// `index.lock`) before anything moves and what is staged is read again
/// under the lock; when the index cannot be put back, the branch moves back
/// to where it was. Whether anything moved.
fn restore_git(local: &Path, now: Option<&GitAt>, then: Option<&GitAt>) -> anyhow::Result<bool> {
    let (Some(now), Some(then)) = (now, then) else { return Ok(false) };
    if now.same(then) {
        return Ok(false);
    }
    let here = git_back::base_of(local)?;
    let head = (now.head != then.head
        && here.head_ref == now.head_ref
        && here.head == now.head
        && now.head_ref == then.head_ref)
        .then(|| now.head.clone().zip(then.head.clone()))
        .flatten();
    let index = if now.staged != then.staged && here.staged == now.staged {
        match (then.index.as_deref().and_then(blob), GitDirs::of(local)?) {
            (Some(blob), Some(dirs)) => Some((blob, dirs)),
            _ => None,
        }
    } else {
        None
    };
    // Lock the index first: no other git process stages anything while the
    // staged changes are compared and replaced.
    let locked = match index {
        Some((blob, dirs)) => {
            let lock = dirs.own.join("index.lock");
            let file = std::fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o644)
                .custom_flags(libc::O_NOFOLLOW)
                .open(&lock)
                .context("git's index is locked")?;
            let unlock = |error: anyhow::Error| {
                let _ = std::fs::remove_file(&lock);
                error
            };
            let staged = git_back::base_of(local).map_err(unlock)?.staged;
            if staged == now.staged {
                Some((file, blob, lock.clone(), dirs.own.join("index")))
            } else {
                let _ = std::fs::remove_file(&lock);
                None
            }
        }
        None => None,
    };
    let mut moved = false;
    if let Some((old, new)) = &head {
        let status = update_ref(local, now.head_ref.as_deref(), new, old);
        if !status {
            if let Some((_, _, lock, _)) = &locked {
                let _ = std::fs::remove_file(lock);
            }
            bail!("cannot move the branch back");
        }
        moved = true;
    }
    if let Some((mut file, blob, lock, index)) = locked {
        let written = std::fs::File::open(&blob)
            .and_then(|mut source| std::io::copy(&mut source, &mut file))
            .and_then(|_| file.sync_all())
            .and_then(|()| std::fs::rename(&lock, &index));
        if let Err(error) = written {
            let _ = std::fs::remove_file(&lock);
            if let Some((old, new)) = &head
                && !update_ref(local, now.head_ref.as_deref(), old, new)
            {
                return Err(error).context(format!(
                    "cannot put the staged changes back, nor the branch (it is at {new}, was {old})"
                ));
            }
            return Err(error).context("cannot put the staged changes back");
        }
        moved = true;
    }
    Ok(moved)
}

/// Moves `head_ref` (or a detached HEAD) to `new` while it is at `old`.
fn update_ref(local: &Path, head_ref: Option<&str>, new: &str, old: &str) -> bool {
    let mut command = git_back::local(local);
    command.args(["update-ref", "-m", "cmux sync restore"]);
    match head_ref {
        Some(name) => command.arg(name),
        None => command.args(["--no-deref", "HEAD"]),
    };
    command.args([new, old]).status().is_ok_and(|status| status.success())
}

/// The answer line of `cmux link sync history`.
pub(super) fn history_line(local: &Path, remote_root: &str) -> anyhow::Result<Value> {
    let local =
        std::fs::canonicalize(local).with_context(|| format!("cannot open {}", local.display()))?;
    let snapshots: Vec<Value> = list(&local, remote_root)?
        .iter()
        .rev()
        .map(|snapshot| {
            json!({
                "seq": snapshot.seq,
                "at": snapshot.at,
                "action": snapshot.action,
                "restored": snapshot.restored,
                "files": snapshot.paths.values().filter(|held| matches!(held, Held::File { .. })).count(),
                "links": snapshot.paths.values().filter(|held| matches!(held, Held::Link { .. })).count(),
                "head": snapshot.git.as_ref().and_then(|git| git.head.clone()),
            })
        })
        .collect();
    Ok(json!({ "ok": true, "snapshots": snapshots }))
}

/// The snapshot of the paths `changes` sets, on top of the newest kept one
/// (or `manifest`'s paths when none is kept): each path's state, None for
/// gone.
pub(super) fn on_top(
    local: &Path,
    remote_root: &str,
    manifest: &Manifest,
    changes: impl IntoIterator<Item = (String, Option<Held>)>,
) -> BTreeMap<String, Held> {
    let mut paths = newest(local, remote_root).map_or_else(|| paths_of(manifest), |n| n.paths);
    for (relative, held) in changes {
        if !is_worktree_path(&relative) {
            continue;
        }
        match held {
            Some(held) => paths.insert(relative, held),
            None => paths.remove(&relative),
        };
    }
    paths
}
