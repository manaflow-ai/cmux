//! Freed memory goes back to the OS after chats leave memory (`hub/evict.rs`; Leo 2026-11-14:
//! "the bigger question is of memory and cpu staying flat on infinite chats").
//!
//! mimalloc (the daemon's allocator on Linux, `main.rs`) gives a page back only when its owning
//! thread collects it: a chat's session was allocated on whichever runtime workers served it, and
//! when the reaper drops it those blocks are freed from another thread, onto the owners' pages.
//! The owner sees them on its next allocation in that size class, and keeps an emptied page
//! retired for reuse, so at n=1,000 the heap held 224-249 MB with the resident cap on or off,
//! where glibc returned the same work to 170-207 MB. `purge_delay` 0 (`main.rs`) purges a freed
//! arena slice at once, but only once a thread has handed the page back.
//!
//! So an eviction pass that evicted a chat calls [`after_eviction`]: the reaper's own thread
//! collects with force (`mi_collect(true)`: its freed and retired pages, then the arenas), and
//! every runtime worker collects once on its next park ([`on_worker_park`], a tokio
//! `on_thread_park` hook: one atomic load a park while nothing was evicted).

#[cfg(all(target_os = "linux", not(feature = "dhat-heap")))]
mod imp {
    use std::cell::Cell;
    use std::sync::atomic::{AtomicU64, Ordering};

    // Links the crate that defines `mi_collect` (libmimalloc-sys, through mimalloc).
    use mimalloc as _;

    unsafe extern "C" {
        fn mi_collect(force: bool);
    }

    /// Bumped by each eviction pass that evicted a chat; a worker collects when it has not seen
    /// the newest.
    static EVICTED: AtomicU64 = AtomicU64::new(0);

    thread_local! {
        static SEEN: Cell<u64> = const { Cell::new(0) };
    }

    fn collect() {
        // SAFETY: mimalloc's collect of the calling thread's heap and the arenas; callable from
        // any thread at any time, and a no-op on a thread mimalloc never allocated on.
        unsafe { mi_collect(true) }
    }

    pub fn after_eviction() {
        let now = EVICTED.fetch_add(1, Ordering::Relaxed) + 1;
        SEEN.with(|seen| seen.set(now));
        collect();
    }

    pub fn on_worker_park() {
        let now = EVICTED.load(Ordering::Relaxed);
        if SEEN.with(|seen| seen.replace(now)) != now {
            collect();
        }
    }

    pub fn evicted_passes() -> u64 {
        EVICTED.load(Ordering::Relaxed)
    }
}

#[cfg(not(all(target_os = "linux", not(feature = "dhat-heap"))))]
mod imp {
    pub fn after_eviction() {}
    pub fn on_worker_park() {}
    pub fn evicted_passes() -> u64 {
        0
    }
}

/// An eviction pass evicted at least one chat: this thread returns what it can now, and each
/// runtime worker on its next park. Call at most once a pass.
pub fn after_eviction() {
    imp::after_eviction()
}

/// The runtime's `on_thread_park` hook: collects once after each eviction pass this worker has
/// not collected for.
pub fn on_worker_park() {
    imp::on_worker_park()
}

/// How many eviction passes asked for a collect since the start (0 where nothing collects).
pub fn evicted_passes() -> u64 {
    imp::evicted_passes()
}

#[cfg(test)]
mod tests {
    #[test]
    fn a_pass_that_evicted_is_counted_and_a_parked_worker_collects_once() {
        let before = super::evicted_passes();
        super::after_eviction();
        if cfg!(all(target_os = "linux", not(feature = "dhat-heap"))) {
            assert!(super::evicted_passes() > before);
        }
        // Another thread: it has not seen the pass, collects, then has nothing left to do.
        std::thread::spawn(|| {
            let _warm = vec![0u8; 1 << 20];
            super::on_worker_park();
            super::on_worker_park();
        })
        .join()
        .unwrap();
    }
}
