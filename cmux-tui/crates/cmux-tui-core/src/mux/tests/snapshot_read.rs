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

/// Run `hook` for every statement that a registry connection (the writer's,
/// the read-only one and the snapshot readers' own) compiles; `None` removes
/// it.
fn watch_statements(mux: &Mux, hook: Option<Arc<dyn Fn(&AuthContext<'_>) + Send + Sync>>) {
    let install = |connection: &rusqlite::Connection| match hook.clone() {
        Some(hook) => connection.authorizer(Some(move |context: AuthContext<'_>| {
            hook(&context);
            Authorization::Allow
        })),
        None => connection.authorizer(None::<fn(AuthContext<'_>) -> Authorization>),
    };
    install(&*mux.registry_connection.get()).unwrap();
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
    let registry_before = crate::mux::registry_locks_taken_on_this_thread();
    let state_before = crate::mux::state_locks_taken_on_this_thread();
    reads();
    let state = crate::mux::state_locks_taken_on_this_thread() - state_before;
    let registry = crate::mux::registry_locks_taken_on_this_thread() - registry_before;
    watch_statements(mux, None);
    (registry, state, selects.load(Ordering::Relaxed))
}

/// K snapshot reads with no change between them take the registry lock 0
/// times, the state lock 0 times and run 0 SELECT statements, at 1, 60 and
/// 826 workspaces: the cost of a read does not grow with the session.
#[test]
fn snapshot_reads_with_no_change_take_no_lock_and_run_no_statement() {
    let root = temp_root("counts");
    let mux = session_at_rest("snapshot-counts", &root);
    let mut failures = Vec::new();
    eprintln!(
        "snapshot-read counts: workspaces | {READS} reads with no change: registry takes, state takes, SELECTs | first read after a change: registry takes, state takes, SELECTs"
    );
    for workspaces in [1_usize, 60, 826] {
        grow_to(&mux, workspaces);
        let (changed_registry, changed_state, changed_selects) = cost(&mux, || {
            public_session_snapshot(&mux).unwrap();
        });
        let (registry, state, selects) = cost(&mux, || {
            for _ in 0..READS {
                public_session_snapshot(&mux).unwrap();
            }
        });
        eprintln!(
            "snapshot-read counts: {workspaces} | {registry} {state} {selects} | {changed_registry} {changed_state} {changed_selects}"
        );
        if (registry, state, selects) != (0, 0, 0) {
            failures.push(format!(
                "{workspaces} workspaces: {READS} snapshot reads with no change took the registry lock {registry} times, the state lock {state} times and ran {selects} SELECT statements"
            ));
        }
        if (changed_registry, changed_state) != (0, 0) {
            failures.push(format!(
                "{workspaces} workspaces: the first snapshot read after a change took the registry lock {changed_registry} times and the state lock {changed_state} times"
            ));
        }
    }
    drop(mux);
    let _ = std::fs::remove_dir_all(&root);
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}

/// A split through the real request path answers while a snapshot read is
/// stopped in its row read: the reader holds no lock the split needs.
#[test]
fn a_split_beside_a_stopped_snapshot_read_does_not_wait_for_it() {
    let root = temp_root("split");
    let mux = session_at_rest("snapshot-split", &root);
    grow_to(&mux, 60);
    let created = call(
        &mux,
        "workspace.create",
        json!({"initial_content":"terminal","name":"split-here"}),
        Some("snapshot-split-create"),
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
        &mux,
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
                Some("snapshot-split-split"),
            );
            let _ = answered.send(split);
        })
    };
    let split_answer = answered_receiver.recv_timeout(Duration::from_secs(2));
    release.send(()).unwrap();
    let snapshot = snapshot.join().unwrap();
    split.join().unwrap();
    watch_statements(&mux, None);
    drop(mux);
    let _ = std::fs::remove_dir_all(&root);
    let split_answer =
        split_answer.expect("pane.split waited for the snapshot read that was stopped beside it");
    assert!(split_answer["value"]["pane_id"].is_string(), "the split made a pane: {split_answer}");
    assert!(
        snapshot["workspaces"].is_array() || snapshot["value"]["workspaces"].is_array(),
        "the snapshot read answered: {snapshot}"
    );
}

/// Readers beside a writer: each snapshot is one committed revision. Every
/// workspace create commits its rows and its journal records together, so a
/// snapshot whose cursor is revision R has the journal head that revision R
/// committed: never an older one, never the head of a later revision.
#[test]
fn a_snapshot_read_beside_a_writer_is_one_committed_revision() {
    const WRITES: usize = 40;
    let root = temp_root("cut");
    let mux = session_at_rest("snapshot-cut", &root);
    grow_to(&mux, 60);
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
    let done = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let readers = (0..2)
        .map(|_| {
            let mux = mux.clone();
            let done = done.clone();
            std::thread::spawn(move || {
                let mut seen = Vec::new();
                while !done.load(Ordering::Relaxed) {
                    let (snapshot, head) = public_session_snapshot_with_journal_head(&mux).unwrap();
                    let revision =
                        snapshot["cursor"]["revision"].as_str().unwrap().parse::<u64>().unwrap();
                    seen.push((revision, head));
                }
                seen
            })
        })
        .collect::<Vec<_>>();
    let mut committed = vec![committed_pair(&mux)];
    for _ in 0..WRITES {
        mux.create_empty_workspace(None, None, None).unwrap();
        committed.push(committed_pair(&mux));
    }
    done.store(true, Ordering::Relaxed);
    let seen = readers.into_iter().flat_map(|reader| reader.join().unwrap()).collect::<Vec<_>>();
    drop(mux);
    let _ = std::fs::remove_dir_all(&root);

    assert!(
        committed.last().unwrap().1 > committed[0].1
            && committed.last().unwrap().0 > committed[0].0,
        "setup: the writer moved the revision and the journal head: {committed:?}"
    );
    assert!(seen.len() >= 2, "setup: the readers read beside the writer");
    for (revision, head) in &seen {
        let Some(index) = committed.iter().position(|(committed, _)| committed == revision) else {
            panic!(
                "a snapshot showed revision {revision}, which no write committed: {committed:?}"
            );
        };
        assert!(
            *head >= committed[index].1,
            "a snapshot of revision {revision} has journal head {head}, older than the head {} of that revision",
            committed[index].1
        );
        if let Some((_, next_head)) = committed.get(index + 1)
            && *next_head > committed[index].1
        {
            assert!(
                head < next_head,
                "a snapshot of revision {revision} has journal head {head}: the head of a later revision ({next_head}), newer than its topology"
            );
        }
    }
}
