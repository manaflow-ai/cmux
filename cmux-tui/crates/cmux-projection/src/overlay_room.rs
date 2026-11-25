//! Disk writes that may run out of room: scratch files that never outlive a failed write, the
//! cache's share of the disk, and the retry that empties the cache when the agent's write needs it.

use std::fs;
use std::path::{Path, PathBuf};

use super::Overlay;
use super::errno::ENOSPC;

/// The cache leaves free 1/`CACHE_RESERVE_PART` of the disk it is on, at most
const CACHE_RESERVE_PART: u64 = 10;
/// `CACHE_RESERVE_MAX`: that room stays for what the agent writes.
const CACHE_RESERVE_MAX: u64 = 2 * 1024 * 1024 * 1024;

/// A file being written in the scratch folder: removed when dropped unless the upper layer moved
/// it into place, so a write that fails half way (a full disk, a fetch that failed) leaves nothing
/// behind holding the space until the next mount.
pub(super) struct Temp {
    path: PathBuf,
    placed: bool,
}

impl Temp {
    pub(super) fn path(&self) -> &Path {
        &self.path
    }

    /// Leaves it where it is: something else moved it into place.
    pub(super) fn keep(mut self) {
        self.placed = true;
    }
}

impl Drop for Temp {
    fn drop(&mut self) {
        if !self.placed {
            let _ = fs::remove_file(&self.path);
        }
    }
}

impl Overlay {
    pub(super) fn scratch_file(&self) -> Temp {
        Temp { path: self.scratch_path(), placed: false }
    }

    /// Runs `op`, and once more after emptying the cache when it ran out of disk: the cache holds
    /// only bytes the Mac still has, so the agent's own writes always come first.
    pub(super) fn with_room<T>(&self, op: impl Fn() -> Result<T, i32>) -> Result<T, i32> {
        match op() {
            Err(ENOSPC) if self.free_cache() => op(),
            done => done,
        }
    }

    /// Deletes every cached byte (whole files and chunks; the next read fetches them again).
    /// Whether anything was freed.
    pub(super) fn free_cache(&self) -> bool {
        let mut index = self.cache_lock();
        let mut freed = false;
        while let Some(key) = index.oldest() {
            if fs::remove_file(self.cache_path(key)).is_ok() {
                freed = true;
            }
            index.remove(key);
        }
        drop(index);
        if let Some(content) = &self.content {
            freed |= content.discard_cached_blobs();
        }
        freed
    }

    /// Whether the cache may keep `len` more bytes: never into the last [`CACHE_RESERVE_PART`] of
    /// the disk (at most [`CACHE_RESERVE_MAX`]), which stays for what the agent writes.
    pub(super) fn cache_has_room(&self, len: u64) -> bool {
        #[cfg(target_os = "linux")]
        {
            use std::os::unix::ffi::OsStrExt as _;
            let Ok(path) = std::ffi::CString::new(self.cache.as_os_str().as_bytes()) else {
                return true;
            };
            // SAFETY: `path` is a NUL-terminated string and `stat` a zeroed out-parameter.
            let mut stat: libc::statvfs = unsafe { std::mem::zeroed() };
            if unsafe { libc::statvfs(path.as_ptr(), &raw mut stat) } != 0 {
                return true;
            }
            let block = stat.f_frsize;
            let total = stat.f_blocks.saturating_mul(block);
            let free = stat.f_bavail.saturating_mul(block);
            let reserve = (total / CACHE_RESERVE_PART).min(CACHE_RESERVE_MAX);
            free.saturating_sub(len) >= reserve
        }
        #[cfg(not(target_os = "linux"))]
        {
            let _ = len;
            true
        }
    }
}
