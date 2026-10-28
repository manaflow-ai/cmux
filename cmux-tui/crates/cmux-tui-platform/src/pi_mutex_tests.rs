//! The priority-inheriting locks (p05-ipc-138): exclusion, poisoning, the
//! deadline wait and its wake, reentrancy, and on macOS the inversion bound.

use super::*;
use std::sync::Arc;
use std::sync::atomic::AtomicU64;
use std::sync::mpsc;

use cmux_threads::ThreadQos;

fn spawn<R: Send + 'static>(
    name: &str,
    qos: ThreadQos,
    body: impl FnOnce() -> R + Send + 'static,
) -> std::thread::JoinHandle<R> {
    cmux_threads::spawn(name, qos, body).expect("spawn test thread")
}

fn join<R>(handle: std::thread::JoinHandle<R>) -> R {
    cmux_threads::checked::sync::join(handle).expect("test thread")
}

#[test]
fn pi_mutex_excludes_concurrent_holders() {
    const THREADS: u64 = 8;
    const ROUNDS: u64 = 5_000;
    let mutex = Arc::new(PiMutex::new(0_u64));
    let threads: Vec<_> = (0..THREADS)
        .map(|_| {
            let mutex = Arc::clone(&mutex);
            spawn("pi-mutex-adder", ThreadQos::UserInitiated, move || {
                for _ in 0..ROUNDS {
                    let mut value = mutex.lock().expect("lock");
                    // A read and a later write: lost updates show a race.
                    let seen = *value;
                    std::hint::black_box(&seen);
                    *value = seen + 1;
                }
            })
        })
        .collect();
    threads.into_iter().for_each(join);
    assert_eq!(*mutex.lock().expect("lock"), THREADS * ROUNDS);
}

#[test]
fn pi_mutex_try_lock_fails_while_another_thread_holds_it() {
    let mutex = Arc::new(PiMutex::new(()));
    let guard = mutex.lock().expect("lock");
    let other = Arc::clone(&mutex);
    let tried = join(spawn("pi-mutex-try", ThreadQos::UserInitiated, move || {
        matches!(other.try_lock(), Err(TryLockError::WouldBlock))
    }));
    assert!(tried, "try_lock took a held lock");
    drop(guard);
    assert!(mutex.try_lock().is_ok());
}

#[test]
fn pi_mutex_poisons_when_a_holder_panics() {
    let mutex = Arc::new(PiMutex::new(7_u32));
    let holder = Arc::clone(&mutex);
    let panicked = cmux_threads::checked::sync::join(spawn(
        "pi-mutex-poison",
        ThreadQos::UserInitiated,
        move || {
            let _guard = holder.lock().expect("lock");
            // crash-allow: the test's deliberate panic under the lock.
            panic!("holder panics");
        },
    ));
    assert!(panicked.is_err());
    assert!(mutex.is_poisoned());
    let recovered = mutex.lock().expect_err("poisoned").into_inner();
    assert_eq!(*recovered, 7);
    drop(recovered);
    assert!(matches!(mutex.try_lock(), Err(TryLockError::Poisoned(_))));
    mutex.clear_poison();
    assert!(mutex.lock().is_ok());
}

#[test]
fn pi_mutex_into_inner_and_get_mut_read_the_value() {
    let mut mutex = PiMutex::new(vec![1, 2]);
    mutex.get_mut().expect("get_mut").push(3);
    assert_eq!(mutex.into_inner().expect("into_inner"), vec![1, 2, 3]);
}

/// A leaked guard leaves the lock held; moving the mutex keeps it held, as
/// the boxed lock's address does not move with it.
#[test]
fn pi_mutex_moved_while_leaked_stays_locked() {
    let mutex = PiMutex::new(1_u8);
    std::mem::forget(mutex.lock().expect("lock"));
    let moved = Box::new(mutex);
    assert!(matches!(moved.try_lock(), Err(TryLockError::WouldBlock)));
}

#[test]
fn pi_mutex_an_init_raw_lock_allocates_on_first_use() {
    let mutex: lock_api::Mutex<PiRawMutex, u32> = lock_api::Mutex::new(3);
    let guard = mutex.lock();
    assert!(mutex.try_lock().is_none());
    drop(guard);
    assert_eq!(*mutex.lock(), 3);
}

#[test]
fn pi_mutex_deadline_wait_times_out_while_held() {
    let mutex = Arc::new(reentrant_mutex(()));
    let guard = mutex.lock();
    let other = Arc::clone(&mutex);
    let (acquired, waited) =
        join(spawn("pi-mutex-deadline", ThreadQos::UserInitiated, move || {
            let since = Instant::now();
            let acquired = other.try_lock_until(since + Duration::from_millis(20)).is_some();
            (acquired, since.elapsed())
        }));
    drop(guard);
    assert!(!acquired, "a deadline wait took a held lock");
    assert!(waited >= Duration::from_millis(20), "gave up after {waited:?}");
}

/// Each round a deadline waiter parks behind a holder that then unlocks: the
/// unlock wakes it, so no round lasts until the deadline (a lost wake would).
#[test]
fn pi_mutex_unlock_wakes_a_parked_deadline_waiter() {
    const ROUNDS: usize = 200;
    const DEADLINE: Duration = Duration::from_secs(10);
    let mutex = Arc::new(reentrant_mutex(()));
    let counter = Arc::new(AtomicU64::new(0));
    for round in 0..ROUNDS {
        let guard = mutex.lock();
        let (ready_tx, ready_rx) = mpsc::channel();
        let waiter = spawn("pi-mutex-deadline-wake", ThreadQos::UserInitiated, {
            let mutex = Arc::clone(&mutex);
            let counter = Arc::clone(&counter);
            move || {
                ready_tx.send(()).expect("ready");
                let since = Instant::now();
                let acquired = mutex.try_lock_until(since + DEADLINE).is_some();
                counter.fetch_add(1, Ordering::Relaxed);
                (acquired, since.elapsed())
            }
        });
        ready_rx.recv().expect("waiter started");
        // Unlock at a varying point of the waiter's try and park.
        if round % 2 == 0 {
            cmux_threads::checked::sync::sleep(Duration::from_micros(200));
        }
        drop(guard);
        let (acquired, waited) = join(waiter);
        assert!(acquired, "round {round}: the waiter timed out");
        assert!(waited < DEADLINE / 2, "round {round}: woke after {waited:?}");
    }
    assert_eq!(counter.load(Ordering::Relaxed), ROUNDS as u64);
}

#[test]
fn pi_reentrant_mutex_reenters_on_its_owner_and_excludes_others() {
    let mutex = Arc::new(reentrant_mutex(5_u32));
    let outer = mutex.lock();
    let inner = mutex.lock();
    assert!(mutex.is_owned_by_current_thread());
    let other = Arc::clone(&mutex);
    let blocked = join(spawn("pi-reentrant-other", ThreadQos::UserInitiated, move || {
        other.try_lock().is_none()
    }));
    assert!(blocked, "another thread entered a held reentrant lock");
    assert_eq!(*inner + *outer, 10);
    drop(inner);
    drop(outer);
    assert!(!mutex.is_owned_by_current_thread());
    let arc = mutex.lock_arc();
    assert_eq!(*arc, 5);
}

#[test]
fn pi_mutex_donates_priority_on_apple_platforms_only() {
    assert_eq!(DONATES_PRIORITY, cfg!(target_vendor = "apple"));
}

/// Priority inversion, macOS only: a background holder runs a fixed
/// critical section while at least 8 background hogs fill the cores
/// background work may use, and a user-interactive waiter blocks on the
/// lock. The waiter's turnstile pushes the holder past the hogs, so the
/// waiter's p99 wait stays within twice the hold measured with no hogs.
/// Without the push the holder shares its cores with the hogs and the waits
/// grow with their count.
#[cfg(target_vendor = "apple")]
#[test]
fn pi_mutex_inversion_wait_p99_is_within_twice_the_uncontended_hold() {
    use std::sync::atomic::AtomicBool;

    const ROUNDS: usize = 200;
    const TARGET_HOLD: Duration = Duration::from_millis(2);

    fn critical_section(iterations: u64) -> u64 {
        let mut value = 0_u64;
        for step in 0..iterations {
            value = std::hint::black_box(value.wrapping_mul(31).wrapping_add(step));
        }
        value
    }

    fn percentile(samples: &mut [Duration], fraction: f64) -> Duration {
        samples.sort_unstable();
        let index = ((samples.len() as f64 - 1.0) * fraction).round() as usize;
        samples[index]
    }

    /// Stops the hogs on every exit of the test, a failed assertion too.
    struct Stop(Arc<AtomicBool>);
    impl Drop for Stop {
        fn drop(&mut self) {
            self.0.store(true, Ordering::Relaxed);
        }
    }

    let mutex = Arc::new(PiMutex::new(0_u64));

    // The holder's section with no hogs, sized to about TARGET_HOLD.
    let (iterations, mut uncontended) =
        join(spawn("pi-holder-calibrate", ThreadQos::Background, {
            let mutex = Arc::clone(&mutex);
            move || {
                let probe = 1_000_000_u64;
                let since = Instant::now();
                std::hint::black_box(critical_section(probe));
                let per = since.elapsed().as_nanos().max(1) as f64 / probe as f64;
                let iterations = (TARGET_HOLD.as_nanos() as f64 / per).max(1.0) as u64;
                let holds: Vec<Duration> = (0..ROUNDS / 4)
                    .map(|_| {
                        let mut value = mutex.lock().expect("lock");
                        let since = Instant::now();
                        *value = value.wrapping_add(critical_section(iterations));
                        let held = since.elapsed();
                        drop(value);
                        held
                    })
                    .collect();
                (iterations, holds)
            }
        }));
    let hold = percentile(&mut uncontended, 0.5);

    let stop = Stop(Arc::new(AtomicBool::new(false)));
    let hog_count = std::thread::available_parallelism().map_or(8, std::num::NonZero::get).max(8);
    let hogs: Vec<_> = (0..hog_count)
        .map(|_| {
            let stop = Arc::clone(&stop.0);
            spawn("pi-hog", ThreadQos::Background, move || {
                let mut value = 0_u64;
                while !stop.load(Ordering::Relaxed) {
                    value = std::hint::black_box(critical_section(10_000).wrapping_add(value));
                }
                value
            })
        })
        .collect();

    let (held_tx, held_rx) = mpsc::channel::<()>();
    let (next_tx, next_rx) = mpsc::channel::<()>();
    let holder = spawn("pi-holder", ThreadQos::Background, {
        let mutex = Arc::clone(&mutex);
        move || {
            for _ in 0..ROUNDS {
                let mut value = mutex.lock().expect("lock");
                held_tx.send(()).expect("held");
                *value = value.wrapping_add(critical_section(iterations));
                drop(value);
                if next_rx.recv().is_err() {
                    return;
                }
            }
        }
    });
    let mut waits = join(spawn("pi-waiter", ThreadQos::UserInteractive, {
        let mutex = Arc::clone(&mutex);
        move || {
            (0..ROUNDS)
                .map(|_| {
                    held_rx.recv().expect("holder holds");
                    let since = Instant::now();
                    let guard = mutex.lock().expect("lock");
                    let waited = since.elapsed();
                    drop(guard);
                    next_tx.send(()).expect("next round");
                    waited
                })
                .collect::<Vec<_>>()
        }
    }));
    join(holder);
    drop(stop);
    hogs.into_iter().for_each(|hog| {
        join(hog);
    });

    let p99 = percentile(&mut waits, 0.99);
    assert!(
        p99 <= hold * 2,
        "waiter p99 {p99:?} exceeds twice the uncontended hold {hold:?} with {hog_count} \
         background hogs"
    );
}

/// The guard is as small as std's, so a `LockResult` of a ranked guard
/// stays as small as it was.
#[test]
fn pi_mutex_guard_is_two_words() {
    assert_eq!(size_of::<PiMutexGuard<'_, u64>>(), size_of::<std::sync::MutexGuard<'_, u64>>());
}
