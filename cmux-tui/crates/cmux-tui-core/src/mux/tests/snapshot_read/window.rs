//! The window between a COMMIT and the publish of its routes, on the two real mutators.
//!
//! A terminal respawn (`mux/terminal_respawn.rs` `install_respawned_runtime`) and a terminal adoption at daemon
//! start (`mux/terminal_adoption.rs` `finish_terminal_adoption`) put a new runtime in the tabs and COMMIT the
//! terminal as running in one hold of the pinned state. The routes of that runtime are published when the state
//! guard drops, after the COMMIT. A snapshot read between the two has the row of the commit (running) and the
//! routes of before it (no runtime): it shows the terminal running with an empty title, 80x24, no directory and no
//! stream revision. A client that starts at that cursor never gets the delta of the commit.
//!
//! These tests run the real functions. A test hook stops the mutator after its COMMIT and before the drop of its
//! state guard (`mux/test_hooks.rs` `set_committed_before_route_publish_hook`). What a unit test cannot do is
//! launch or connect a terminal host process: the new runtime is a hosted surface on a fake host connection
//! (`input_ack_surface_fixture`), made the way the launch (`Surface::respawn_hosted`) and the connect
//! (`Surface::adopt_hosted_with_resource_identity`) make theirs, with the size, title and directory of its host.

use std::os::unix::net::UnixStream;

use super::*;
use crate::mux::terminal_respawn::RespawnDecision;
use crate::mux::test_hooks::set_committed_before_route_publish_hook;
use crate::terminal_host_runtime::{HostAttachment, input_ack_surface_fixture};

/// The size and title of the fake host: no placeholder and no durable row has them.
const COLS: u16 = 132;
const ROWS: u16 = 43;
const TITLE: &str = "shell-of-the-commit";

/// A connection to a fake host of `terminal_id` in `incarnation`, the host, and the directory of its shell.
fn host_of(
    terminal_id: &str,
    incarnation: &str,
    workspace_key: &str,
) -> (HostAttachment, UnixStream, String) {
    let (mut attachment, host) = input_ack_surface_fixture();
    attachment.record.terminal_id = terminal_id.into();
    attachment.record.incarnation = incarnation.into();
    attachment.record.workspace_key = workspace_key.into();
    attachment.snapshot.cols = COLS;
    attachment.snapshot.rows = ROWS;
    attachment.snapshot.replay = format!("\x1b]2;{TITLE}\x07").into_bytes();
    let directory =
        std::fs::canonicalize(std::env::temp_dir()).unwrap().to_string_lossy().into_owned();
    attachment.snapshot.cwd = Some(directory.clone());
    (attachment, host, directory)
}

/// What a snapshot shows of one terminal.
#[derive(Debug, PartialEq)]
struct Shown {
    running: bool,
    title: String,
    size: (u64, u64),
    cwd: Option<String>,
    has_stream_revision: bool,
}

impl Shown {
    /// What a snapshot shows of a running terminal whose runtime is `surface`.
    fn of_the_runtime(surface: &Surface) -> Self {
        let (cols, rows) = surface.size();
        Self {
            running: true,
            title: surface.title(),
            size: (u64::from(cols), u64::from(rows)),
            cwd: surface.presented_directory(),
            has_stream_revision: true,
        }
    }
}

/// The values of the new runtime, which are the values of its host and not those of a terminal with no runtime
/// (an empty title, 80x24, no directory).
fn values_of_the_host(surface: &Surface, directory: &str) -> Shown {
    let expected = Shown::of_the_runtime(surface);
    eprintln!("snapshot-window: the runtime of the commit: {expected:?}");
    assert_eq!(
        expected,
        Shown {
            running: true,
            title: TITLE.into(),
            size: (u64::from(COLS), u64::from(ROWS)),
            cwd: Some(directory.to_string()),
            has_stream_revision: true,
        },
        "setup: the new runtime has the title, the size and the directory of its host"
    );
    expected
}

/// What `snapshot` shows of `terminal`, and its stream revision.
fn shown(snapshot: &Value, terminal: &str) -> (Shown, Option<u64>) {
    let value = snapshot["terminals"]
        .as_array()
        .unwrap()
        .iter()
        .find(|value| value["id"].as_str() == Some(terminal))
        .unwrap_or_else(|| panic!("setup: the snapshot shows the terminal: {snapshot}"));
    let stream_revision =
        value["stream_revision"].as_str().map(|revision| revision.parse::<u64>().unwrap());
    let shown = Shown {
        running: value["running"].as_bool().unwrap(),
        title: value["title"].as_str().unwrap().to_string(),
        size: (value["cols"].as_u64().unwrap(), value["rows"].as_u64().unwrap()),
        cwd: value["cwd"].as_str().map(str::to_string),
        has_stream_revision: stream_revision.is_some(),
    };
    (shown, stream_revision)
}

/// Runs `mutate` on a thread of its own, stopped after its COMMIT and before the drop of its state guard, and
/// `read` on another thread beside it. Returns what the read gave, whether it answered while the mutator was
/// stopped (a read that proves the routes of its rows waits for the mutator instead), and how many times it
/// waited for the state lock.
fn read_in_the_window(
    mux: &Arc<Mux>,
    mutate: impl FnOnce(&Arc<Mux>) + Send + 'static,
    read: impl FnOnce(&Arc<Mux>) -> Value + Send + 'static,
) -> (Value, bool, u64) {
    let (committed, committed_receiver) = sync_channel::<()>(1);
    let (release, release_receiver) = sync_channel::<()>(1);
    let mutator = {
        let mux = mux.clone();
        std::thread::spawn(move || {
            set_committed_before_route_publish_hook(move || {
                committed.send(()).unwrap();
                release_receiver.recv().unwrap();
            });
            mutate(&mux);
        })
    };
    if committed_receiver.recv_timeout(Duration::from_secs(20)).is_err() {
        // The mutator ended (its panic is the cause) or never reached its COMMIT.
        mutator.join().unwrap();
        panic!(
            "setup: the mutator did not stop between its COMMIT and the drop of its state guard"
        );
    }
    // `true`: the read answered. `false`: the read started its wait for the mutator. The first of the two says
    // whether the read answered in the window; no fixed time decides it.
    let (step, step_receiver) = std::sync::mpsc::channel::<bool>();
    let reader = {
        let mux = mux.clone();
        std::thread::spawn(move || {
            let waits = step.clone();
            crate::resource_api::set_route_wait_start_hook_on_this_thread(move || {
                let _ = waits.send(false);
            });
            let snapshot = read(&mux);
            let _ = step.send(true);
            (snapshot, crate::resource_api::route_waits_on_this_thread())
        })
    };
    let in_window = step_receiver.recv_timeout(Duration::from_secs(20));
    release.send(()).unwrap();
    let in_window =
        in_window.expect("setup: the read answered or started its wait for the mutator");
    mutator.join().unwrap();
    let (snapshot, waits) = reader.join().unwrap();
    (snapshot, in_window, waits)
}

/// The real respawn. The host of a placed terminal is lost: the exit commit, the respawn decision
/// (`plan_terminal_respawn_locked`, which takes the dead runtime out of the tabs; the daemon makes it in the hold
/// of the exit commit, `mux/terminal_exit.rs`, this test in a hold of its own after it), the reopen of the row
/// (`begin_terminal_respawn`), a new host at the terminal's slot, then `install_respawned_runtime`. The worker's
/// steps after the install (the journal gap, the Activate frame, the pre-fill) come after the window.
#[test]
fn a_snapshot_read_in_the_window_of_a_terminal_respawn_shows_the_new_shell() {
    const TERMINAL: &str = "00000000000040008000000000408261";
    const LOST: &str = "10000000000040008000000000408261";
    const NEW: &str = "20000000000040008000000000408261";
    let root = temp_root("respawn-window");
    let mux = session_at_rest("snapshot-respawn-window", &root);
    let workspace_key = mux.create_empty_workspace(Some("respawn".into()), None, None).unwrap().key;
    let placed = mux.seed_running_terminal_for_test(TERMINAL, LOST, &workspace_key).unwrap();
    let terminal = mux.surface(placed).unwrap().terminal_public_id().unwrap().clone();

    let end = TerminalEnd::host_lost("terminal host ended without a durable exit sidecar");
    assert!(
        mux.persist_terminal_exit(TERMINAL, Some(LOST), &end).unwrap(),
        "setup: the host loss of the seeded terminal commits"
    );
    let plan = {
        let registry = mux.workspace_registry.lock().unwrap();
        let mut state = mux.lock_state_pinned(&registry).unwrap();
        let cause = end.wire_json()["reason"].as_str().unwrap().to_string();
        let decision = mux.plan_terminal_respawn_locked(
            &registry,
            &mut state,
            TERMINAL,
            (cause, LOST.to_string()),
            &end,
        );
        match decision {
            Some(RespawnDecision::Planned(plan)) => plan,
            _ => panic!("setup: the host loss of a placed terminal plans a respawn"),
        }
    };
    {
        let mut registry = mux.workspace_registry.lock().unwrap();
        let revision = registry
            .begin_terminal_respawn(
                &plan.terminal_id,
                plan.old_incarnation.as_deref(),
                plan.user_restart,
            )
            .unwrap()
            .expect("setup: the row of the lost terminal reopens");
        mux.emit_terminal_registry_changed(&registry, revision);
    }
    let (attachment, host, directory) = host_of(TERMINAL, NEW, &workspace_key);
    let surface = Surface::spawn_hosted_awaiting_activation_for_test(
        plan.slot,
        Arc::downgrade(&mux),
        attachment,
        plan.identity.clone(),
    )
    .unwrap();
    let expected = values_of_the_host(&surface, &directory);
    let revision_before = surface.terminal_stream_revision().unwrap();
    // A warm cache, as a session with clients has: the read in the window is the first one after the commit.
    let (before, ..) = read_cut(&mux);
    assert!(
        !shown(&before, terminal.as_str()).0.running,
        "setup: the terminal is not running before its new runtime is installed"
    );

    let (snapshot, in_window, waits) = read_in_the_window(
        &mux,
        {
            let surface = surface.clone();
            move |mux: &Arc<Mux>| {
                assert!(
                    mux.install_respawned_runtime(&plan, &surface).unwrap(),
                    "setup: the respawn installs its runtime"
                );
                surface.release_pending_terminal_host_binding();
            }
        },
        |mux: &Arc<Mux>| read_cut(mux).0,
    );
    let revision_after = surface.terminal_stream_revision().unwrap();
    let (got, stream_revision) = shown(&snapshot, terminal.as_str());
    drop(mux);
    drop(host);
    let _ = std::fs::remove_dir_all(&root);

    assert_eq!(
        got, expected,
        "a snapshot read that started between the commit of a terminal respawn and the publish of its routes (it answered in the window: {in_window}) shows the terminal of the commit without the values of its new runtime"
    );
    assert!(
        stream_revision
            .is_some_and(|revision| (revision_before..=revision_after).contains(&revision)),
        "the snapshot shows the stream revision of the new runtime ({revision_before}..={revision_after}): {stream_revision:?}"
    );
    assert_eq!(
        (in_window, waits),
        (false, 1),
        "the reader that builds beside the respawn waits for its state guard once, and no more"
    );
}

/// The real adoption at daemon start, beside the first snapshot of a client that attaches. A daemon that starts
/// has the durable tabs of the terminal and no runtime. It marks the row adopting (`adopt_terminal_hosts`), reads
/// the restored placement (`restored_terminal_binding`), connects to the host at that slot, then
/// `finish_terminal_adoption`.
///
/// The read is `public_session_snapshot`, the read of the `session.snapshot` request. The request itself is not
/// used: its route check takes the state lock before the read, so it would wait for the stopped mutator before
/// its read starts and would show nothing about the read.
#[test]
fn the_first_snapshot_in_the_window_of_a_terminal_adoption_shows_the_adopted_shell() {
    const TERMINAL: &str = "00000000000040008000000000408262";
    const INCARNATION: &str = "10000000000040008000000000408262";
    let root = temp_root("adoption-window");
    let mux = session_at_rest("snapshot-adoption-window", &root);
    let workspace_key =
        mux.create_empty_workspace(Some("adoption".into()), None, None).unwrap().key;
    let placed = mux.seed_running_terminal_for_test(TERMINAL, INCARNATION, &workspace_key).unwrap();
    let terminal = mux.surface(placed).unwrap().terminal_public_id().unwrap().clone();
    mux.commit_terminal_lifecycle_for_test(TERMINAL, TerminalLifecycle::Adopting, INCARNATION)
        .unwrap();
    // The seed left a placeholder runtime in the tab. A daemon that starts has none.
    assert!(mux.remove_terminal_catalog_for_test(&terminal).is_some());
    assert!(mux.remove_surface_runtime_for_test(placed).is_some());
    let binding = mux
        .restored_terminal_binding(TERMINAL)
        .unwrap()
        .expect("setup: the terminal has a restored binding");
    let (slot, identity) =
        binding.placements.first().cloned().expect("setup: the terminal has a restored placement");
    let (attachment, host, directory) = host_of(TERMINAL, INCARNATION, &workspace_key);
    let surface =
        Surface::spawn_hosted_adopted_for_test(slot, Arc::downgrade(&mux), attachment, identity)
            .unwrap();
    let expected = values_of_the_host(&surface, &directory);
    let revision_before = surface.terminal_stream_revision().unwrap();

    let (snapshot, in_window, waits) = read_in_the_window(
        &mux,
        {
            let surface = surface.clone();
            move |mux: &Arc<Mux>| {
                mux.finish_terminal_adoption(TERMINAL, INCARNATION, surface).unwrap();
            }
        },
        |mux: &Arc<Mux>| public_session_snapshot(mux).unwrap(),
    );
    let revision_after = surface.terminal_stream_revision().unwrap();
    let (got, stream_revision) = shown(&snapshot, terminal.as_str());
    drop(mux);
    drop(host);
    let _ = std::fs::remove_dir_all(&root);

    assert_eq!(
        got, expected,
        "the first snapshot of a client, read between the commit of a terminal adoption and the publish of its routes (it answered in the window: {in_window}), shows the terminal of the commit without the values of its adopted runtime"
    );
    assert!(
        stream_revision
            .is_some_and(|revision| (revision_before..=revision_after).contains(&revision)),
        "the snapshot shows the stream revision of the adopted runtime ({revision_before}..={revision_after}): {stream_revision:?}"
    );
    assert_eq!(
        (in_window, waits),
        (false, 1),
        "the reader that builds beside the adoption waits for its state guard once, and no more"
    );
}
