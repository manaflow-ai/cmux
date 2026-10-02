//! Unix `stat` field accessors for checked session-state reset deletion.

#[cfg(unix)]
pub(super) fn reset_stat_is_dir(stat: &libc::stat) -> bool {
    stat.st_mode & libc::S_IFMT == libc::S_IFDIR
}

#[cfg(unix)]
pub(super) fn reset_stat_is_file(stat: &libc::stat) -> bool {
    stat.st_mode & libc::S_IFMT == libc::S_IFREG
}

#[cfg(unix)]
pub(super) fn reset_stat_kind(stat: &libc::stat) -> libc::mode_t {
    stat.st_mode & libc::S_IFMT
}

#[cfg(unix)]
pub(super) fn reset_stat_metadata_fingerprint(stat: &libc::stat) -> String {
    let kind = if reset_stat_is_dir(stat) {
        "dir"
    } else if reset_stat_is_file(stat) {
        "file"
    } else if stat.st_mode & libc::S_IFMT == libc::S_IFLNK {
        "symlink"
    } else {
        "other"
    };
    format!(
        "{kind}:dev={},ino={},mode={},len={},mtime={}.{}",
        reset_stat_device(stat),
        reset_stat_inode(stat),
        stat.st_mode,
        stat.st_size,
        reset_stat_mtime_seconds(stat),
        reset_stat_mtime_nanoseconds(stat)
    )
}

#[cfg(all(unix, not(any(target_vendor = "apple", target_os = "aix", target_os = "hurd"))))]
fn reset_stat_mtime_seconds(stat: &libc::stat) -> i64 {
    stat.st_mtime
}

#[cfg(any(target_os = "aix", target_os = "hurd"))]
fn reset_stat_mtime_seconds(stat: &libc::stat) -> i64 {
    stat.st_mtim.tv_sec
}

#[cfg(all(unix, target_vendor = "apple"))]
fn reset_stat_mtime_seconds(stat: &libc::stat) -> i64 {
    // Rust libc exposes Darwin's st_mtimespec through these stable aliases.
    stat.st_mtime
}

#[cfg(all(unix, not(any(target_vendor = "apple", target_os = "aix", target_os = "hurd"))))]
fn reset_stat_mtime_nanoseconds(stat: &libc::stat) -> i64 {
    stat.st_mtime_nsec
}

#[cfg(any(target_os = "aix", target_os = "hurd"))]
fn reset_stat_mtime_nanoseconds(stat: &libc::stat) -> i64 {
    stat.st_mtim.tv_nsec
}

#[cfg(all(unix, target_vendor = "apple"))]
fn reset_stat_mtime_nanoseconds(stat: &libc::stat) -> i64 {
    // Rust libc exposes Darwin's st_mtimespec through these stable aliases.
    stat.st_mtime_nsec
}

#[cfg(unix)]
pub(super) fn reset_stat_device(stat: &libc::stat) -> u64 {
    #[cfg(any(target_os = "linux", target_os = "android"))]
    {
        stat.st_dev
    }
    #[cfg(not(any(target_os = "linux", target_os = "android")))]
    {
        stat.st_dev as u64
    }
}

#[cfg(unix)]
pub(super) fn reset_stat_inode(stat: &libc::stat) -> u64 {
    stat.st_ino
}
