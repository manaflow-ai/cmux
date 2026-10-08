//! The open-file limit of a process that owns many terminals.
//!
//! A cmux daemon holds several descriptors per terminal (its host socket and
//! duplicates), so the default soft `RLIMIT_NOFILE` (256 on macOS, often 1024
//! on Linux) stops it at a few dozen to a few hundred terminals. The daemon
//! raises its soft limit at start ([`raise_open_file_limit`]) and every
//! process it starts for a terminal gets the original soft limit back
//! ([`restore_open_file_limit_in_child`]): programs in a terminal see the
//! limit of the environment that launched cmux, and a raised limit is not
//! inherited by code that uses `select(2)` with descriptors below 1024.
//! Ghostty does the same for its own children.

use std::io;
use std::sync::atomic::{AtomicU64, Ordering};

/// The daemon never asks for more than this many descriptors. It is enough
/// for far more terminals than one machine can run with real PTYs, and it
/// bounds the post-fork descriptor sweep that platforms without
/// `close_range` run for every spawned terminal.
pub const OPEN_FILE_LIMIT_CEILING: u64 = 65_536;

/// The soft limit before [`raise_open_file_limit`] changed it, plus one;
/// zero while it has not changed it.
static ORIGINAL_SOFT_LIMIT: AtomicU64 = AtomicU64::new(0);

/// The soft limit before and after a raise.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct OpenFileLimit {
    pub before: u64,
    pub after: u64,
}

/// Raise this process's soft `RLIMIT_NOFILE` to `min(hard, ceiling)` (and on
/// macOS to at most `kern.maxfilesperproc`). It never
/// lowers the soft limit and never changes the hard limit. The first call
/// that changes the limit records the original soft limit for
/// [`restore_open_file_limit_in_child`].
pub fn raise_open_file_limit(ceiling: u64) -> io::Result<OpenFileLimit> {
    let mut limit = libc::rlimit { rlim_cur: 0, rlim_max: 0 };
    // SAFETY: `limit` is valid writable storage for one rlimit.
    if unsafe { libc::getrlimit(libc::RLIMIT_NOFILE, &raw mut limit) } != 0 {
        return Err(io::Error::last_os_error());
    }
    let before = limit.rlim_cur;
    let target = limit.rlim_max.min(ceiling);
    // setrlimit refuses a soft limit above kern.maxfilesperproc on macOS
    // even when the hard limit is RLIM_INFINITY.
    #[cfg(target_os = "macos")]
    let target = target.min(macos_max_files_per_process());
    if target <= before {
        return Ok(OpenFileLimit { before, after: before });
    }
    let raised = libc::rlimit { rlim_cur: target, rlim_max: limit.rlim_max };
    // SAFETY: `raised` is a valid rlimit; only the soft limit grows.
    if unsafe { libc::setrlimit(libc::RLIMIT_NOFILE, &raw const raised) } != 0 {
        return Err(io::Error::last_os_error());
    }
    let _ = ORIGINAL_SOFT_LIMIT.compare_exchange(
        0,
        before.saturating_add(1),
        Ordering::AcqRel,
        Ordering::Acquire,
    );
    Ok(OpenFileLimit { before, after: target })
}

#[cfg(target_os = "macos")]
fn macos_max_files_per_process() -> u64 {
    let mut value: libc::c_int = 0;
    let mut size = std::mem::size_of::<libc::c_int>();
    // SAFETY: the name is NUL-terminated and `value`/`size` describe valid storage.
    let ok = unsafe {
        libc::sysctlbyname(
            c"kern.maxfilesperproc".as_ptr(),
            (&raw mut value).cast(),
            &raw mut size,
            std::ptr::null_mut(),
            0,
        )
    } == 0;
    if ok && value > 0 { value as u64 } else { libc::OPEN_MAX as u64 }
}

/// Give a child the soft limit this process had before
/// [`raise_open_file_limit`]. Call it between fork and exec: it only calls
/// `setrlimit(2)`, which is async-signal-safe. Without an earlier raise it
/// does nothing.
pub fn restore_open_file_limit_in_child() -> io::Result<()> {
    let recorded = ORIGINAL_SOFT_LIMIT.load(Ordering::Acquire);
    if recorded == 0 {
        return Ok(());
    }
    let mut limit = libc::rlimit { rlim_cur: 0, rlim_max: 0 };
    // SAFETY: `limit` is valid writable storage for one rlimit.
    if unsafe { libc::getrlimit(libc::RLIMIT_NOFILE, &raw mut limit) } != 0 {
        return Err(io::Error::last_os_error());
    }
    let original = (recorded - 1).min(limit.rlim_max);
    let restored = libc::rlimit { rlim_cur: original, rlim_max: limit.rlim_max };
    // SAFETY: `restored` is a valid rlimit at or below the hard limit.
    if unsafe { libc::setrlimit(libc::RLIMIT_NOFILE, &raw const restored) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}
