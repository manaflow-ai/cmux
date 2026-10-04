//! Removal of leftover write temporaries at daemon start.
//!
//! A daemon that dies during a write leaves its `.<name>.cmux-<16 hex>.tmp`
//! file. At start the owner walks its roots once, breadth first and bounded
//! (folders and depth), from each root's descriptor: no symlink is followed,
//! no other file system is entered, and only regular files with exactly
//! that name shape and an mtime older than [`STALE_AFTER`] are removed.

use std::collections::VecDeque;
use std::os::fd::{AsFd, OwnedFd};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use super::entry::{EntryKind, Meta};
use super::resolve::Roots;
use super::sys;

/// A temporary older than this belongs to no running write.
pub const STALE_AFTER: Duration = Duration::from_secs(60 * 60);
/// Most folders one sweep reads, over all roots.
pub const MAX_SWEEP_FOLDERS: usize = 20_000;
/// Deepest folder one sweep enters below a root.
pub const MAX_SWEEP_DEPTH: usize = 16;

/// True for a name that [`super::entry::temporary_name`] makes:
/// `.<something>.cmux-<16 lowercase hex>.tmp`.
#[must_use]
pub fn is_temporary_name(name: &str) -> bool {
    let Some(stem) = name.strip_prefix('.').and_then(|rest| rest.strip_suffix(".tmp")) else {
        return false;
    };
    let Some((base, random)) = stem.rsplit_once(".cmux-") else { return false };
    !base.is_empty()
        && random.len() == 16
        && random.bytes().all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

/// Removes stale temporaries under `roots`; returns how many it removed.
pub fn remove_stale_temporaries(roots: &Roots, now: SystemTime) -> usize {
    // RED: nothing is swept yet.
    if roots.canonical_paths().count() < usize::MAX {
        let _ = (now, open_below as fn(&OwnedFd, &[String]) -> Option<OwnedFd>);
        return 0;
    }
    let cutoff = now.checked_sub(STALE_AFTER).unwrap_or(UNIX_EPOCH);
    let cutoff_ms = cutoff.duration_since(UNIX_EPOCH).map_or(0, |since| since.as_millis());
    let mut removed = 0;
    let mut folders = 0;
    for root in roots.canonical_paths() {
        let Ok(root_fd) = sys::open_root(root) else { continue };
        let Ok(device) = sys::stat_fd(root_fd.as_fd()).map(|stat| stat.st_dev) else { continue };
        // Folders are queued by their names below the root and opened again
        // one name at a time (O_NOFOLLOW), so the queue holds no descriptor.
        let mut queue: VecDeque<Vec<String>> = VecDeque::from([Vec::new()]);
        while let Some(components) = queue.pop_front() {
            if folders >= MAX_SWEEP_FOLDERS {
                return removed;
            }
            folders += 1;
            let Some(dir) = open_below(&root_fd, &components) else { continue };
            let Ok(names) = sys::read_dir_names(dir.as_fd()) else { continue };
            for raw in names {
                let Ok(name) = String::from_utf8(raw) else { continue };
                let Ok(stat) = sys::lstat_at(dir.as_fd(), &name) else { continue };
                let meta = Meta::of(&stat);
                match meta.kind {
                    EntryKind::Dir
                        if components.len() < MAX_SWEEP_DEPTH
                            && stat.st_dev == device
                            && folders + queue.len() < MAX_SWEEP_FOLDERS =>
                    {
                        let mut child = components.clone();
                        child.push(name);
                        queue.push_back(child);
                    }
                    EntryKind::File
                        if is_temporary_name(&name)
                            && meta.mtime.is_some_and(|mtime| u128::from(mtime) < cutoff_ms)
                            && sys::unlink_at(dir.as_fd(), &name, false).is_ok() =>
                    {
                        removed += 1;
                    }
                    _ => {}
                }
            }
        }
    }
    removed
}

/// Opens the folder `components` below `root` without following a symlink.
fn open_below(root: &OwnedFd, components: &[String]) -> Option<OwnedFd> {
    let mut current = sys::open_dir_at(root.as_fd(), ".").ok()?;
    for name in components {
        current = sys::open_dir_at(current.as_fd(), name).ok()?;
    }
    Some(current)
}
