//! A full disk under acpmux's store (a Mac mini or server that serves chats to the person's
//! other machines). acpmux keeps running: a chat it cannot save is never taken silently. A
//! new prompt or chat is refused with `storage.full` (see [`RpcError::storage_full`]) while
//! the store's disk has less than [`FLOOR_BYTES`] free, or since a write failed for want of
//! space and no free space was seen after it.

use crate::rpc::RpcError;

/// Below this many free bytes a new prompt or chat is refused: room for the prompt, the
/// agent's answer and the session files, so a turn that starts can finish saving.
pub const FLOOR_BYTES: u64 = 64 << 20;

/// Whether `error` is a write that found no space: ENOSPC, or a quota (EDQUOT), anywhere in
/// its chain.
pub fn is_disk_full(error: &anyhow::Error) -> bool {
    error.chain().filter_map(|cause| cause.downcast_ref::<std::io::Error>()).any(io_is_disk_full)
}

fn io_is_disk_full(error: &std::io::Error) -> bool {
    if matches!(error.kind(), std::io::ErrorKind::StorageFull | std::io::ErrorKind::QuotaExceeded) {
        return true;
    }
    #[cfg(unix)]
    {
        matches!(error.raw_os_error(), Some(code) if code == libc::ENOSPC || code == libc::EDQUOT)
    }
    #[cfg(not(unix))]
    {
        false
    }
}

/// Free bytes for an unprivileged writer on the file system that holds `path`; `None` when
/// the system cannot say.
pub fn free_bytes(path: &std::path::Path) -> Option<u64> {
    #[cfg(unix)]
    {
        use std::os::unix::ffi::OsStrExt;
        let c = std::ffi::CString::new(path.as_os_str().as_bytes()).ok()?;
        let mut stat = std::mem::MaybeUninit::<libc::statvfs>::uninit();
        // SAFETY: `c` is a valid NUL-terminated path and `stat` is written by statvfs on success.
        let rc = unsafe { libc::statvfs(c.as_ptr(), stat.as_mut_ptr()) };
        if rc != 0 {
            return None;
        }
        // SAFETY: statvfs returned 0, so it filled `stat`.
        let stat = unsafe { stat.assume_init() };
        #[allow(clippy::unnecessary_cast)]
        Some((stat.f_bavail as u64).saturating_mul(stat.f_frsize as u64))
    }
    #[cfg(not(unix))]
    {
        let _ = path;
        None
    }
}

impl RpcError {
    /// A prompt or chat refused because the store's disk is full; `free`: the free bytes
    /// when known. Retryable once space is freed.
    pub fn storage_full(free: Option<u64>) -> Self {
        let full = crate::hand::pair::hostname();
        let host = full.strip_suffix(".local").unwrap_or(&full).to_owned();
        let message = format!(
            "the disk on {host} is full, so acpmux cannot save this chat; free some space there, then try again"
        );
        let mut data =
            serde_json::json!({"reason": "storage.full", "retryable": true, "host": host});
        if let Some(free) = free {
            data["freeBytes"] = free.into();
        }
        Self::new(-32000, message).with_data(data)
    }
}
