use super::*;

const S: u64 = 1000;

fn secs(s: u64) -> Duration {
    Duration::from_secs(s)
}

#[test]
fn ticks_on_time_are_no_resume() {
    let mut w = ResumeWatch::new(1_000 * S, secs(0));
    for i in 1..=20 {
        // A little jitter either way is noise.
        let jitter = if i % 2 == 0 { 300 } else { 0 };
        assert_eq!(w.observe(1_000 * S + i * 10 * S + jitter, secs(i * 10)), None, "tick {i}");
    }
    // An early check (a timer asks before it judges) is no resume either.
    assert_eq!(w.observe(1_000 * S + 201 * S, secs(201)), None);
}

#[test]
fn a_vm_pause_is_the_wall_clock_running_ahead() {
    let mut w = ResumeWatch::new(1_000 * S, secs(50));
    // Paused 5 minutes between two ticks: the monotonic clock moved one period.
    let r = w.observe(1_000 * S + 310 * S, secs(60)).expect("a pause");
    assert_eq!(r.kind, ResumeKind::Paused);
    assert_eq!(r.gap, secs(300));
    // The next tick counts from the resume.
    assert_eq!(w.observe(1_000 * S + 320 * S, secs(70)), None);
}

#[test]
fn a_wall_clock_set_late_after_the_resume_still_reads_as_a_pause() {
    // Virtualization.framework: the guest clock stops with the VM and is set again later. The
    // tick right after the resume sees nothing; the one after the clock is set sees the jump.
    let mut w = ResumeWatch::new(1_000 * S, secs(0));
    assert_eq!(w.observe(1_000 * S + 10 * S, secs(10)), None);
    let r = w.observe(1_000 * S + 20 * S + 120 * S, secs(20)).expect("the set clock");
    assert_eq!((r.kind, r.gap), (ResumeKind::Paused, secs(120)));
}

#[test]
fn a_stopped_process_is_a_late_tick_on_both_clocks() {
    let mut w = ResumeWatch::new(1_000 * S, secs(0));
    // SIGSTOP for 60 s: both clocks moved 70 s over a 10 s period.
    let r = w.observe(1_000 * S + 70 * S, secs(70)).expect("a stop");
    assert_eq!((r.kind, r.gap), (ResumeKind::Stopped, secs(60)));
}

#[test]
fn a_parked_watch_sees_a_pause_but_no_stop() {
    // An idle daemon parks the watch: an hour on both clocks is no gap.
    let mut w = ResumeWatch::new(1_000 * S, secs(0));
    w.park();
    assert!(w.parked());
    assert_eq!(w.observe(1_000 * S + 3_600 * S, secs(3_600)), None);
    // The check unparked it: from here a late tick is a stop again.
    assert!(!w.parked());
    let r = w.observe(1_000 * S + 3_670 * S, secs(3_670)).expect("a stop");
    assert_eq!((r.kind, r.gap), (ResumeKind::Stopped, secs(60)));
    // A computer that slept 5 minutes while parked: the wall clock ran ahead, seen at once.
    w.park();
    let r = w.observe(1_000 * S + 4_270 * S + 300 * S, secs(4_270)).expect("a pause");
    assert_eq!((r.kind, r.gap), (ResumeKind::Paused, secs(300)));
}

#[test]
fn small_gaps_and_a_clock_set_back_are_noise() {
    let mut w = ResumeWatch::new(10_000 * S, secs(0));
    // 14 s late: under the slack.
    assert_eq!(w.observe(10_000 * S + 24 * S, secs(24)), None);
    // The wall clock set back an hour: no pause.
    assert_eq!(w.observe(10_000 * S - 3_600 * S, secs(34)), None);
    // And the watch goes on from there.
    assert_eq!(w.observe(10_000 * S - 3_590 * S, secs(44)), None);
}
