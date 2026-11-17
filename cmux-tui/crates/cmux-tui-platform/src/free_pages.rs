//! Gives the allocator's free pages back to the system once the daemon's
//! startup has settled (CMUX-571, goal ram-baseline).
//!
//! The daemon allocates and frees a burst while it starts (the session
//! registry, the config and catalogs, the launch snapshot, the first client's
//! requests). macOS's malloc keeps the pages of what was freed, so they stay
//! dirty and count in the process's physical footprint for as long as the
//! daemon lives, though nothing uses them. One
//! `malloc_zone_pressure_relief(NULL, 0)` after the burst returns them; glibc
//! gets `malloc_trim(0)`, the same thing for its arenas.
//!
//! Nothing waits on it: it runs once, on a thread of its own, [`SETTLE`]
//! after the daemon is ready, so no request or terminal output is slower,
//! and the thread ends after the call (no timer stays behind to wake the
//! idle daemon).

use std::thread::JoinHandle;
use std::time::Duration;

/// From the daemon's readiness to the release: the app's launch reaches its
/// first window and settles its first requests well inside it.
pub const SETTLE: Duration = Duration::from_secs(8);

/// Returns the allocator's free whole pages to the system now.
pub fn release() {
    #[cfg(target_os = "macos")]
    {
        unsafe extern "C" {
            fn malloc_zone_pressure_relief(zone: *mut std::ffi::c_void, goal: usize) -> usize;
        }
        // SAFETY: the allocator's thread-safe API takes NULL for every zone
        // and zero for no goal; no pointer of ours is passed.
        let _ = unsafe { malloc_zone_pressure_relief(std::ptr::null_mut(), 0) };
    }
    #[cfg(all(target_os = "linux", target_env = "gnu"))]
    {
        // SAFETY: no pointer is passed; glibc documents malloc_trim as
        // MT-Safe, and zero asks it to return every free whole page.
        let _ = unsafe { libc::malloc_trim(0) };
    }
}

/// Calls [`release`] once, `after` from now, on a thread named
/// `cmux-free-pages`. None when the thread could not start (the daemon runs
/// on, keeping its pages).
pub fn release_after(after: Duration) -> Option<JoinHandle<()>> {
    std::thread::Builder::new()
        .name("cmux-free-pages".into())
        .spawn(move || {
            std::thread::sleep(after);
            release();
        })
        .ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn release_returns_and_leaves_live_blocks_intact() {
        let kept: Vec<(u8, Vec<u8>)> = (0u8..64).map(|i| (i, vec![i; 64 * 1024])).collect();
        let freed: Vec<Vec<u8>> = (0..256).map(|_| vec![7u8; 64 * 1024]).collect();
        drop(freed);
        release();
        for (i, block) in &kept {
            assert!(block.iter().all(|b| b == i));
        }
    }

    #[test]
    fn release_after_runs_once_and_ends() {
        let handle = release_after(Duration::from_millis(1)).expect("thread starts");
        handle.join().expect("release thread ends without a panic");
    }
}
