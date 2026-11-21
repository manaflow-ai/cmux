//! A panic while a thread held the agent roster (or its fold lock) poisons
//! the lock. The roster is a cache of the journal, so the daemon keeps it:
//! readers and the terminal close path recover the guard
//! (`PoisonError::into_inner`) as the rest of the daemon does, instead of
//! panicking on every later `cmux agent list` or terminal close (#32243
//! review).

use super::*;

fn poison<T: Send>(mutex: &Mutex<T>) {
    std::thread::scope(|scope| {
        let _ = scope
            .spawn(|| {
                let _guard = mutex.lock().unwrap_or_else(PoisonError::into_inner);
                // crash-allow: test-only panic to poison the lock under test.
                panic!("poison the lock under test");
            })
            .join();
    });
    assert!(mutex.is_poisoned(), "the lock is poisoned");
}

#[test]
fn a_poisoned_roster_does_not_break_agent_list_or_terminal_close() {
    let mux = test_mux();
    mux.new_workspace(None, Some((80, 24))).unwrap();
    poison(&mux.agent_roster);
    poison(&mux.agent_roster_worker.fold);

    let caught = |run: &dyn Fn()| {
        std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            run();
        }))
        .is_ok()
    };
    let terminal = TerminalPublicId::parse(format!("term_{:032x}", 7)).unwrap();
    let survived = [
        (
            "agent list",
            caught(&|| {
                mux.list_agents(None, None);
            }),
        ),
        ("terminal close", caught(&|| mux.purge_terminal_side_tables(&terminal))),
        (
            "terminal respawn or adoption",
            caught(&|| mux.reconcile_agent_roster_projections_for_terminal(&terminal)),
        ),
        ("daemon start", caught(&|| mux.reconcile_agent_roster_projections())),
    ];
    let failed = survived.iter().filter(|(_, ok)| !ok).map(|(path, _)| *path).collect::<Vec<_>>();
    assert!(failed.is_empty(), "panicked on a poisoned roster lock: {failed:?}");
}

/// A persistent session whose state lock was poisoned (a writer panicked while it held it) still shuts down: the
/// output store's last write looks each terminal up, and that lookup must recover the poisoned guard as the rest of
/// the shutdown does (`finalize_terminal_journal`). It panicked instead, inside `Mux::drop`, so the rest of the
/// drop (the journal writer's stop, the browser runtime's shutdown) never ran (#35127 review).
#[cfg(unix)]
#[test]
fn a_persistent_session_with_a_poisoned_state_still_shuts_down() {
    const TERMINAL: &str = "0000000000004000800000000000005e";
    const INCARNATION: &str = "1000000000004000800000000000005e";
    let root = std::env::temp_dir()
        .join(format!("cmux-poisoned-drop-{}", crate::workspace_registry::new_uuid_v4()));
    let mux = Mux::open_persistent("poisoned-drop", SurfaceOptions::default(), &root).unwrap();
    let workspace = mux.create_empty_workspace(None, None, None).unwrap();
    mux.seed_running_terminal_for_test(TERMINAL, INCARNATION, &workspace.key).unwrap();
    let terminal =
        mux.workspace_registry.lock().unwrap().terminal_resource_id(TERMINAL).unwrap().unwrap();
    // Output the store must write at shutdown.
    mux.output_store.append(&terminal, &Arc::from(INCARNATION), b"last line before quit\r\n", None);
    let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let _state = mux.state.lock().unwrap_or_else(PoisonError::into_inner);
        // crash-allow: test-only panic to poison the session state.
        panic!("a writer panics while it holds the session state");
    }));
    assert!(mux.state.is_poisoned(), "the session state is poisoned");

    // The output store's writer holds a handle during its pass: take the last handle, so the drop (and any panic in
    // it) runs here, inside catch_unwind, not on the writer's thread (#35279 review).
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut handle = mux;
    let mux = loop {
        match Arc::try_unwrap(handle) {
            Ok(mux) => break mux,
            Err(shared) => {
                assert!(Instant::now() < deadline, "another handle to the mux stayed for 5 s");
                handle = shared;
                std::thread::sleep(Duration::from_millis(10));
            }
        }
    };
    let dropped = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| drop(mux)));
    assert!(dropped.is_ok(), "the shutdown of a session with a poisoned state panicked");
    let _ = std::fs::remove_dir_all(&root);
}

/// A terminal's launch credential is an authorization decision: on a poisoned session state the daemon cannot show
/// the terminal is still open, so the check refuses it (fails closed), as the other auth checks do on a poisoned lock.
/// The lookup itself no longer panics on poison (#35279 review), so the refusal must be explicit.
#[test]
fn a_terminal_credential_is_refused_on_a_poisoned_state() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal = surface.terminal_public_id().cloned().expect("a workspace terminal");
    let credential = mux.mint_terminal_credential(&terminal).expect("the test mux has launch keys");
    assert!(
        matches!(
            mux.check_launch_credential(&credential),
            launch_identity::CredentialCheck::Verified(_)
        ),
        "the credential of a live terminal verifies"
    );
    let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let _state = mux.state.lock().unwrap_or_else(PoisonError::into_inner);
        // crash-allow: test-only panic to poison the session state.
        panic!("a writer panics while it holds the session state");
    }));
    assert!(
        matches!(
            mux.check_launch_credential(&credential),
            launch_identity::CredentialCheck::Refused("credential_closed")
        ),
        "a poisoned session state verified a terminal credential"
    );
}
