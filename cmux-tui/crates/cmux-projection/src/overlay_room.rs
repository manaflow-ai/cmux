//! Disk writes that may run out of room: scratch files that never outlive a failed write, the
//! cache's share of the disk, and the retry that empties the cache when the agent's write needs it.

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::Ordering;

use super::errno::ENOSPC;
use super::{Inner, Key, Overlay, io_errno};

/// The cache leaves free 1/`CACHE_RESERVE_PART` of the disk it is on, at most
const CACHE_RESERVE_PART: u64 = 10;
/// `CACHE_RESERVE_MAX`: that room stays for what the agent writes.
const CACHE_RESERVE_MAX: u64 = 2 * 1024 * 1024 * 1024;

/// A file being written in the scratch folder: removed when dropped unless [`Temp::place`] moved
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

    /// Renames it to `to`.
    pub(super) fn place(mut self, to: &Path) -> std::io::Result<()> {
        fs::rename(&self.path, to)?;
        self.placed = true;
        Ok(())
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
        Temp {
            path: self.scratch.join(format!("t{}", self.temp.fetch_add(1, Ordering::Relaxed))),
            placed: false,
        }
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
        let Ok(read) = fs::read_dir(&self.cache) else { return false };
        let mut freed = false;
        for entry in read.flatten() {
            if entry.file_name() != "manifest-id" && fs::remove_file(entry.path()).is_ok() {
                freed = true;
            }
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

    /// Keeps fetched bytes in the cache. A failure (a full disk) only means the next read fetches
    /// them again: the read itself has its bytes.
    pub(super) fn store(&self, key: Key, bytes: &[u8]) {
        if !self.cache_has_room(bytes.len() as u64) {
            self.cache_failing.store(true, Ordering::Relaxed);
            return;
        }
        let temp = self.scratch_file();
        let kept = fs::write(temp.path(), bytes).and_then(|()| temp.place(&self.cache_path(key)));
        self.cache_failing.store(kept.is_err(), Ordering::Relaxed);
    }

    pub(super) fn write_whiteouts(&self, inner: &Inner) -> Result<(), i32> {
        let mut text = String::new();
        for path in &inner.whiteouts {
            text.push_str(path);
            text.push('\0');
        }
        let temp = self.scratch_file();
        fs::write(temp.path(), text)
            .and_then(|()| temp.place(&self.whiteouts_file))
            .map_err(|error| io_errno(&error))
    }

    pub(super) fn set_whiteout(&self, path: &str, on: bool) -> Result<(), i32> {
        let mut inner = self.lock();
        let changed =
            if on { inner.whiteouts.insert(path.to_owned()) } else { inner.whiteouts.remove(path) };
        if !changed {
            return Ok(());
        }
        let saved = self.write_whiteouts(&inner);
        if saved.is_err() {
            // Not on disk (a full disk): not in effect either, so a reopen agrees with now.
            if on {
                inner.whiteouts.remove(path);
            } else {
                inner.whiteouts.insert(path.to_owned());
            }
        }
        saved
    }
}
