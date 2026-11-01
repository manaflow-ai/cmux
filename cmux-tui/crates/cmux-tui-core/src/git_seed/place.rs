//! The sandbox of `git-seed-v1`: the folder and the bundle lie under the
//! roots `fs-v1` serves, exactly as `fs-v1` would place them. A request path
//! is absolute with no `.` or `..` component; its deepest existing ancestor
//! is resolved (symlinks followed by the kernel) and must still lie under a
//! root, so a symlink cannot lead a seed out of the home.

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

/// The uploaded bundle: a regular file under a root.
pub fn bundle(roots: &Roots, path: &str) -> Result<PathBuf, SeedRefusal> {
    let placed = place(roots, path)?;
    match std::fs::symlink_metadata(&placed) {
        Ok(meta) if meta.is_file() => Ok(placed),
        Ok(_) => Err(SeedRefusal::bad_request("the bundle is not a regular file")),
        Err(_) => Err(SeedRefusal::bad_request("no bundle at that path")),
    }
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
