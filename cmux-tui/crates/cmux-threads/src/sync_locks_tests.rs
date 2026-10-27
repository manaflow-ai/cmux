//! Each test waits at its own source line: the site table is process-wide
//! and tests run in parallel, so a site belongs to one test.

use super::{Condvar, Mutex, RwLock};
use crate::blocking::{self, AllowReason, BlockingKind, BlockingMode};
use std::sync::Arc;
use std::sync::mpsc::channel;
use std::time::Duration;

/// How long a holder keeps the lock in the long-wait tests: over the 2 ms
/// budget.
const LONG_HOLD: Duration = Duration::from_millis(5);

/// How long a holder keeps the lock in the short-wait tests: far under it.
const SHORT_HOLD: Duration = Duration::from_micros(100);

fn site_at(line: u32) -> Option<blocking::BlockingSite> {
    blocking::snapshot().site(file!(), line).copied()
}

/// Runs `f` on a new thread that disallows blocking in panic mode, its own
/// mode only: a long wait records and never panics, and the other tests of
/// the binary keep the process-wide mode.
fn on_disallowed_thread<R: Send + 'static>(f: impl FnOnce() -> R + Send + 'static) -> R {
    std::thread::spawn(|| {
        blocking::with_mode(BlockingMode::Panic, || {
            blocking::disallow_blocking();
            f()
        })
    })
    .join()
    .expect("the disallowed thread returns")
}

/// Takes `lock` on a holder thread, then runs `wait` on a disallowed
/// waiter thread while the holder keeps it for `hold`, and returns what
/// `wait` returned. The holder starts timing only once the waiter is about
/// to wait.
fn contend<L: Send + Sync + 'static, R: Send + 'static>(
    lock: L,
    hold: Duration,
    take: impl FnOnce(&L, &dyn Fn()) + Send + 'static,
    wait: impl FnOnce(&L) -> R + Send + 'static,
) -> R {
    let lock = Arc::new(lock);
    let (held_tx, held_rx) = channel();
    let (go_tx, go_rx) = channel::<()>();
    let holder = {
        let lock = Arc::clone(&lock);
        std::thread::spawn(move || {
            take(&lock, &|| {
                held_tx.send(()).expect("held");
                go_rx.recv().expect("the waiter is about to wait");
                std::thread::sleep(hold);
            });
        })
    };
    held_rx.recv().expect("the holder took the lock");
    let result = on_disallowed_thread(move || {
        go_tx.send(()).expect("go");
        wait(&lock)
    });
    holder.join().expect("holder");
    result
}

#[cfg(debug_assertions)]
#[test]
fn a_5ms_mutex_holder_makes_a_disallowed_waiter_one_lock_wait_site() {
    let line = contend(
        Mutex::new(0u32),
        LONG_HOLD,
        |mutex, hold| {
            let _guard = mutex.lock().expect("lock");
            hold();
        },
        |mutex| {
            let line = line!() + 1;
            *mutex.lock().expect("lock") += 1;
            line
        },
    );
    let site = site_at(line).expect("the long wait is a site");
    assert_eq!(site.kinds.iter().collect::<Vec<_>>(), vec![BlockingKind::LockWait]);
    assert_eq!(site.count, 1);
    assert!(!site.lane_sync, "{site:?}");
}

#[test]
fn a_100us_mutex_holder_records_nothing() {
    let line = contend(
        Mutex::new(0u32),
        SHORT_HOLD,
        |mutex, hold| {
            let _guard = mutex.lock().expect("lock");
            hold();
        },
        |mutex| {
            let line = line!() + 1;
            *mutex.lock().expect("lock") += 1;
            line
        },
    );
    assert_eq!(site_at(line), None);
}

#[cfg(debug_assertions)]
#[test]
fn a_5ms_rwlock_writer_makes_disallowed_readers_and_writers_sites() {
    let read_line = contend(
        RwLock::new(0u32),
        LONG_HOLD,
        |lock, hold| {
            let _guard = lock.write().expect("write");
            hold();
        },
        |lock| {
            let line = line!() + 1;
            let _value = *lock.read().expect("read");
            line
        },
    );
    let write_line = contend(
        RwLock::new(0u32),
        LONG_HOLD,
        |lock, hold| {
            let _guard = lock.read().expect("read");
            hold();
        },
        |lock| {
            let line = line!() + 1;
            *lock.write().expect("write") += 1;
            line
        },
    );
    for line in [read_line, write_line] {
        let site = site_at(line).expect("the long wait is a site");
        assert_eq!(site.kinds.iter().collect::<Vec<_>>(), vec![BlockingKind::LockWait]);
        assert_eq!(site.count, 1);
    }
}

#[cfg(debug_assertions)]
#[test]
fn a_long_condvar_wait_on_a_disallowed_thread_is_a_condvar_wait_site() {
    let line = on_disallowed_thread(|| {
        let mutex = Mutex::new(());
        let condvar = Condvar::new();
        let guard = mutex.lock().expect("lock");
        let line = line!() + 1;
        let (_guard, timeout) = condvar.wait_timeout(guard, LONG_HOLD).expect("wait");
        assert!(timeout.timed_out());
        line
    });
    let site = site_at(line).expect("the long wait is a site");
    assert_eq!(site.kinds.iter().collect::<Vec<_>>(), vec![BlockingKind::CondvarWait]);
}

#[test]
fn waits_on_an_ordinary_or_allowed_thread_record_nothing() {
    let lines = std::thread::spawn(|| {
        let mutex = Mutex::new(());
        let condvar = Condvar::new();
        let ordinary = line!() + 1;
        let (guard, _) =
            condvar.wait_timeout(mutex.lock().expect("lock"), LONG_HOLD).expect("wait");
        drop(guard);
        blocking::disallow_blocking();
        blocking::allow_blocking(AllowReason::Shutdown, || {
            let allowed = line!() + 1;
            let (guard, _) =
                condvar.wait_timeout(mutex.lock().expect("lock"), LONG_HOLD).expect("wait");
            drop(guard);
            [ordinary, allowed]
        })
    })
    .join()
    .expect("waiter");
    for line in lines {
        assert_eq!(site_at(line), None, "line {line}");
    }
}

/// A thread idle for its own next work (Chromium's
/// `WaitableEvent::declare_only_used_while_idle`) records nothing at any
/// length, on a disallowed thread in panic mode too.
#[test]
fn idle_waits_on_a_disallowed_thread_record_nothing() {
    let pair = Arc::new((Mutex::new(false), Condvar::new()));
    let notifier = Arc::clone(&pair);
    let (waiting_tx, waiting_rx) = channel::<()>();
    let waker = std::thread::spawn(move || {
        waiting_rx.recv().expect("the waiter is idle");
        std::thread::sleep(LONG_HOLD);
        *notifier.0.lock().expect("lock") = true;
        notifier.1.notify_all();
    });
    let lines = on_disallowed_thread(move || {
        let (mutex, condvar) = &*pair;
        let guard = mutex.lock().expect("lock");
        let timed = line!() + 1;
        let (guard, timeout) = condvar.idle().wait_timeout(guard, LONG_HOLD).expect("wait");
        assert!(timeout.timed_out());
        waiting_tx.send(()).expect("idle");
        let mut ready = guard;
        let untimed = line!() + 2;
        while !*ready {
            ready = condvar.idle().wait(ready).expect("wait");
        }
        [timed, untimed]
    });
    waker.join().expect("waker");
    for line in lines {
        assert_eq!(site_at(line), None, "line {line}");
    }
}

#[test]
fn guards_are_std_and_poisoning_passes_through() {
    let mutex = Arc::new(Mutex::new(1));
    let condvar = Condvar::new();
    let poisoner = Arc::clone(&mutex);
    let _ = std::thread::spawn(move || {
        let _guard: std::sync::MutexGuard<'_, i32> = poisoner.lock().expect("lock");
        panic!("poison the lock");
    })
    .join();
    assert!(mutex.is_poisoned());
    let guard = mutex.lock().expect_err("poisoned").into_inner();
    let (guard, _) = condvar
        .wait_timeout(guard, Duration::from_millis(1))
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    assert_eq!(*guard, 1);
    drop(guard);
    mutex.clear_poison();
    assert_eq!(*mutex.lock().expect("cleared"), 1);
}

#[test]
fn checked_waits_take_the_timed_condvar() {
    let pair = Arc::new((Mutex::new(false), Condvar::new()));
    let notifier = Arc::clone(&pair);
    std::thread::spawn(move || {
        *notifier.0.lock().expect("lock") = true;
        notifier.1.notify_all();
    });
    let guard = pair.0.lock().expect("lock");
    let guard = crate::checked::sync::wait_while(&pair.1, guard, |ready| !*ready).expect("wait");
    assert!(*guard);
}

#[test]
fn statics_and_unsized_values_work_as_with_std() {
    static COUNTER: Mutex<u32> = Mutex::new(0);
    static READY: Condvar = Condvar::new();
    *COUNTER.lock().expect("lock") += 1;
    READY.notify_all();
    let shared: Arc<Mutex<dyn std::fmt::Debug + Send>> = Arc::new(Mutex::new(7u8));
    assert_eq!(format!("{:?}", &*shared.lock().expect("lock")), "7");
    assert_eq!(Mutex::from(3).into_inner().expect("value"), 3);
    assert_eq!(RwLock::<u8>::default().into_inner().expect("value"), 0);
}
