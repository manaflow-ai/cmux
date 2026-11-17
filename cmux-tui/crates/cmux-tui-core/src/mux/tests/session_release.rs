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
/// What an owner writes in its record when it keeps the session until its
/// exit.
const KEPT_RELEASE: &str = "kept until the exit";
/// What a next owner says when it is refused after its wait for such an
/// owner.
const KEPT_REASON: &str = "keeps the session until its exit";
/// The longest wait for the thread of a next owner to say something. A
/// bound for a thread that never comes, not a time the test measures.
const NEXT_OWNER_THREAD_WAIT: Duration = Duration::from_secs(60);
/// A bound of the next owner's wait that no test reaches: an event of the
/// test ends that wait, or the open must not wait at all.
const LONG_OWNER_WAIT: Duration = Duration::from_secs(60);
/// A bound of the next owner's wait for an owner that never gives the
/// session up: the open is refused when it ends.
const SHORT_OWNER_WAIT: Duration = Duration::from_millis(50);

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
fn start_line(owner: &Mux, folder: &Path) -> Value {
    let timings = owner.take_startup_timings().expect("a start from a store has its laps");
    owner.record_startup_timings(&timings);
    let lines =
        std::fs::read_to_string(folder.join(crate::startup_timings::STARTUP_TIMINGS_FILE)).unwrap();
    serde_json::from_str(lines.lines().next_back().expect("the owner wrote its start line"))
        .unwrap()
}

/// The keys of a start line, for a failure text (the line itself is long).
fn keys(line: &Value) -> Vec<&str> {
    line.as_object().map(|fields| fields.keys().map(String::as_str).collect()).unwrap_or_default()
}

/// An owner whose journal writer is at the commit of an event that it
/// admitted, and stays there: the owner's own wait for the writer's end ran
/// out, as it does in a shutdown with a slow disk.
struct HeldWriter {
    mux: Arc<Mux>,
    resume: SyncSender<()>,
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
        // The step of a shutdown that waits for the writer's end.
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

/// Writes, in the session's folder, the record of an owner that keeps the
/// session until its exit, as that owner writes it.
fn write_kept_record(folder: &Path) {
    let record = serde_json::json!({
        "at_ms": 1_700_000_000_000_u64,
        "pid": std::process::id(),
        "release": KEPT_RELEASE,
        "alive": ["session journal writer"],
        "waited_ms": 2000,
    });
    std::fs::write(folder.join(RELEASE_RECORD_FILE), record.to_string()).unwrap();
}

/// Sets, for each later open on this thread, the longest wait for an owner
/// that keeps the session. The flag that it returns says if an open waited.
fn set_owner_wait(bound: Duration) -> Arc<AtomicBool> {
    let waited = Arc::new(AtomicBool::new(false));
    let flag = Arc::clone(&waited);
    crate::workspace_registry::terminal_state_end::set_kept_owner_wait_for_test(
        bound,
        Some(Box::new(move || flag.store(true, Ordering::Release))),
    );
    waited
}

/// An open of a session that must not pass: the text of its refusal.
fn refusal(root: &Path, session: &str) -> String {
    match try_open_owner(root, session) {
        Ok(next) => {
            drop(next);
            "the open passed".to_owned()
        }
        Err(error) => format!("{error:#}"),
    }
}

/// What the thread of a next owner says to its test.
enum NextOwner {
    /// Its open waits for the owner before it.
    Waiting,
    /// Its open ended.
    Done(Result<Arc<Mux>, String>),
}

/// Opens the session as its next owner on a thread of its own, with `bound`
/// as the longest wait for an owner that keeps the session.
fn open_next_owner_on_a_thread(
    root: &Path,
    session: &str,
    bound: Duration,
) -> (Receiver<NextOwner>, std::thread::JoinHandle<()>) {
    let (events, next_owner) = mpsc::channel();
    let (root, session) = (root.to_path_buf(), session.to_owned());
    let thread = std::thread::spawn(move || {
        let waiting = events.clone();
        crate::workspace_registry::terminal_state_end::set_kept_owner_wait_for_test(
            bound,
            Some(Box::new(move || {
                let _ = waiting.send(NextOwner::Waiting);
            })),
        );
        let opened = try_open_owner(&root, &session).map_err(|error| format!("{error:#}"));
        let _ = events.send(NextOwner::Done(opened));
    });
    (next_owner, thread)
}

/// Creates a conversation in the owner's conversation store, which the owner
/// opens at its first use.
fn create_conversation(owner: &Mux, key: &str) -> Result<(), String> {
    let people: Vec<cmux_conversation::Participant> = serde_json::from_value(serde_json::json!([
        {"id": "user_local", "kind": "human", "display_name": "Me"},
        {"id": "agent_chief", "kind": "agent", "display_name": "Chief"}
    ]))
    .unwrap();
    owner
        .with_conversations(|store| store.create(key, "user_local", "Chief", &people))
        .map(|_| ())
        .map_err(|error| format!("{error:#}"))
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
    let settle_panicked = mux.exit_settle_run_panicked_for_test();
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
    assert!(
        !settle_panicked,
        "the settle thread of an owner that released its session ended with a panic at its \
         write, which the store refused"
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
    // A panic of the write would leave the lock of the owner's registry poisoned.
    let writer_panicked = mux.workspace_registry.lock().is_err();
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
    assert!(
        !writer_panicked,
        "the write of an owner that released its session ended with a panic, and not with the \
         store's refusal"
    );
}

/// The journal writer admitted a commit, and the owner's wait for the
/// writer's end ran out. The owner then releases the session. The next owner
/// is refused because the session still has an owner: an owner keeps its
/// session while its writer lives (decision of 2026-11-16). An open that
/// passes then is a failure, also when that commit does not land in the
/// store that the open got.
#[test]
fn a_commit_admitted_before_the_release_does_not_land_under_the_next_owner() {
    let root = std::env::temp_dir()
        .join(format!("cmux-session-release-commit-{}", crate::workspace_registry::new_uuid_v4()));
    let session = "release-commit";
    let held = HeldWriter::open(&root, session);
    held.mux.release_ownership(&root.join("control.sock"));
    // The owner never gives the session up here: a small bound for the wait
    // of the open that it refuses.
    let _ = set_owner_wait(SHORT_OWNER_WAIT);
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
    panic!(
        "the next owner got the session while the journal writer of the owner before it was at \
         an admitted commit: that owner must keep the session until its writer ended (the \
         store did not change: ((revision, tabs), journal head) {before:?})"
    );
}

/// An owner that keeps its session says what of it still lives. The next
/// owner's open waits for that owner, has the session when that owner's
/// process ended, and says in its start line what that owner wrote in its
/// record.
#[test]
fn an_owner_that_keeps_its_session_says_what_of_it_still_lives() {
    let root = std::env::temp_dir()
        .join(format!("cmux-session-release-names-{}", crate::workspace_registry::new_uuid_v4()));
    let session = "release-names";
    let held = HeldWriter::open(&root, session);
    let folder = session_folder(&held.mux);
    let release = held.mux.release_ownership(&root.join("control.sock"));
    // The writer ends, and the owner's value goes: the session stays kept.
    drop(held.finish());
    // A bound that the test does not reach: the end of the kept owner's
    // process ends the wait of the next owner's open.
    let (next_owner, thread) = open_next_owner_on_a_thread(&root, session, LONG_OWNER_WAIT);
    let first = next_owner
        .recv_timeout(NEXT_OWNER_THREAD_WAIT)
        .expect("the next owner's thread said nothing");
    // What the end of that owner's process does.
    crate::workspace_registry::owner_release::end_kept_owner_for_test(&folder);
    let (waited, opened) = match first {
        NextOwner::Done(opened) => (false, opened),
        NextOwner::Waiting => match next_owner.recv_timeout(NEXT_OWNER_THREAD_WAIT) {
            Ok(NextOwner::Done(opened)) => (true, opened),
            Ok(NextOwner::Waiting) => {
                (true, Err("its open said two times that it waits".to_owned()))
            }
            Err(error) => (true, Err(format!("its open did not end: {error}"))),
        },
    };
    let (outcome, record) = match &opened {
        Ok(next) => (
            "it has the session".to_owned(),
            start_line(next, &folder)
                .get(RELEASE_RECORD_KEY)
                .map(ToString::to_string)
                .unwrap_or_default(),
        ),
        Err(error) => (format!("refused: {error}"), String::new()),
    };
    if !outcome.contains("its open did not end") {
        let _ = thread.join();
    }
    drop(opened);
    let _ = std::fs::remove_dir_all(&root);
    let names = match &release {
        lifecycle::OwnershipRelease::KeptUntilExit { alive, .. } => alive.clone(),
        lifecycle::OwnershipRelease::Released => Vec::new(),
    };
    assert!(
        names == ["session journal writer"],
        "an owner whose journal writer was at an admitted commit did not say that it keeps the \
         session because of that writer: its release: {release:?}"
    );
    assert!(
        waited && outcome == "it has the session",
        "a kept session did not stay kept until the end of its owner's process, or it stayed \
         kept after it: the next owner's open waited: {waited}; the open's end: {outcome}"
    );
    assert!(
        record.contains(KEPT_RELEASE) && record.contains("session journal writer"),
        "the next owner's start line does not say what the owner before it wrote when it kept \
         the session: field `{RELEASE_RECORD_KEY}`: {record:?}"
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
    // The owner never gives the session up here: a small bound for the wait
    // of the open that it refuses.
    let _ = set_owner_wait(SHORT_OWNER_WAIT);
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
    // The writer's thread ends after its commit. The test waits for that
    // end here, so the bound of the release does not decide its result.
    let writer_ended = mux.journal_ingress.writer_ended_by(Instant::now() + WRITER_THREAD_WAIT);
    assert!(writer_ended, "setup: the journal writer did not end after its commit");
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

/// An owner said in its record that it keeps the session until its exit. The
/// next owner's open waits for it, and it has the session when that owner
/// gives it up.
#[test]
fn the_next_owner_waits_for_an_owner_that_keeps_the_session_until_its_exit() {
    let root = std::env::temp_dir()
        .join(format!("cmux-session-release-wait-{}", crate::workspace_registry::new_uuid_v4()));
    let session = "release-wait";
    let old = open_owner(&root, session);
    write_kept_record(&session_folder(&old));
    let (next_owner, thread) = open_next_owner_on_a_thread(&root, session, LONG_OWNER_WAIT);
    let first = next_owner
        .recv_timeout(NEXT_OWNER_THREAD_WAIT)
        .expect("the next owner's thread said nothing");
    // The owner before gives the session up here: while the next owner waits
    // for it or, with no wait, after that owner's open ended.
    old.shutdown();
    old.release_ownership(&root.join("control.sock"));
    drop(old);
    let (waited, opened) = match first {
        NextOwner::Done(opened) => (false, opened),
        NextOwner::Waiting => match next_owner.recv_timeout(NEXT_OWNER_THREAD_WAIT) {
            Ok(NextOwner::Done(opened)) => (true, opened),
            Ok(NextOwner::Waiting) => {
                (true, Err("its open said two times that it waits".to_owned()))
            }
            Err(error) => (true, Err(format!("its open did not end: {error}"))),
        },
    };
    let outcome = match &opened {
        Ok(_) => "it has the session".to_owned(),
        Err(error) => format!("refused: {error}"),
    };
    if !outcome.contains("its open did not end") {
        let _ = thread.join();
    }
    drop(opened);
    let _ = std::fs::remove_dir_all(&root);
    assert!(
        waited && outcome == "it has the session",
        "the next owner did not get the session of an owner that said that it keeps it until \
         its exit, and that then gave it up: the open waited: {waited}; the open's end: {outcome}"
    );
}

/// The owner before keeps the session and does not end. The next owner's
/// open waits for its bound, and then it is refused with the reason.
#[test]
fn the_next_owner_says_why_when_the_kept_session_stays_kept_past_its_wait() {
    let root = std::env::temp_dir()
        .join(format!("cmux-session-release-bound-{}", crate::workspace_registry::new_uuid_v4()));
    let session = "release-bound";
    let old = open_owner(&root, session);
    write_kept_record(&session_folder(&old));
    let waited = set_owner_wait(SHORT_OWNER_WAIT);
    let refused = refusal(&root, session);
    let waited = waited.load(Ordering::Acquire);
    drop(old);
    let _ = std::fs::remove_dir_all(&root);
    assert!(
        waited
            && refused.contains("already owned by another daemon")
            && refused.contains(KEPT_REASON),
        "the next owner's refusal does not say that the owner before it keeps the session: the \
         open waited: {waited}; the refusal: {refused}"
    );
}

/// With no record of the owner before, the open of a session that has an
/// owner is refused at once: the wait is only for an owner that said that it
/// keeps the session.
#[test]
fn the_next_owner_does_not_wait_when_no_record_says_that_the_session_is_kept() {
    let root = std::env::temp_dir()
        .join(format!("cmux-session-release-owned-{}", crate::workspace_registry::new_uuid_v4()));
    let session = "release-owned";
    let old = open_owner(&root, session);
    let waited = set_owner_wait(LONG_OWNER_WAIT);
    let refused = refusal(&root, session);
    let waited = waited.load(Ordering::Acquire);
    drop(old);
    let _ = std::fs::remove_dir_all(&root);
    assert!(
        !waited && refused.contains("already owned by another daemon"),
        "the open of a session that has a healthy owner was not refused at once: the open \
         waited: {waited}; the refusal: {refused}"
    );
}

/// A next owner that has the session reads the record of the owner before it
/// into its start line and removes the file. So a later open, which that
/// healthy owner refuses, does not wait.
#[test]
fn the_next_owner_removes_the_record_that_it_read_into_its_start_line() {
    let root = std::env::temp_dir()
        .join(format!("cmux-session-release-read-{}", crate::workspace_registry::new_uuid_v4()));
    let session = "release-read";
    let old = open_owner(&root, session);
    let folder = session_folder(&old);
    old.shutdown();
    old.release_ownership(&root.join("control.sock"));
    drop(old);
    write_kept_record(&folder);

    let waited = set_owner_wait(LONG_OWNER_WAIT);
    let next = match try_open_owner(&root, session) {
        Ok(next) => next,
        Err(error) => {
            let _ = std::fs::remove_dir_all(&root);
            panic!("the record of the owner before stopped the next owner's start: {error:#}");
        }
    };
    let line = start_line(&next, &folder);
    let record_stays = folder.join(RELEASE_RECORD_FILE).exists();
    let later = refusal(&root, session);
    let waited = waited.load(Ordering::Acquire);
    drop(next);
    let _ = std::fs::remove_dir_all(&root);
    let record = line.get(RELEASE_RECORD_KEY).map(ToString::to_string).unwrap_or_default();
    assert!(
        record.contains(KEPT_RELEASE)
            && !record_stays
            && !waited
            && later.contains("already owned by another daemon"),
        "the next owner did not take the record of the owner before it out of the session's \
         folder: field `{RELEASE_RECORD_KEY}`: {record:?}; the record file is still there: \
         {record_stays}; an open waited: {waited}; a later open: {later}"
    );
}

/// The conversations of a session are a store of their own in the session's
/// folder. An owner that had it open at its release cannot write it after
/// the release.
#[test]
fn an_owner_that_released_its_session_cannot_write_its_conversation_store() {
    let root = std::env::temp_dir()
        .join(format!("cmux-session-release-talk-{}", crate::workspace_registry::new_uuid_v4()));
    let session = "release-talk";
    let mux = open_owner(&root, session);
    let first = create_conversation(&mux, "release-talk-first");
    mux.shutdown();
    mux.release_ownership(&root.join("control.sock"));
    let late = create_conversation(&mux, "release-talk-late");
    drop(mux);
    let _ = std::fs::remove_dir_all(&root);
    assert!(first.is_ok(), "setup: the owner writes its conversation store: {first:?}");
    assert!(
        late.is_err(),
        "an owner that released its session wrote its conversation store, which the next owner \
         has: its write: {late:?}"
    );
}

/// An owner opens that store at its first use. A first use after the release
/// writes nothing either.
#[test]
fn a_store_that_an_owner_opens_after_its_release_takes_no_write() {
    let root = std::env::temp_dir()
        .join(format!("cmux-session-release-open-{}", crate::workspace_registry::new_uuid_v4()));
    let session = "release-open";
    let mux = open_owner(&root, session);
    mux.shutdown();
    mux.release_ownership(&root.join("control.sock"));
    let late = create_conversation(&mux, "release-open-late");
    drop(mux);
    let _ = std::fs::remove_dir_all(&root);
    assert!(
        late.is_err(),
        "an owner that released its session opened its conversation store after the release \
         and wrote it: its write: {late:?}"
    );
}

/// The record file is read with a bound. A file with that name that is
/// longer than the bound is not taken as the word of the owner before: the
/// next owner starts, and its start line says that the record cannot be
/// read.
#[test]
fn a_record_file_past_the_read_bound_does_not_go_into_the_next_owners_start_line() {
    let root = std::env::temp_dir()
        .join(format!("cmux-session-release-long-{}", crate::workspace_registry::new_uuid_v4()));
    let session = "release-long";
    let mux = open_owner(&root, session);
    let folder = session_folder(&mux);
    mux.shutdown();
    mux.release_ownership(&root.join("control.sock"));
    drop(mux);
    // A record in the right form, 128 KiB long.
    let long = serde_json::json!({"release": "released", "alive": ["x".repeat(128 * 1024)]});
    std::fs::write(folder.join(RELEASE_RECORD_FILE), long.to_string()).unwrap();

    let next = open_owner(&root, session);
    let line = start_line(&next, &folder);
    drop(next);
    let _ = std::fs::remove_dir_all(&root);
    let record = line.get(RELEASE_RECORD_KEY).map(ToString::to_string).unwrap_or_default();
    assert!(
        record.contains("unreadable") && record.len() < 1024,
        "the next owner read a record file of 128 KiB whole into its start line: field \
         `{RELEASE_RECORD_KEY}` has {} bytes; the line's keys: {:?}",
        record.len(),
        keys(&line)
    );
}
