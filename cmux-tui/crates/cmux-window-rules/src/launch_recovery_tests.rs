use super::*;

const SIGSEGV: i32 = 11;
const SIGABRT: i32 = 6;

fn run(signal: Option<i32>) -> PreviousRun {
    PreviousRun { survived: true, signal, quitting: Some(false), ..PreviousRun::default() }
}

/// CrashNoticeTests.aKilledRunRestoresWithoutTheCrashNotice.
#[test]
fn a_killed_run_restores_without_the_notice() {
    assert_eq!(decide(Some(&run(None))), Recovery::Clean);
}

/// CrashNoticeTests.aRunThatCrashedShowsTheNotice.
#[test]
fn a_run_that_crashed_shows_the_notice() {
    assert_eq!(decide(Some(&run(Some(SIGSEGV)))), Recovery::Restarted);
    assert_eq!(decide(Some(&run(Some(SIGABRT)))), Recovery::Restarted);
}

/// CrashNoticeTests.anUncaughtExceptionShowsTheNotice.
#[test]
fn an_uncaught_exception_shows_the_notice() {
    let previous = PreviousRun { exception: true, ..run(None) };
    assert!(previous.crashed());
    assert_eq!(decide(Some(&previous)), Recovery::Restarted);
}

/// CrashNoticeTests.aRestoreThatHangsTwiceSkipsBrowserPages.
#[test]
fn a_restore_that_hangs_twice_is_a_safe_restart() {
    let first = PreviousRun { survived: false, ..run(None) };
    assert_eq!(decide(Some(&first)), Recovery::Clean);
    assert!(watches_for_loop(Some(&first)));
    let second = PreviousRun { recovery: true, survived: false, ..run(None) };
    assert_eq!(decide(Some(&second)), Recovery::RestartedSafely);
    assert!(!watches_for_loop(Some(&run(None))));
}

/// CrashNoticeTests.aSafeRestartHoldsOnlyThePagesTheEndedRunStarted.
#[test]
fn a_safe_restart_holds_only_the_started_pages() {
    let pages = Some(vec!["tab-a".to_owned()]);
    let safe = PreviousRun {
        recovery: true,
        survived: false,
        started_pages: pages.clone(),
        ..run(Some(SIGSEGV))
    };
    assert_eq!(plan(Some(&safe)).crashed_pages, vec!["tab-a".to_owned()]);
    let plain = PreviousRun { started_pages: pages, ..run(Some(SIGSEGV)) };
    assert!(plan(Some(&plain)).crashed_pages.is_empty());
    let old = PreviousRun { recovery: true, survived: false, ..run(Some(SIGSEGV)) };
    assert!(plan(Some(&old)).crashed_pages.is_empty(), "a marker without started pages holds none");
}

/// CrashNoticeTests.aRestartLoopStartsTheUpdaterBeforeTheWindows.
#[test]
fn a_restart_loop_starts_the_updater_first() {
    let loop_run = PreviousRun { recovery: true, survived: false, ..run(Some(SIGSEGV)) };
    assert!(plan(Some(&loop_run)).starts_updater_before_windows);
    let hang_loop = PreviousRun { recovery: true, survived: false, ..run(None) };
    assert!(plan(Some(&hang_loop)).starts_updater_before_windows);
    assert!(!plan(Some(&run(Some(SIGSEGV)))).starts_updater_before_windows);
    assert!(!plan(None).starts_updater_before_windows);
    assert!(!plan(Some(&run(None))).starts_updater_before_windows);
}

#[test]
fn no_previous_run_is_clean_and_unwatched() {
    assert_eq!(
        plan(None),
        Plan {
            recovery: Recovery::Clean,
            watches_for_loop: false,
            crashed_pages: vec![],
            starts_updater_before_windows: false
        }
    );
}

#[test]
fn requested_quit_signals_end_as_asked_even_mid_loop() {
    for signal in REQUESTED_QUIT_SIGNALS {
        let previous = PreviousRun { recovery: true, survived: false, ..run(Some(signal)) };
        assert!(previous.ended_as_asked());
        assert_eq!(decide(Some(&previous)), Recovery::Clean);
        assert!(!watches_for_loop(Some(&previous)));
    }
}

#[test]
fn a_fault_during_a_quit_is_still_a_crash() {
    let previous = PreviousRun { quitting: Some(true), ..run(Some(SIGSEGV)) };
    assert!(!previous.ended_as_asked());
    assert_eq!(decide(Some(&previous)), Recovery::Restarted);
}

#[test]
fn a_kill_during_a_requested_quit_ended_as_asked() {
    let previous = PreviousRun {
        quitting: Some(true),
        survived: false,
        footprint_megabytes: Some(9000),
        ..run(None)
    };
    assert!(previous.ended_as_asked());
    assert!(!previous.was_likely_oom());
    assert_eq!(decide(Some(&previous)), Recovery::Clean);
    assert!(!watches_for_loop(Some(&previous)));
    // An old marker (no quitting field) did not end as asked.
    assert!(!PreviousRun { quitting: None, ..run(None) }.ended_as_asked());
}

#[test]
fn a_high_footprint_kill_reads_as_oom() {
    let at = PreviousRun { footprint_megabytes: Some(HIGH_FOOTPRINT_MEGABYTES), ..run(None) };
    assert!(at.was_likely_oom());
    assert_eq!(decide(Some(&at)), Recovery::Restarted);
    assert!(watches_for_loop(Some(&at)));
    let below =
        PreviousRun { footprint_megabytes: Some(HIGH_FOOTPRINT_MEGABYTES - 1), ..run(None) };
    assert!(!below.was_likely_oom());
    assert_eq!(decide(Some(&below)), Recovery::Clean);
    // OOM wins over the safe restart a loop would get.
    let looping = PreviousRun { recovery: true, survived: false, ..at.clone() };
    assert_eq!(decide(Some(&looping)), Recovery::Restarted);
    // A signal or exception is never read as OOM.
    assert!(!PreviousRun { signal: Some(SIGSEGV), ..at.clone() }.was_likely_oom());
    assert!(!PreviousRun { exception: true, ..at }.was_likely_oom());
}

#[test]
fn crashed_pages_dedup() {
    let safe = PreviousRun {
        recovery: true,
        survived: false,
        started_pages: Some(vec!["b".into(), "a".into(), "b".into()]),
        ..run(None)
    };
    assert_eq!(plan(Some(&safe)).crashed_pages, vec!["a".to_owned(), "b".to_owned()]);
}

#[test]
fn wire_shape() {
    let previous: PreviousRun =
        serde_json::from_value(serde_json::json!({ "recovery": true, "startedPages": ["t"] }))
            .unwrap();
    let wire = serde_json::to_value(plan(Some(&previous))).unwrap();
    assert_eq!(
        wire,
        serde_json::json!({
            "recovery": "restartedSafely",
            "watchesForLoop": true,
            "crashedPages": ["t"],
            "startsUpdaterBeforeWindows": true
        })
    );
}
