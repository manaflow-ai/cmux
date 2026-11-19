//! Freed memory goes back to the system once the daemon goes quiet (CMUX-571
//! infinite items).
//!
//! glibc keeps the pages a daemon frees: a burst of requests (opening a
//! thousand workspaces, a day of switches and tab cycles) leaves its arenas
//! holding pages that no live allocation uses. dhat at 300 workspaces read a
//! 15 MB live heap in cmux-tui where PSS read about 120 MB
//! (manaflow-ai/cmux#43824), and both daemons grew every simulated day in the
//! infinite-items run with a flat live heap. So the cmux-tui daemon and acpmux
//! call [`note_activity`] where they do work (a request, a batch of terminal
//! output, an agent message), and [`QUIET`] after the last of it one worker
//! thread calls `malloc_trim(0)`, which hands every free whole page of every
//! arena back with `madvise`.
//!
//! An idle daemon runs nothing: the worker blocks on a condition variable
//! with no timeout until the next activity, then waits out one quiet period
//! per burst. The worker starts with the first activity, so a process that
//! serves nothing (a CLI call) never starts it.
//!
//! Only glibc has `malloc_trim`: the musl builds and macOS compile this to
//! nothing.

#[cfg(all(target_os = "linux", target_env = "gnu"))]
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
#[cfg(all(target_os = "linux", target_env = "gnu"))]
use std::sync::{Condvar, Mutex, OnceLock, PoisonError};
use std::time::Duration;

/// How long after the last activity the daemon gives its free pages back.
pub const QUIET: Duration = Duration::from_secs(5);

#[cfg(all(target_os = "linux", target_env = "gnu"))]
struct Trimmer {
    /// Counts activity; the worker trims only when it did not move over a whole [`QUIET`].
    activity: AtomicU64,
    /// Activity came since the last trim: the worker has a trim to make.
    armed: AtomicBool,
    lock: Mutex<()>,
    wake: Condvar,
}

#[cfg(all(target_os = "linux", target_env = "gnu"))]
static TRIMMER: OnceLock<&'static Trimmer> = OnceLock::new();

/// Notes that the daemon did work that may have freed memory. Cheap: two
/// atomic operations, plus a wake of the worker on the first activity after a
/// trim.
pub fn note_activity() {
    #[cfg(all(target_os = "linux", target_env = "gnu"))]
    {
        let trimmer = TRIMMER.get_or_init(start);
        // SeqCst with the worker's `disarm`: a note that still sees `armed` set is seen by the
        // worker's count read after it clears `armed`.
        trimmer.activity.fetch_add(1, Ordering::SeqCst);
        if !trimmer.armed.load(Ordering::SeqCst) && !trimmer.armed.swap(true, Ordering::SeqCst) {
            // Under the lock, so the worker is either before its check of `armed` (and sees it)
            // or already waiting (and wakes).
            drop(trimmer.lock.lock().unwrap_or_else(PoisonError::into_inner));
            trimmer.wake.notify_one();
        }
    }
}

#[cfg(all(target_os = "linux", target_env = "gnu"))]
fn start() -> &'static Trimmer {
    let trimmer: &'static Trimmer = Box::leak(Box::new(Trimmer {
        activity: AtomicU64::new(0),
        armed: AtomicBool::new(false),
        lock: Mutex::new(()),
        wake: Condvar::new(),
    }));
    // A failed spawn leaves the pages where they are, as before.
    let _ = std::thread::Builder::new()
        .name("malloc-quiet-trim".into())
        .stack_size(64 * 1024)
        .spawn(move || run(trimmer, QUIET, release_free_pages));
    trimmer
}

#[cfg(all(target_os = "linux", target_env = "gnu"))]
fn run(trimmer: &Trimmer, quiet: Duration, trim: impl Fn()) {
    loop {
        let mut guard = trimmer.lock.lock().unwrap_or_else(PoisonError::into_inner);
        while !trimmer.armed.load(Ordering::Acquire) {
            guard = trimmer.wake.wait(guard).unwrap_or_else(PoisonError::into_inner);
        }
        drop(guard);
        let seen = quiet_period(trimmer, quiet);
        if disarm(trimmer, seen) {
            trim();
        }
    }
}

/// Clears `armed` before the trim, so activity during it arms the next one. Activity after the
/// quiet period's last read saw `armed` still set and woke no one: then `armed` stays set and the
/// worker waits out another quiet period instead of trimming before that work frees.
#[cfg(all(target_os = "linux", target_env = "gnu"))]
fn disarm(trimmer: &Trimmer, seen: u64) -> bool {
    trimmer.armed.store(false, Ordering::SeqCst);
    if trimmer.activity.load(Ordering::SeqCst) == seen {
        return true;
    }
    trimmer.armed.store(true, Ordering::SeqCst);
    false
}

/// Returns the activity count once `quiet` passed with no activity.
#[cfg(all(target_os = "linux", target_env = "gnu"))]
fn quiet_period(trimmer: &Trimmer, quiet: Duration) -> u64 {
    let mut seen = trimmer.activity.load(Ordering::SeqCst);
    loop {
        std::thread::sleep(quiet);
        let now = trimmer.activity.load(Ordering::SeqCst);
        if now == seen {
            return seen;
        }
        seen = now;
    }
}

/// Hands every free whole page of the allocator back to the system.
pub fn release_free_pages() {
    #[cfg(all(target_os = "linux", target_env = "gnu"))]
    {
        unsafe extern "C" {
            fn malloc_trim(pad: usize) -> std::ffi::c_int;
        }
        // SAFETY: no pointer is passed; glibc documents malloc_trim as MT-Safe, and a pad of
        // zero returns every free whole page.
        let _ = unsafe { malloc_trim(0) };
    }
}

#[cfg(all(test, target_os = "linux", target_env = "gnu"))]
mod tests {
    use super::*;
    use std::sync::Arc;
    use std::sync::atomic::AtomicUsize;

    fn trimmer() -> &'static Trimmer {
        Box::leak(Box::new(Trimmer {
            activity: AtomicU64::new(0),
            armed: AtomicBool::new(false),
            lock: Mutex::new(()),
            wake: Condvar::new(),
        }))
    }

    fn note(trimmer: &Trimmer) {
        trimmer.activity.fetch_add(1, Ordering::SeqCst);
        if !trimmer.armed.swap(true, Ordering::SeqCst) {
            drop(trimmer.lock.lock().unwrap());
            trimmer.wake.notify_one();
        }
    }

    /// Waits up to `limit` for `count` to reach `want`.
    fn reaches(count: &AtomicUsize, want: usize, limit: Duration) -> bool {
        let start = std::time::Instant::now();
        while count.load(Ordering::SeqCst) < want {
            if start.elapsed() > limit {
                return false;
            }
            std::thread::yield_now();
        }
        true
    }

    #[test]
    fn one_trim_per_burst_after_the_quiet_period_and_none_while_idle() {
        let t = trimmer();
        let trims = Arc::new(AtomicUsize::new(0));
        let counted = trims.clone();
        let _ = std::thread::Builder::new().name("quiet-trim-test".into()).spawn(move || {
            run(t, Duration::from_millis(50), move || {
                counted.fetch_add(1, Ordering::SeqCst);
            });
        });
        // Idle from the start: no trim.
        std::thread::sleep(Duration::from_millis(200));
        assert_eq!(trims.load(Ordering::SeqCst), 0);
        // A burst: one trim, after it went quiet.
        for _ in 0..20 {
            note(t);
            std::thread::sleep(Duration::from_millis(10));
        }
        assert!(reaches(&trims, 1, Duration::from_secs(5)));
        std::thread::sleep(Duration::from_millis(300));
        assert_eq!(trims.load(Ordering::SeqCst), 1, "idle after the trim: no second one");
        // The next burst arms it again.
        note(t);
        assert!(reaches(&trims, 2, Duration::from_secs(5)));
    }

    #[test]
    fn activity_through_the_quiet_period_holds_the_trim_back() {
        let t = trimmer();
        let trims = Arc::new(AtomicUsize::new(0));
        let counted = trims.clone();
        let _ = std::thread::Builder::new().name("quiet-trim-test".into()).spawn(move || {
            run(t, Duration::from_millis(100), move || {
                counted.fetch_add(1, Ordering::SeqCst);
            });
        });
        // Busy for 600 ms, a note every 20 ms: still no trim at the end.
        for _ in 0..30 {
            note(t);
            std::thread::sleep(Duration::from_millis(20));
        }
        assert_eq!(trims.load(Ordering::SeqCst), 0);
        assert!(reaches(&trims, 1, Duration::from_secs(5)));
    }

    #[test]
    fn activity_between_the_last_quiet_read_and_the_disarm_keeps_it_armed() {
        let t = trimmer();
        note(t);
        // The quiet period's last read.
        let seen = t.activity.load(Ordering::SeqCst);
        // A request lands now: it sees `armed` still set and wakes no one.
        note(t);
        assert!(!disarm(t, seen), "no trim before that request's work frees");
        assert!(t.armed.load(Ordering::SeqCst), "the next quiet period trims it");
        // Quiet since: the next disarm trims.
        let seen = t.activity.load(Ordering::SeqCst);
        assert!(disarm(t, seen));
        assert!(!t.armed.load(Ordering::SeqCst));
    }

    #[test]
    fn note_activity_and_a_real_trim_run() {
        note_activity();
        release_free_pages();
    }
}
