//! The cache's own disk bound: the mirrors never take the machine's disk below a floor.
//!
//! A Cloud machine has one small disk (20 GiB) that the person's clones, builds and chats share
//! with this cache. A full mirror of a big repository (manaflow-ai/cmux: about 11 GiB) filled
//! behind the first clone took a lane machine to 0 bytes free on 2026-11-25 (cmuxterm-hq#26404),
//! and every later write on the machine failed. So the cache bounds itself, by the free space of
//! the filesystem it lives on: no fill, kept pack or repack starts below the floor, and one that
//! takes the disk under it while it runs is stopped and leaves nothing behind
//! (cmuxterm-hq docs/handbook/sparse-vm-disk-never-shrinks.md: bound every cache in the guest
//! by itself).

use std::path::Path;

/// The share of the filesystem the cache always leaves free (percent of its size).
pub const FREE_FLOOR_PERCENT: u64 = 25;

/// (available bytes, total bytes) of the filesystem holding `path`, or of its nearest existing
/// ancestor (a mirror's directory may not exist yet). `None` when it cannot be read.
pub fn space(path: &Path) -> Option<(u64, u64)> {
    let mut at = path;
    loop {
        if at.exists() {
            return statvfs(at);
        }
        at = at.parent()?;
    }
}

/// Whether `avail` of `total` is still above the floor.
pub fn above_floor(avail: u64, total: u64) -> bool {
    total == 0 || avail.saturating_mul(100) > total.saturating_mul(FREE_FLOOR_PERCENT)
}

/// Whether the cache may write more under `path` now. An unreadable filesystem counts as room:
/// the bound never stops a cache it cannot measure (the write itself still fails on a full disk).
pub fn has_room(path: &Path) -> bool {
    space(path).is_none_or(|(avail, total)| above_floor(avail, total))
}

/// The line a write the floor stopped logs.
pub fn why_not(path: &Path) -> String {
    match space(path) {
        Some((avail, total)) => format!(
            "{} MiB of {} MiB free, under the cache's {FREE_FLOOR_PERCENT}% floor",
            avail >> 20,
            total >> 20
        ),
        None => "disk space unreadable".to_owned(),
    }
}

#[cfg(unix)]
fn statvfs(path: &Path) -> Option<(u64, u64)> {
    use std::os::unix::ffi::OsStrExt;
    let c = std::ffi::CString::new(path.as_os_str().as_bytes()).ok()?;
    // SAFETY: a zeroed statvfs is a valid out-parameter.
    let mut st: libc::statvfs = unsafe { std::mem::zeroed() };
    // SAFETY: c is NUL-terminated and st is a valid out-parameter.
    if unsafe { libc::statvfs(c.as_ptr(), &mut st) } != 0 {
        return None;
    }
    #[allow(clippy::unnecessary_cast, clippy::useless_conversion)]
    let (frsize, avail, blocks) = (st.f_frsize as u64, st.f_bavail as u64, st.f_blocks as u64);
    Some((avail.saturating_mul(frsize), blocks.saturating_mul(frsize)))
}

#[cfg(not(unix))]
fn statvfs(_path: &Path) -> Option<(u64, u64)> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn floor_is_a_quarter_of_the_disk() {
        let gib = 1u64 << 30;
        assert!(above_floor(6 * gib, 20 * gib));
        assert!(!above_floor(5 * gib, 20 * gib));
        assert!(!above_floor(0, 20 * gib));
        assert!(above_floor(0, 0), "an unmeasured filesystem is never refused");
    }

    #[test]
    fn space_reads_the_nearest_existing_ancestor() {
        let dir = tempfile::tempdir().unwrap();
        let missing = dir.path().join("team/github.com/o/r.git");
        let (avail, total) = space(&missing).expect("tempdir's filesystem");
        assert!(total > 0 && avail <= total);
    }
}
