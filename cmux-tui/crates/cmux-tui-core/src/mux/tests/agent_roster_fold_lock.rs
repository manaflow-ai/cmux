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
/// its whole tail read and snapshot write (agent_roster_fold.rs, before this test), and request
/// paths take that lock: every agent hook (`session.journal.append` ->
/// `finish_journal_ingress` -> `fold_agent_roster`) and every terminal close
/// (`purge_terminal_side_tables`, from the resource close, a terminal exit, batch closes). Requests
/// on one connection run in order on one dispatch thread, so one of them waiting there held every
/// later request of the app (#34628's 5-8 s step timed out `workspace.place`,
/// `new-conversation-tab` and others together; #35075 raised the app's deadline to 30 s for it).
/// While a catch-up is mid-tail, those requests must finish within the typing budget, and the
/// catch-up still does what they asked: it folds the hook and retires the closed terminal.
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
    let doomed_terminal = doomed.terminal_public_id().cloned().expect("workspace terminal");
    append_journal_hook(&mux, &doomed_terminal, "SessionStart", Some("doomed-fold-hold"));
    assert!(roster_agent_state(&mux, &doomed_terminal).is_some(), "the closed terminal's entry");
    // A tail of journal records the catch-up has not read yet.
    for index in 0..40 {
        mux.create_empty_workspace(Some(format!("tail-{index}")), None, None).unwrap();
    }

    let budget = Duration::from_millis(500);
    let (hooked, closed) = std::thread::scope(|scope| {
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
        let hook_done = done_sender.clone();
        let (mux_ref, agent_ref, doomed_ref) = (&mux, &agent_terminal, &doomed_terminal);
        scope.spawn(move || {
            let started = Instant::now();
            append_journal_hook(mux_ref, agent_ref, "UserPromptSubmit", Some("agent-fold-hold"));
            let _ = hook_done.send(("hook", started.elapsed()));
        });
        scope.spawn(move || {
            let started = Instant::now();
            mux_ref.purge_terminal_side_tables(doomed_ref);
            let _ = done_sender.send(("close", started.elapsed()));
        });
        let mut results = HashMap::new();
        let deadline = Instant::now() + budget;
        while results.len() < 2 {
            let left = deadline.saturating_duration_since(Instant::now());
            match done.recv_timeout(left) {
                Ok((what, took)) => {
                    results.insert(what, took);
                }
                Err(_) => break,
            }
        }
        // Let the catch-up go on, so the requests that waited for it end and the scope joins.
        release.send(()).unwrap();
        fold.join().unwrap();
        (results.get("hook").copied(), results.get("close").copied())
    });
    assert!(
        hooked.is_some(),
        "an agent hook waited for the roster catch-up's tail read (budget {budget:?})"
    );
    assert!(
        closed.is_some(),
        "a terminal close waited for the roster catch-up's tail read (budget {budget:?})"
    );
    // What they asked for is done once the catch-up lets go.
    let head = mux.workspace_registry.lock().unwrap().session_journal_head().unwrap();
    assert_eq!(saved_roster_cursor(&mux), head, "the roster reaches the journal head");
    assert_eq!(roster_agent_state(&mux, &doomed_terminal), None, "the closed terminal's entry");
    assert!(roster_agent_state(&mux, &agent_terminal).is_some(), "the hooked agent's entry");
    mux.shutdown();
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}

/// Review repro (PR 35334, not for landing): a fold request recorded while another thread holds
/// the fold in a run that makes no progress (here a retirement of a terminal with no roster entry,
/// with the roster at the head) is left behind. That run returns without reading the requests
/// again (`drain_roster_requests`: `if !progressed || ...`), and the request's own `try_lock`
/// already failed, so no thread folds it until another roster request or a maintenance tick.
#[test]
fn review_repro_a_hook_recorded_during_a_fold_that_makes_no_progress_is_folded() {
    let root = std::env::temp_dir()
        .join(format!("cmux-roster-fold-lost-{}", crate::workspace_registry::new_uuid_v4()));
    let mux = open_persistent_test_mux("roster-fold-lost", &root);
    mux.stop_journal_maintenance();
    let agent = mux.new_workspace(None, None).unwrap();
    let agent_terminal = agent.terminal_public_id().cloned().expect("workspace terminal");
    append_journal_hook(&mux, &agent_terminal, "SessionStart", Some("agent-fold-lost"));
    // The roster at the journal head, so the retirement below folds nothing and retires nothing.
    mux.catch_up_agent_roster();
    let head_before = mux.workspace_registry.lock().unwrap().session_journal_head().unwrap();
    assert_eq!(
        mux.agent_roster.lock().unwrap().cursor,
        head_before,
        "the roster starts at the head"
    );
    let state_before = roster_agent_state(&mux, &agent_terminal);
    let no_agent = TerminalPublicId::parse(format!("term_{:032x}", 7)).unwrap();

    let hooked = std::thread::scope(|scope| {
        let (entered_sender, entered) = std::sync::mpsc::sync_channel(0);
        let (release, release_receiver) = std::sync::mpsc::sync_channel(0);
        mux.pause_agent_roster_fold_after_head_for_test(entered_sender, release_receiver);
        // A terminal close with no agent: it takes the fold and the requests, reads the head, pauses.
        let close = scope.spawn(|| mux.retire_roster_terminal(&no_agent));
        entered.recv_timeout(Duration::from_secs(30)).expect("the close's fold reads the head");
        // An agent hook while the close holds the fold: it commits, records its fold, its try_lock
        // fails, and it returns.
        let (done_sender, done) = std::sync::mpsc::channel();
        let (mux_ref, agent_ref) = (&mux, &agent_terminal);
        scope.spawn(move || {
            append_journal_hook(mux_ref, agent_ref, "UserPromptSubmit", Some("agent-fold-lost"));
            let _ = done_sender.send(());
        });
        let hooked = done.recv_timeout(Duration::from_secs(5)).is_ok();
        release.send(()).unwrap();
        close.join().unwrap();
        hooked
    });
    assert!(hooked, "the hook returned while the close held the fold");
    // Maintenance is stopped and no other request comes: nothing else would fold it.
    std::thread::sleep(Duration::from_millis(200));
    let head = mux.workspace_registry.lock().unwrap().session_journal_head().unwrap();
    let (cursor, wanted, retire_pending) = {
        let host = mux.agent_roster.lock().unwrap();
        (host.cursor, host.requests.wanted, host.requests.retire.len())
    };
    let state_after = roster_agent_state(&mux, &agent_terminal);
    eprintln!(
        "review repro: head_before={head_before} head={head} cursor={cursor} wanted={wanted} \
         retire_pending={retire_pending} state_before={state_before:?} state_after={state_after:?}"
    );
    assert!(
        cursor >= wanted,
        "a hook recorded while a no-progress fold held the lock was left behind: \
         wanted {wanted}, roster cursor {cursor}, state {state_after:?}"
    );
    assert_eq!(
        state_after.as_deref(),
        Some("working"),
        "the hook's prompt makes the agent working"
    );
    mux.shutdown();
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}
