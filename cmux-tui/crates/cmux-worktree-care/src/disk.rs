//! How full a disk is, and how many bytes a folder holds on it.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::time::Instant;

use serde::Serialize;

/// A filesystem's size and free space, in bytes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Usage {
    pub total: u64,
    /// What an unprivileged user may still write.
    pub available: u64,
}

impl Usage {
    /// The used share, from 0 to 1: what is not available to the user.
    pub fn used_fraction(&self) -> f64 {
        if self.total == 0 {
            return 0.0;
        }
        1.0 - (self.available as f64 / self.total as f64)
    }
}

/// The filesystem `path` is on.
#[cfg(unix)]
pub fn usage(path: &Path) -> Option<Usage> {
    use std::os::unix::ffi::OsStrExt;
    let mut bytes = path.as_os_str().as_bytes().to_vec();
    bytes.push(0);
    let mut stat = std::mem::MaybeUninit::<libc::statvfs>::zeroed();
    // SAFETY: `bytes` is NUL-terminated and outlives the call; `stat` is
    // written by statvfs(3) before it is read.
    let status = unsafe { libc::statvfs(bytes.as_ptr().cast(), stat.as_mut_ptr()) };
    if status != 0 {
        return None;
    }
    // SAFETY: statvfs returned 0, so it filled `stat`.
    let stat = unsafe { stat.assume_init() };
    // The field types differ by platform (u32 on macOS, u64 on Linux).
    #[allow(clippy::unnecessary_cast)]
    let (block, blocks, available) =
        ((stat.f_frsize as u64).max(1), stat.f_blocks as u64, stat.f_bavail as u64);
    Some(Usage { total: blocks.saturating_mul(block), available: available.saturating_mul(block) })
}

#[cfg(not(unix))]
pub fn usage(_path: &Path) -> Option<Usage> {
    None
}

/// The bytes a folder takes on disk, and those of the listed subfolders in
/// it (each counted in the total too).
#[derive(Debug, Default, Clone)]
pub struct Sizes {
    pub total: u64,
    pub parts: HashMap<PathBuf, u64>,
    /// The walk stopped at its deadline: the numbers are lower bounds.
    pub partial: bool,
}

/// Walks `root` once, without following links or entering other
/// filesystems, adding up the blocks each file takes. A folder in `parts`
/// (relative to `root`) is summed on its own as well. Unreadable entries
/// count as nothing.
pub fn sizes(root: &Path, parts: &[PathBuf], deadline: Instant) -> Sizes {
    let mut sizes = Sizes::default();
    let wanted: HashMap<PathBuf, ()> = parts.iter().map(|part| (root.join(part), ())).collect();
    let device = device(root);
    let mut stack = vec![(root.to_path_buf(), None::<PathBuf>)];
    while let Some((dir, owner)) = stack.pop() {
        if Instant::now() >= deadline {
            sizes.partial = true;
            break;
        }
        let Ok(entries) = std::fs::read_dir(&dir) else { continue };
        for entry in entries.flatten() {
            let path = entry.path();
            let Ok(meta) = std::fs::symlink_metadata(&path) else { continue };
            let bytes = allocated(&meta);
            let owner = match &owner {
                Some(owner) => Some(owner.clone()),
                None if wanted.contains_key(&path) => {
                    path.strip_prefix(root).ok().map(Path::to_path_buf)
                }
                None => None,
            };
            sizes.total += bytes;
            if let Some(owner) = &owner {
                *sizes.parts.entry(owner.clone()).or_default() += bytes;
            }
            if meta.is_dir() && device.is_none_or(|device| device_of(&meta) == device) {
                stack.push((path, owner));
            }
        }
    }
    sizes
}

#[cfg(unix)]
fn allocated(meta: &std::fs::Metadata) -> u64 {
    use std::os::unix::fs::MetadataExt;
    meta.blocks().saturating_mul(512)
}

#[cfg(not(unix))]
fn allocated(meta: &std::fs::Metadata) -> u64 {
    meta.len()
}

#[cfg(unix)]
fn device_of(meta: &std::fs::Metadata) -> u64 {
    use std::os::unix::fs::MetadataExt;
    meta.dev()
}

#[cfg(not(unix))]
fn device_of(_meta: &std::fs::Metadata) -> u64 {
    0
}

fn device(path: &Path) -> Option<u64> {
    std::fs::symlink_metadata(path).ok().map(|meta| device_of(&meta))
}

#[cfg(test)]
mod care_tests {
    use super::*;
    use std::time::Duration;

    #[test]
    fn a_listed_folder_is_summed_inside_the_total() {
        let root = crate::store::care_tests::scratch("sizes");
        std::fs::create_dir_all(root.join("node_modules/a")).unwrap();
        std::fs::write(root.join("node_modules/a/big"), vec![1u8; 64 * 1024]).unwrap();
        std::fs::write(root.join("small"), b"x").unwrap();
        let part = PathBuf::from("node_modules");
        let sizes =
            sizes(&root, std::slice::from_ref(&part), Instant::now() + Duration::from_secs(10));
        let modules = sizes.parts.get(&part).copied().unwrap_or(0);
        assert!(modules >= 64 * 1024, "{modules}");
        assert!(sizes.total > modules);
        assert!(!sizes.partial);
    }

    #[test]
    fn the_disk_of_a_folder_has_a_size() {
        let usage = usage(Path::new("/")).unwrap();
        assert!(usage.total > 0 && usage.available <= usage.total);
        assert!((0.0..=1.0).contains(&usage.used_fraction()));
    }
}
