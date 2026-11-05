use super::{START_HUNG, StartWatch};
use crate::cpu_class::{HarnessSeen, HarnessState};
use std::time::Duration;

fn harness(cpu_ms: u64, threads_running: i32) -> HarnessSeen {
    HarnessSeen::Running(HarnessState {
        pid: 1,
        priority: 31,
        background: false,
        ran_secs: 0,
        cpu_ms,
        threads: 4,
        threads_running,
        processes: 2,
        pageins: 0,
    })
}

const TICK: Duration = Duration::from_secs(10);

#[test]
fn a_harness_that_uses_no_cpu_with_no_thread_ready_is_hung_after_the_whole_wait() {
    let mut watch = StartWatch::default();
    assert!(!watch.hung(&harness(50, 0), Duration::ZERO), "the first read is not idle yet");
    assert!(!watch.hung(&harness(50, 0), TICK));
    assert!(!watch.hung(&harness(50, 0), TICK + START_HUNG - Duration::from_secs(1)));
    assert!(watch.hung(&harness(50, 0), TICK + START_HUNG));
}

#[test]
fn any_work_starts_the_wait_again() {
    let mut watch = StartWatch::default();
    assert!(!watch.hung(&harness(50, 0), Duration::ZERO));
    assert!(!watch.hung(&harness(50, 0), TICK));
    // Its CPU time moved, however little: slow, not hung.
    assert!(!watch.hung(&harness(51, 0), START_HUNG + TICK));
    assert!(!watch.hung(&harness(51, 0), START_HUNG + 2 * TICK));
    // A thread waits for a CPU on a loaded host.
    assert!(!watch.hung(&harness(51, 3), 2 * START_HUNG + 2 * TICK));
    assert!(!watch.hung(&harness(51, 0), 2 * START_HUNG + 3 * TICK));
    assert!(watch.hung(&harness(51, 0), 3 * START_HUNG + 3 * TICK));
}

#[test]
fn a_harness_it_cannot_read_or_has_not_spawned_is_never_hung() {
    let mut watch = StartWatch::default();
    for seen in [HarnessSeen::NotStarted, HarnessSeen::Unread, HarnessSeen::Ended] {
        assert!(!watch.hung(&seen, 10 * START_HUNG));
    }
    // And the clock starts over once it can.
    assert!(!watch.hung(&harness(50, 0), 10 * START_HUNG));
    assert!(!watch.hung(&harness(50, 0), 10 * START_HUNG + TICK));
}

/// 2026-11-04: a `claude` harness short of memory waits on page-ins with no CPU to speak of and no
/// thread ready; it works, and its start goes on.
#[test]
fn a_harness_that_only_reads_pages_in_still_works() {
    let paging = |pageins: u64| {
        HarnessSeen::Running(HarnessState {
            pid: 1,
            priority: 20,
            background: false,
            ran_secs: 0,
            cpu_ms: 100,
            threads: 12,
            threads_running: 0,
            processes: 2,
            pageins,
        })
    };
    let mut watch = StartWatch::default();
    let mut at = Duration::ZERO;
    for step in 0..100u64 {
        assert!(!watch.hung(&paging(1_000 + step), at), "paging in at {at:?}");
        at += TICK;
    }
    assert!(at > START_HUNG);
}
