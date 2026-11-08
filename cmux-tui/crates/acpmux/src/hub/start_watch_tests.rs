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
        name: String::new(),
        first_child: None,
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
    // Its CPU time moved by 160 ms over the 5 min since the last read (over the bar's 150 ms for
    // that span): slow, not hung.
    assert!(!watch.hung(&harness(210, 0), START_HUNG + TICK));
    assert!(!watch.hung(&harness(210, 0), START_HUNG + 2 * TICK));
    // A thread waits for a CPU on a loaded host.
    assert!(!watch.hung(&harness(210, 3), 2 * START_HUNG + 2 * TICK));
    assert!(!watch.hung(&harness(210, 0), 2 * START_HUNG + 3 * TICK));
    assert!(watch.hung(&harness(210, 0), 3 * START_HUNG + 3 * TICK));
}

/// #36028: `sr2 claude` with its `claude` stopped. The launcher's Go runtime alone moves the tree's
/// CPU time by under a millisecond per read; that is no work, so the start ends as hung.
#[test]
fn a_launchers_idle_runtime_ticks_do_not_keep_a_stopped_agent_counted_as_working() {
    let mut watch = StartWatch::default();
    let mut at = Duration::ZERO;
    let mut cpu = 140;
    assert!(!watch.hung(&harness(cpu, 0), at));
    while at < START_HUNG {
        at += TICK;
        cpu += 1;
        assert!(!watch.hung(&harness(cpu, 0), at), "hung early at {at:?}");
    }
    at += TICK;
    cpu += 1;
    assert!(watch.hung(&harness(cpu, 0), at), "a stopped agent under its launcher is hung");
}

/// The CPU bar is a rate, not a per-read amount: read every second (a short start budget), a
/// launcher's ticks summed over a window still are no work, and an agent spending 1 ms a second
/// (10 ms per window, twice the bar) is never called hung.
#[test]
fn the_cpu_bar_is_the_same_rate_at_a_short_tick() {
    let second = Duration::from_secs(1);
    let mut idle = StartWatch::default();
    let mut working = StartWatch::default();
    let mut at = Duration::ZERO;
    let (mut launcher, mut agent) = (140, 140);
    assert!(!idle.hung(&harness(launcher, 0), at));
    assert!(!working.hung(&harness(agent, 0), at));
    while at < 2 * START_HUNG {
        at += second;
        agent += 1;
        if at.as_secs().is_multiple_of(3) {
            launcher += 1;
        }
        assert!(!working.hung(&harness(agent, 0), at), "a working agent hung at {at:?}");
        if idle.hung(&harness(launcher, 0), at) {
            assert!(at >= START_HUNG && at <= START_HUNG + 2 * TICK, "hung at {at:?}");
            return;
        }
    }
    panic!("a launcher's ticks at a 1 s read kept its stopped agent counted as working");
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
            name: String::new(),
            first_child: None,
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
