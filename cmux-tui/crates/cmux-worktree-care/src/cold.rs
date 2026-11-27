//! "Optimize storage" for a cold folder (Leo, 2026-11-24: "files that rarely get touched and are
//! safe in the cloud copy get removed locally and come back the moment something needs them").
//!
//! - [`upload`]: every file of a folder into a cloud copy, as `cas/1` chunks (`cmux-cas`: BLAKE3
//!   ids, zstd, the store checks each chunk against its id on every read).
//! - [`evict`]: the folder goes, only when the cloud copy is verified by content hash: the folder
//!   is read again, and every chunk of every file is read back from the cloud and must hash to
//!   its id. A missing chunk, a damaged one, a file that changed since the upload, a symlink or a
//!   special file the copy cannot carry: the folder stays and nothing is written. The record
//!   (the folder's manifest, its directories and which cloud holds it) is on disk before the
//!   folder goes, and the folder is renamed aside in one step before it is deleted, so a crash
//!   leaves either the whole folder or the record.
//! - [`recall`]: the folder back from its record, byte for byte (every file's whole hash checked,
//!   as `cmux_cas::assemble` does), built beside its place and renamed in, so a reader never sees half
//!   of it. [`recall_for`] is the "moment something needs it" hook: given any path, it brings
//!   back the evicted folder that holds it, and costs a few stats when none does. acpmux calls it
//!   before a session's agent starts in a missing folder (`hub/worktree_care.rs`).
//!
//! Nothing here runs on its own and nothing evicts by default: a caller decides which folders
//! are cold (`policy`'s last use, `hub/cold_archive.rs`'s idle days) and that nothing has them
//! open (`procs`). A linked git worktree's admin entry is the caller's to keep (`git worktree
//! lock`) while its folder is away.

use std::path::{Path, PathBuf};

use cmux_cas::Id;
use cmux_cas::manifest::{File, Manifest};
use serde::{Deserialize, Serialize};

use crate::inventory::now_ms;

/// Where evicted folders' records live: `~/.cmux/cold-evict`.
pub fn default_records() -> Option<PathBuf> {
    std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".cmux/cold-evict"))
}

/// A cloud copy of chunks. Every read is checked against the id it was asked by.
pub trait CloudCopy {
    /// The bytes of chunk `id`, refused unless they hash to `id`.
    fn get(&self, id: &Id) -> Result<Vec<u8>, String>;
    /// Stores `bytes` as chunk `id`.
    fn put(&self, id: &Id, bytes: &[u8]) -> Result<(), String>;
}

/// A `cas/1` chunk store as the cloud copy (a cloud machine's store, a mounted bucket).
impl CloudCopy for cmux_cas::Store {
    fn get(&self, id: &Id) -> Result<Vec<u8>, String> {
        cmux_cas::Store::get(self, id).map_err(|e| e.to_string())
    }

    fn put(&self, id: &Id, bytes: &[u8]) -> Result<(), String> {
        cmux_cas::Store::put(self, id, bytes).map_err(|e| e.to_string())
    }
}

/// What a folder holds, by content: its files' manifest and its directories (empty ones too).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Snapshot {
    pub manifest: Manifest,
    /// Every directory under the folder, `/`-separated, sorted.
    pub dirs: Vec<String>,
}

impl Snapshot {
    /// The manifest's id: equal ids, equal bytes in every file.
    pub fn id(&self) -> Result<Id, String> {
        self.manifest.id().map_err(|e| e.to_string())
    }
}

/// An evicted folder: enough to bring it back.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Record {
    pub path: PathBuf,
    /// The `cas/1` store that holds its chunks ([`recall_for`] opens it).
    pub cloud: PathBuf,
    /// The manifest's id; [`Record::manifest`] is refused unless its bytes hash to it.
    pub manifest_id: String,
    /// The manifest's JSON.
    pub manifest_json: String,
    pub dirs: Vec<String>,
    pub bytes: u64,
    pub evicted_ms: u64,
}

impl Record {
    /// The manifest, checked against its id.
    pub fn manifest(&self) -> Result<Manifest, String> {
        let id = Id::parse(&self.manifest_id).map_err(|e| e.to_string())?;
        Manifest::from_bytes(self.manifest_json.as_bytes(), &id).map_err(|e| e.to_string())
    }
}

/// Reads `dir` by content, sending each distinct chunk to `chunk`. Refuses a symlink or any
/// entry that is neither a file nor a directory: the copy could not bring it back.
pub fn snapshot(
    dir: &Path,
    mut chunk: impl FnMut(Id, &[u8]) -> Result<(), String>,
) -> Result<Snapshot, String> {
    let mut files: Vec<File> = Vec::new();
    let mut dirs = Vec::new();
    walk(dir, dir, &mut dirs, &mut |rel, bytes, exec| {
        // One file at a time, so memory holds one file, not the folder.
        let one = std::collections::BTreeMap::from([(rel.to_owned(), (bytes, exec))]);
        let m = Manifest::build(&one, |id, piece| chunk(id, piece).map_err(Into::into))
            .map_err(|e| format!("{rel}: {e}"))?;
        files.extend(m.files);
        Ok(())
    })?;
    files.sort_by(|a, b| a.path.cmp(&b.path));
    dirs.sort();
    Ok(Snapshot { manifest: Manifest { schema: cmux_cas::manifest::SCHEMA, files }, dirs })
}

type OnFile<'a> = dyn FnMut(&str, Vec<u8>, bool) -> Result<(), String> + 'a;

fn walk(
    root: &Path,
    dir: &Path,
    dirs: &mut Vec<String>,
    on_file: &mut OnFile<'_>,
) -> Result<(), String> {
    let entries = std::fs::read_dir(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    for entry in entries {
        let entry = entry.map_err(|e| format!("{}: {e}", dir.display()))?;
        let path = entry.path();
        let kind = entry.file_type().map_err(|e| format!("{}: {e}", path.display()))?;
        let rel = path
            .strip_prefix(root)
            .map_err(|e| e.to_string())?
            .to_str()
            .ok_or_else(|| format!("{} is not UTF-8", path.display()))?
            .to_owned();
        if kind.is_dir() {
            dirs.push(rel);
            walk(root, &path, dirs, on_file)?;
        } else if kind.is_file() {
            let bytes = std::fs::read(&path).map_err(|e| format!("{}: {e}", path.display()))?;
            on_file(&rel, bytes, exec(&entry)?)?;
        } else {
            return Err(format!("{rel} is not a file or a folder; the copy cannot carry it"));
        }
    }
    Ok(())
}

#[cfg(unix)]
fn exec(entry: &std::fs::DirEntry) -> Result<bool, String> {
    use std::os::unix::fs::PermissionsExt as _;
    let meta = entry.metadata().map_err(|e| e.to_string())?;
    Ok(meta.permissions().mode() & 0o111 != 0)
}

#[cfg(not(unix))]
fn exec(_: &std::fs::DirEntry) -> Result<bool, String> {
    Ok(false)
}

/// Copies every file of `dir` into `cloud`. Returns what was copied; [`evict`] reads the folder
/// and the cloud again and trusts neither this nor the caller.
pub fn upload(dir: &Path, cloud: &dyn CloudCopy) -> Result<Snapshot, String> {
    snapshot(dir, |id, bytes| cloud.put(&id, bytes))
}

/// Whether `cloud` holds every byte of `snapshot`: each chunk read back and checked against its
/// id by the store, its length against the manifest's, and each file's chunks hashed whole
/// against the file's hash.
pub fn verify(snapshot: &Snapshot, cloud: &dyn CloudCopy) -> Result<(), String> {
    for file in &snapshot.manifest.files {
        let mut whole = Vec::with_capacity(usize::try_from(file.size).map_err(|e| e.to_string())?);
        for chunk in &file.chunks {
            let bytes = cloud.get(&chunk.id).map_err(|e| {
                format!("{}: the cloud copy lacks chunk {}: {e}", file.path, chunk.id)
            })?;
            if Id::of(&bytes) != chunk.id || bytes.len() as u64 != u64::from(chunk.len) {
                return Err(format!("{}: the cloud copy of chunk {} differs", file.path, chunk.id));
            }
            whole.extend_from_slice(&bytes);
        }
        if Id::of(&whole) != file.hash {
            return Err(format!("{}: the cloud copy differs from the file", file.path));
        }
    }
    Ok(())
}

/// The record file of folder `path` in `records`.
pub fn record_path(records: &Path, path: &Path) -> PathBuf {
    records.join(format!("{}.json", Id::of(path.as_os_str().as_encoded_bytes()).hex()))
}

/// Removes `dir` once `cloud` (the `cas/1` store at `cloud_root`) is verified to hold every byte
/// of it, writing its record in `records` first. Refuses, leaving the folder as it was, on any
/// doubt: a chunk the cloud lacks or holds damaged, a file changed while it was checked, an
/// entry the copy cannot carry, a record already there.
pub fn evict(
    dir: &Path,
    cloud: &dyn CloudCopy,
    cloud_root: &Path,
    records: &Path,
) -> Result<Record, String> {
    if !dir.is_absolute() {
        return Err(format!("{} is not an absolute folder", dir.display()));
    }
    let meta = std::fs::symlink_metadata(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    if !meta.is_dir() {
        return Err(format!("{} is not a folder", dir.display()));
    }
    let record_file = record_path(records, dir);
    if record_file.exists() {
        return Err(format!("{} is already evicted", dir.display()));
    }
    let before = snapshot(dir, |_, _| Ok(()))?;
    verify(&before, cloud)?;
    let manifest_json = String::from_utf8(before.manifest.to_bytes().map_err(|e| e.to_string())?)
        .map_err(|e| e.to_string())?;
    let record = Record {
        path: dir.to_path_buf(),
        cloud: cloud_root.to_path_buf(),
        manifest_id: before.id()?.hex(),
        manifest_json,
        dirs: before.dirs.clone(),
        bytes: before.manifest.size(),
        evicted_ms: now_ms(),
    };
    // Aside in one step: what is renamed is what gets deleted, and a writer that opens the folder
    // by its path after this finds it gone, not half deleted.
    let aside = sibling(dir, "evicting")?;
    std::fs::rename(dir, &aside).map_err(|e| format!("{}: {e}", dir.display()))?;
    let put_back = |why: String| {
        let _ = std::fs::rename(&aside, dir);
        Err(why)
    };
    // Read once more after the rename: a write that landed while the cloud was checked shows here.
    match snapshot(&aside, |_, _| Ok(())) {
        Ok(after) if after == before => {}
        Ok(_) => {
            return put_back(format!("{} changed while it was checked; it stays", dir.display()));
        }
        Err(e) => return put_back(format!("{e}; it stays")),
    }
    if let Err(e) = write_record(records, &record_file, &record) {
        return put_back(e);
    }
    std::fs::remove_dir_all(&aside).map_err(|e| format!("{}: {e}", aside.display()))?;
    Ok(record)
}

/// Brings back the evicted folder that holds `path` (it or a parent), when there is one and
/// `path` is missing. `Ok(None)` when nothing evicted holds it; a few stats then.
pub fn recall_for(path: &Path, records: &Path) -> Result<Option<Record>, String> {
    if std::fs::symlink_metadata(path).is_ok() {
        return Ok(None);
    }
    for folder in path.ancestors() {
        let file = record_path(records, folder);
        if file.is_file() {
            if std::fs::symlink_metadata(folder).is_ok() {
                // Put back by hand, or another start brought it back: nothing to recall.
                return Ok(None);
            }
            let record = read_record(&file)?;
            let cloud = cmux_cas::Store::new(&record.cloud);
            return recall(folder, records, &cloud).map(Some);
        }
    }
    Ok(None)
}

/// Brings evicted `dir` back from `cloud`, byte for byte, and drops its record.
pub fn recall(dir: &Path, records: &Path, cloud: &dyn CloudCopy) -> Result<Record, String> {
    let file = record_path(records, dir);
    let record = read_record(&file)?;
    if record.path != dir {
        return Err(format!("the record of {} names {}", dir.display(), record.path.display()));
    }
    if std::fs::symlink_metadata(dir).is_ok() {
        return Err(format!("{} is there already; it is not overwritten", dir.display()));
    }
    let manifest = record.manifest()?;
    let building = sibling(dir, "recall")?;
    let built = (|| {
        std::fs::create_dir_all(&building).map_err(|e| format!("{}: {e}", building.display()))?;
        for d in &record.dirs {
            if d.split('/').any(|p| p.is_empty() || p == "." || p == "..") || d.starts_with('/') {
                return Err(format!("the record names a folder {d:?} outside it"));
            }
            let p = building.join(d);
            std::fs::create_dir_all(&p).map_err(|e| format!("{}: {e}", p.display()))?;
        }
        assemble_from(cloud, &manifest, &building)?;
        std::fs::rename(&building, dir).map_err(|e| format!("{}: {e}", dir.display()))
    })();
    if let Err(e) = built {
        let _ = std::fs::remove_dir_all(&building);
        return Err(e);
    }
    let _ = std::fs::remove_file(&file);
    Ok(record)
}

/// Writes `manifest`'s files under `dir` from `cloud`, as `cmux_cas::assemble` does: each file
/// built whole, refused unless it hashes to its manifest entry, written beside its place and
/// renamed in, with its mode.
fn assemble_from(cloud: &dyn CloudCopy, manifest: &Manifest, dir: &Path) -> Result<(), String> {
    for f in &manifest.files {
        let mut bytes = Vec::with_capacity(usize::try_from(f.size).map_err(|e| e.to_string())?);
        for c in &f.chunks {
            bytes.extend_from_slice(&cloud.get(&c.id)?);
        }
        if Id::of(&bytes) != f.hash {
            return Err(format!("{}: the cloud copy does not hash to its manifest entry", f.path));
        }
        let path = dir.join(&f.path);
        let parent = path.parent().ok_or_else(|| format!("{} has no parent", f.path))?;
        std::fs::create_dir_all(parent).map_err(|e| format!("{}: {e}", parent.display()))?;
        cmux_cas::store::write_atomic(parent, &path, &bytes)
            .map_err(|e| format!("{}: {e}", path.display()))?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt as _;
            let mode = if f.exec { 0o755 } else { 0o644 };
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(mode))
                .map_err(|e| format!("{}: {e}", path.display()))?;
        }
    }
    Ok(())
}

/// A new name beside `dir` for a step of `what`.
fn sibling(dir: &Path, what: &str) -> Result<PathBuf, String> {
    use std::sync::atomic::{AtomicU64, Ordering};
    static N: AtomicU64 = AtomicU64::new(0);
    let parent = dir.parent().ok_or_else(|| format!("{} has no parent", dir.display()))?;
    let name = dir.file_name().ok_or_else(|| format!("{} has no name", dir.display()))?;
    let n = N.fetch_add(1, Ordering::Relaxed);
    Ok(parent.join(format!(".{}.cmux-{what}-{}-{n}", name.to_string_lossy(), std::process::id())))
}

fn write_record(records: &Path, file: &Path, record: &Record) -> Result<(), String> {
    std::fs::create_dir_all(records).map_err(|e| format!("{}: {e}", records.display()))?;
    let json = serde_json::to_vec_pretty(record).map_err(|e| e.to_string())?;
    cmux_cas::store::write_atomic(records, file, &json)
        .map_err(|e| format!("{}: {e}", file.display()))
}

fn read_record(file: &Path) -> Result<Record, String> {
    let bytes = std::fs::read(file).map_err(|e| format!("{}: {e}", file.display()))?;
    serde_json::from_slice(&bytes).map_err(|e| format!("{}: {e}", file.display()))
}

#[cfg(test)]
#[path = "cold_tests.rs"]
mod tests;
