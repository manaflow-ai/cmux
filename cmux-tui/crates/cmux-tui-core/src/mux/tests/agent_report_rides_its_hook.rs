//! One agent hook's report rides the commit of the hook's journal row.
//!
//! A hook that changes its agent's state makes 3 commits of the registry's
//! file before its answer: the journal writer admits the hook's row, the
//! request's thread commits the agent report's projection, and the journal
//! writer deletes the hook's retry row in a batch of its own. Each commit is
//! a sync of the file.
//!
//! The rows of the first group ask for one commit: the journal writer applies
//! the report in the transaction of the hook's row, so no projection commit
//! and no delete follow. The rows of the second group hold what that change
//! must keep: the state at the hook's answer, the order of 2 hooks of one
//! terminal, the order of the rows a journal follower reads, one report row
//! for one hook, and the retry of a report that could not be applied.
//!
//! COUNT form (no clock): the registry is a file in a temporary directory and
//! its commits go through the journal writer thread, as in a daemon. The rows
//! read the commits by the name of their writer (`server-stats`
//! `write_path.commits_by_writer`), as a client does. The burst prints its
//! time for a reader of the log and asserts nothing on it.
//!
//! What these rows leave out: a report of another source between the commit
//! and the request's finish, a first hook whose thread ends with no finish,
//! and a daemon that stops between the two: each needs a hold inside the
//! change and comes with it. A hook for a closed terminal and a replayed hook
//! have their rows in `agent_hook_fences.rs` and `agent_hook_retry.rs`.

use std::sync::Barrier;
use std::time::Instant;

use serde_json::json;

use super::*;

/// The terminals of the burst, one thread each.
const BURST_TERMINALS: usize = 10;
/// The turns each terminal of the burst starts: 100 hooks counted.
const BURST_TURNS: usize = 10;

/// One hook of the agent session on `terminal`, through the journal ingress
/// path, as its hook helper sends it.
fn send(
    mux: &Arc<Mux>,
    terminal: &TerminalPublicId,
    event: &str,
    mut native: Value,
) -> crate::JournalAppendCommit {
    native["session_id"] = json!(format!("session-{}", terminal.as_str()));
    native["cwd"] = json!("/srv/project");
    let ingress = crate::agent_hooks::agent_hook_journal_ingress(
        "claude",
        event,
        Some(terminal.as_str()),
        native,
    )
    .unwrap();
    let key = format!("report-rides-{}", crate::workspace_registry::new_uuid_v4());
    mux.append_journal_ingress(&ingress, "test", &key).unwrap()
}

/// A registry in a file with `count` running terminals, each with an agent
/// session that sits at its prompt (`idle`).
fn session(name: &str, count: usize) -> (Arc<Mux>, std::path::PathBuf, Vec<TerminalPublicId>) {
    let root = std::env::temp_dir()
        .join(format!("cmux-report-rides-{name}-{}", crate::workspace_registry::new_uuid_v4()));
    let mux = open_persistent_test_mux("report-rides", &root);
    // The maintenance worker checkpoints and seals on its own clock; the
    // counts below must see only what the hooks cause.
    mux.stop_journal_maintenance();
    let workspace = mux.create_empty_workspace(None, None, None).unwrap().key;
    let terminals = (0..count)
        .map(|index| {
            let raw = format!("00000000000040008000{:012x}", index + 1);
            let incarnation = format!("10000000000040008000{:012x}", index + 1);
            mux.seed_running_terminal_for_test(&raw, &incarnation, &workspace).unwrap();
            mux.workspace_registry.lock().unwrap().terminal_resource_id(&raw).unwrap().unwrap()
        })
        .collect::<Vec<_>>();
    for terminal in &terminals {
        send(&mux, terminal, "SessionStart", json!({}));
    }
    settled(&mux);
    (mux, root, terminals)
}

/// The `write_path` section as a client reads it.
fn section(mux: &Mux) -> Value {
    serde_json::to_value(mux.write_path_stats()).unwrap()
}

/// The commits of `writer` in the section's rows.
fn commits(section: &Value, writer: &str) -> u64 {
    for row in section["commits_by_writer"].as_array().into_iter().flatten() {
        if row["writer"].as_str() == Some(writer) {
            return row["commits"].as_u64().unwrap_or(0);
        }
    }
    0
}

/// The commits of the registry's file in the section.
fn all_commits(section: &Value) -> u64 {
    section["wal_commits"].as_u64().unwrap()
}

/// The state of the terminal's agent in the session's public snapshot.
fn public_state(mux: &Mux, terminal: &TerminalPublicId) -> Option<String> {
    hook_projected_agents(mux)
        .into_iter()
        .find(|agent| agent["terminal_id"].as_str() == Some(terminal.as_str()))
        .and_then(|agent| agent["state"].as_str().map(str::to_owned))
}

/// The retry rows that wait for a projection.
fn retry_rows(mux: &Mux) -> usize {
    mux.workspace_registry.lock().unwrap().pending_agent_hook_projections().unwrap().len()
}

/// The journal rows after `sequence`: (sequence, kind), in their order.
fn rows_after(mux: &Mux, sequence: u64) -> Vec<(u64, String)> {
    mux.session_journal_after(sequence, 500)
        .unwrap()
        .records
        .iter()
        .map(|record| (record.sequence, record.kind.clone()))
        .collect()
}

/// One hook of a turn's start is one commit of the registry's file at its
/// answer, and the agent's state is there at that answer.
#[test]
fn one_hook_is_one_commit_of_the_registry_file_at_its_answer() {
    let (mux, root, terminals) = session("one", 1);
    let terminal = &terminals[0];

    let before = section(&mux);
    let answer = send(&mux, terminal, "UserPromptSubmit", json!({ "prompt": "go on" }));
    let at_answer = section(&mux);
    let state = public_state(&mux, terminal);
    let waiting = retry_rows(&mux);
    drop(mux);
    let _ = std::fs::remove_dir_all(&root);

    assert!(!answer.replayed, "setup: the hook of a turn's start is a new journal row");
    assert_eq!(state.as_deref(), Some("working"), "the agent's state at the hook's answer");
    assert_eq!(waiting, 0, "no retry row waits at the hook's answer");
    let by = |writer: &str| commits(&at_answer, writer) - commits(&before, writer);
    assert_eq!(
        (all_commits(&at_answer) - all_commits(&before), by("journal_writer"), by("agent_report")),
        (1, 1, 0),
        "(all, journal_writer, agent_report): one hook is one commit of the registry's file, the \
         journal writer's, with the agent report in it"
    );
}

/// A burst of 100 hooks over 10 terminals, each terminal from its own thread:
/// no commit of an agent report, and not more journal batches than hooks.
#[test]
fn a_burst_of_hooks_makes_no_commit_of_an_agent_report() {
    let (mux, root, terminals) = session("burst", BURST_TERMINALS);
    let hooks = BURST_TERMINALS * BURST_TURNS;

    let mut rows = 0;
    let mut reports = 0;
    let mut batches = 0;
    let mut took = std::time::Duration::ZERO;
    for turn in 0..BURST_TURNS {
        if turn > 0 {
            // Not counted: each agent ends its turn, so the next hook of a
            // turn's start changes its state again.
            for terminal in &terminals {
                send(&mux, terminal, "Stop", json!({}));
            }
            settled(&mux);
        }
        let before = section(&mux);
        let gate = Barrier::new(BURST_TERMINALS);
        let started = Instant::now();
        let new_rows = std::thread::scope(|scope| {
            let threads = terminals
                .iter()
                .map(|terminal| {
                    let (mux, gate) = (&mux, &gate);
                    scope.spawn(move || {
                        gate.wait();
                        let prompt = json!({ "prompt": format!("turn {turn}") });
                        !send(mux, terminal, "UserPromptSubmit", prompt).replayed
                    })
                })
                .collect::<Vec<_>>();
            threads.into_iter().map(|thread| usize::from(thread.join().unwrap())).sum::<usize>()
        });
        took += started.elapsed();
        let after = section(&mux);
        rows += new_rows;
        reports += commits(&after, "agent_report") - commits(&before, "agent_report");
        batches += commits(&after, "journal_writer") - commits(&before, "journal_writer");
    }
    let states = terminals.iter().map(|terminal| public_state(&mux, terminal)).collect::<Vec<_>>();
    drop(mux);
    let _ = std::fs::remove_dir_all(&root);

    eprintln!(
        "burst: {hooks} hooks of a turn's start from {BURST_TERMINALS} threads in {took:?}: \
         {batches} journal batches, {reports} commits of an agent report"
    );
    assert_eq!(rows, hooks, "setup: each hook of the burst is a new journal row");
    assert!(
        states.iter().all(|state| state.as_deref() == Some("working")),
        "each agent's state after the burst: {states:?}"
    );
    assert_eq!(reports, 0, "the reports of the burst's {hooks} hooks ride their hooks' commits");
    assert!(
        batches <= u64::try_from(hooks).unwrap(),
        "not more journal batches than hooks: {batches} for {hooks}"
    );
}

/// 2 hooks of one terminal from 2 threads: the agent's state at the end is
/// that of the 2 hooks in the order of their journal rows.
#[test]
fn two_hooks_of_one_terminal_from_two_threads_end_in_the_order_of_their_rows() {
    let (mux, root, terminals) = session("pair", 1);
    let terminal = &terminals[0];
    send(&mux, terminal, "UserPromptSubmit", json!({ "prompt": "go on" }));
    send(&mux, terminal, "PermissionRequest", json!({ "tool_name": "Bash" }));

    let gate = Barrier::new(2);
    let (stop, prompt) = std::thread::scope(|scope| {
        let stop = scope.spawn(|| {
            gate.wait();
            send(&mux, terminal, "Stop", json!({}))
        });
        let prompt = scope.spawn(|| {
            gate.wait();
            send(&mux, terminal, "UserPromptSubmit", json!({ "prompt": "next" }))
        });
        (stop.join().unwrap(), prompt.join().unwrap())
    });
    let public = public_state(&mux, terminal);
    let roster = settled(&mux).agent_roster_state_now_for_test(terminal.as_str());
    let waiting = retry_rows(&mux);
    drop(mux);
    let _ = std::fs::remove_dir_all(&root);

    assert!(!stop.replayed && !prompt.replayed, "setup: each of the 2 hooks is a new journal row");
    // The turn's end, then the next turn's start: the agent works. The other
    // order: the agent sits at its prompt.
    let expected = if stop.sequence < prompt.sequence { "working" } else { "idle" };
    assert_eq!(
        (public.as_deref(), roster.as_deref()),
        (Some(expected), Some(expected)),
        "(public snapshot, roster): the state of the 2 hooks in the order of their rows (the \
         turn's end is row {}, the turn's start is row {})",
        stop.sequence,
        prompt.sequence
    );
    assert_eq!(waiting, 0, "no retry row waits after the 2 answers");
}

/// A journal follower reads the hook's row before the row of its report, and
/// one hook has one report row.
#[test]
fn a_follower_reads_the_hooks_row_and_then_one_report_row() {
    let (mux, root, terminals) = session("order", 1);
    let terminal = &terminals[0];

    let head = mux.session_journal_head().unwrap();
    let answer = send(&mux, terminal, "UserPromptSubmit", json!({ "prompt": "go on" }));
    settled(&mux);
    let rows = rows_after(&mux, head);
    drop(mux);
    let _ = std::fs::remove_dir_all(&root);

    assert_eq!(
        rows.first().map(|row| row.0),
        Some(answer.sequence),
        "the hook's row is the first row after the head: {rows:?}"
    );
    let reports = rows.iter().filter(|row| row.1 == "agent.report").collect::<Vec<_>>();
    assert_eq!(reports.len(), 1, "one hook has one report row: {rows:?}");
    assert!(reports[0].0 > answer.sequence, "the report's row follows the hook's row: {rows:?}");
}

/// A report that the registry refuses keeps its hook's row and a retry row,
/// does not hold the hook of another terminal, and is applied by the retry.
#[test]
fn a_refused_report_keeps_its_hooks_row_for_the_retry() {
    let (mux, root, terminals) = session("refused", 2);
    let (first, second) = (&terminals[0], &terminals[1]);

    let head = mux.session_journal_head().unwrap();
    mux.workspace_registry.lock().unwrap().set_resource_patch_failure(true).unwrap();
    let refused = send(&mux, first, "UserPromptSubmit", json!({ "prompt": "go on" }));
    let rows = rows_after(&mux, head);
    let state_while_refused = public_state(&mux, first);
    let waiting_while_refused = retry_rows(&mux);
    mux.workspace_registry.lock().unwrap().set_resource_patch_failure(false).unwrap();
    send(&mux, second, "UserPromptSubmit", json!({ "prompt": "go on" }));
    let other = public_state(&mux, second);
    mux.retry_pending_agent_hooks().unwrap();
    let state_after_retry = public_state(&mux, first);
    let waiting_after_retry = retry_rows(&mux);
    drop(mux);
    let _ = std::fs::remove_dir_all(&root);

    assert!(!refused.replayed, "setup: the hook is a new journal row");
    assert!(
        rows.iter().any(|row| row.0 == refused.sequence),
        "the journal keeps the row of the hook whose report was refused: {rows:?}"
    );
    assert_eq!(
        (state_while_refused.as_deref(), waiting_while_refused),
        (Some("idle"), 1),
        "(state, retry rows) while the report is refused: the state before the hook, and one \
         retry row"
    );
    assert_eq!(other.as_deref(), Some("working"), "the hook of another terminal is applied");
    assert_eq!(
        (state_after_retry.as_deref(), waiting_after_retry),
        (Some("working"), 0),
        "(state, retry rows) after the retry"
    );
}
