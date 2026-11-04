//! The agent roster fold reads the journal tail with no daemon lock held.
//!
//! cli-latency-under-load (STATUS 6460, base 33cdf18e6dc, 90 calls/s, 32
//! workers, typing): the largest single hold of the workspace registry lock
//! was the roster fold, 1.378 s, while it read the journal tail page by
//! page. Every request that needs the registry waited behind it (registry
//! waits up to 1.6 s, 824 `tab.create` calls failed with
//! `session.no_answer` after 10 s), and `agent.list` waited on the roster.

use super::*;

fn saved_roster_cursor(mux: &Mux) -> u64 {
    mux.workspace_registry
        .lock()
        .unwrap()
        .journal_reducer_state(crate::journal_reducers::AGENT_ROSTER_REDUCER_ID)
        .unwrap()
        .map_or(0, |(_, cursor, _)| cursor)
}

#[test]
fn a_roster_fold_reads_the_journal_tail_with_the_registry_and_roster_locks_free() {
    let root = std::env::temp_dir()
        .join(format!("cmux-roster-fold-lock-{}", crate::workspace_registry::new_uuid_v4()));
    let mux = open_persistent_test_mux("roster-fold-lock", &root);
    // The maintenance worker folds the tail on its own ticks; stop it so the
    // fold below is the one that reads the tail.
    mux.stop_journal_maintenance();
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal_id = surface.terminal_public_id().cloned().expect("workspace terminal");
    append_journal_hook(&mux, &terminal_id, "SessionStart", Some("agent-fold-lock"));
    let after_agent = saved_roster_cursor(&mux);
    assert!(after_agent > 0, "an agent event saves the roster");
    // A tail of journal records the fold has not read yet.
    for index in 0..40 {
        mux.create_empty_workspace(Some(format!("tail-{index}")), None, None).unwrap();
    }
    let head = mux.workspace_registry.lock().unwrap().session_journal_head().unwrap();
    assert!(head > after_agent, "the tail appended journal records");

    let (registry_free, roster_free) = std::thread::scope(|scope| {
        // Both ends live in this closure, so a failed wait drops `release`
        // and the paused fold ends instead of blocking the scope's join.
        let (entered_sender, entered) = std::sync::mpsc::sync_channel(0);
        let (release, release_receiver) = std::sync::mpsc::sync_channel(0);
        mux.pause_agent_roster_fold_after_page_for_test(entered_sender, release_receiver);
        let fold = scope.spawn(|| mux.catch_up_agent_roster());
        entered
            .recv_timeout(Duration::from_secs(30))
            .expect("the fold reads a page of the journal tail");
        // Another request takes each lock while the fold is mid-tail.
        let registry_free = mux.workspace_registry.try_lock().is_ok();
        let roster_free = mux.agent_roster.try_lock().is_ok();
        release.send(()).unwrap();
        fold.join().unwrap();
        (registry_free, roster_free)
    });
    assert!(
        registry_free,
        "the roster fold holds the workspace registry lock while it reads the journal tail"
    );
    assert!(roster_free, "the roster fold holds the roster lock while it reads the journal tail");
    assert_eq!(saved_roster_cursor(&mux), head, "the fold reaches the journal head");
    assert_eq!(roster_agent_state(&mux, &terminal_id).as_deref(), Some("idle"));
    mux.shutdown();
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}

/// cmux-ad m11 item 2: a journal maintenance tick's roster catch-up held the roster FOLD lock for
/// its whole tail read and snapshot write (agent_roster_fold.rs `advance_agent_roster`), and request
/// paths take that lock: a terminal close (`purge_terminal_side_tables`), a direct agent report (its
/// journal echo folds) and every agent hook. Requests on one connection run in order on one
/// dispatch thread, so one of them waiting there held every later request of the app (#34628's
/// 5-8 s step timed out `workspace.place`, `new-conversation-tab` and others together; #35075
/// raised the app's deadline to 30 s for it). While a catch-up is mid-tail, those requests must
/// finish within the typing budget.
#[test]
fn requests_do_not_wait_for_a_roster_catch_up_reading_the_journal_tail() {
    let root = std::env::temp_dir()
        .join(format!("cmux-roster-fold-hold-{}", crate::workspace_registry::new_uuid_v4()));
    let mux = open_persistent_test_mux("roster-fold-hold", &root);
    mux.stop_journal_maintenance();
    let agent = mux.new_workspace(None, None).unwrap();
    let agent_terminal = agent.terminal_public_id().cloned().expect("workspace terminal");
    append_journal_hook(&mux, &agent_terminal, "SessionStart", Some("agent-fold-hold"));
    let doomed = mux.new_workspace(None, None).unwrap();
    let doomed_workspace = mux.surface_workspace(doomed.id).expect("its workspace");
    // A tail of journal records the catch-up has not read yet.
    for index in 0..40 {
        mux.create_empty_workspace(Some(format!("tail-{index}")), None, None).unwrap();
    }

    let budget = Duration::from_millis(500);
    let (closed, reported) = std::thread::scope(|scope| {
        let (entered_sender, entered) = std::sync::mpsc::sync_channel(0);
        let (release, release_receiver) = std::sync::mpsc::sync_channel(0);
        mux.pause_agent_roster_fold_after_page_for_test(entered_sender, release_receiver);
        let fold = scope.spawn(|| mux.catch_up_agent_roster());
        entered
            .recv_timeout(Duration::from_secs(30))
            .expect("the catch-up reads a page of the journal tail");
        // Two requests while the catch-up is paused mid-tail, each on its own thread so a request
        // that waits for the fold lock cannot hang the test.
        let (done_sender, done) = std::sync::mpsc::channel();
        let close_done = done_sender.clone();
        let mux_ref = &mux;
        scope.spawn(move || {
            let started = Instant::now();
            let closed = mux_ref.close_workspace(doomed_workspace);
            let _ = close_done.send(("close", closed, started.elapsed()));
        });
        scope.spawn(move || {
            let started = Instant::now();
            let reported = mux_ref
                .report_agent(agent.id, AgentState::Running, AgentSource::Socket, None)
                .is_ok();
            let _ = done_sender.send(("report", reported, started.elapsed()));
        });
        let mut results = std::collections::HashMap::new();
        let deadline = Instant::now() + budget;
        while results.len() < 2 {
            let left = deadline.saturating_duration_since(Instant::now());
            match done.recv_timeout(left) {
                Ok((what, ok, took)) => {
                    results.insert(what, (ok, took));
                }
                Err(_) => break,
            }
        }
        // Let the catch-up go on, so the requests that waited for it end and the scope joins.
        release.send(()).unwrap();
        fold.join().unwrap();
        (results.get("close").copied(), results.get("report").copied())
    });
    assert!(
        closed.is_some_and(|(ok, _)| ok),
        "a workspace close waited for the roster catch-up's tail read ({budget:?}): {closed:?}"
    );
    assert!(
        reported.is_some_and(|(ok, _)| ok),
        "an agent report waited for the roster catch-up's tail read ({budget:?}): {reported:?}"
    );
    mux.shutdown();
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}
