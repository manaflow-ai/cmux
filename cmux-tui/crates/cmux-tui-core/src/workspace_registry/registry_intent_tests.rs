//! Earlier indeterminate receipts on the request path: `drain_unsettled`
//! waits for the journal writer, a `journal_wait` noted at its caller.

use cmux_threads::sync::mpsc::sync_channel;
use std::sync::Arc;
use std::time::{Duration, Instant};

use super::super::admitted_reply::AdmitStatsSnapshot;
use super::*;
use crate::request_path::{BlockingKind, RequestPathMode, RequestPathScope, RequestPathStats};
use crate::{Mux, MuxEvent, SurfaceOptions};

fn journal_wait_lines(stats: &RequestPathStats) -> Vec<(&'static str, u32)> {
    stats
        .sites()
        .into_iter()
        .filter(|noted| noted.kind == BlockingKind::JournalWait)
        .map(|noted| (noted.site.file(), noted.site.line()))
        .collect()
}

#[test]
fn drain_unsettled_notes_a_journal_wait_for_an_unanswered_receipt() {
    let registry = WorkspaceRegistry::in_memory("drain-unsettled-wait").expect("registry");
    let (answer, receipt) = sync_channel(1);
    registry.connection.hold_unsettled(PendingRegistryReceipt::for_test(receipt), None);
    let writer = std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(5));
        answer.send(Err("rolled back".to_string())).expect("answer");
    });
    let stats = RequestPathStats::new(RequestPathMode::RECORD);
    let _scope = RequestPathScope::enter(&stats);
    let line = line!() + 1;
    registry.connection.drain_unsettled().expect("the receipt arrived");
    writer.join().expect("writer");
    assert_eq!(journal_wait_lines(&stats), [(file!(), line)]);
}

#[test]
fn drain_unsettled_notes_nothing_for_an_answered_receipt() {
    let registry = WorkspaceRegistry::in_memory("drain-unsettled-answered").expect("registry");
    let (answer, receipt) = sync_channel(1);
    answer.send(Err("rolled back".to_string())).expect("answer");
    registry.connection.hold_unsettled(PendingRegistryReceipt::for_test(receipt), None);
    let stats = RequestPathStats::new(RequestPathMode::RECORD);
    let _scope = RequestPathScope::enter(&stats);
    registry.connection.drain_unsettled().expect("already answered");
    registry.connection.drain_unsettled().expect("nothing left to wait for");
    assert_eq!(stats.count(BlockingKind::JournalWait), 0);
}

// Admit then reply (p05-ipc-120, `admitted_reply`).

/// A workspace-added intent on top of `base`, with the receipt a reply
/// gives for it: `replied_revision`. `expected_revision` is its CAS.
fn workspace_intent(
    registry: &WorkspaceRegistry,
    base: &RegistrySnapshot,
    key: &str,
    expected_revision: Option<u64>,
    replied_revision: u64,
) -> (RegistryIntent, RegistryReceipt) {
    let id = base.revision + 1;
    let mut workspaces = base.workspaces.clone();
    workspaces.push(RegistryWorkspace {
        id,
        public_id: WorkspacePublicId::parse(format!("ws_{id:032x}")).unwrap(),
        key: key.into(),
        name: key.into(),
        name_source: Default::default(),
        name_revision: 0,
        group_key: "default".into(),
    });
    let result = serde_json::json!({ "key": key });
    let intent = registry
        .prepare_workspace_commit(
            &WorkspaceMutation::daemon(format!("admit-{key}"), "test").unwrap(),
            &serde_json::json!({ "op": "create", "key": key }),
            None,
            expected_revision,
            "workspace-added",
            key,
            &workspaces,
            None,
            &result,
            false,
        )
        .expect("prepare");
    let prepared = RegistryReceipt::Workspace(WorkspaceCommitReceipt {
        commit: RegistryCommit { revision: replied_revision, result, replayed: false },
        resource_revision: None,
    });
    (RegistryIntent::Workspace(intent), prepared)
}

fn persistent_mux(name: &str) -> (Arc<Mux>, PathBuf) {
    let root = std::env::temp_dir().join(format!("cmux-admit-{name}-{}", new_uuid_v4()));
    let mux = Mux::open_persistent(name, SurfaceOptions::default(), &root).expect("mux");
    mux.registry_connection.admit.set_enabled_for_test(true);
    (mux, root)
}

fn base_snapshot(mux: &Mux) -> RegistrySnapshot {
    mux.workspace_registry.lock().unwrap().snapshot().expect("snapshot")
}

fn admit_stats(mux: &Mux) -> AdmitStatsSnapshot {
    mux.registry_connection.admit_stats()
}

/// Pause the journal writer inside a batch commit (it holds the registry
/// connection); the sender releases it.
fn pause_writer(mux: &Mux) -> std::sync::mpsc::SyncSender<()> {
    let (entered, entered_receiver) = std::sync::mpsc::sync_channel(1);
    let (release, release_receiver) = std::sync::mpsc::sync_channel(1);
    mux.install_journal_before_commit_for_test(entered, release_receiver);
    mux.journal_terminal_output(
        Arc::new(TerminalPublicId::parse(format!("term_{:032x}", 120)).unwrap()),
        Arc::from("admit-then-reply-generation"),
        b"output that pauses the writer".to_vec(),
    );
    entered_receiver.recv_timeout(Duration::from_secs(10)).expect("the writer paused");
    release
}

/// The in-memory base after admitting `key` on `base` (p05-ipc-132/133).
fn after_workspace(base: &RegistrySnapshot, key: &str) -> RegistrySnapshot {
    let mut next = base.clone();
    next.revision += 1;
    next.workspaces.push(RegistryWorkspace {
        id: next.revision,
        public_id: WorkspacePublicId::parse(format!("ws_{:032x}", next.revision)).unwrap(),
        key: key.into(),
        name: key.into(),
        name_source: Default::default(),
        name_revision: 0,
        group_key: "default".into(),
    });
    next
}

fn workspace_revision(admission: Admission) -> u64 {
    admission.into_receipt().into_workspace().expect("a workspace receipt").commit.revision
}

#[test]
fn admit_commits_and_counts_the_reason_when_it_cannot_admit() {
    let mut registry = WorkspaceRegistry::in_memory("admit-fallback").expect("registry");
    let base = registry.snapshot().unwrap();
    let (intent, prepared) =
        workspace_intent(&registry, &base, "off", Some(base.revision), base.revision + 1);
    let admission = registry.admit_registry_intent(intent, prepared, || {}, None).unwrap();
    assert!(matches!(admission, Admission::Committed(_)), "feature off: {admission:?}");
    assert_eq!(registry.snapshot().unwrap().revision, base.revision + 1);

    registry.connection.admit.set_enabled_for_test(true);
    let base = registry.snapshot().unwrap();
    let (intent, prepared) =
        workspace_intent(&registry, &base, "no-writer", Some(base.revision), base.revision + 1);
    let admission = registry.admit_registry_intent(intent, prepared, || {}, None).unwrap();
    assert!(matches!(admission, Admission::Committed(_)), "no writer: {admission:?}");
    assert_eq!(registry.snapshot().unwrap().revision, base.revision + 1);

    let stats = registry.connection.admit_stats();
    assert_eq!(
        (stats.admitted, stats.fallbacks_disabled, stats.fallbacks_writer_not_running),
        (0, 1, 1)
    );
}

/// Red first: with `admitThenReply` off this request waits for the paused
/// writer and the 5 s receive below fails. On: the reply carries the
/// prepared receipt while the writer is still paused, and a later read on
/// the same registry waits for the writer (the read barrier) and sees it.
#[test]
fn an_admitted_reply_does_not_wait_for_the_journal_writer_and_reads_see_it() {
    let (mux, root) = persistent_mux("reply-before-commit");
    let base = base_snapshot(&mux);
    let release = pause_writer(&mux);

    let stats = RequestPathStats::new(RequestPathMode::RECORD);
    let (admitted, admitted_receiver) = std::sync::mpsc::sync_channel(1);
    let (read, read_receiver) = std::sync::mpsc::sync_channel(1);
    let request = std::thread::spawn({
        let (mux, stats, base) = (mux.clone(), stats.clone(), base.clone());
        move || {
            let mut registry = mux.workspace_registry.lock().unwrap();
            let revision = Some(base.revision);
            let (intent, prepared) =
                workspace_intent(&registry, &base, "admitted", revision, base.revision + 1);
            let started = Instant::now();
            let admission = registry.admit_registry_intent(intent, prepared, || {}, None);
            let replied = started.elapsed();
            let admission = admission
                .map(|admission| (admission.sequence(), workspace_revision(admission)))
                .map_err(|error| format!("{error:#}"));
            admitted.send((admission, replied)).unwrap();
            let _scope = RequestPathScope::enter(&stats);
            read.send(registry.snapshot().map_err(|error| format!("{error:#}"))).unwrap();
        }
    });

    let (admission, replied) = admitted_receiver
        .recv_timeout(Duration::from_secs(5))
        .expect("the reply must not wait for the paused journal writer");
    let (sequence, revision) = admission.expect("admitted");
    assert_eq!(sequence, Some(1), "the first admission of this registry");
    assert_eq!(revision, base.revision + 1, "the reply carries the prepared receipt");
    assert!(replied < Duration::from_millis(50), "the reply took {replied:?}");
    assert_eq!(admit_stats(&mux).unresolved, 1, "the writer has not answered");

    // The read waits for the admitted intent's answer, not for the lock.
    let deadline = Instant::now() + Duration::from_secs(10);
    while stats.count(BlockingKind::JournalWait) == 0 {
        assert!(Instant::now() < deadline, "the read never reached the read barrier");
        std::thread::yield_now();
    }
    release.send(()).unwrap();
    let snapshot = read_receiver.recv_timeout(Duration::from_secs(10)).unwrap().unwrap();
    request.join().unwrap();
    assert_eq!(snapshot.revision, base.revision + 1, "read-your-writes after the reply");
    let events = mux.workspace_registry.lock().unwrap().events_after(base.revision).unwrap();
    assert_eq!(
        events
            .iter()
            .map(|event| (event.revision, event.workspace_key.as_str()))
            .collect::<Vec<_>>(),
        [(base.revision + 1, "admitted")]
    );
    let stats = admit_stats(&mux);
    assert_eq!(
        (stats.admitted, stats.read_barrier_waits, stats.journal_degraded, stats.unresolved),
        (1, 1, 0, 0)
    );
    drop(mux);
    fs::remove_dir_all(root).unwrap();
}

/// Back-to-back admissions behind a paused writer: neither waits for the
/// other's commit (the lane keeps their order), and both commit in order.
#[test]
fn back_to_back_admissions_do_not_wait_for_each_other() {
    let (mux, root) = persistent_mux("back-to-back");
    let base = base_snapshot(&mux);
    let release = pause_writer(&mux);

    let (admitted, admitted_receiver) = std::sync::mpsc::sync_channel(2);
    let request = std::thread::spawn({
        let (mux, base) = (mux.clone(), base.clone());
        move || {
            let mut registry = mux.workspace_registry.lock().unwrap();
            let revision = Some(base.revision);
            let (intent, prepared) =
                workspace_intent(&registry, &base, "first", revision, base.revision + 1);
            let first = registry.admit_registry_intent(intent, prepared, || {}, None).unwrap();
            admitted.send(first.sequence()).unwrap();
            let next = after_workspace(&base, "first");
            let revision = Some(next.revision);
            let (intent, prepared) =
                workspace_intent(&registry, &next, "second", revision, next.revision + 1);
            let second = registry.admit_registry_intent(intent, prepared, || {}, None).unwrap();
            admitted.send(second.sequence()).unwrap();
        }
    });
    let timeout = Duration::from_secs(5);
    assert_eq!(admitted_receiver.recv_timeout(timeout).expect("first"), Some(1));
    assert_eq!(admitted_receiver.recv_timeout(timeout).expect("no wait"), Some(2));
    request.join().unwrap();
    release.send(()).unwrap();

    let snapshot = base_snapshot(&mux);
    assert_eq!(snapshot.revision, base.revision + 2);
    let stats = admit_stats(&mux);
    assert_eq!((stats.admitted, stats.journal_degraded, stats.unresolved), (2, 0, 0));
    drop(mux);
    fs::remove_dir_all(root).unwrap();
}

/// The writer rolls the admitted intent back (here a revision conflict the
/// prepare did not see): the reply stands, nothing undoes the state it
/// applied, and the next state holder publishes journal-degraded.
#[test]
fn a_writer_failure_keeps_the_admitted_reply_and_publishes_journal_degraded() {
    let (mux, root) = persistent_mux("writer-failure");
    let base = base_snapshot(&mux);
    let events = mux.subscribe();
    let mut registry = mux.workspace_registry.lock().unwrap();
    let stale = Some(base.revision + 7);
    let (intent, prepared) =
        workspace_intent(&registry, &base, "rolled-back", stale, base.revision + 1);
    let admission = registry.admit_registry_intent(intent, prepared, || {}, None).unwrap();
    assert_eq!(admission.sequence(), Some(1));
    assert_eq!(workspace_revision(admission), base.revision + 1, "the reply stands");

    let snapshot = registry.snapshot().unwrap();
    assert_eq!(snapshot.revision, base.revision, "the journal does not hold the intent");
    let stats = admit_stats(&mux);
    assert_eq!((stats.journal_degraded, stats.receipt_mismatches, stats.unresolved), (1, 0, 0));

    let mut state = mux.state.lock().unwrap();
    mux.settle_registry_receipts(&registry, &mut state);
    drop(state);
    let degraded = events
        .try_iter()
        .filter_map(|event| match event {
            MuxEvent::Status(message) if message.starts_with("journal-degraded: ") => Some(message),
            _ => None,
        })
        .collect::<Vec<_>>();
    assert_eq!(degraded.len(), 1, "one journal-degraded status: {degraded:?}");
    assert!(degraded[0].contains("admitted registry commit 1 did not commit"), "{degraded:?}");
    assert!(registry.connection.take_journal_degraded().is_empty(), "published once");
    drop(registry);
    drop(mux);
    fs::remove_dir_all(root).unwrap();
}

/// A writer receipt that differs from the reply (a prepare that decided the
/// wrong revision) is journal-degraded and counted as a mismatch.
#[test]
fn a_receipt_that_differs_from_the_reply_is_journal_degraded() {
    let (mux, root) = persistent_mux("receipt-mismatch");
    let base = base_snapshot(&mux);
    let mut registry = mux.workspace_registry.lock().unwrap();
    let (intent, prepared) =
        workspace_intent(&registry, &base, "mismatch", Some(base.revision), base.revision + 5);
    registry.admit_registry_intent(intent, prepared, || {}, None).unwrap();
    assert_eq!(registry.snapshot().unwrap().revision, base.revision + 1);
    let stats = admit_stats(&mux);
    assert_eq!((stats.journal_degraded, stats.receipt_mismatches), (1, 1));
    let notes = registry.connection.take_journal_degraded();
    assert_eq!(notes.len(), 1);
    assert!(notes[0].contains("its reply said"), "{notes:?}");
    drop(registry);
    drop(mux);
    fs::remove_dir_all(root).unwrap();
}

/// The writer is apply-only for admitted intents (p05-ipc.md 3.6): their
/// replies are out and memory holds them, so a batch deadline that expires
/// under contention retries them instead of answering with the timeout.
/// Red before: both were dropped from the journal (two journal-degraded
/// notes, the journal stayed at `base`).
#[test]
fn admitted_intents_behind_a_writer_held_past_the_deadline_still_commit() {
    let (mux, root) = persistent_mux("held-past-deadline");
    let base = base_snapshot(&mux);
    let release = pause_writer(&mux);

    let request = std::thread::spawn({
        let (mux, base) = (mux.clone(), base.clone());
        move || {
            let mut registry = mux.workspace_registry.lock().unwrap();
            let revision = Some(base.revision);
            let (intent, prepared) =
                workspace_intent(&registry, &base, "first", revision, base.revision + 1);
            let first = registry.admit_registry_intent(intent, prepared, || {}, None).unwrap();
            let next = after_workspace(&base, "first");
            let revision = Some(next.revision);
            let (intent, prepared) =
                workspace_intent(&registry, &next, "second", revision, next.revision + 1);
            let second = registry.admit_registry_intent(intent, prepared, || {}, None).unwrap();
            (first.sequence(), second.sequence())
        }
    });
    assert_eq!(request.join().unwrap(), (Some(1), Some(2)), "both admitted");
    std::thread::sleep(crate::journal_ingress::JOURNAL_DURABLE_WAIT + Duration::from_millis(500));
    release.send(()).unwrap();

    let deadline = Instant::now() + Duration::from_secs(20);
    // Each read waits, bounded, for the admitted answers (the read barrier).
    while {
        base_snapshot(&mux);
        admit_stats(&mux).unresolved != 0
    } {
        assert!(Instant::now() < deadline, "the writer never answered: {:?}", admit_stats(&mux));
    }
    let stats = admit_stats(&mux);
    assert_eq!((stats.admitted, stats.journal_degraded), (2, 0), "{stats:?}");
    let events = mux.workspace_registry.lock().unwrap().events_after(base.revision).unwrap();
    assert_eq!(
        events
            .iter()
            .map(|event| (event.revision, event.workspace_key.as_str()))
            .collect::<Vec<_>>(),
        [(base.revision + 1, "first"), (base.revision + 2, "second")]
    );
    drop(mux);
    fs::remove_dir_all(root).unwrap();
}
