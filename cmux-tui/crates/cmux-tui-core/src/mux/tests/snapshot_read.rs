//! The whole-session snapshot read holds no writer lock.
//!
//! Lawrence's daemon, 2026-11-10 (826 workspaces, 2 h): the snapshot read
//! (`resource_api::session_snapshot_with_journal_head`) took the workspace
//! registry lock and the state lock 434 times, mean 105 ms, max 262 ms,
//! 45.4 s in total. It was the top stall maker: a split waited behind it.
//!
//! These guards count, they do not time: lock holds, state lock takes and
//! SELECT statements of snapshot reads at 1, 60 and 826 workspaces; a split
//! through the real request path beside a snapshot read that is stopped in
//! its row read; and readers beside a writer, where each snapshot must be one
//! committed revision (its journal head is never newer than its topology).
//!
//! The cache of the committed rows has guards of its own: a warm cache shows
//! the next commit of each kind (workspace create, state store write, journal
//! writer batch, metadata write), a read answers when an in-process terminal
//! closes under it, and a read settles the answer of a late registry commit.

use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{Receiver, SyncSender, sync_channel};
use std::sync::{Mutex, PoisonError};
use std::thread::ThreadId;
use std::time::Duration;

use rusqlite::hooks::{AuthAction, AuthContext, Authorization};
use serde_json::{Value, json};

use super::*;
use crate::resource_api::{public_session_snapshot, public_session_snapshot_with_journal_head};

/// Snapshot reads of one measurement.
const READS: u64 = 5;

/// The session sizes of each guard whose result can depend on the size:
/// light, 60 workspaces, and the 826 workspaces of Lawrence's daemon.
const ARMS: [usize; 3] = [1, 60, 826];

fn temp_root(name: &str) -> PathBuf {
    std::env::temp_dir().join(format!(
        "cmux-snapshot-read-{name}-{}-{}",
        std::process::id(),
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
    ))
}

/// A session on a real on-disk registry, at rest: the maintenance worker
/// stays off so that only the test writes.
fn session_at_rest(name: &str, root: &Path) -> Arc<Mux> {
    let mux = open_persistent_test_mux(name, root);
    mux.stop_journal_maintenance();
    mux
}

fn grow_to(mux: &Arc<Mux>, workspaces: usize) {
    let now = mux.workspace_registry.lock().unwrap().snapshot().unwrap().workspaces.len();
    for _ in now..workspaces {
        mux.create_empty_workspace(None, None, None).unwrap();
    }
}

/// One request through the real request path.
fn call(mux: &Arc<Mux>, operation: &str, fields: Value, key: Option<&str>) -> Value {
    let mut params = json!({"machine":"current","session":"current"});
    params.as_object_mut().unwrap().extend(fields.as_object().unwrap().clone());
    let mut envelope = json!({"protocol":"cmux.protocol/2","type":"request",
        "id":operation,"operation":operation,"params":params});
    if let Some(key) = key {
        envelope["idempotency_key"] = json!(key);
    }
    let response = crate::resource_router::handle_resource_message(mux, &envelope.to_string())
        .unwrap_or_else(|error| panic!("{operation} failed: {error:?}"));
    assert_eq!(response["ok"], true, "{operation} failed: {response}");
    response["result"].clone()
}

/// What a test runs for each statement that a registry connection compiles.
type StatementHook = Arc<dyn Fn(&AuthContext<'_>) + Send + Sync>;

/// Run `hook` for every statement that a registry connection (the writer's,
/// the read-only one and the snapshot readers' own) compiles; `None` removes
/// it.
fn watch_statements(mux: &Mux, hook: Option<StatementHook>) {
    let install = |connection: &rusqlite::Connection| match hook.clone() {
        Some(hook) => connection.authorizer(Some(move |context: AuthContext<'_>| {
            hook(&context);
            Authorization::Allow
        })),
        None => connection.authorizer(None::<fn(AuthContext<'_>) -> Authorization>),
    };
    install(&mux.registry_connection.get()).unwrap();
    mux.registry_connection
        .read_committed(|connection| Ok(install(connection)?))
        .expect("a file registry has a reader")
        .unwrap();
    if let Some(snapshots) = &mux.committed_snapshots {
        snapshots.with_reader_for_test(|connection| install(connection)).unwrap();
    }
}

/// What `reads` cost this thread: (registry lock takes, state lock takes,
/// SELECT statements compiled on either registry connection).
fn cost(mux: &Arc<Mux>, reads: impl FnOnce()) -> (u64, u64, u64) {
    let selects = Arc::new(AtomicU64::new(0));
    let reader = std::thread::current().id();
    let counted = selects.clone();
    watch_statements(
        mux,
        Some(Arc::new(move |context: &AuthContext<'_>| {
            if matches!(context.action, AuthAction::Select) && std::thread::current().id() == reader
            {
                counted.fetch_add(1, Ordering::Relaxed);
            }
        })),
    );
    let registry_before = registry_locks_taken_on_this_thread();
    let state_before = state_locks_taken_on_this_thread();
    reads();
    let state = state_locks_taken_on_this_thread() - state_before;
    let registry = registry_locks_taken_on_this_thread() - registry_before;
    watch_statements(mux, None);
    (registry, state, selects.load(Ordering::Relaxed))
}

/// The first read after a change takes the registry lock 0 times and tries
/// the state lock once (no wait, no walk under it). K snapshot reads with no
/// change between them take the registry lock 0
/// times, the state lock 0 times and run 0 SELECT statements, at 1, 60 and
/// 826 workspaces: the cost of a read does not grow with the session.
#[test]
fn snapshot_reads_with_no_change_take_no_lock_and_run_no_statement() {
    let root = temp_root("counts");
    let mux = session_at_rest("snapshot-counts", &root);
    let mut failures = Vec::new();
    eprintln!(
        "snapshot-read counts: workspaces | {READS} reads with no change: registry takes, state takes, SELECTs | first read after a change: registry takes, state tries, SELECTs"
    );
    for workspaces in ARMS {
        grow_to(&mux, workspaces);
        let waits_before = crate::resource_api::route_waits_on_this_thread();
        let (changed_registry, changed_state, changed_selects) = cost(&mux, || {
            public_session_snapshot(&mux).unwrap();
        });
        let (registry, state, selects) = cost(&mux, || {
            for _ in 0..READS {
                public_session_snapshot(&mux).unwrap();
            }
        });
        let waits = crate::resource_api::route_waits_on_this_thread() - waits_before;
        if waits != 0 {
            failures.push(format!(
                "{workspaces} workspaces: snapshot reads beside no mutator waited {waits} times for the state lock"
            ));
        }
        eprintln!(
            "snapshot-read counts: {workspaces} | {registry} {state} {selects} | {changed_registry} {changed_state} {changed_selects}"
        );
        if (registry, state, selects) != (0, 0, 0) {
            failures.push(format!(
                "{workspaces} workspaces: {READS} snapshot reads with no change took the registry lock {registry} times, the state lock {state} times and ran {selects} SELECT statements"
            ));
        }
        // The first read after a change tries the state lock once, with no
        // wait and no walk under it: the routes of its rows are published.
        if (changed_registry, changed_state) != (0, 1) {
            failures.push(format!(
                "{workspaces} workspaces: the first snapshot read after a change took the registry lock {changed_registry} times and the state lock {changed_state} times (0 takes and 1 try expected)"
            ));
        }
    }
    drop(mux);
    let _ = std::fs::remove_dir_all(&root);
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}

/// A split through the real request path answers while a snapshot read is
/// stopped in its row read: the reader holds no lock the split needs. At 1,
/// 60 and 826 workspaces.
#[test]
fn a_split_beside_a_stopped_snapshot_read_does_not_wait_for_it() {
    let root = temp_root("split");
    let mux = session_at_rest("snapshot-split", &root);
    let mut failures = Vec::new();
    for workspaces in ARMS {
        grow_to(&mux, workspaces);
        if let Err(failure) = split_beside_a_stopped_read(&mux, workspaces) {
            failures.push(format!("{workspaces} workspaces: {failure}"));
        }
    }
    drop(mux);
    let _ = std::fs::remove_dir_all(&root);
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}

/// One arm of the split guard: `Err` says what a person would see.
fn split_beside_a_stopped_read(mux: &Arc<Mux>, workspaces: usize) -> Result<(), String> {
    let created = call(
        mux,
        "workspace.create",
        json!({"initial_content":"terminal","name":format!("split-here-{workspaces}")}),
        Some(&format!("snapshot-split-create-{workspaces}")),
    );
    let pane = created["value"]["pane_id"].as_str().unwrap().to_string();

    // Stop the snapshot thread at its read of the terminal rows, on
    // whichever registry connection it reads.
    let slow: Arc<Mutex<Option<ThreadId>>> = Arc::default();
    let (entered, entered_receiver) = sync_channel::<()>(1);
    let (release, release_receiver) = sync_channel::<()>(1);
    let gate: Arc<(SyncSender<()>, Mutex<Receiver<()>>)> =
        Arc::new((entered, Mutex::new(release_receiver)));
    let slow_thread = slow.clone();
    watch_statements(
        mux,
        Some(Arc::new(move |context: &AuthContext<'_>| {
            let AuthAction::Read { table_name, .. } = context.action else { return };
            if table_name != "terminal_hosts" {
                return;
            }
            let mut slow = slow_thread.lock().unwrap_or_else(PoisonError::into_inner);
            if *slow == Some(std::thread::current().id()) {
                *slow = None;
                drop(slow);
                gate.0.send(()).unwrap();
                gate.1.lock().unwrap_or_else(PoisonError::into_inner).recv().unwrap();
            }
        })),
    );
    let snapshot = {
        let mux = mux.clone();
        std::thread::spawn(move || {
            *slow.lock().unwrap() = Some(std::thread::current().id());
            call(&mux, "session.snapshot", json!({}), None)
        })
    };
    entered_receiver
        .recv_timeout(Duration::from_secs(20))
        .expect("the snapshot read reaches its terminal row read");

    let (answered, answered_receiver) = std::sync::mpsc::channel();
    let split = {
        let mux = mux.clone();
        std::thread::spawn(move || {
            let split = call(
                &mux,
                "pane.split",
                json!({"pane":pane,"direction":"right"}),
                Some(&format!("snapshot-split-split-{workspaces}")),
            );
            let _ = answered.send(split);
        })
    };
    let split_answer = answered_receiver.recv_timeout(Duration::from_secs(2));
    release.send(()).unwrap();
    let snapshot = snapshot.join().unwrap();
    split.join().unwrap();
    watch_statements(mux, None);
    let split_answer = split_answer.map_err(|_| {
        "pane.split waited for the snapshot read that was stopped beside it".to_string()
    })?;
    if !split_answer["value"]["pane_id"].is_string() {
        return Err(format!("the split made no pane: {split_answer}"));
    }
    if !(snapshot["workspaces"].is_array() || snapshot["value"]["workspaces"].is_array()) {
        return Err(format!("the snapshot read did not answer: {snapshot}"));
    }
    Ok(())
}

/// Readers beside a writer: each snapshot is one committed revision. Every
/// workspace create commits its rows and its journal records together, so a
/// snapshot whose cursor is revision R has the journal head that revision R
/// committed: never an older one, never the head of a later revision. At 1,
/// 60 and 826 workspaces.
#[test]
fn a_snapshot_read_beside_a_writer_is_one_committed_revision() {
    let root = temp_root("cut");
    let mux = session_at_rest("snapshot-cut", &root);
    let mut arms = Vec::new();
    for workspaces in ARMS {
        grow_to(&mux, workspaces);
        arms.push((workspaces, cuts_beside_a_writer(&mux)));
    }
    drop(mux);
    let _ = std::fs::remove_dir_all(&root);

    for (workspaces, (committed, seen)) in arms {
        assert!(
            committed.last().unwrap().1 > committed[0].1
                && committed.last().unwrap().0 > committed[0].0,
            "{workspaces} workspaces: setup: the writer moved the revision and the journal head: {committed:?}"
        );
        assert!(
            seen.len() >= 2,
            "{workspaces} workspaces: setup: the readers read beside the writer"
        );
        for (revision, head) in &seen {
            let Some(index) = committed.iter().position(|(committed, _)| committed == revision)
            else {
                panic!(
                    "{workspaces} workspaces: a snapshot showed revision {revision}, which no write committed: {committed:?}"
                );
            };
            assert!(
                *head >= committed[index].1,
                "{workspaces} workspaces: a snapshot of revision {revision} has journal head {head}, older than the head {} of that revision",
                committed[index].1
            );
            if let Some((_, next_head)) = committed.get(index + 1)
                && *next_head > committed[index].1
            {
                assert!(
                    head < next_head,
                    "{workspaces} workspaces: a snapshot of revision {revision} has journal head {head}: the head of a later revision ({next_head}), newer than its topology"
                );
            }
        }
    }
}

/// (revision, journal head) pairs.
type Cuts = Vec<(u64, u64)>;

/// One arm of the cut guard: the (revision, journal head) pairs the writer
/// committed, and the pairs two readers saw beside it.
fn cuts_beside_a_writer(mux: &Arc<Mux>) -> (Cuts, Cuts) {
    const WRITES: usize = 40;
    let committed_pair = |mux: &Mux| {
        let registry = mux.workspace_registry.lock().unwrap();
        let revision: String = registry
            .connection
            .get()
            .query_row("SELECT value FROM meta WHERE key = 'resource_revision'", [], |row| {
                row.get(0)
            })
            .unwrap();
        (revision.parse::<u64>().unwrap(), registry.session_journal_head().unwrap())
    };
    let done = Arc::new(AtomicBool::new(false));
    let readers = (0..2)
        .map(|_| {
            let mux = mux.clone();
            let done = done.clone();
            std::thread::spawn(move || {
                let mut seen = Vec::new();
                // At least one read: a short arm can end before this thread starts.
                loop {
                    let (snapshot, head) = public_session_snapshot_with_journal_head(&mux).unwrap();
                    let revision =
                        snapshot["cursor"]["revision"].as_str().unwrap().parse::<u64>().unwrap();
                    seen.push((revision, head));
                    if done.load(Ordering::Relaxed) {
                        break;
                    }
                }
                seen
            })
        })
        .collect::<Vec<_>>();
    let mut committed = vec![committed_pair(mux)];
    for _ in 0..WRITES {
        mux.create_empty_workspace(None, None, None).unwrap();
        committed.push(committed_pair(mux));
    }
    done.store(true, Ordering::Relaxed);
    let seen = readers.into_iter().flat_map(|reader| reader.join().unwrap()).collect::<Vec<_>>();
    (committed, seen)
}

/// One read: (snapshot, cursor revision, journal head, registry commit count).
fn read_cut(mux: &Arc<Mux>) -> (Value, u64, u64, u64) {
    let (snapshot, head) = public_session_snapshot_with_journal_head(mux).unwrap();
    let revision = snapshot["cursor"]["revision"].as_str().unwrap().parse::<u64>().unwrap();
    (snapshot, revision, head, mux.registry_connection.durability_counts().0)
}

/// A WARM cache shows the next commit of each kind: a workspace create, a
/// state store write, a journal writer batch and a metadata write that takes
/// no resource revision. The cache key is the registry writer's commit count
/// (`RegistryConnection::durability_counts`), so the count must move in every
/// commit made after the open path's PRAGMAs: a cache that never invalidates,
/// a key that is the resource revision, or a WAL hook that no longer counts
/// fails here.
#[test]
fn a_warm_snapshot_shows_the_next_commit_of_each_kind() {
    let root = temp_root("fresh");
    let mux = session_at_rest("snapshot-fresh", &root);
    grow_to(&mux, 3);
    read_cut(&mux);
    let (before, revision_0, _, commits_0) = read_cut(&mux);
    let workspaces_0 = before["workspaces"].as_array().unwrap().len();
    let workspace = before["workspaces"][0]["id"].as_str().unwrap().to_string();

    // 1. A workspace create.
    mux.create_empty_workspace(Some("fresh-create".into()), None, None).unwrap();
    let (after, revision_1, _, commits_1) = read_cut(&mux);
    assert!(commits_1 > commits_0, "the commit count did not move on a workspace create");
    assert_eq!(
        after["workspaces"].as_array().unwrap().len(),
        workspaces_0 + 1,
        "a warm snapshot did not show the workspace created after it"
    );
    assert!(revision_1 > revision_0, "a warm snapshot kept the cursor of before the create");

    // 2. A state store write.
    let selectors = mux.local_workspace_selectors(&workspace);
    mux.state_workspace_status(
        &WorkspaceMutation::daemon_local("test"),
        "workspace_status.set",
        None,
        &selectors,
        WorkspaceStatusChange::Set {
            key: "fresh".into(),
            text: "fresh-status-text".into(),
            icon: None,
            color: None,
            meta: Box::default(),
        },
    )
    .unwrap();
    let (after, revision_2, head_2, commits_2) = read_cut(&mux);
    assert!(commits_2 > commits_1, "the commit count did not move on a state store write");
    assert!(
        after["extra"]["state"]["workspace_status"].to_string().contains("fresh-status-text"),
        "a warm snapshot did not show the status written after it: {}",
        after["extra"]["state"]["workspace_status"]
    );
    assert!(revision_2 > revision_1, "a warm snapshot kept the cursor of before the status write");

    // 3. A journal writer batch.
    let id = |prefix: &str, value: u128| format!("{prefix}_{value:032x}");
    mux.journal_local_frontend_event(crate::FrontendJournalEvent::Focus {
        event_id: "event_snapshot_read_fresh".into(),
        frontend_projection_id: FrontendProjectionPublicId::parse(id("projection", 6)).unwrap(),
        generation: "frontend_generation_1".into(),
        target: crate::FrontendFocusTarget::Pane,
        workspace_id: Some(WorkspacePublicId::parse(id("ws", 1)).unwrap()),
        screen_id: Some(ScreenPublicId::parse(id("screen", 2)).unwrap()),
        pane_id: Some(PanePublicId::parse(id("pane", 3)).unwrap()),
        tab_id: Some(TabPublicId::parse(id("tab", 4)).unwrap()),
        content_id: Some(ContentPublicId::Terminal(
            TerminalPublicId::parse(id("term", 5)).unwrap(),
        )),
    })
    .unwrap();
    let (_, revision_3, head_3, commits_3) = read_cut(&mux);
    assert!(commits_3 > commits_2, "the commit count did not move on a journal writer batch");
    assert!(
        head_3 > head_2,
        "a warm snapshot kept journal head {head_2} after a journal writer batch (head {head_3} expected to be newer)"
    );

    // 4. A metadata write: no resource revision, no journal record.
    mux.write_registry_meta(|transaction| {
        crate::state::workspace_status_store::set_status(
            transaction,
            &workspace,
            "fresh-meta",
            "fresh-meta-text",
            None,
            None,
            1,
        )
    })
    .unwrap();
    let (after, revision_4, _, commits_4) = read_cut(&mux);
    drop(mux);
    let _ = std::fs::remove_dir_all(&root);
    assert!(commits_4 > commits_3, "the commit count did not move on a metadata write");
    assert_eq!(revision_4, revision_3, "setup: a metadata write takes no resource revision");
    assert!(
        after["extra"]["state"]["workspace_status"].to_string().contains("fresh-meta-text"),
        "a warm snapshot did not show the metadata row written after it: {}",
        after["extra"]["state"]["workspace_status"]
    );
}

/// A snapshot read that already holds its route tables answers when an
/// in-process terminal is fully closed under it. The durable identity of an
/// in-process runtime is in a table of the mux that the close purges after it
/// releases the state guard; the read failed with "runtime omitted its
/// durable identity", which every client shows as "machine unreachable".
#[test]
fn a_snapshot_read_answers_when_an_in_process_terminal_closes_under_it() {
    // A child that writes nothing.
    let quiet = vec!["/bin/sh".into(), "-c".into(), "IFS= read -r line".into()];
    let options = SurfaceOptions { command: Some(quiet), ..SurfaceOptions::default() };
    let name = format!(
        "snapshot-close-{}-{}",
        std::process::id(),
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
    );
    let mux = Mux::new(name, options);
    mux.new_workspace(Some("kept".into()), Some((80, 24))).unwrap();
    let closed = mux.new_workspace(Some("closed".into()), Some((80, 24))).unwrap();
    assert!(closed.terminal_host_identity().is_none(), "setup: the terminal runs in process");
    let host = mux.resource_terminal_host_identity(&closed).expect("setup: a reserved identity");
    public_session_snapshot(&mux).expect("setup: the snapshot read answers before the close");

    let hook_ran = Arc::new(AtomicBool::new(false));
    let ran = hook_ran.clone();
    let closing = mux.clone();
    crate::resource_api::set_snapshot_after_routes_hook(move || {
        closing.close_terminal(&host.terminal_id, &host.incarnation).unwrap();
        assert!(
            closing.resource_terminal_host_identity(&closed).is_none(),
            "setup: the close purged the identity of the runtime"
        );
        ran.store(true, Ordering::SeqCst);
    });
    let snapshot = public_session_snapshot(&mux);
    assert!(hook_ran.load(Ordering::SeqCst), "setup: the terminal closed under the read");
    let snapshot = snapshot.unwrap_or_else(|error| {
        panic!("the snapshot read failed when a terminal closed under it: {error:?}")
    });
    assert!(snapshot["terminals"].is_array(), "the snapshot read answered: {snapshot}");
    public_session_snapshot(&mux).expect("the next snapshot read answers too");
}

/// Two in-process terminals close under ONE snapshot read, each right after the read took its live surface. The
/// builder of the terminals read the durable identity of a live surface a second time: the first close failed
/// the first pass of the terminals, the second close failed the second pass, and the read failed with "runtime
/// omitted its durable identity", which every client shows as "machine unreachable".
#[test]
fn a_snapshot_read_answers_when_two_in_process_terminals_close_under_it() {
    // A child that writes nothing.
    let quiet = vec!["/bin/sh".into(), "-c".into(), "IFS= read -r line".into()];
    let options = SurfaceOptions { command: Some(quiet), ..SurfaceOptions::default() };
    let name = format!(
        "snapshot-two-closes-{}-{}",
        std::process::id(),
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
    );
    let mux = Mux::new(name, options);
    mux.new_workspace(Some("kept".into()), Some((80, 24))).unwrap();
    let mut closing_under_the_read = Vec::new();
    for workspace in ["first", "second"] {
        let surface = mux.new_workspace(Some(workspace.into()), Some((80, 24))).unwrap();
        let host =
            mux.resource_terminal_host_identity(&surface).expect("setup: a reserved identity");
        closing_under_the_read.push((surface.id, host));
    }
    public_session_snapshot(&mux).expect("setup: the snapshot read answers before the closes");

    let closes = Arc::new(AtomicU64::new(0));
    let (closing, closed) = (mux.clone(), closes.clone());
    let close_it = move |surface: &Surface| {
        let at = closing_under_the_read.iter().position(|(id, _)| *id == surface.id);
        let Some(at) = at else { return };
        let (_, host) = closing_under_the_read.remove(at);
        closing.close_terminal(&host.terminal_id, &host.incarnation).unwrap();
        assert!(
            closing.resource_terminal_host_identity(surface).is_none(),
            "setup: the close purged the identity of the runtime"
        );
        closed.fetch_add(1, Ordering::SeqCst);
    };
    crate::resource_api::set_live_terminal_hook_on_this_thread(Some(Box::new(close_it)));
    let snapshot = public_session_snapshot(&mux);
    crate::resource_api::set_live_terminal_hook_on_this_thread(None);
    assert_eq!(closes.load(Ordering::SeqCst), 2, "setup: both terminals closed under the read");
    let snapshot = snapshot.unwrap_or_else(|error| {
        panic!("the snapshot read failed when two terminals closed under it: {error:?}")
    });
    assert!(snapshot["terminals"].is_array(), "the snapshot read answered: {snapshot}");
    public_session_snapshot(&mux).expect("the next snapshot read answers too");
}

/// The answer of an indeterminate registry commit that arrives late owes a
/// state update (cx-g1fa.3). The old snapshot read settled it, because it
/// pinned the state. A session that only reads snapshots must still settle
/// it: the rows of the late commit are in the snapshot, so its state update
/// and its journal event must not wait for some later mutation.
#[test]
fn a_snapshot_read_settles_the_answer_of_a_late_registry_commit() {
    let root = temp_root("settle");
    let mux = session_at_rest("snapshot-settle", &root);
    public_session_snapshot(&mux).unwrap();
    let (answer, pending) = crate::journal_ingress::PendingRegistryReceipt::for_test();
    let settled = Arc::new(AtomicBool::new(false));
    let settled_by = settled.clone();
    mux.workspace_registry.lock().unwrap().connection.hold_unsettled_for_test(
        pending,
        Some(Box::new(move |_state, _receipt| {
            settled_by.store(true, Ordering::SeqCst);
        })),
    );
    answer
        .send(Ok(crate::workspace_registry::RegistryReceipt::Terminal(
            crate::workspace_registry::TerminalRegistryCommit {
                revision: 1,
                result: json!({}),
                replayed: false,
            },
        )))
        .unwrap();

    public_session_snapshot(&mux).unwrap();
    let settled = settled.load(Ordering::SeqCst);
    drop(mux);
    let _ = std::fs::remove_dir_all(&root);
    assert!(settled, "a snapshot read did not settle the answer of a late registry commit");
}

/// Another thread can hold the list of late answers when a snapshot read
/// starts: a drain of a prepare path (it gets the answers, it does not settle
/// them) or a second reader. The read must still settle the late answer: a
/// busy list does not mean that another thread settles it.
#[test]
fn a_snapshot_read_settles_a_late_answer_while_another_thread_holds_the_list() {
    let root = temp_root("settle-held");
    let mux = session_at_rest("snapshot-settle-held", &root);
    public_session_snapshot(&mux).unwrap();
    let (answer, pending) = crate::journal_ingress::PendingRegistryReceipt::for_test();
    let settled = Arc::new(AtomicBool::new(false));
    let settled_by = settled.clone();
    mux.workspace_registry.lock().unwrap().connection.hold_unsettled_for_test(
        pending,
        Some(Box::new(move |_state, _receipt| {
            settled_by.store(true, Ordering::SeqCst);
        })),
    );
    answer
        .send(Ok(crate::workspace_registry::RegistryReceipt::Terminal(
            crate::workspace_registry::TerminalRegistryCommit {
                revision: 1,
                result: json!({}),
                replayed: false,
            },
        )))
        .unwrap();

    let (answered, answered_receiver) = std::sync::mpsc::channel();
    let reader = mux.registry_connection.with_unsettled_list_held_for_test(|| {
        let reader = {
            let mux = mux.clone();
            std::thread::spawn(move || {
                public_session_snapshot(&mux).unwrap();
                let _ = answered.send(());
            })
        };
        // A read that knows it owes the settlement waits for the list, so it
        // does not answer here. A read that answers here did not settle.
        let _ = answered_receiver.recv_timeout(Duration::from_millis(500));
        reader
    });
    reader.join().unwrap();
    let settled = settled.load(Ordering::SeqCst);
    drop(mux);
    let _ = std::fs::remove_dir_all(&root);
    assert!(
        settled,
        "a snapshot read that started while another thread held the list of late answers did not settle the late answer"
    );
}

/// A mutator that changes a route table and commits in one hold of the
/// pinned state publishes its routes only when its state guard drops, after
/// its COMMIT (a terminal respawn, `mux/terminal_respawn.rs`
/// `install_respawned_runtime`; an adoption at daemon start,
/// `mux/terminal_adoption.rs`). A snapshot read that starts between the
/// COMMIT and the drop must not show the rows of that commit with the routes
/// of before it: a client that starts at that cursor never gets the delta of
/// the commit, so it would keep the size of the runtime that was replaced.
///
/// The mutator here is a model with the same lock structure, built in the
/// test: registry lock, pinned state, replace the catalog runtime of a
/// terminal by one of another size, COMMIT a status row, then drop the guard.
#[cfg(unix)]
#[test]
fn a_snapshot_read_between_a_commit_and_its_route_publish_shows_the_routes_of_the_commit() {
    let root = temp_root("window");
    let mux = session_at_rest("snapshot-window", &root);
    let workspace_key = mux.create_empty_workspace(Some("window".into()), None, None).unwrap().key;
    let host = TerminalHostIdentity {
        terminal_id: format!("00000000000040008000{:012x}", 7),
        incarnation: format!("10000000000040008000{:012x}", 7),
    };
    let placed = mux
        .seed_running_terminal_for_test(&host.terminal_id, &host.incarnation, &workspace_key)
        .unwrap();
    let terminal = mux.surface(placed).unwrap().terminal_public_id().unwrap().clone();
    let size_of = |snapshot: &Value| {
        let shown = snapshot["terminals"]
            .as_array()
            .unwrap()
            .iter()
            .find(|shown| shown["id"].as_str() == Some(terminal.as_str()))
            .unwrap_or_else(|| panic!("setup: the snapshot shows the terminal: {snapshot}"));
        (shown["cols"].as_u64().unwrap(), shown["rows"].as_u64().unwrap())
    };
    let (before, _, _, commits_before) = read_cut(&mux);
    assert_ne!(size_of(&before), (132, 43), "setup: the first runtime has another size");
    let workspace = before["workspaces"][0]["id"].as_str().unwrap().to_string();
    let replacement = Surface::exited_terminal_placeholder_with_terminal_public_id(
        mux.next_surface_id_for_test(),
        SurfaceOptions { cols: 132, rows: 43, ..SurfaceOptions::default() },
        Arc::downgrade(&mux),
        host,
        terminal.clone(),
    )
    .unwrap();

    let (committed, committed_receiver) = sync_channel::<()>(1);
    let (release, release_receiver) = sync_channel::<()>(1);
    let mutator = {
        let mux = mux.clone();
        let terminal = terminal.clone();
        std::thread::spawn(move || {
            let registry = mux.workspace_registry.lock().unwrap();
            let mut state = mux.lock_state_pinned(&registry).unwrap();
            state.remove_catalog_terminal(&terminal);
            state.insert_catalog_terminal(&terminal, &replacement).unwrap();
            {
                let db = registry.connection.get();
                let transaction = db.unchecked_transaction().unwrap();
                crate::state::workspace_status_store::set_status(
                    &transaction,
                    &workspace,
                    "window",
                    "window-commit-text",
                    None,
                    None,
                    1,
                )
                .unwrap();
                transaction.commit().unwrap();
            }
            committed.send(()).unwrap();
            release_receiver.recv().unwrap();
            drop(state);
            drop(registry);
        })
    };
    committed_receiver
        .recv_timeout(Duration::from_secs(20))
        .expect("setup: the mutator committed under the pinned state");

    // `true`: the read answered. `false`: the read started its wait for the mutator. A read that proves the routes
    // of its rows sends `false` first; a read that sends `true` first answered in the window.
    let (step, step_receiver) = std::sync::mpsc::channel::<bool>();
    let reader = {
        let mux = mux.clone();
        std::thread::spawn(move || {
            let waits = step.clone();
            crate::resource_api::set_route_wait_start_hook_on_this_thread(move || {
                let _ = waits.send(false);
            });
            let cut = read_cut(&mux);
            let _ = step.send(true);
            (cut, crate::resource_api::route_waits_on_this_thread())
        })
    };
    let in_window = step_receiver.recv_timeout(Duration::from_secs(20));
    release.send(()).unwrap();
    let in_window =
        in_window.expect("setup: the read answered or started its wait for the mutator");
    mutator.join().unwrap();
    let ((snapshot, _, _, commits), waits) = reader.join().unwrap();
    let size = size_of(&snapshot);
    let status = snapshot["extra"]["state"]["workspace_status"].to_string();
    drop(mux);
    let _ = std::fs::remove_dir_all(&root);

    assert!(commits > commits_before, "setup: the commit of the mutator moved the commit count");
    assert!(
        status.contains("window-commit-text"),
        "setup: the read shows the commit of the mutator: {status}"
    );
    assert_eq!(waits, 1, "the read waited once for the mutator that held the state lock");
    assert_eq!(
        size,
        (132, 43),
        "a snapshot read that started between a commit and the publish of its routes (it answered in the window: {in_window}) shows the rows of the commit with the size of the runtime that the commit replaced"
    );
}

mod route_wait;
#[cfg(unix)]
mod window;
