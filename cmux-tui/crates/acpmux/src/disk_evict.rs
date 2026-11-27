//! Clears re-creatable bytes off a Cloud machine's root disk when it runs low, before it is full
//! (Leo: "what happens with growing disk"). cmux Cloud grows the disk at the same budget
//! (cmux-platform `DISK_GROW`, cmux-cloud-disk [`cmux_cloud_disk::almost_full_under`]); a grow
//! takes minutes and stops at the plan's cap, so the guest frees what it can at once.
//!
//! Runs inside the background disk walk (`disk_usage.rs`, every few minutes at nice 19), only
//! when the root filesystem has under `max(4 GiB, 15%)` free, and stops once it has
//! [`TARGET_FREE_SHARE`] free again. What it may clear, in this order, and nothing else:
//! - the package managers' download caches of [`PACKAGE_CACHES`], each only once untouched for
//!   [`CACHE_IDLE`] (an install writing to one keeps it);
//! - cargo build output (a `target` whose `CACHEDIR.TAG` cargo wrote) untouched for
//!   [`BUILD_IDLE`], oldest first (a running build writes into it, so it stays).
//!
//! "Untouched" is the newest modification time of the directory and the two levels under it, so
//! no process is ever scanned (plans/cmux-next/pty-holder.md).
//!
//! Never a user's file: never a checkout's sources, `.git`, a `node_modules`, `~/chats`' own
//! files, or anything outside the home directory or on another filesystem. A symlink is never
//! followed. Every path it clears is in the split's `evicted`, the event the machine card shows.

use crate::disk_usage::{Evicted, statvfs};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

/// The free bytes under which the disk is low, on a small disk.
pub const LOW_FREE_BYTES: u64 = cmux_cloud_disk::ALMOST_FULL_FREE_BYTES;
/// The share of the disk under which it is low, on a larger one.
pub const LOW_FREE_SHARE: f64 = cmux_cloud_disk::ALMOST_FULL_FREE_SHARE;
/// The free share an eviction stops at.
pub const TARGET_FREE_SHARE: f64 = 0.25;
/// How long cargo build output sits untouched before it may go.
pub const BUILD_IDLE: Duration = Duration::from_secs(2 * 60 * 60);
/// How long a package cache sits untouched before it may go.
pub const CACHE_IDLE: Duration = Duration::from_secs(10 * 60);

/// The package managers' download caches under home. Each is re-fetched on the next install.
pub const PACKAGE_CACHES: &[&str] = &[
    ".npm/_cacache",
    ".bun/install/cache",
    ".cache/bun",
    ".cache/yarn",
    ".yarn/berry/cache",
    ".cache/pnpm",
    ".local/share/pnpm/store",
    ".cache/pip",
    ".cache/uv",
    ".cache/go-build",
    ".cache/node-gyp",
];

/// Whether a disk of `total` bytes with `free` free is low.
pub fn is_low(total: u64, free: u64) -> bool {
    free < cmux_cloud_disk::almost_full_under(total)
}

/// The free bytes an eviction stops at on a disk of `total` bytes.
pub fn target_free(total: u64) -> u64 {
    ((total as f64 * TARGET_FREE_SHARE) as u64).max(LOW_FREE_BYTES)
}

/// What may go, in order: the package caches untouched for [`CACHE_IDLE`], then cargo build
/// output untouched for [`BUILD_IDLE`], oldest first. `build_dirs` comes from the walk;
/// `last_touched` says when a directory was last written.
pub fn candidates(
    home: &Path,
    build_dirs: &[PathBuf],
    now: SystemTime,
    last_touched: impl Fn(&Path) -> Option<SystemTime>,
) -> Vec<PathBuf> {
    let idle_for = |dir: &Path, idle: Duration| {
        last_touched(dir).filter(|t| now.duration_since(*t).is_ok_and(|i| i >= idle))
    };
    let mut out: Vec<PathBuf> = PACKAGE_CACHES
        .iter()
        .map(|rel| home.join(rel))
        .filter(|path| is_plain_dir(path) && idle_for(path, CACHE_IDLE).is_some())
        .collect();
    let mut builds: Vec<(SystemTime, &PathBuf)> = build_dirs
        .iter()
        .filter(|dir| dir.starts_with(home) && is_plain_dir(dir))
        .filter_map(|dir| idle_for(dir, BUILD_IDLE).map(|t| (t, dir)))
        .collect();
    builds.sort();
    out.extend(builds.into_iter().map(|(_, dir)| dir.clone()));
    out
}

/// A directory itself, not a symlink to one.
fn is_plain_dir(path: &Path) -> bool {
    std::fs::symlink_metadata(path).is_ok_and(|m| m.is_dir())
}

/// When a directory was last written: the newest modification time of it and the directories
/// one and two levels in (a cargo `target`'s `debug`, `debug/deps`, `debug/incremental`; a
/// cache's index and content shards), where every build or install adds or replaces files.
pub fn last_touched(dir: &Path) -> Option<SystemTime> {
    let mtime = |p: &Path| std::fs::symlink_metadata(p).ok().and_then(|m| m.modified().ok());
    let mut newest = mtime(dir)?;
    for child in std::fs::read_dir(dir).ok()?.flatten() {
        let path = child.path();
        if !is_plain_dir(&path) {
            continue;
        }
        newest = newest.max(mtime(&path).unwrap_or(newest));
        for grand in std::fs::read_dir(&path).into_iter().flatten().flatten() {
            let grand = grand.path();
            if is_plain_dir(&grand) {
                newest = newest.max(mtime(&grand).unwrap_or(newest));
            }
        }
    }
    Some(newest)
}

/// Clears candidates in order until `free_now` says the disk has `target` free. `remove` clears
/// one path. Returns the cleared paths.
pub fn evict(
    candidates: &[PathBuf],
    target: u64,
    mut free_now: impl FnMut() -> Option<u64>,
    mut remove: impl FnMut(&Path) -> bool,
) -> Vec<PathBuf> {
    let mut cleared = Vec::new();
    for c in candidates {
        if free_now().is_none_or(|free| free >= target) {
            break;
        }
        if remove(c) {
            cleared.push(c.clone());
        }
    }
    cleared
}

/// The walk's hook: when the root disk is low, clear what may go and say what went.
pub fn evict_if_low(home: &Path, build_dirs: &[PathBuf], now_ms: u64) -> Option<Evicted> {
    let root = Path::new("/");
    let before = statvfs(root)?;
    if !is_low(before.total, before.free) {
        return None;
    }
    let candidates = candidates(home, build_dirs, SystemTime::now(), last_touched);
    let cleared = evict(
        &candidates,
        target_free(before.total),
        || statvfs(root).map(|r| r.free),
        |path| std::fs::remove_dir_all(path).is_ok(),
    );
    if cleared.is_empty() {
        return None;
    }
    let after = statvfs(root).map_or(before.free, |r| r.free);
    let evicted = Evicted {
        at: now_ms,
        freed_bytes: after.saturating_sub(before.free),
        paths: cleared.iter().map(|p| p.to_string_lossy().into_owned()).collect(),
    };
    tracing::info!(
        freed_bytes = evicted.freed_bytes,
        free_before = before.free,
        total = before.total,
        paths = ?evicted.paths,
        "disk low: cleared caches and idle build output"
    );
    Some(evicted)
}

#[cfg(test)]
#[path = "disk_evict_tests.rs"]
mod tests;
