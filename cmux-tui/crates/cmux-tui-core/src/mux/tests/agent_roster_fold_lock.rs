//! The agent roster fold reads the journal tail with no daemon lock held.
//!
//! cli-latency-under-load (STATUS 6460, base 33cdf18e6dc, 90 calls/s, 32
//! workers, typing): the largest single hold of the workspace registry lock
//! was the roster fold, 1.378 s, while it read the journal tail page by
//! page. Every request that needs the registry waited behind it (registry
//! waits up to 1.6 s, 824 `tab.create` calls failed with
//! `session.no_answer` after 10 s), and `agent.list` waited on the roster.

use super::*;

/// The roster's one owner thread: every journal read for the roster and every
/// snapshot save runs there (plans/cmux-next/perf-lead.md D1).
const ROSTER_OWNER_THREAD: &str = "cmux-agent-roster";

fn saved_roster_cursor(mux: &Mux) -> u64 {
    assert!(mux.settle_agent_roster_for_test(), "the roster owner settles");
    mux.workspace_registry
        .lock()
        .unwrap()
        .journal_reducer_state(crate::journal_reducers::AGENT_ROSTER_REDUCER_ID)
        .unwrap()
        .map_or(0, |(_, cursor, _)| cursor)
}

fn journal_head(mux: &Mux) -> u64 {
    mux.workspace_registry.lock().unwrap().session_journal_head().unwrap()
}

fn roster_cursor(mux: &Mux) -> u64 {
    mux.agent_roster.lock().unwrap().cursor
}

/// `append_journal_hook` that returns the hook record's journal sequence: the
/// roster folds through it. The hook's projection commits a journal record of its
/// own after it, which no fold asks for, so the journal head is not the target.
fn append_hook(mux: &Mux, terminal_id: &TerminalPublicId, event: &str, session_id: &str) -> u64 {
    let ingress = crate::agent_hooks::agent_hook_journal_ingress(
        "claude",
        event,
        Some(terminal_id.as_str()),
        serde_json::json!({ "session_id": session_id }),
    )
    .unwrap();
    let key = format!("roster-fold-hook-{}", crate::workspace_registry::new_uuid_v4());
    mux.append_journal_ingress(&ingress, "test", &key).unwrap().sequence
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
    let head = journal_head(&mux);
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
/// roster still does what they asked: it folds the hook and retires the closed terminal.
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
    // What they asked for is done once the roster's work settles.
    assert_eq!(
        saved_roster_cursor(&mux),
        journal_head(&mux),
        "the roster reaches the journal head"
    );
    assert_eq!(roster_agent_state(&mux, &doomed_terminal), None, "the closed terminal's entry");
    assert_eq!(
        roster_agent_state(&mux, &agent_terminal).as_deref(),
        Some("working"),
        "the hook's prompt makes the agent working"
    );
    mux.shutdown();
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}

/// Review of #35334, F1: a request recorded while another thread held the fold in a pass that made
/// no progress (here a retirement of a terminal with no roster entry, with the roster at the head:
/// the same pass as a batch close's later purges, or a maintenance catch-up with nothing to do) was
/// left behind. That pass returned without reading the requests again, and the request's own
/// `try_lock` had failed, so nothing folded it until another roster request or a maintenance tick (30
/// s or more apart): `cmux agent list` and the Feed reply gate read the old state. Reproduced by the
/// review at f65ccd337d7 (fleet 49167234ad06f7d0119fca51).
#[test]
fn a_hook_recorded_while_the_roster_runs_a_pass_that_makes_no_progress_is_folded() {
    let root = std::env::temp_dir()
        .join(format!("cmux-roster-fold-lost-{}", crate::workspace_registry::new_uuid_v4()));
    let mux = open_persistent_test_mux("roster-fold-lost", &root);
    mux.stop_journal_maintenance();
    let agent = mux.new_workspace(None, None).unwrap();
    let agent_terminal = agent.terminal_public_id().cloned().expect("workspace terminal");
    append_journal_hook(&mux, &agent_terminal, "SessionStart", Some("agent-fold-lost"));
    // The roster at the journal head, so the retirement below folds nothing and retires nothing.
    mux.catch_up_agent_roster();
    assert!(mux.settle_agent_roster_for_test(), "the roster owner settles");
    let head_before = journal_head(&mux);
    assert_eq!(
        mux.agent_roster.lock().unwrap().cursor,
        head_before,
        "the roster starts at the head"
    );
    let no_agent = TerminalPublicId::parse(format!("term_{:032x}", 7)).unwrap();

    let (paused, hook_sequence) = std::thread::scope(|scope| {
        let (entered_sender, entered) = std::sync::mpsc::sync_channel(0);
        let (release, release_receiver) = std::sync::mpsc::sync_channel(0);
        mux.pause_agent_roster_fold_after_head_for_test(entered_sender, release_receiver);
        // A terminal close with no agent: its pass takes the requests, reads the head and pauses.
        let close = scope.spawn(|| mux.retire_roster_terminal(&no_agent));
        let paused = entered.recv_timeout(Duration::from_secs(30)).is_ok();
        // An agent hook while that pass holds the fold: it commits, records its fold and returns.
        let (done_sender, done) = std::sync::mpsc::channel();
        let (mux_ref, agent_ref) = (&mux, &agent_terminal);
        scope.spawn(move || {
            let sequence = append_hook(mux_ref, agent_ref, "UserPromptSubmit", "agent-fold-lost");
            let _ = done_sender.send(sequence);
        });
        let hook_sequence = done.recv_timeout(Duration::from_secs(5)).ok();
        // The paused pass goes on.
        drop(release);
        close.join().unwrap();
        (paused, hook_sequence)
    });
    assert!(paused, "the close's pass reads the journal head");
    let hook_sequence =
        hook_sequence.expect("the hook answered while the close's pass held the fold");
    // Maintenance is stopped and no other request comes: only the roster's own work can fold it.
    assert!(mux.settle_agent_roster_for_test(), "the roster owner settles");
    let cursor = roster_cursor(&mux);
    let state = roster_agent_state(&mux, &agent_terminal);
    assert!(
        cursor >= hook_sequence,
        "a hook recorded while a pass that made no progress held the fold was left behind: \
         hook at {hook_sequence}, roster cursor {cursor} (head before the hook {head_before}), \
         state {state:?}"
    );
    assert_eq!(state.as_deref(), Some("working"), "the hook's prompt makes the agent working");
    mux.shutdown();
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}

/// Review of #35334, F2 (plans/cmux-next/perf-lead.md D1, no I/O on a request path): a terminal
/// close commits its resource change, which appends a journal record, before it purges, so at the
/// purge the journal head is past the roster cursor. A close that found the fold free read the
/// whole tail since the last fold on its request thread, page by page, then saved the snapshot,
/// before it answered; a hook that found it free read its own record's page the same way. Both must
/// answer within the typing budget while the roster's fold of that tail waits at the page seam
/// (whichever thread reads the first page waits there).
#[test]
fn a_terminal_close_and_an_agent_hook_answer_before_the_roster_reads_the_journal_tail() {
    let root = std::env::temp_dir()
        .join(format!("cmux-roster-request-tail-{}", crate::workspace_registry::new_uuid_v4()));
    let mux = open_persistent_test_mux("roster-request-tail", &root);
    mux.stop_journal_maintenance();
    let agent = mux.new_workspace(None, None).unwrap();
    let agent_terminal = agent.terminal_public_id().cloned().expect("workspace terminal");
    append_journal_hook(&mux, &agent_terminal, "SessionStart", Some("agent-request-tail"));
    let doomed = mux.new_workspace(None, None).unwrap();
    let doomed_terminal = doomed.terminal_public_id().cloned().expect("workspace terminal");
    append_journal_hook(&mux, &doomed_terminal, "SessionStart", Some("doomed-request-tail"));
    assert!(mux.settle_agent_roster_for_test(), "the roster owner settles");
    // A tail of journal records the roster has not folded: a fold of it reads pages.
    for index in 0..40 {
        mux.create_empty_workspace(Some(format!("tail-{index}")), None, None).unwrap();
    }

    let budget = Duration::from_millis(500);
    let (closed, hooked, hook_sequence) = std::thread::scope(|scope| {
        let (entered_sender, entered) = std::sync::mpsc::sync_channel(0);
        let (release, release_receiver) = std::sync::mpsc::sync_channel(0);
        mux.pause_agent_roster_fold_after_page_for_test(entered_sender, release_receiver);
        let (done_sender, done) = std::sync::mpsc::channel();
        let (mux_ref, agent_ref, doomed_ref) = (&mux, &agent_terminal, &doomed_terminal);
        let requests = scope.spawn(move || {
            let started = Instant::now();
            mux_ref.purge_terminal_side_tables(doomed_ref);
            let _ = done_sender.send(("close", started.elapsed()));
            let started = Instant::now();
            let sequence =
                append_hook(mux_ref, agent_ref, "UserPromptSubmit", "agent-request-tail");
            let _ = done_sender.send(("hook", started.elapsed()));
            sequence
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
        // The thread that waits at the page seam goes on once both ends are gone, so the
        // requests end whether or not one of them waited there.
        drop((entered, release));
        let hook_sequence = requests.join().unwrap();
        (results.get("close").copied(), results.get("hook").copied(), hook_sequence)
    });
    assert!(
        closed.is_some(),
        "a terminal close read the roster's journal tail on its own thread before it answered \
         (budget {budget:?})"
    );
    assert!(
        hooked.is_some(),
        "an agent hook read the roster's journal tail on its own thread before it answered \
         (budget {budget:?})"
    );
    let cursor = saved_roster_cursor(&mux);
    assert_eq!(cursor, roster_cursor(&mux), "the saved snapshot is at the roster's cursor");
    assert!(cursor >= hook_sequence, "the roster folds the hook (at {hook_sequence}): {cursor}");
    assert_eq!(roster_agent_state(&mux, &doomed_terminal), None, "the closed terminal's entry");
    assert_eq!(
        roster_agent_state(&mux, &agent_terminal).as_deref(),
        Some("working"),
        "the hook's prompt makes the agent working"
    );
    mux.shutdown();
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}

/// Review of #35334, F2: with the roster at the journal head, a terminal close that won the fold
/// still read the journal head and saved the roster snapshot on its request thread, and an agent
/// hook read its record's page and saved too. Only the roster's owner thread reads the journal for
/// the roster or saves its snapshot; a close and a hook only record their work.
#[test]
fn only_the_roster_owner_reads_the_journal_or_saves_the_roster_for_a_close_or_a_hook() {
    let root = std::env::temp_dir()
        .join(format!("cmux-roster-owner-io-{}", crate::workspace_registry::new_uuid_v4()));
    let mux = open_persistent_test_mux("roster-owner-io", &root);
    mux.stop_journal_maintenance();
    let agent = mux.new_workspace(None, None).unwrap();
    let agent_terminal = agent.terminal_public_id().cloned().expect("workspace terminal");
    append_journal_hook(&mux, &agent_terminal, "SessionStart", Some("agent-owner-io"));
    let doomed = mux.new_workspace(None, None).unwrap();
    let doomed_terminal = doomed.terminal_public_id().cloned().expect("workspace terminal");
    append_journal_hook(&mux, &doomed_terminal, "SessionStart", Some("doomed-owner-io"));
    // The roster at the journal head: the close below has no tail to read.
    mux.catch_up_agent_roster();
    assert!(mux.settle_agent_roster_for_test(), "the roster owner settles");
    let _ = mux.take_agent_roster_io_threads_for_test();

    // A close and a hook on a request thread of their own name.
    let (mux_ref, agent_ref, doomed_ref) = (&mux, &agent_terminal, &doomed_terminal);
    let hook_sequence = std::thread::scope(|scope| {
        std::thread::Builder::new()
            .name("cmux-test-request".into())
            .spawn_scoped(scope, move || {
                mux_ref.purge_terminal_side_tables(doomed_ref);
                append_hook(mux_ref, agent_ref, "UserPromptSubmit", "agent-owner-io")
            })
            .unwrap()
            .join()
            .unwrap()
    });
    assert!(mux.settle_agent_roster_for_test(), "the roster owner settles");
    let io_threads = mux.take_agent_roster_io_threads_for_test();
    let elsewhere = io_threads
        .iter()
        .filter(|name| name.as_deref() != Some(ROSTER_OWNER_THREAD))
        .collect::<Vec<_>>();
    assert!(
        elsewhere.is_empty(),
        "the roster read the journal or saved its snapshot on {elsewhere:?}, not only on its \
         owner thread {ROSTER_OWNER_THREAD} (every read and save: {io_threads:?})"
    );
    assert!(!io_threads.is_empty(), "the roster's owner folded the hook and retired the close");
    let cursor = saved_roster_cursor(&mux);
    assert_eq!(cursor, roster_cursor(&mux), "the saved snapshot is at the roster's cursor");
    assert!(cursor >= hook_sequence, "the roster folds the hook (at {hook_sequence}): {cursor}");
    assert_eq!(roster_agent_state(&mux, &doomed_terminal), None, "the closed terminal's entry");
    assert_eq!(
        roster_agent_state(&mux, &agent_terminal).as_deref(),
        Some("working"),
        "the hook's prompt makes the agent working"
    );
    mux.shutdown();
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}
