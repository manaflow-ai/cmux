//! Gives the pages a long fold freed back to the system. A fold of a long chat's whole log
//! (`hub/processes.rs`, `hub/hosts/journal.rs`) allocates and frees tens of MB, and glibc's
//! malloc keeps the freed pages for reuse: the live heap fell (dhat at 1G: 68 MB peak to 55 MB)
//! while the daemon's resident memory did not (rssIdle median 128.7 MiB against 127.6 on base,
//! 3 runs each). Called once after such a fold, never per record: a trim walks the free lists.

/// Returns glibc's free pages to the system (`malloc_trim(0)`). Nothing on mimalloc: its
/// options (`main.rs`, `purge_delay` 0) already give freed pages back, and a forced
/// `mi_collect(true)` there measured no lower (restartRss median 175.7 MiB against 172.1). Nor
/// in a `dhat-heap` build or on another target.
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
}
