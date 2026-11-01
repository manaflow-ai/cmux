//! The sandbox of `git-seed-v1`: the folder and the bundle lie under the
//! roots `fs-v1` serves. A request path is absolute with no `.` or `..`
//! component; its deepest existing ancestor is resolved and must still lie
//! under a root, so a symlink cannot lead a seed out of the home.
//!
//! Nothing is checked once and used later by path where the remote side
//! could swap it in between:
//! - The bundle is opened through `fs-v1`'s own descriptor walk (no symlink
//!   leaves the roots) and copied to a file of this daemon's own before
//!   `git.seed.start` answers; git reads only the copy.
//! - A seed folder never nests: no git repository above it under the root,
//!   and no other seed's folder above or below it. A seed's checkout is the
//!   only way the remote side can make a symlink, and it writes only inside
//!   its own folder, so it cannot swap a directory above another seed's
//!   folder. The worker still checks the folder again before every step
//!   ([`recheck`]).

use std::path::{Component, Path, PathBuf};

use super::SeedRefusal;
use crate::fs_ops::Roots;

/// Longest request path (as `fs-v1`).
const MAX_PATH_BYTES: usize = 4096;

fn outside() -> SeedRefusal {
    SeedRefusal::bad_request("the path is outside the folders this machine serves")
}

/// The folder to seed: strictly under a root, not a symlink. Its missing
/// parents are created (under the same root).
pub fn folder(roots: &Roots, path: &str) -> Result<PathBuf, SeedRefusal> {
    let placed = place(roots, path)?;
    match std::fs::symlink_metadata(&placed) {
        Ok(meta) if meta.file_type().is_symlink() => return Err(outside()),
        Ok(meta) if !meta.is_dir() => {
            return Err(SeedRefusal::bad_request("the folder is a file"));
        }
        _ => {}
    }
    if let Some(parent) = placed.parent() {
        std::fs::create_dir_all(parent).map_err(|error| {
            SeedRefusal::bad_request(format!("cannot make the folder: {error}"))
        })?;
        // A parent made just now cannot have moved out; check again anyway.
        let canonical = std::fs::canonicalize(parent).map_err(|_| outside())?;
        if !under_a_root(roots, &canonical, true) {
            return Err(outside());
        }
    }
    Ok(placed)
}

/// Refuses a folder with a git repository above it (strictly under its root:
/// a clone inside a clone), and one above or below another seed's folder.
pub fn not_nested(
    roots: &Roots,
    folder: &Path,
    others: &mut dyn Iterator<Item = &Path>,
) -> Result<(), SeedRefusal> {
    let nested = |message: &str| SeedRefusal::bad_request(message.to_owned());
    let root = roots.canonical_paths().find(|root| folder.starts_with(root)).ok_or_else(outside)?;
    let mut above = folder.parent();
    while let Some(dir) = above {
        if dir == root || !dir.starts_with(root) {
            break;
        }
        if std::fs::symlink_metadata(dir.join(".git")).is_ok() {
            return Err(nested("the folder is inside another git repository"));
        }
        above = dir.parent();
    }
    for other in others {
        if other != folder && (other.starts_with(folder) || folder.starts_with(other)) {
            return Err(nested("the folder is inside or around another seed's folder"));
        }
    }
    Ok(())
}

/// The folder is still where it was placed: its parent resolves to the same
/// canonical path, and the folder itself (when it exists) is a directory,
/// not a symlink.
pub fn recheck(folder: &Path) -> Result<(), SeedRefusal> {
    let parent = folder.parent().ok_or_else(outside)?;
    if std::fs::canonicalize(parent).ok().as_deref() != Some(parent) {
        return Err(outside());
    }
    match std::fs::symlink_metadata(folder) {
        Ok(meta) if !meta.is_dir() => Err(outside()),
        _ => Ok(()),
    }
}

/// A bundle copied out of the roots into a directory of this daemon's own,
/// removed (with the directory) on drop.
#[derive(Debug)]
pub struct BundleCopy {
    pub path: PathBuf,
    dir: PathBuf,
}

impl Drop for BundleCopy {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
        let _ = std::fs::remove_dir(&self.dir);
    }
}

/// A fresh directory for one job's bundle: `mkdir` (mode 0700) of a name
/// carrying the job's random id, which fails on anything already there (a
/// symlink or another user's directory included), then checked to be a
/// directory this process owns with no access for anyone else.
fn private_dir(id: &str) -> Result<PathBuf, SeedRefusal> {
    use std::os::unix::fs::{DirBuilderExt as _, MetadataExt as _};
    let refused =
        |what: &str| SeedRefusal::bad_request(format!("cannot make a private folder: {what}"));
    let dir = std::env::temp_dir().join(format!("cmux-git-seed-{id}"));
    std::fs::DirBuilder::new()
        .mode(0o700)
        .create(&dir)
        .map_err(|error| refused(&error.to_string()))?;
    let meta = std::fs::symlink_metadata(&dir).map_err(|error| refused(&error.to_string()))?;
    // SAFETY: geteuid has no preconditions and cannot fail.
    let uid = unsafe { libc::geteuid() };
    if !meta.is_dir() || meta.uid() != uid || meta.mode() & 0o077 != 0 {
        return Err(refused("it is not this daemon's own"));
    }
    Ok(dir)
}

/// Opens the uploaded bundle through `fs-v1`'s descriptor walk and copies
/// it to a fresh private file (mode 0600, created new).
pub fn bundle(roots: &Roots, path: &str, id: &str) -> Result<BundleCopy, SeedRefusal> {
    use std::os::unix::fs::OpenOptionsExt as _;
    let fs = crate::fs_ops::FsService::new(roots.clone());
    let (mut file, _) = fs.open_file(path).map_err(|error| match error {
        crate::fs_ops::FsError::PermissionDenied => outside(),
        crate::fs_ops::FsError::NotFound => SeedRefusal::bad_request("no bundle at that path"),
        _ => SeedRefusal::bad_request("the bundle is not a readable regular file"),
    })?;
    let dir = private_dir(id)?;
    let copy = BundleCopy { path: dir.join("seed.bundle"), dir };
    let mut out = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(&copy.path)
        .map_err(|error| SeedRefusal::bad_request(format!("cannot copy the bundle: {error}")))?;
    std::io::copy(&mut file, &mut out).map_err(|error| {
        let code = if error.raw_os_error() == Some(libc::ENOSPC) {
            "seed.disk_full"
        } else {
            "seed.bad_request"
        };
        SeedRefusal { code, message: format!("cannot copy the bundle: {error}") }
    })?;
    Ok(copy)
}

/// Deletes the uploaded bundle through `fs-v1` (no path is reopened).
pub fn delete_upload(roots: &Roots, path: &str) {
    let fs = crate::fs_ops::FsService::new(roots.clone());
    let _ =
        fs.call("git-seed", "fs.delete", serde_json::json!({ "paths": [path], "permanent": true }));
}

/// `path` with its deepest existing ancestor canonicalized, when the result
/// lies strictly under a root.
fn place(roots: &Roots, path: &str) -> Result<PathBuf, SeedRefusal> {
    if !path.starts_with('/') || path.len() > MAX_PATH_BYTES || path.chars().any(char::is_control) {
        return Err(SeedRefusal::bad_request("paths must be absolute"));
    }
    let request = Path::new(path);
    if request.components().any(|part| !matches!(part, Component::RootDir | Component::Normal(_)))
        || path.split('/').any(|part| part == ".")
    {
        return Err(outside());
    }
    let mut existing = request.to_path_buf();
    let mut missing: Vec<std::ffi::OsString> = Vec::new();
    while std::fs::symlink_metadata(&existing).is_err() {
        let Some(name) = existing.file_name().map(ToOwned::to_owned) else {
            return Err(outside());
        };
        missing.push(name);
        if !existing.pop() {
            return Err(outside());
        }
    }
    // The last component itself is checked by the caller without
    // following it; its parent is resolved here.
    let (resolved, tail) = if missing.is_empty() {
        let name = existing.file_name().map(ToOwned::to_owned).ok_or_else(outside)?;
        let parent = existing.parent().ok_or_else(outside)?;
        (std::fs::canonicalize(parent).map_err(|_| outside())?, vec![name])
    } else {
        (
            std::fs::canonicalize(&existing).map_err(|_| outside())?,
            missing.into_iter().rev().collect(),
        )
    };
    let mut placed = resolved;
    for part in tail {
        placed.push(part);
    }
    if under_a_root(roots, &placed, false) { Ok(placed) } else { Err(outside()) }
}

/// True when `path` lies under a root (`or_is_root`: or is one).
fn under_a_root(roots: &Roots, path: &Path, or_is_root: bool) -> bool {
    roots.canonical_paths().any(|root| path.starts_with(root) && (or_is_root || path != root))
}
