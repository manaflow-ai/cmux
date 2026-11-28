//! Gives the pages a long fold freed back to the system. A fold of a long chat's whole log
//! (`hub/processes.rs`, `hub/hosts/journal.rs`) allocates and frees tens of MB, and the
//! allocator keeps the freed pages for reuse: the live heap fell (dhat at 1G: 68 MB peak to
//! 55 MB) while the daemon's resident memory did not. Called once after such a fold, never per
//! record: a trim walks the allocator's free lists.

/// Returns the allocator's free pages to the system: `malloc_trim(0)` on glibc's malloc,
/// `mi_collect(true)` on mimalloc, `malloc_zone_pressure_relief` on macOS's malloc. Nothing in a
/// `dhat-heap` build (its allocator is dhat's) or on another target.
pub fn return_freed() {
    #[cfg(all(
        target_os = "linux",
        target_env = "gnu",
        not(feature = "dhat-heap"),
        not(feature = "mimalloc-gnu")
    ))]
    // SAFETY: no pointer is passed; glibc documents `malloc_trim` as MT-Safe.
    unsafe {
        libc::malloc_trim(0);
    }
    #[cfg(all(
        target_os = "linux",
        not(feature = "dhat-heap"),
        not(feature = "musl-malloc"),
        any(target_env = "musl", feature = "mimalloc-gnu")
    ))]
    {
        // The linked mimalloc's (the global allocator in `main.rs`).
        use mimalloc as _;
        unsafe extern "C" {
            fn mi_collect(force: bool);
        }
        // SAFETY: a plain call into the linked mimalloc; it collects under its own locks.
        unsafe { mi_collect(true) };
    }
    #[cfg(all(target_os = "macos", not(feature = "dhat-heap")))]
    {
        unsafe extern "C" {
            fn malloc_zone_pressure_relief(zone: *mut std::ffi::c_void, goal: usize) -> usize;
        }
        // SAFETY: a null zone means every zone, and goal 0 means as much as can go back.
        unsafe { malloc_zone_pressure_relief(std::ptr::null_mut(), 0) };
    }
}
