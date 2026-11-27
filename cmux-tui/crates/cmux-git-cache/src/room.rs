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

/// The most the floor ever asks to keep free, in GiB. A quarter of a 20 GiB Cloud disk is 5 GiB;
/// a quarter of a 256 GiB lane VM disk is 64 GiB, which refused every fill on a lane VM with
/// 52 GiB free (2026-11-25) though an 11 GiB mirror fit with room to spare.
pub const FREE_FLOOR_MAX_GIB: u64 = 16;

/// The bytes the cache leaves free on a filesystem of `total` bytes: a quarter of it, at most
/// `FREE_FLOOR_MAX_GIB`.
pub fn floor_bytes(total: u64) -> u64 {
    (total.saturating_mul(FREE_FLOOR_PERCENT) / 100).min(FREE_FLOOR_MAX_GIB << 30)
}

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
    room_after(avail, total, 0)
}

/// Whether writing `need` more bytes still leaves `avail` of `total` above the floor. A fill
/// checked only against the free space it starts with ran a 63 GiB lane VM from 31 GiB to
/// 16 GiB free with one 15.5 GiB mirror of manaflow-ai/cmux (fs-agent-lane-24 and -14,
/// 2026-11-26), and the mirror then sat under the floor for good: every refresh refused.
pub fn room_after(avail: u64, total: u64, need: u64) -> bool {
    total == 0 || avail.saturating_sub(need) > floor_bytes(total)
}

/// Whether the cache may write more under `path` now. An unreadable filesystem counts as room:
/// the bound never stops a cache it cannot measure (the write itself still fails on a full disk).
pub fn has_room(path: &Path) -> bool {
    space(path).is_none_or(|(avail, total)| above_floor(avail, total))
}

/// `has_room` for a write of `need` bytes: it must end above the floor, not just start there.
pub fn has_room_for(path: &Path, need: u64) -> bool {
    space(path).is_none_or(|(avail, total)| room_after(avail, total, need))
}

/// The line a write of `need` bytes the floor refused logs.
pub fn why_not_for(path: &Path, need: u64) -> String {
    match space(path) {
        Some((avail, total)) => format!(
            "{} MiB more would leave {} MiB of {} MiB free, under the cache's {} MiB floor \
             ({FREE_FLOOR_PERCENT}% of the disk, at most {FREE_FLOOR_MAX_GIB} GiB)",
            need >> 20,
            avail.saturating_sub(need) >> 20,
            total >> 20,
            floor_bytes(total) >> 20
        ),
        None => "disk space unreadable".to_owned(),
    }
}

/// The line a write the floor stopped logs.
pub fn why_not(path: &Path) -> String {
    match space(path) {
        Some((avail, total)) => format!(
            "{} MiB of {} MiB free, under the cache's {} MiB floor \
             ({FREE_FLOOR_PERCENT}% of the disk, at most {FREE_FLOOR_MAX_GIB} GiB)",
            avail >> 20,
            total >> 20,
            floor_bytes(total) >> 20
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
    fn floor_is_capped_on_big_disks() {
        let gib = 1u64 << 30;
        // A lane VM: 52 GiB free of 257 GiB was refused by the old 64 GiB floor.
        assert!(above_floor(52 * gib, 257 * gib));
        assert!(above_floor(17 * gib, 257 * gib));
        assert!(!above_floor(16 * gib, 257 * gib));
        assert_eq!(floor_bytes(20 * gib), 5 * gib, "Cloud's 20 GiB disk keeps its 5 GiB floor");
    }

    #[test]
    fn a_write_must_end_above_the_floor() {
        let gib = 1u64 << 30;
        // fs-agent-lane-24: 63 GiB disk (floor 15.75 GiB), 31 GiB free, a 15.5 GiB cmux mirror.
        assert!(above_floor(31 * gib, 63 * gib), "the old check let the fill start");
        assert!(!room_after(31 * gib, 63 * gib, 31 * gib / 2), "it would end under the floor");
        assert!(room_after(40 * gib, 63 * gib, 15 * gib));
        assert!(!room_after(gib, 63 * gib, 2 * gib), "more than is free never wraps around");
        assert!(room_after(0, 0, u64::MAX), "an unmeasured filesystem is never refused");
    }

    #[test]
    fn space_reads_the_nearest_existing_ancestor() {
        let dir = tempfile::tempdir().unwrap();
        let missing = dir.path().join("team/github.com/o/r.git");
        let (avail, total) = space(&missing).expect("tempdir's filesystem");
        assert!(total > 0 && avail <= total);
    }
}
