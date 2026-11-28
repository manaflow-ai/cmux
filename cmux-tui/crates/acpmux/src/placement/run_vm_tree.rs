//! What a git patch cannot carry back from a run VM: empty folders, a removed empty folder, and a
//! path's exact mode (git keeps only 644 or 755, and `git apply` writes a file it touches with
//! the umask's mode). The fork lists its checkout before and after the command ([`entries`]: every
//! path git does not ignore, its kind, mode and change stamp), sends the [`TreeDelta`] beside the
//! patch, and this checkout takes it after the patch ([`apply`]).

use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashSet};
use std::path::Path;

use super::sub_fork_wire::B64;

/// A path (relative to the checkout, raw bytes) and its mode bits (`& 0o7777`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PathMode {
    pub path: B64,
    pub mode: u32,
}

/// The changes a patch does not carry.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct TreeDelta {
    /// Folders made or whose mode changed: made here when missing, then given the mode.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub dirs: Vec<PathMode>,
    /// Files made or changed (content or mode): given the fork's mode after the patch lands.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub files: Vec<PathMode>,
    /// Folders the command removed: removed here when empty after the patch.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub gone: Vec<B64>,
}

impl TreeDelta {
    pub fn is_empty(&self) -> bool {
        self.dirs.is_empty() && self.files.is_empty() && self.gone.is_empty()
    }
}

/// One path of a listing: its kind (`d`, `f`, `l`, `o`), mode, and for a file what changes with
/// any write or chmod (size, inode, ctime).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Entry {
    pub kind: u8,
    pub mode: u32,
    pub stamp: (u64, u64, i64, i64),
}

/// A checkout's listing: every path but `.git` and what git ignores, by raw relative path.
pub type Listing = BTreeMap<Vec<u8>, Entry>;

fn git_ignored(checkout: &Path) -> Result<HashSet<Vec<u8>>, String> {
    let out = cmux_process::Command::new("git")
        .arg("-C")
        .arg(checkout)
        .args(["ls-files", "-z", "--others", "--ignored", "--exclude-standard", "--directory"])
        .env_remove("GIT_DIR")
        .env_remove("GIT_WORK_TREE")
        .env_remove("GIT_INDEX_FILE")
        .stdin(cmux_process::Stdio::null())
        .output()
        .map_err(|e| format!("git ls-files: {e}"))?;
    if !out.status.success() {
        return Err(format!("git ls-files: {}", String::from_utf8_lossy(&out.stderr).trim()));
    }
    Ok(out
        .stdout
        .split(|b| *b == 0)
        .filter(|p| !p.is_empty())
        .map(|p| p.strip_suffix(b"/").unwrap_or(p).to_vec())
        .collect())
}

/// List `checkout` ([`Listing`]).
#[cfg(unix)]
pub fn entries(checkout: &Path) -> Result<Listing, String> {
    use std::os::unix::ffi::{OsStrExt as _, OsStringExt as _};
    use std::os::unix::fs::MetadataExt as _;
    let ignored = git_ignored(checkout)?;
    let mut out = Listing::new();
    let mut stack: Vec<(std::path::PathBuf, Vec<u8>)> = vec![(checkout.to_owned(), Vec::new())];
    while let Some((dir, rel)) = stack.pop() {
        let read = std::fs::read_dir(&dir).map_err(|e| format!("{}: {e}", dir.display()))?;
        for e in read {
            let e = e.map_err(|e| format!("{}: {e}", dir.display()))?;
            let name = e.file_name();
            if name.as_bytes() == b".git" {
                continue;
            }
            let mut path = rel.clone();
            if !path.is_empty() {
                path.push(b'/');
            }
            path.extend_from_slice(&name.into_vec());
            if ignored.contains(&path) {
                continue;
            }
            let Ok(meta) = std::fs::symlink_metadata(e.path()) else { continue };
            let ft = meta.file_type();
            let mode = meta.mode() & 0o7777;
            let entry = if ft.is_symlink() {
                Entry { kind: b'l', mode: 0, stamp: (0, 0, 0, 0) }
            } else if ft.is_dir() {
                stack.push((e.path(), path.clone()));
                Entry { kind: b'd', mode, stamp: (0, 0, 0, 0) }
            } else if ft.is_file() {
                Entry {
                    kind: b'f',
                    mode,
                    stamp: (meta.size(), meta.ino(), meta.ctime(), meta.ctime_nsec()),
                }
            } else {
                Entry { kind: b'o', mode, stamp: (0, 0, 0, 0) }
            };
            out.insert(path, entry);
        }
    }
    Ok(out)
}

/// What changed from `before` to `after` that a patch does not carry.
pub fn delta(before: &Listing, after: &Listing) -> TreeDelta {
    let mut d = TreeDelta::default();
    for (path, e) in after {
        if before.get(path) == Some(e) {
            continue;
        }
        let pm = PathMode { path: B64(path.clone()), mode: e.mode };
        match e.kind {
            b'd' => d.dirs.push(pm),
            b'f' => d.files.push(pm),
            _ => {}
        }
    }
    for (path, e) in before {
        if e.kind == b'd' && after.get(path).is_none_or(|a| a.kind != b'd') {
            d.gone.push(B64(path.clone()));
        }
    }
    d
}

/// Take `delta` into `checkout` after its patch: make the folders, give files and folders their
/// modes (folders deepest first, so a folder closed to writes is closed last), remove the folders
/// that went (only when empty here). Answers how many paths it changed.
#[cfg(unix)]
pub fn apply(checkout: &Path, delta: &TreeDelta) -> Result<usize, String> {
    use std::os::unix::ffi::OsStrExt as _;
    use std::os::unix::fs::PermissionsExt as _;
    let at = |p: &B64| checkout.join(std::ffi::OsStr::from_bytes(&p.0));
    let chmod = |path: &Path, mode: u32| {
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode))
            .map_err(|e| format!("chmod {}: {e}", path.display()))
    };
    let mut changed = 0;
    let mut dirs: Vec<&PathMode> = delta.dirs.iter().collect();
    dirs.sort_by(|a, b| a.path.0.cmp(&b.path.0));
    for d in &dirs {
        let path = at(&d.path);
        if std::fs::symlink_metadata(&path).is_err() {
            std::fs::create_dir_all(&path).map_err(|e| format!("{}: {e}", path.display()))?;
            changed += 1;
        }
    }
    for f in &delta.files {
        let path = at(&f.path);
        let Ok(meta) = std::fs::symlink_metadata(&path) else { continue };
        if meta.is_file() && meta.permissions().mode() & 0o7777 != f.mode {
            chmod(&path, f.mode)?;
            changed += 1;
        }
    }
    let mut gone: Vec<&B64> = delta.gone.iter().collect();
    gone.sort_by(|a, b| b.0.cmp(&a.0));
    for g in gone {
        let path = at(g);
        if std::fs::symlink_metadata(&path).is_ok_and(|m| m.is_dir())
            && std::fs::remove_dir(&path).is_ok()
        {
            changed += 1;
        }
    }
    for d in dirs.iter().rev() {
        let path = at(&d.path);
        let Ok(meta) = std::fs::symlink_metadata(&path) else { continue };
        if meta.is_dir() && meta.permissions().mode() & 0o7777 != d.mode {
            chmod(&path, d.mode)?;
            changed += 1;
        }
    }
    Ok(changed)
}

/// Without unix modes there is nothing past the patch to list.
#[cfg(not(unix))]
pub fn entries(_checkout: &Path) -> Result<Listing, String> {
    Ok(Listing::new())
}

#[cfg(not(unix))]
pub fn apply(_checkout: &Path, _delta: &TreeDelta) -> Result<usize, String> {
    Ok(0)
}

#[cfg(all(test, unix))]
#[path = "run_vm_tree_tests.rs"]
mod tests;
