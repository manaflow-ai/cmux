//! The cold-scrollback policy: when a terminal is due, the
//! one deadline, and what keeps a terminal hot.

use std::sync::atomic::AtomicUsize;

use super::*;

const HOUR: Duration = Duration::from_secs(60 * 60);

fn id(n: u8) -> TerminalPublicId {
    TerminalPublicId::parse(format!("term_{n:032x}")).unwrap()
}

fn hot(terminal_id: &TerminalPublicId) -> ColdCandidate<'_> {
    ColdCandidate { terminal_id, viewed: false, attach_epoch: 0, last_output: None, cold: false }
}

fn normal() -> MemoryPressure {
    MemoryPressure::Normal
}

fn warning() -> MemoryPressure {
    MemoryPressure::Warning
}

#[test]
fn cold_scrollback_terminal_is_due_once_unviewed_and_quiet_for_the_period() {
    let start = Instant::now();
    let a = id(1);
    let mut tracker = ColdTracker::default();

    assert!(tracker.due(start, HOUR, &[hot(&a)]).is_empty(), "the first pass starts the clock");
    assert_eq!(tracker.next_deadline(HOUR, &[hot(&a)]), Some(start + HOUR));
    assert!(tracker.due(start + HOUR - Duration::from_secs(1), HOUR, &[hot(&a)]).is_empty());
    assert_eq!(tracker.due(start + HOUR, HOUR, &[hot(&a)]), vec![a.clone()]);
}

#[test]
fn cold_scrollback_output_and_views_restart_the_clock() {
    let start = Instant::now();
    let a = id(1);
    let mut tracker = ColdTracker::default();
    tracker.due(start, HOUR, &[hot(&a)]);

    let printed = ColdCandidate { last_output: Some(start + HOUR / 2), ..hot(&a) };
    assert!(tracker.due(start + HOUR, HOUR, &[printed]).is_empty());
    assert_eq!(tracker.next_deadline(HOUR, &[printed]), Some(start + HOUR / 2 + HOUR));

    let viewed = ColdCandidate { viewed: true, ..printed };
    assert!(tracker.due(start + 5 * HOUR, HOUR, &[viewed]).is_empty());
    assert_eq!(tracker.next_deadline(HOUR, &[viewed]), None, "a viewed terminal has no deadline");

    // Detached again: a new period from the pass that sees it.
    let detached_at = start + 6 * HOUR;
    let detached = ColdCandidate { attach_epoch: 1, ..printed };
    assert!(tracker.due(detached_at, HOUR, &[detached]).is_empty());
    assert_eq!(tracker.next_deadline(HOUR, &[detached]), Some(detached_at + HOUR));

    // A view that came and went between two passes restarts it too.
    let flicker = ColdCandidate { attach_epoch: 2, ..printed };
    assert!(tracker.due(detached_at + HOUR, HOUR, &[flicker]).is_empty());
    assert_eq!(tracker.due(detached_at + 2 * HOUR, HOUR, &[flicker]), vec![a.clone()]);
}

#[test]
fn cold_scrollback_cold_terminals_leave_no_deadline_and_a_restore_restarts_the_clock() {
    let start = Instant::now();
    let a = id(1);
    let mut tracker = ColdTracker::default();
    tracker.due(start, HOUR, &[hot(&a)]);
    assert_eq!(tracker.due(start + HOUR, HOUR, &[hot(&a)]), vec![a.clone()]);
    tracker.settle(&a, ColdFreeze::Frozen { held_bytes: 1 }, start + HOUR, None);
    assert_eq!(tracker.next_deadline(HOUR, &[hot(&a)]), None, "a frozen terminal waits for a wake");

    let cold = ColdCandidate { cold: true, ..hot(&a) };
    assert!(tracker.due(start + 3 * HOUR, HOUR, &[cold]).is_empty());
    assert_eq!(tracker.next_deadline(HOUR, &[cold]), None);

    // Restored by a read: the read is activity, so it is not frozen again at once.
    let restored_at = start + 4 * HOUR;
    assert!(tracker.due(restored_at, HOUR, &[hot(&a)]).is_empty());
    assert_eq!(tracker.next_deadline(HOUR, &[hot(&a)]), Some(restored_at + HOUR));
}

#[test]
fn cold_scrollback_refused_terminal_is_asked_again_only_after_output() {
    let start = Instant::now();
    let a = id(1);
    let mut tracker = ColdTracker::default();
    tracker.due(start, HOUR, &[hot(&a)]);
    tracker.due(start + HOUR, HOUR, &[hot(&a)]);
    tracker.settle(
        &a,
        ColdFreeze::Refused(ghostty_vt::ColdPagesError::KittyUploadInProgress),
        start + HOUR,
        None,
    );

    assert!(tracker.due(start + 10 * HOUR, HOUR, &[hot(&a)]).is_empty());
    assert_eq!(tracker.next_deadline(HOUR, &[hot(&a)]), None, "no retry timer for a refusal");

    let printed = ColdCandidate { last_output: Some(start + 11 * HOUR), ..hot(&a) };
    assert!(tracker.due(start + 11 * HOUR, HOUR, &[printed]).is_empty());
    assert_eq!(tracker.due(start + 12 * HOUR, HOUR, &[printed]), vec![a.clone()]);
}

#[test]
fn cold_scrollback_busy_or_viewed_at_the_freeze_waits_a_period_and_closed_terminals_are_forgotten()
{
    let start = Instant::now();
    let (a, b) = (id(1), id(2));
    let mut tracker = ColdTracker::default();
    tracker.due(start, HOUR, &[hot(&a), hot(&b)]);
    assert_eq!(tracker.due(start + HOUR, HOUR, &[hot(&a), hot(&b)]).len(), 2);
    tracker.settle(&a, ColdFreeze::Busy, start + HOUR, None);
    tracker.settle(&b, ColdFreeze::Viewed, start + HOUR, None);
    assert_eq!(tracker.next_deadline(HOUR, &[hot(&a), hot(&b)]), Some(start + 2 * HOUR));

    assert!(tracker.due(start + HOUR, HOUR, &[hot(&b)]).is_empty());
    assert_eq!(tracker.terminals.len(), 1, "a closed terminal is forgotten");
}

#[test]
fn cold_scrollback_pass_freezes_a_quiet_unviewed_terminal_with_one_deadline() {
    let mux = Mux::new_for_test("cold-scrollback-pass", SurfaceOptions::default());
    let surface = mux.new_workspace(None, None).unwrap();
    surface.with_terminal(|term| {
        for line in 0..400 {
            term.vt_write(format!("line {line}\r\n").as_bytes());
        }
    });
    let policy = ColdPolicy { after: HOUR, pressure: normal };
    let mut tracker = ColdTracker::default();
    let start = Instant::now();

    assert_eq!(mux.cold_scrollback_pass(&mut tracker, start, policy), Some(start + HOUR));
    assert!(!surface.terminal_is_cold());

    assert_eq!(mux.cold_scrollback_pass(&mut tracker, start + HOUR, policy), None);
    assert!(surface.terminal_is_cold(), "due terminal was not compressed");
    assert_eq!(
        mux.cold_scrollback_pass(&mut tracker, start + 5 * HOUR, policy),
        None,
        "an all-cold mux has no deadline: no wakeups"
    );

    let rows = surface.with_terminal(|term| term.history_rows()).unwrap();
    assert!(rows > 300 && !surface.terminal_is_cold());
    let restored_at = start + 6 * HOUR;
    assert_eq!(
        mux.cold_scrollback_pass(&mut tracker, restored_at, policy),
        Some(restored_at + HOUR)
    );
}

#[test]
fn cold_scrollback_pass_compresses_nothing_under_memory_pressure() {
    let mux = Mux::new_for_test("cold-scrollback-pressure", SurfaceOptions::default());
    let surface = mux.new_workspace(None, None).unwrap();
    let mut tracker = ColdTracker::default();
    let start = Instant::now();
    let pressed = ColdPolicy { after: HOUR, pressure: warning };

    mux.cold_scrollback_pass(&mut tracker, start, pressed);
    assert_eq!(
        mux.cold_scrollback_pass(&mut tracker, start + HOUR, pressed),
        Some(start + 2 * HOUR),
        "a due terminal waits one more period"
    );
    assert!(!surface.terminal_is_cold());

    let calm = ColdPolicy { after: HOUR, pressure: normal };
    mux.cold_scrollback_pass(&mut tracker, start + 2 * HOUR, calm);
    assert!(surface.terminal_is_cold());
}

#[test]
fn cold_scrollback_feature_snapshot_starts_the_worker_and_the_kill_switch_stops_it() {
    use cmux_features::{Channel, Snapshot};
    const NAME: &str = "coldScrollbackCompression";
    let started = |features: Snapshot| {
        let mux = Mux::new_for_test("cold-scrollback-feature", SurfaceOptions::default());
        mux.start_cold_scrollback(&features).unwrap();
        mux.cold_scrollback_wake.get().is_some()
    };
    for channel in [Channel::Dev, Channel::Nightly, Channel::Release] {
        assert!(!started(Snapshot::defaults(channel)), "off by default on {channel:?}");
    }
    assert!(started(Snapshot::from_env(Channel::Release, Some(NAME), None)));
    assert!(!started(Snapshot::from_env(Channel::Release, Some(NAME), Some(NAME))));
    // flags.json `DisabledFeatures` wins over the person's enable list.
    assert!(!started(Snapshot::from_env(Channel::Release, Some(NAME), None).with_disabled([NAME])));
}

#[test]
fn cold_scrollback_terminal_created_after_an_empty_pass_wakes_the_worker() {
    let mux = Mux::new_for_test("cold-scrollback-catalog-wake", SurfaceOptions::default());
    let wakes = mux.install_cold_scrollback_wake().unwrap();
    let policy = ColdPolicy { after: HOUR, pressure: normal };
    let mut tracker = ColdTracker::default();
    let start = Instant::now();
    assert_eq!(mux.cold_scrollback_pass(&mut tracker, start, policy), None, "nothing to track");
    assert!(wakes.try_recv().is_err());

    let _surface = mux.new_workspace(None, None).unwrap();
    assert!(wakes.try_recv().is_ok(), "a terminal entering the catalog wakes the worker");
    while wakes.try_recv().is_ok() {}
    let woke_at = start + Duration::from_secs(1);
    assert_eq!(mux.cold_scrollback_pass(&mut tracker, woke_at, policy), Some(woke_at + HOUR));
}

#[cfg(unix)]
#[test]
fn cold_scrollback_worker_compresses_a_terminal_created_while_it_blocks() {
    let quiet = SurfaceOptions { command: Some(vec!["/bin/cat".into()]), ..Default::default() };
    let mux = Mux::new_for_test("cold-scrollback-worker", quiet);
    let after = Duration::from_millis(50);
    mux.start_cold_scrollback_with(ColdPolicy { after, pressure: normal }).unwrap();
    // The worker's first pass finds no terminal and blocks with no deadline.
    let surface = mux.new_workspace(None, None).unwrap();

    let deadline = Instant::now() + Duration::from_secs(20);
    while !surface.terminal_is_cold() {
        assert!(Instant::now() < deadline, "the worker never compressed the new terminal");
        std::thread::sleep(after);
    }
}

#[test]
fn cold_scrollback_refused_terminal_reports_its_next_output() {
    let mux = Mux::new_for_test("cold-scrollback-refusal", SurfaceOptions::default());
    let store = &mux.output_store;
    let terminal = id(7);
    let generation: Arc<str> = Arc::from("g1");
    assert!(store.append(&terminal, &generation, b"first"), "a new log reports its first output");
    assert!(!store.append(&terminal, &generation, b"second"));

    let seen = store.last_output(&terminal);
    assert!(!store.wake_on_next_output(&terminal, seen), "armed");
    assert!(store.append(&terminal, &generation, b"after the refusal"));
    assert!(!store.append(&terminal, &generation, b"once"));

    assert!(store.wake_on_next_output(&terminal, seen), "it printed since the pass read it");
}

#[test]
fn cold_scrollback_pass_keeps_a_placement_scrolled_back_across_a_restore() {
    let mux = Mux::new_for_test("cold-scrollback-view", SurfaceOptions::default());
    let surface = mux.new_workspace(None, None).unwrap();
    surface.with_terminal(|term| {
        for line in 0..1_000 {
            term.vt_write(format!("line {line}\r\n").as_bytes());
        }
    });
    let scrolled = surface.view_scroll_delta(-100).unwrap().unwrap();
    let policy = ColdPolicy { after: HOUR, pressure: normal };
    let mut tracker = ColdTracker::default();
    let start = Instant::now();
    mux.cold_scrollback_pass(&mut tracker, start, policy);
    mux.cold_scrollback_pass(&mut tracker, start + HOUR, policy);
    assert!(surface.terminal_is_cold());

    assert_eq!(surface.view_scrollbar(), Some(scrolled), "the view jumped after a restore");
}

#[cfg(unix)]
#[test]
fn cold_scrollback_checkpoint_leaves_cold_terminals_cold() {
    let root = std::env::temp_dir().join(format!(
        "cmux-cold-scrollback-checkpoint-{}-{}",
        std::process::id(),
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
    ));
    let quiet = SurfaceOptions { command: Some(vec!["/bin/cat".into()]), ..Default::default() };
    let mux = Mux::open_persistent("cold-scrollback-checkpoint", quiet, &root).unwrap();
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal = surface.terminal_public_id().unwrap().clone();
    mux.output_store.append(&terminal, &Arc::from("g1"), b"printed before the freeze\r\n");
    let thaws = Arc::new(AtomicUsize::new(0));
    let counter = thaws.clone();
    let wake: ThawWake = Arc::new(move || _ = counter.fetch_add(1, Ordering::Relaxed));
    assert!(matches!(surface.freeze_cold_terminal(&[], &wake), Some(ColdFreeze::Frozen { .. })));

    mux.output_store.write_now(&mux);
    mux.create_journal_checkpoint("client_test", "cold_scrollback_checkpoint").unwrap();
    assert!(surface.terminal_is_cold(), "a checkpoint restored a cold terminal");
    assert_eq!(thaws.load(Ordering::Relaxed), 0);

    drop(surface);
    mux.shutdown();
    drop(mux);
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn cold_scrollback_psi_thresholds_match_the_pressure_source() {
    let psi = |some: f64, full: f64| {
        format!(
            "some avg10={some:.2} avg60=0.00 avg300=0.00 total=1\nfull avg10={full:.2} avg60=0.00 avg300=0.00 total=1\n"
        )
    };
    assert_eq!(psi_pressure(&psi(0.0, 0.0)), MemoryPressure::Normal);
    assert_eq!(psi_pressure(&psi(14.99, 0.0)), MemoryPressure::Normal);
    assert_eq!(psi_pressure(&psi(15.0, 2.0)), MemoryPressure::Warning);
    assert_eq!(psi_pressure(&psi(40.0, 15.0)), MemoryPressure::Critical);
    assert_eq!(psi_pressure("garbage"), MemoryPressure::Normal);
}
