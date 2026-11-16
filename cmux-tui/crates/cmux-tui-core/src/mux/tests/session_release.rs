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

fn open_owner(root: &Path, session: &str) -> Arc<Mux> {
    let options = SurfaceOptions {
        terminal_host_root: Some(crate::terminal_host_runtime::terminal_host_root(root, session)),
        ..SurfaceOptions::default()
    };
    Mux::open_persistent(session, options, root).unwrap()
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
