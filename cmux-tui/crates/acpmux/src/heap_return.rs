//! Gives the pages a long fold freed back to the system. A fold of a long chat's whole log
//! (`hub/processes.rs`, `hub/hosts/journal.rs`) allocates and frees tens of MB, and glibc's
//! malloc keeps the freed pages for reuse: the live heap fell (dhat at 1G: 68 MB peak to 55 MB)
//! while the daemon's resident memory did not (rssIdle median 128.7 MiB against 127.6 on base,
//! 3 runs each). Called once after such a fold, never per record: a trim walks the free lists.
//! The quiet trim (`cmux_tui_platform::malloc_quiet_trim`) gives pages back 5 s after the last
//! request; this one gives a fold's back as it ends, before a restart's adoption or a chat's
//! open reads on (restartRss median 121.1 to 114.0 MiB at 1G).

/// Returns glibc's free pages to the system (`malloc_trim(0)`). Nothing on mimalloc: its
/// options (`main.rs`, `purge_delay` 0) already give freed pages back, and a forced
/// `mi_collect(true)` there measured no lower (restartRss median 175.7 MiB against 172.1). Nor
/// in a `dhat-heap` build or on another target.
pub fn return_freed() {
    #[cfg(test)]
    RETURNS.with(|n| n.set(n.get() + 1));
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
    // The shipped macOS daemon runs on the system allocator (no global allocator is set there),
    // whose zones also keep freed pages; this asks every zone to give them back.
    #[cfg(all(target_os = "macos", not(feature = "dhat-heap")))]
    // SAFETY: a null zone means every zone; a goal of 0 means as much as can be released.
    unsafe {
        malloc_zone_pressure_relief(std::ptr::null_mut(), 0);
    }
}

#[cfg(all(target_os = "macos", not(feature = "dhat-heap")))]
unsafe extern "C" {
    fn malloc_zone_pressure_relief(zone: *mut std::ffi::c_void, goal: usize) -> usize;
}

#[cfg(test)]
thread_local! {
    static RETURNS: std::cell::Cell<u64> = const { std::cell::Cell::new(0) };
}

/// How many times this thread called [`return_freed`]: a test's own count, as tests run in parallel.
#[cfg(test)]
pub fn returns_on_this_thread() -> u64 {
    RETURNS.with(|n| n.get())
}

#[cfg(test)]
mod tests {
    #[test]
    fn a_return_is_counted_and_harmless_on_any_allocator() {
        let before = super::returns_on_this_thread();
        let kept = vec![7u8; 1 << 20];
        drop(vec![0u8; 8 << 20]);
        super::return_freed();
        assert_eq!(super::returns_on_this_thread(), before + 1);
        assert!(kept.iter().all(|b| *b == 7));
    }
}
