//! When a journal maintenance pass runs: one interval after a commit it has
//! not seen, on the durability deadline grid, never for its own commits.

use super::*;

const INTERVAL: Duration = Duration::from_secs(30);
const MS: u64 = 1_000_000;
const S: u64 = 1_000_000_000;

/// An instant off the whole-second grid, so alignment is visible.
const START: Ticks = Ticks(1_000 * S + 250 * MS);

fn later(by: Duration) -> Ticks {
    START.after(by)
}

/// Where a pass armed at `now` fires.
fn armed_at(now: Ticks) -> Ticks {
    crate::wake::deadline(now, INTERVAL, Policy::FlexibleNoSooner).fire
}

/// The start pass, taken with nothing committed: what an idle daemon
/// leaves armed afterwards.
fn after_start_pass() -> MaintenanceSchedule {
    let mut schedule = MaintenanceSchedule::new(INTERVAL, START);
    let first = armed_at(START);
    assert_eq!(schedule.due, Some(first));
    assert!(schedule.take_due(first, 0));
    schedule.pass_finished(MaintenancePass::Done, first, 0);
    schedule
}

#[test]
fn a_pass_is_armed_on_the_whole_second_grid_within_ten_percent_after_the_interval() {
    let schedule = MaintenanceSchedule::new(INTERVAL, START);
    let due = schedule.due.expect("the start pass is armed");
    assert_eq!(due.0 % S, 0, "{due:?} is not on the whole-second grid");
    assert!(due >= START.after(INTERVAL), "{due:?} fires before the interval");
    assert!(due <= START.after(INTERVAL + INTERVAL / 10), "{due:?} is past the 10% leeway");
    // 1000.25 s + 30 s: the next whole second.
    assert_eq!(due, Ticks(1_031 * S));
}

#[test]
fn an_idle_daemon_arms_no_pass_after_the_start_pass() {
    let mut schedule = after_start_pass();
    assert_eq!(schedule.due, None);
    assert!(!schedule.take_due(later(INTERVAL * 100), 0));
    // A reply that committed nothing arms nothing.
    assert!(!schedule.note_commits(0, later(INTERVAL * 2)));
    assert_eq!(schedule.due, None);
}

#[test]
fn a_commit_arms_one_pass_an_interval_later() {
    let mut schedule = after_start_pass();
    let commit = later(INTERVAL * 3);
    let due = armed_at(commit);
    assert!(schedule.note_commits(4, commit));
    assert_eq!(schedule.due, Some(due));
    // Later commits join the armed pass instead of moving it.
    assert!(!schedule.note_commits(9, later(INTERVAL * 3 + Duration::from_secs(5))));
    assert_eq!(schedule.due, Some(due));
    assert!(!schedule.take_due(Ticks(due.0 - 1), 9));
    assert!(schedule.take_due(due, 9));
    schedule.pass_finished(MaintenancePass::Done, due, 9);
    // The pass saw commit 9: noting it again arms nothing.
    assert!(!schedule.note_commits(9, later(INTERVAL * 5)));
    assert_eq!(schedule.due, None);
    assert!(schedule.note_commits(10, later(INTERVAL * 5)));
}

#[test]
fn work_left_rearms_without_a_commit() {
    let mut schedule = MaintenanceSchedule::new(INTERVAL, START);
    let first = armed_at(START);
    assert!(schedule.take_due(first, 0));
    schedule.pass_finished(MaintenancePass::WorkLeft, first, 0);
    let second = armed_at(first);
    assert_eq!(schedule.due, Some(second));
    assert!(schedule.take_due(second, 0));
    schedule.pass_finished(MaintenancePass::Done, second, 0);
    assert_eq!(schedule.due, None);
}

#[test]
fn a_commit_during_a_pass_keeps_its_own_deadline() {
    let mut schedule = after_start_pass();
    let commit = later(INTERVAL * 2);
    assert!(schedule.note_commits(3, commit));
    assert!(schedule.take_due(armed_at(commit), 3));
    // Another thread committed while the pass ran, after it read the count.
    let during = armed_at(commit).after(Duration::from_secs(1));
    assert!(schedule.note_commits(5, during));
    schedule.pass_finished(MaintenancePass::WorkLeft, during.after(INTERVAL), 5);
    assert_eq!(schedule.due, Some(armed_at(during)));
}

#[test]
fn a_stopped_schedule_arms_nothing() {
    let mut schedule = after_start_pass();
    schedule.stopped = true;
    assert!(!schedule.note_commits(7, later(INTERVAL * 2)));
    assert_eq!(schedule.due, None);
}

fn control_after_start_pass() -> JournalMaintenanceControl {
    JournalMaintenanceControl {
        schedule: Mutex::new(after_start_pass()),
        changed: Condvar::new(),
        noted_commits: AtomicU64::new(0),
    }
}

#[test]
fn notes_from_the_passs_own_thread_arm_no_pass_and_others_still_do() {
    let control = control_after_start_pass();
    control.schedule.lock().unwrap().take(2);
    {
        let _running = RunningPass::enter();
        // The pass checkpointed and sealed: each commit publishes a note.
        control.note_commits(3);
        control.note_commits(4);
        assert_eq!(control.schedule.lock().unwrap().due, None);
    }
    // A commit on another thread during the same pass owes a pass.
    std::thread::scope(|scope| {
        scope.spawn(|| control.note_commits(4));
    });
    assert!(control.schedule.lock().unwrap().due.is_some());
}

fn persistent_mux(name: &str) -> (Arc<Mux>, std::path::PathBuf) {
    let root = std::env::temp_dir().join(format!(
        "cmux-journal-maintenance-{name}-{}",
        crate::workspace_registry::new_uuid_v4()
    ));
    let mux = Mux::open_persistent(name, SurfaceOptions::default(), &root).unwrap();
    (mux, root)
}

fn create_workspace(mux: &Arc<Mux>, key: &str) {
    let request = serde_json::json!({
        "protocol": "cmux.protocol/2",
        "type": "request",
        "id": key,
        "operation": "workspace.create",
        "params": {"machine": "current", "session": "current", "initial_content": "empty"},
        "idempotency_key": key,
    });
    crate::resource_router::handle_resource_message(mux, &request.to_string()).unwrap();
}

#[test]
fn a_pass_that_seals_arms_no_pass_from_its_own_commits() {
    let (mux, root) = persistent_mux("own-commits");
    create_workspace(&mux, "maintenance-own-commits");
    // A checkpoint past the sealed segments: the pass seals up to it.
    mux.create_journal_checkpoint("client_test", "maintenance_checkpoint").unwrap();
    assert!(mux.journal_segments().unwrap().is_empty());
    let before = mux.registry_connection.durability_counts().0;

    let (pass, due) = mux.run_journal_maintenance_pass_for_test();

    assert_eq!(pass, MaintenancePass::Done);
    assert!(!mux.journal_segments().unwrap().is_empty(), "the pass sealed nothing");
    assert!(mux.registry_connection.durability_counts().0 > before, "the pass committed nothing");
    assert_eq!(due, None, "the pass's own seal armed another pass");
    mux.shutdown();
    let _ = std::fs::remove_dir_all(root);
}
