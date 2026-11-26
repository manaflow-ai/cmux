//! Disk-space policy for projection writes and lower-layer caching.

use std::fs;
use std::os::unix::ffi::OsStrExt as _;

use super::Overlay;
use super::errno::ENOSPC;

/// The cache leaves free 1/`CACHE_RESERVE_PART` of the disk it is on, at most
const CACHE_RESERVE_PART: u64 = 10;
/// Room reserved for the agent's own writes.
const CACHE_RESERVE_MAX: u64 = 2 * 1024 * 1024 * 1024;

impl Overlay {
    /// Runs `op`, retrying once after freeing lower-layer cache bytes when the disk is full.
    pub(super) fn with_room<T>(&self, op: impl Fn() -> Result<T, i32>) -> Result<T, i32> {
        match op() {
            Err(ENOSPC) if self.free_cache() => op(),
            done => done,
        }
    }

    /// Deletes every evictable cached blob. The manifest marker stays in place.
    pub(super) fn free_cache(&self) -> bool {
        let Ok(read) = fs::read_dir(&self.cache) else { return false };
        let mut freed = false;
        for entry in read.flatten() {
            if entry.file_name() != super::CACHE_ID_FILE && fs::remove_file(entry.path()).is_ok() {
                freed = true;
            }
        }
        if freed {
            *self.cache_lock() = Default::default();
        }
        freed
    }

    /// Whether retaining `len` bytes would consume the disk reserve for agent writes.
    pub(super) fn cache_has_room(&self, len: u64) -> bool {
        #[cfg(target_os = "linux")]
        {
            let Ok(path) = std::ffi::CString::new(self.cache.as_os_str().as_bytes()) else {
                return true;
            };
            // SAFETY: `path` is NUL-terminated and `stat` is an initialized out-parameter.
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
