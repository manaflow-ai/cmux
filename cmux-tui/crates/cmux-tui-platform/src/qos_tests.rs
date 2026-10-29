//! Request QoS and the lock-holder boost. Each test runs
//! on its own thread: the scopes are thread-local and change its QoS.
//!
//! On Linux an unprivileged thread cannot take back a lowering, so UTILITY
//! is refused there (and under `nice`): the tests then check that nothing
//! changed. On macOS every class applies.

use super::*;
use std::hint::black_box;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Barrier, Mutex, mpsc};
use std::time::{Duration, Instant};

/// The calling thread's class as `qos_class_self()` reports it.
#[cfg(target_vendor = "apple")]
fn live() -> Option<ThreadQos> {
    // The class is read as its `u32` repr: the kernel may report a class
    // `libc::qos_class_t` has no variant for (QOS_CLASS_MAINTENANCE).
    unsafe extern "C" {
        #[link_name = "qos_class_self"]
        fn qos_class_self_raw() -> u32;
    }
    // SAFETY: qos_class_self has no preconditions and returns a plain value.
    let raw = unsafe { qos_class_self_raw() };
    ThreadQos::from_qos_class(raw)
}

/// The calling thread's nice value: what a class sets on Linux.
#[cfg(not(target_vendor = "apple"))]
fn live() -> cmux_threads::LiveQos {
    cmux_threads::current()
}

/// What [`live`] reads for a thread running at `qos`.
#[cfg(target_vendor = "apple")]
fn at(qos: ThreadQos) -> Option<ThreadQos> {
    Some(qos)
}

#[cfg(any(target_os = "linux", target_os = "android"))]
fn at(qos: ThreadQos) -> cmux_threads::LiveQos {
    cmux_threads::LiveQos::Nice(qos.linux_nice())
}

#[cfg(not(any(target_vendor = "apple", target_os = "linux", target_os = "android")))]
fn at(_qos: ThreadQos) -> cmux_threads::LiveQos {
    cmux_threads::LiveQos::Unknown
}

fn on_own_thread(test: impl FnOnce() + Send + 'static) {
    std::thread::spawn(test).join().expect("test thread");
}

#[test]
fn qos_request_class_is_set_for_the_scope_and_restored() {
    for qos in [ThreadQos::Utility, ThreadQos::UserInitiated] {
        on_own_thread(move || {
            let before = live();
            {
                let scope = WorkQos::enter(qos);
                #[cfg(target_vendor = "apple")]
                assert!(scope.applied(), "{qos}: macOS takes every class");
                if scope.applied() {
                    assert_eq!(live(), at(qos), "{qos}");
                    assert_eq!(work_qos(), Some(qos));
                } else {
                    assert_eq!(live(), before, "{qos}: a refused class changes nothing");
                    assert_eq!(work_qos(), None);
                }
                // The same class nested changes nothing.
                let nested = WorkQos::enter(qos);
                assert!(!nested.applied());
                drop(nested);
                assert_eq!(work_qos(), scope.applied().then_some(qos));
            }
            assert_eq!(live(), before, "{qos}: restored");
            assert_eq!(work_qos(), None);
        });
    }
}

#[test]
fn qos_lock_boost_raises_a_utility_holder_until_its_outermost_release() {
    on_own_thread(|| {
        let request = WorkQos::enter(ThreadQos::Utility);
        let lowered = request.applied();
        let outer = LockBoost::hold();
        assert_eq!(boosted(), lowered);
        if lowered {
            assert_eq!(live(), at(LOCK_HOLDER_QOS), "raised while the lock is held");
        }
        let inner = LockBoost::hold();
        drop(inner);
        assert_eq!(boosted(), lowered, "an inner release keeps the raise");
        if lowered {
            assert_eq!(live(), at(LOCK_HOLDER_QOS));
        }
        drop(outer);
        assert!(!boosted());
        if lowered {
            assert_eq!(live(), at(ThreadQos::Utility), "back to the request's class");
        }
        assert_eq!(work_qos(), lowered.then_some(ThreadQos::Utility));
    });
}

#[test]
fn qos_lock_boost_leaves_frontend_and_program_threads_alone() {
    on_own_thread(|| {
        // Outside every request: the thread keeps its own class.
        let before = live();
        let boost = LockBoost::hold();
        assert!(!boosted());
        assert_eq!(live(), before);
        drop(boost);

        let request = WorkQos::enter(ThreadQos::UserInitiated);
        let boost = LockBoost::hold();
        assert!(!boosted(), "a USER_INITIATED holder needs no raise");
        if request.applied() {
            assert_eq!(live(), at(ThreadQos::UserInitiated));
        }
        drop(boost);
    });
}

/// A thread declared below Default at its start (watchers at
/// utility, idle workers at background) is raised while it holds a ranked
/// lock, as a thread a request lowered is: a request that waits for the lock
/// never waits behind it. A thread declared Default or above is left alone.
#[test]
fn qos_lock_boost_raises_a_declared_low_thread_until_its_release() {
    for declared in [ThreadQos::Background, ThreadQos::Utility] {
        let probe = cmux_threads::spawn("qos-declared-low-probe", declared, move || {
            let before = live();
            let raisable = cmux_threads::reversible(declared);
            let outer = LockBoost::hold();
            let held = (boosted(), live());
            let inner = LockBoost::hold();
            drop(inner);
            let after_inner = boosted();
            drop(outer);
            (raisable, before, held, after_inner, boosted(), live())
        })
        .expect("probe thread");
        let (raisable, before, held, after_inner, released, after) = probe.join().expect("probe");
        #[cfg(target_vendor = "apple")]
        {
            assert_eq!(before, at(declared), "{declared}: started at its declared class");
            assert!(raisable, "{declared}: macOS takes every class back");
        }
        if raisable {
            assert_eq!(held, (true, at(LOCK_HOLDER_QOS)), "{declared}: raised while held");
            assert!(after_inner, "{declared}: an inner release keeps the raise");
        } else {
            assert_eq!(held, (false, before), "{declared}: nothing it could not undo");
        }
        assert!(!released, "{declared}: the last release ends the raise");
        assert_eq!(after, before, "{declared}: back to the class it started at");
    }
    let (held, before, during) =
        cmux_threads::spawn("qos-declared-default-probe", ThreadQos::Default, || {
            let before = live();
            let boost = LockBoost::hold();
            let held = boosted();
            let during = live();
            drop(boost);
            (held, before, during)
        })
        .expect("probe thread")
        .join()
        .expect("probe");
    assert!(!held, "a Default thread is not raised");
    assert_eq!(during, before);
}

/// `spawn_raisable` starts a utility or background thread at its class where
/// the process can raise it for a lock and take that back, else at Default,
/// else (a niced process that cannot reach Default) at the creator's own
/// class: never at a class its start would be refused. The
/// body reads its class and its registry row's refusals.
#[test]
fn qos_spawn_raisable_starts_at_a_class_the_creator_can_reach() {
    for asked in [ThreadQos::Background, ThreadQos::Utility] {
        let class = raisable_class(asked);
        if cmux_threads::reversible(asked) {
            assert_eq!(class, asked);
        } else if cmux_threads::reachable(ThreadQos::Default) {
            assert_eq!(class, ThreadQos::Default, "{asked}");
        } else {
            assert!(class < ThreadQos::Default, "{asked}: below Default, got {class}");
        }
        let reachable = cmux_threads::reachable(class);
        // A name no other thread has: the body finds its own row by it.
        let name = format!("qos-raisable-probe-{asked}");
        let (declared, read, refused) = spawn_raisable(name.clone(), asked, None, move || {
            let slot = cmux_threads::current_slot().expect("registered");
            let refused = cmux_threads::snapshot()
                .into_iter()
                .find(|row| row.name == name)
                .map(|row| row.refused_changes);
            (slot.declared(), live(), refused)
        })
        .expect("spawn")
        .join()
        .expect("probe");
        assert_eq!(declared, class, "{asked}");
        if reachable {
            assert_eq!(read, at(class), "{asked}: runs at {class}");
            assert_eq!(refused, Some(0), "{asked}: its start was not refused");
        }
    }
}

#[test]
fn qos_request_entered_under_a_held_lock_changes_nothing() {
    on_own_thread(|| {
        let before = live();
        let boost = LockBoost::hold();
        let request = WorkQos::enter(ThreadQos::Utility);
        assert!(!request.applied(), "a lock holder is never lowered");
        assert_eq!(work_qos(), None);
        assert_eq!(live(), before);
        drop(request);
        drop(boost);
        // A rank that is no lock does not count as one.
        let not_a_lock = LockBoost::none();
        let request = WorkQos::enter(ThreadQos::Utility);
        assert_eq!(work_qos(), request.applied().then_some(ThreadQos::Utility));
        drop(request);
        drop(not_a_lock);
        assert_eq!(live(), before);
    });
}

/// CPU work with no lock, no allocation and no system call.
fn spin(iterations: u64) -> u64 {
    let mut x = 0x9e37_79b9_7f4a_7c15_u64;
    for i in 0..iterations {
        x = black_box(x.wrapping_mul(6_364_136_223_846_793_005).wrapping_add(i));
    }
    x
}

/// Iterations of [`spin`] that take about `target` on an idle core.
fn calibrate(target: Duration) -> (u64, Duration) {
    let probe = 1_000_000;
    let started = Instant::now();
    black_box(spin(probe));
    let per_probe = started.elapsed().max(Duration::from_micros(1));
    let iterations = (probe as f64 * target.as_secs_f64() / per_probe.as_secs_f64()) as u64;
    let started = Instant::now();
    black_box(spin(iterations));
    (iterations, started.elapsed())
}

/// The CPU the holder and the spinners share (Linux): the first CPU this
/// process may run on.
#[cfg(any(target_os = "linux", target_os = "android"))]
fn shared_cpu() -> usize {
    // SAFETY: a zeroed cpu_set_t is an empty set; the pointer is valid for
    // the call and the size is the set's.
    unsafe {
        let mut set: libc::cpu_set_t = std::mem::zeroed();
        libc::sched_getaffinity(0, size_of::<libc::cpu_set_t>(), &mut set);
        (0..libc::CPU_SETSIZE as usize).find(|&cpu| libc::CPU_ISSET(cpu, &set)).unwrap_or(0)
    }
}

/// Pins the calling thread to `cpu` (Linux).
#[cfg(any(target_os = "linux", target_os = "android"))]
fn pin_to(cpu: usize) {
    // SAFETY: as in `shared_cpu`; 0 is the calling thread.
    unsafe {
        let mut set: libc::cpu_set_t = std::mem::zeroed();
        libc::CPU_SET(cpu, &mut set);
        libc::sched_setaffinity(0, size_of::<libc::cpu_set_t>(), &set);
    }
}

/// Where the contention runs: Linux pins the holder and two spinners to one
/// core, so the scheduler's weights decide the holder's share; elsewhere a
/// spinner per core keeps every core busy.
struct Contention {
    #[cfg(any(target_os = "linux", target_os = "android"))]
    cpu: usize,
    spinners: usize,
}

impl Contention {
    fn new() -> Self {
        #[cfg(any(target_os = "linux", target_os = "android"))]
        {
            Self { cpu: shared_cpu(), spinners: 2 }
        }
        #[cfg(not(any(target_os = "linux", target_os = "android")))]
        {
            Self { spinners: std::thread::available_parallelism().map_or(4, |n| n.get()) }
        }
    }

    /// Run on each contending thread before it starts work.
    fn join(&self) {
        #[cfg(any(target_os = "linux", target_os = "android"))]
        pin_to(self.cpu);
    }

    /// How many times longer than on an idle core a section takes when the
    /// holder runs at the spinners' class.
    fn fair_share_factor(&self) -> u32 {
        #[cfg(any(target_os = "linux", target_os = "android"))]
        {
            self.spinners as u32 + 1
        }
        #[cfg(not(any(target_os = "linux", target_os = "android")))]
        {
            // Raised above the spinners, the holder keeps a core.
            4
        }
    }
}

struct Run {
    lowered: bool,
    raised: bool,
    waited: Duration,
}

/// A UTILITY holder runs a section of `iterations` under the lock while a
/// USER_INITIATED frontend waits for it, with every contended core busy at
/// the default class. With `boost` the holder takes its [`LockBoost`]
/// before it waits for the lock, as the ranked locks do.
fn frontend_behind_utility_holder(
    contention: &Arc<Contention>,
    iterations: u64,
    boost: bool,
) -> Run {
    let stop = Arc::new(AtomicBool::new(false));
    let running = Arc::new(AtomicUsize::new(0));
    let mut threads = Vec::new();
    for _ in 0..contention.spinners {
        let (stop, running, contention) = (stop.clone(), running.clone(), contention.clone());
        threads.push(std::thread::spawn(move || {
            contention.join();
            // The default class, also when the test runs under `nice`.
            let _ = cmux_threads::set_current(ThreadQos::Default);
            running.fetch_add(1, Ordering::AcqRel);
            while !stop.load(Ordering::Acquire) {
                black_box(spin(10_000));
            }
        }));
    }
    while running.load(Ordering::Acquire) < contention.spinners {
        std::thread::yield_now();
    }

    let lock = Arc::new(Mutex::new(()));
    let ready = Arc::new(Barrier::new(2));
    let (held_tx, held_rx) = mpsc::sync_channel(1);
    let holder = {
        let (lock, ready, contention) = (lock.clone(), ready.clone(), contention.clone());
        std::thread::spawn(move || {
            contention.join();
            let _ = cmux_threads::set_current(ThreadQos::Default);
            let request = WorkQos::enter(ThreadQos::Utility);
            ready.wait();
            let boost = boost.then(LockBoost::hold);
            let raised = boosted();
            let guard = lock.lock().expect("lock");
            held_tx.send(()).expect("held");
            black_box(spin(iterations));
            drop(guard);
            drop(boost);
            (request.applied(), raised)
        })
    };
    let frontend = std::thread::spawn(move || {
        let _ = cmux_threads::set_current(ThreadQos::Default);
        let _request = WorkQos::enter(ThreadQos::UserInitiated);
        ready.wait();
        held_rx.recv().expect("holder took the lock");
        let started = Instant::now();
        drop(lock.lock().expect("lock"));
        started.elapsed()
    });
    let (lowered, raised) = holder.join().expect("holder");
    let waited = frontend.join().expect("frontend");
    stop.store(true, Ordering::Release);
    for thread in threads {
        thread.join().expect("spinner");
    }
    Run { lowered, raised, waited }
}

#[test]
fn qos_frontend_request_behind_a_utility_holder_waits_one_critical_section() {
    let (iterations, uncontended) = calibrate(Duration::from_millis(10));
    let contention = Arc::new(Contention::new());
    let boosted_run = frontend_behind_utility_holder(&contention, iterations, true);
    assert_eq!(
        boosted_run.raised, boosted_run.lowered,
        "a lowered holder is raised before it waits for the lock"
    );
    if !boosted_run.lowered {
        // UTILITY is not applied here (Linux without RLIMIT_NICE): there is
        // no inversion to measure.
        return;
    }
    let control = frontend_behind_utility_holder(&contention, iterations, false);
    // One section at the spinners' class: the frontend waits for that one
    // critical section, not for a starved UTILITY thread.
    let bound = uncontended * contention.fair_share_factor() + Duration::from_millis(20);
    assert!(
        boosted_run.waited <= bound,
        "waited {:?} (bound {bound:?}); the section takes {uncontended:?} on an idle core",
        boosted_run.waited
    );
    // The same section at UTILITY, not raised, takes clearly longer.
    assert!(
        boosted_run.waited * 3 < control.waited * 2,
        "raised {:?}, not raised {:?}",
        boosted_run.waited,
        control.waited
    );
}

/// The class `spawn_outside_request`'s thread runs at, read in that thread.
fn child_live(name: &str) -> LiveOf {
    spawn_outside_request(name, live).expect("spawn").join().expect("child")
}

#[cfg(target_vendor = "apple")]
type LiveOf = Option<ThreadQos>;
#[cfg(not(target_vendor = "apple"))]
type LiveOf = cmux_threads::LiveQos;

#[test]
fn qos_a_thread_started_in_a_request_runs_at_its_creators_own_class() {
    let probe = cmux_threads::spawn("qos-spawn-probe", ThreadQos::Default, || {
        let own = live();
        let request = WorkQos::enter(ThreadQos::Utility);
        let lowered = request.applied();
        // A plain thread inherits the request's class...
        let inherited = std::thread::spawn(live).join().expect("plain child");
        // ...a thread started outside the request gets the creator's own.
        let child = child_live("qos-spawn-child");
        let boost = LockBoost::hold();
        let child_of_holder = child_live("qos-spawn-child-of-holder");
        drop(boost);
        (lowered, own, inherited, child, child_of_holder)
    })
    .expect("probe thread");
    let (lowered, own, inherited, child, child_of_holder) = probe.join().expect("probe");
    assert_eq!(child, own, "not the request's class");
    assert_eq!(child_of_holder, own, "not the lock boost's class");
    if lowered {
        assert_eq!(inherited, at(ThreadQos::Utility), "the control: a plain thread inherits");
        assert_ne!(child, at(ThreadQos::Utility));
    }
}

/// A connection thread that rests at UTILITY asks for it in its registry
/// row (`desired`) and holds it as its work class between requests
/// (cmux-tui-core server/connection_qos.rs). A thread it starts outside a
/// request (a pool worker every connection shares) runs at the class the
/// creator declared, never the class it rests at.
#[test]
fn qos_a_thread_started_by_a_resting_thread_runs_at_its_declared_class() {
    let probe = cmux_threads::spawn("qos-resting-probe", ThreadQos::Default, || {
        let own = live();
        let slot = cmux_threads::current_slot().expect("a registered thread");
        slot.request(ThreadQos::Utility);
        let resting = WorkQos::enter(ThreadQos::Utility);
        let lowered = resting.applied();
        let child = child_live("qos-resting-child");
        // What the child is set to when the resting class applied (it does
        // not on Linux without the right to take nice 5 back).
        let class_for_children = own_class();
        drop(resting);
        (lowered, own, child, slot.desired(), class_for_children)
    })
    .expect("probe thread");
    let (lowered, own, child, desired, class_for_children) = probe.join().expect("probe");
    assert_eq!(desired, ThreadQos::Utility, "the row shows the resting class");
    assert_eq!(class_for_children, ThreadQos::Default, "the declared class");
    assert_eq!(child, own, "the creator's declared class, not its resting class");
    if lowered {
        assert_ne!(child, at(ThreadQos::Utility));
    }
}

#[test]
fn qos_a_thread_started_in_a_request_is_registered_at_the_creators_declared_class() {
    let (class, row) = cmux_threads::spawn("qos-spawn-row-probe", ThreadQos::Utility, || {
        let request = WorkQos::enter(ThreadQos::UserInitiated);
        let row = spawn_outside_request("qos-spawn-row-child", || {
            cmux_threads::snapshot().into_iter().find(|row| row.name == "qos-spawn-row-child")
        })
        .expect("spawn")
        .join()
        .expect("child");
        drop(request);
        (outside_request_class(), row)
    })
    .expect("probe thread")
    .join()
    .expect("probe");
    assert_eq!(class, ThreadQos::Utility);
    let row = row.expect("the child is in the thread registry");
    assert_eq!(row.declared, ThreadQos::Utility, "the creator's class, not the request's");
    // A creator that declared no class starts its thread at Default.
    let undeclared = std::thread::spawn(outside_request_class).join().expect("plain thread");
    assert_eq!(undeclared, ThreadQos::Default);
}

#[test]
fn qos_a_class_the_process_cannot_take_back_is_not_entered_or_counted() {
    let probe = cmux_threads::spawn("qos-refusal-probe", ThreadQos::Default, || {
        // Under `nice` the probe's own start at Default is refused: count
        // only what the requests add.
        let refused = || {
            cmux_threads::snapshot()
                .into_iter()
                .find(|row| row.name == "qos-refusal-probe")
                .expect("the probe's row")
                .refused_changes
        };
        let at_start = refused();
        let reversible = cmux_threads::reversible(ThreadQos::Utility);
        for _ in 0..100 {
            let request = WorkQos::enter(ThreadQos::Utility);
            assert_eq!(request.applied(), reversible);
            let boost = LockBoost::hold();
            drop(boost);
            drop(request);
        }
        refused() - at_start
    })
    .expect("probe thread");
    assert_eq!(probe.join().expect("probe"), 0, "no request counts as a refused change");
}
