//! `process_priority::set_self` on this test process, alone in its binary:
//! a process other tests start while it is best-effort would inherit it, and
//! a parallel test's change would race this one's (one test, in steps).
#![cfg(unix)]

use cmux_tui_platform::process_priority::{
    PriorityError, ProcessPriority, SelfLowered, is_background, reversible, set_self,
};

#[test]
fn process_priority_set_self_reads_back_and_comes_back() {
    let me = std::process::id();
    // Cargo under `nice -n 10` starts this process best-effort already.
    let baseline = is_background(me).unwrap();
    let mut lowered = SelfLowered::default();
    if !reversible() {
        assert_eq!(
            set_self(ProcessPriority::BestEffort, &mut lowered),
            Err(PriorityError::NotReversible)
        );
        assert_eq!(is_background(me), Ok(baseline), "unchanged");
        return;
    }
    // A second thread exists while the change is made: every thread changes.
    let (tx, rx) = std::sync::mpsc::channel::<()>();
    let other = std::thread::spawn(move || rx.recv());
    set_self(ProcessPriority::BestEffort, &mut lowered).unwrap();
    assert_eq!(is_background(me), Ok(true));
    set_self(ProcessPriority::UserVisible, &mut lowered).unwrap();
    assert_eq!(is_background(me), Ok(baseline), "back to what it was");
    assert!(lowered.is_empty(), "the change back empties the record");
    tx.send(()).unwrap();
    other.join().unwrap().unwrap();

    #[cfg(target_os = "linux")]
    threads_keep_their_own_nice_across_a_round_trip();
}

/// The nice of thread `tid`.
#[cfg(target_os = "linux")]
fn nice_of(tid: u32) -> i32 {
    // SAFETY: plain syscall with integer arguments.
    unsafe { libc::getpriority(libc::PRIO_PROCESS, tid) }
}

/// Threads at a QoS nice of their own (cmux_threads Utility 5, Background
/// 10) and one started while the process was best-effort: after a round
/// trip each is back where it was, the late one at the main thread's nice.
#[cfg(target_os = "linux")]
fn threads_keep_their_own_nice_across_a_round_trip() {
    use std::sync::mpsc;
    let main_nice = nice_of(std::process::id());
    // SAFETY: gettid takes no arguments.
    let creator_nice = nice_of(unsafe { libc::syscall(libc::SYS_gettid) } as u32);
    let start = |nice: Option<i32>| {
        let (tid_tx, tid_rx) = mpsc::channel::<u32>();
        let (stop_tx, stop_rx) = mpsc::channel::<()>();
        let thread = std::thread::spawn(move || {
            // SAFETY: gettid takes no arguments.
            let tid = unsafe { libc::syscall(libc::SYS_gettid) } as u32;
            if let Some(nice) = nice {
                // SAFETY: plain syscall with integer arguments, on this thread.
                assert_eq!(unsafe { libc::setpriority(libc::PRIO_PROCESS, tid, nice) }, 0);
            }
            tid_tx.send(tid).unwrap();
            let _ = stop_rx.recv();
        });
        (tid_rx.recv().unwrap(), stop_tx, thread)
    };
    let utility = start(Some(5));
    let background = start(Some(10));
    let mut lowered = SelfLowered::default();
    set_self(ProcessPriority::BestEffort, &mut lowered).unwrap();
    assert_eq!(nice_of(utility.0), 10);
    assert_eq!(nice_of(background.0), 10);
    let late = start(None);
    assert_eq!(nice_of(late.0), 10, "a thread started now inherits it");
    set_self(ProcessPriority::UserVisible, &mut lowered).unwrap();
    assert_eq!(nice_of(utility.0), 5, "Utility comes back to 5, not 0");
    assert_eq!(nice_of(background.0), 10, "Background stays at 10");
    // A process started best-effort keeps what it inherited.
    let expected = if main_nice < 10 { main_nice } else { creator_nice.max(10) };
    assert_eq!(nice_of(late.0), expected, "the late thread gets the main thread's nice");
    assert_eq!(nice_of(std::process::id()), main_nice);
    for (_, stop, thread) in [utility, background, late] {
        stop.send(()).unwrap();
        thread.join().unwrap();
    }
}
