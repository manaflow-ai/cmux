//! The store of a session after its owner released it: from the moment the
//! next owner has the store, nothing of the owner before it changes it.

use std::sync::mpsc;
use std::time::Duration;

use super::*;
use crate::session_shutdown::SESSION_SHUTDOWN_LEAD_MS as LEAD;
use crate::terminal_host_protocol::{TerminalExit, TerminalExitOutcome};

const TERMINAL: &str = "0000000000004000800000000000007a";
const INCARNATION: &str = "1000000000004000800000000000007a";
/// The longest wait for the settle thread to reach its detach. A bound for a
/// thread that never comes, not a time the test measures.
const SETTLE_THREAD_WAIT: Duration = Duration::from_secs(60);

/// The longest wait for the journal writer to reach its commit. A bound for a
/// thread that never comes, not a time the test measures.
const WRITER_THREAD_WAIT: Duration = Duration::from_secs(60);
/// The file, in the session's folder, in which an owner says how its release
/// went when a wait of it ran out.
const RELEASE_RECORD_FILE: &str = "previous-owner-release.json";
/// The key of that record in the start line of the next owner.
const RELEASE_RECORD_KEY: &str = "previous_owner_release";
/// The key of the event whose commit the journal writer is held at.
const WRITER_EVENT: &str = "release_writer_1";

fn try_open_owner(root: &Path, session: &str) -> anyhow::Result<Arc<Mux>> {
    let options = SurfaceOptions {
        terminal_host_root: Some(crate::terminal_host_runtime::terminal_host_root(root, session)),
        ..SurfaceOptions::default()
    };
    Mux::open_persistent(session, options, root)
}

fn open_owner(root: &Path, session: &str) -> Arc<Mux> {
    try_open_owner(root, session).unwrap()
}

/// The folder of the owner's session: its store, its lock files, its start
/// lines.
fn session_folder(owner: &Mux) -> std::path::PathBuf {
    let store = owner.workspace_registry.lock().unwrap().session_journal_database_path();
    store.as_deref().and_then(Path::parent).expect("a session on disk has its folder").to_path_buf()
}

/// The line that `owner` writes for its start, read back from the file of the
/// session's start lines.
fn start_line(owner: &Mux, folder: &Path) -> serde_json::Value {
    let timings = owner.take_startup_timings().expect("a start from a store has its laps");
    owner.record_startup_timings(&timings);
    let lines =
        std::fs::read_to_string(folder.join(crate::startup_timings::STARTUP_TIMINGS_FILE)).unwrap();
    serde_json::from_str(lines.lines().next_back().expect("the owner wrote its start line"))
        .unwrap()
}

/// The keys of a start line, for a failure text (the line itself is long).
fn keys(line: &serde_json::Value) -> Vec<&str> {
    line.as_object().map(|fields| fields.keys().map(String::as_str).collect()).unwrap_or_default()
}

/// An owner whose journal writer is at the commit of an event that it
/// admitted, and stays there: the owner's own wait for the writer's end ran
/// out, as it does in a shutdown with a slow disk.
struct HeldWriter {
    mux: Arc<Mux>,
    resume: mpsc::SyncSender<()>,
    producer: std::thread::JoinHandle<()>,
}

impl HeldWriter {
    fn open(root: &Path, session: &str) -> Self {
        let mux = open_owner(root, session);
        let (reached, at_the_commit) = mpsc::sync_channel(1);
        let (resume, held) = mpsc::sync_channel(1);
        mux.install_journal_after_commit_admission_for_test(reached, held);
        let ingress = crate::agent_hook_journal_ingress(
            "codex",
            "SubagentStop",
            None,
            serde_json::json!({
                "session_id":"release-writer-root",
                "root_session_id":"release-writer-root",
                "parent_session_id":"release-writer-root",
                "child_agent_id":"release-writer-child",
                "message":"release-writer-marker",
            }),
        )
        .unwrap();
        let producer_mux = Arc::clone(&mux);
        let producer = std::thread::spawn(move || {
            // The event's result goes to its producer; the tests read the
            // store of the next owner instead.
            let _ = producer_mux.append_journal_ingress(
                &ingress,
                "client_release_writer",
                WRITER_EVENT,
            );
        });
        at_the_commit
            .recv_timeout(WRITER_THREAD_WAIT)
            .expect("the journal writer did not reach its commit");
        // The step of a shutdown that waits for the writer's end. Limit: the
        // whole shutdown with a held writer: NOT RUN; which other shutdown
        // steps wait for the writer: NOT READ.
        let joined = mux.journal_ingress.close_and_join();
        assert!(
            joined.is_err(),
            "setup: the owner's wait for its journal writer ran out, with the writer at its commit"
        );
        Self { mux, resume, producer }
    }

    /// Lets the writer commit. Returns after that commit ended and after the
    /// producer's thread ended.
    fn finish(self) -> Arc<Mux> {
        let Self { mux, resume, producer } = self;
        let _ = resume.send(());
        drop(resume);
        // The writer has the store's connection from before its hold to
        // after its commit: this waits for the end of that commit.
        drop(mux.registry_connection.get());
        let _ = producer.join();
        mux
    }
}

/// What an owner reads of its store: the resource revision and the number
/// of tabs.
fn store_state(registry: &WorkspaceRegistry) -> (u64, usize) {
    (
        registry.resource_revision().unwrap(),
        registry.resource_topology_snapshot().unwrap().tabs.len(),
    )
}

/// A write that changes no resource, at `expected` as the store's revision.
fn write_at(registry: &mut WorkspaceRegistry, id: &str, expected: u64) -> Result<u64, String> {
    registry
        .commit_resource_patch(
            &WorkspaceMutation::daemon(id, "test").unwrap(),
            "test.store.write",
            &serde_json::json!({"operation": "test.store.write", "write": id}),
            None,
            Some(expected),
            &ResourcePatch { changes: Vec::new() },
            &serde_json::json!({}),
            &serde_json::json!([]),
        )
        .map(|commit| commit.revision)
        .map_err(|error| format!("{error:#}"))
}

/// A signal ends a shell; its detach waits out the shutdown lead on the
/// settle thread. That thread read the owner's shutdown flag and is about to
/// detach when the owner shuts down and releases the session. The next owner
/// then has the store: the detach of the owner before it must not change it.
/// An owner that keeps the session until its settle run ended refuses the
/// next owner's open instead, and the store has one owner at each moment.
#[test]
fn the_next_owner_keeps_its_store_when_a_settle_ran_at_the_release() {
    let root = std::env::temp_dir()
        .join(format!("cmux-session-release-settle-{}", crate::workspace_registry::new_uuid_v4()));
    let session = "release-settle";
    let mux = open_owner(&root, session);
    // One millisecond before the lead ends: the settle thread, which the
    // owner starts at the exit below, waits until the clock moves.
    let base = crate::session_shutdown::unix_now_ms() - 60_000;
    mux.set_session_clock_now_for_test(base + LEAD);
    let workspace = mux.create_empty_workspace(None, None, None).unwrap();
    let surface = mux
        .seed_running_terminal_with_on_exit_for_test(
            TERMINAL,
            INCARNATION,
            &workspace.key,
            TerminalOnExit::Close,
        )
        .unwrap();
    let (reached, at_the_detach) = mpsc::sync_channel(1);
    let (resume, held) = mpsc::channel();
    mux.hold_next_exit_settle_for_test(reached, held);
    mux.surface(surface).unwrap().record_process_end_for_test(TerminalExit {
        outcome: TerminalExitOutcome::Signal { signal: libc::SIGHUP, core_dumped: false },
        exited_at_ms: base,
    });
    mux.surface_exited(surface);
    // The lead ended and no shutdown began in it: a real end. The settle
    // thread goes to its detach, where the seam holds it.
    mux.set_session_clock_now_for_test(base + 10_000);
    at_the_detach
        .recv_timeout(SETTLE_THREAD_WAIT)
        .expect("the settle thread did not reach its detach");

    mux.shutdown();
    mux.release_ownership(&root.join("control.sock"));
    let mut next = match WorkspaceRegistry::open(&root, session) {
        Ok(next) => next,
        Err(error) => {
            let refused = format!("{error:#}");
            drop(resume);
            // Returns after the held settle run: both take the run lock.
            mux.run_due_exit_settles_for_test();
            drop(mux);
            let _ = std::fs::remove_dir_all(&root);
            assert!(
                refused.contains("already owned by another daemon"),
                "the next owner's open failed, and not because the session has an owner: {refused}"
            );
            return;
        }
    };
    let before = store_state(&next);
    drop(resume);
    // Returns after the held settle run: both take the run lock.
    mux.run_due_exit_settles_for_test();
    let after = store_state(&next);
    let write = write_at(&mut next, "next-owner-write", before.0);
    drop(next);
    drop(mux);
    let _ = std::fs::remove_dir_all(&root);
    assert!(
        before == after && write.is_ok(),
        "an owner that released its session changed the store that the next owner has: \
         (revision, tabs) before {before:?}, after {after:?}; the next owner's write at \
         revision {}: {write:?}",
        before.0
    );
}

/// After the release, a write of the owner before fails, and it says so: the
/// store that the next owner has stays as that owner read it.
#[test]
fn an_owner_that_released_its_session_cannot_write_the_store() {
    let root = std::env::temp_dir()
        .join(format!("cmux-session-release-write-{}", crate::workspace_registry::new_uuid_v4()));
    let session = "release-write";
    let mux = open_owner(&root, session);
    mux.create_empty_workspace(None, None, None).unwrap();
    mux.shutdown();
    mux.release_ownership(&root.join("control.sock"));
    let mut next = WorkspaceRegistry::open(&root, session)
        .expect("the session is free for the next owner after the release");
    let before = store_state(&next);
    let late = write_at(&mut mux.workspace_registry.lock().unwrap(), "late-write", before.0);
    let after = store_state(&next);
    let write = write_at(&mut next, "next-owner-write", before.0);
    drop(next);
    drop(mux);
    let _ = std::fs::remove_dir_all(&root);
    assert!(
        late.is_err() && before == after && write.is_ok(),
        "an owner that released its session wrote the store that the next owner has: its \
         write: {late:?}; (revision, tabs) before {before:?}, after {after:?}; the next \
         owner's write at revision {}: {write:?}",
        before.0
    );
}

/// The journal writer admitted a commit, and the owner's wait for the
/// writer's end ran out. The owner then releases the session. The next owner
/// either is refused because the session still has an owner, or it has a
/// store in which that commit does not land.
#[test]
fn a_commit_admitted_before_the_release_does_not_land_under_the_next_owner() {
    let root = std::env::temp_dir()
        .join(format!("cmux-session-release-commit-{}", crate::workspace_registry::new_uuid_v4()));
    let session = "release-commit";
    let held = HeldWriter::open(&root, session);
    held.mux.release_ownership(&root.join("control.sock"));
    let next = match WorkspaceRegistry::open(&root, session) {
        Ok(next) => next,
        Err(error) => {
            let refused = format!("{error:#}");
            drop(held.finish());
            let _ = std::fs::remove_dir_all(&root);
            assert!(
                refused.contains("already owned by another daemon"),
                "the next owner's open failed, and not because the session has an owner: {refused}"
            );
            return;
        }
    };
    let before = (store_state(&next), next.session_journal_head().unwrap());
    let mux = held.finish();
    let after = (store_state(&next), next.session_journal_head().unwrap());
    drop(next);
    drop(mux);
    let _ = std::fs::remove_dir_all(&root);
    assert!(
        before == after,
        "a commit that the owner before had admitted at its release landed in the store that \
         the next owner has: ((revision, tabs), journal head) before {before:?}, after {after:?}"
    );
}

/// The same owner, and its journal writer commits after the owner released
/// the session and before the next owner opens it. The next owner either is
/// refused because the session still has an owner, or its store does not
/// hold that commit.
#[test]
fn the_next_owner_has_no_commit_that_the_owner_before_made_after_its_release() {
    let root = std::env::temp_dir()
        .join(format!("cmux-session-release-late-{}", crate::workspace_registry::new_uuid_v4()));
    let session = "release-late";
    let held = HeldWriter::open(&root, session);
    held.mux.release_ownership(&root.join("control.sock"));
    // The writer's commit ends here, after the release.
    let mux = held.finish();
    let next = match WorkspaceRegistry::open(&root, session) {
        Ok(next) => next,
        Err(error) => {
            let refused = format!("{error:#}");
            drop(mux);
            let _ = std::fs::remove_dir_all(&root);
            assert!(
                refused.contains("already owned by another daemon"),
                "the next owner's open failed, and not because the session has an owner: {refused}"
            );
            return;
        }
    };
    let head = next.session_journal_head().unwrap();
    let landed = next
        .session_journal_after(0, 1024)
        .unwrap()
        .records
        .iter()
        .any(|record| record.correlation_id.as_deref() == Some(WRITER_EVENT));
    drop(next);
    drop(mux);
    let _ = std::fs::remove_dir_all(&root);
    assert!(
        !landed,
        "the owner before committed after it released the session: the store that the next \
         owner has holds that commit (event `{WRITER_EVENT}`, journal head {head})"
    );
}

/// The owner's wait for its journal writer ran out, and the writer ended
/// after it. The stderr of a daemon is often lost, so the next owner says it
/// in its start line: a file holds the text of that wait.
#[test]
fn the_next_owner_says_in_its_start_line_that_the_writer_before_it_ended_late() {
    let root = std::env::temp_dir()
        .join(format!("cmux-session-release-record-{}", crate::workspace_registry::new_uuid_v4()));
    let session = "release-record";
    let held = HeldWriter::open(&root, session);
    let folder = session_folder(&held.mux);
    let mux = held.finish();
    mux.shutdown();
    mux.release_ownership(&root.join("control.sock"));
    drop(mux);

    let next = open_owner(&root, session);
    let line = start_line(&next, &folder);
    drop(next);
    let _ = std::fs::remove_dir_all(&root);
    let record = line.get(RELEASE_RECORD_KEY).map(ToString::to_string).unwrap_or_default();
    assert!(
        record.contains("session journal writer did not stop within"),
        "the next owner's start line does not say that the journal writer of the owner before \
         it ended late: field `{RELEASE_RECORD_KEY}`: {record:?}; the line's keys: {:?}",
        keys(&line)
    );
}

/// An owner can end while it writes its record. A record file that is cut in
/// the middle does not stop the next owner's start, and that owner says in
/// its start line that there was one.
#[test]
fn a_record_file_that_is_cut_in_the_middle_does_not_stop_the_next_owners_start() {
    let root = std::env::temp_dir()
        .join(format!("cmux-session-release-cut-{}", crate::workspace_registry::new_uuid_v4()));
    let session = "release-cut";
    let mux = open_owner(&root, session);
    let folder = session_folder(&mux);
    mux.shutdown();
    mux.release_ownership(&root.join("control.sock"));
    drop(mux);
    std::fs::write(folder.join(RELEASE_RECORD_FILE), br#"{"at_ms":1700000000000,"rele"#).unwrap();

    let next = match try_open_owner(&root, session) {
        Ok(next) => next,
        Err(error) => {
            let _ = std::fs::remove_dir_all(&root);
            panic!(
                "a record file that is cut in the middle stopped the next owner's start: {error:#}"
            );
        }
    };
    let line = start_line(&next, &folder);
    drop(next);
    let _ = std::fs::remove_dir_all(&root);
    assert!(
        line.get(RELEASE_RECORD_KEY).is_some_and(|record| !record.is_null()),
        "the next owner's start line does not say that the owner before it left a record that \
         is cut: no field `{RELEASE_RECORD_KEY}`; the line's keys: {:?}",
        keys(&line)
    );
}
