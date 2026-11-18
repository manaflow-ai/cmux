//! The order and the failures of the one commit that a turn-end hook's
//! notification and agent report share (`agent_turn_end_commits.rs` counts
//! the hook's commits).
//!
//! The notification's effect receipt is `executing` and durable before the
//! post. Its outcome then commits in the transaction of the agent report of
//! the same hook, the notification's record one revision below the report's.
//! When that commit does not take the notification (the report refuses or
//! fails), the notification commits alone, as it did before the two shared a
//! commit. When the daemon stops before that commit, the receipt is
//! `indeterminate` at the next start: the notification is not posted again
//! and it has no record (a person does not see it after the restart), and
//! the hook's retry row keeps the report. The save of the terminal's
//! relaunch record, a commit of its own when the record changes, comes
//! before the receipt is `executing`, so it is not in that span.
//!
//! Each row reads the journal's rows of the turn end, the hooks that wait for
//! a retry and the notifications in the daemon's memory. No clock.

use std::path::PathBuf;

use serde_json::json;

use super::*;

const TERMINAL: &str = "00000000000040008000000000000001";
const INCARNATION: &str = "10000000000040008000000000000001";
const SESSION: &str = "turn-end";
const TURN_END: &str = "agent.turn.completed";
const TOOL_ERROR: &str = "agent.error.reported";
const NOTIFICATION: &str = "notification.create";
const REPORT: &str = "agent.report";

/// The state of the notification's effect receipt (each row here has one).
const RECEIPT_STATE: &str =
    "SELECT state FROM resource_effect_receipts WHERE operation = 'notification.create'";

/// The agent report's rows fail. A commit of the notification alone does not.
const FAIL_THE_REPORT: &str = "CREATE TEMP TRIGGER fail_the_report
     BEFORE INSERT ON resource_mutations
     WHEN NEW.operation = 'agent.report'
     BEGIN SELECT RAISE(ABORT, 'forced agent report failure'); END;";

/// Each outcome commit and each indeterminate mark of an effect receipt
/// fails, so the receipt stays `executing`: what a daemon leaves on the disk
/// when it stops between the `executing` mark and the outcome commit.
const STOP_BEFORE_THE_OUTCOME: &str = "CREATE TEMP TRIGGER stop_before_the_outcome
     BEFORE UPDATE OF state ON resource_effect_receipts
     WHEN NEW.state IN ('committed', 'indeterminate')
     BEGIN SELECT RAISE(ABORT, 'the daemon stops before the outcome commit'); END;";

/// Each save of a terminal's relaunch record notes the state that the
/// notification's receipt has then (`none`: there is no receipt yet).
const NOTE_THE_RECEIPT_AT_A_RELAUNCH_SAVE: &str =
    "CREATE TEMP TABLE relaunch_saves(receipt TEXT NOT NULL);
     CREATE TEMP TRIGGER note_the_receipt_at_a_relaunch_save
     AFTER UPDATE OF agent_json ON terminal_relaunch
     BEGIN
       INSERT INTO relaunch_saves
       SELECT coalesce(
         (SELECT group_concat(state, ' ') FROM resource_effect_receipts
          WHERE operation = 'notification.create'),
         'none');
     END;";

/// The noted states, one for each save, in order (`no save`: none was made).
const RECEIPT_AT_EACH_RELAUNCH_SAVE: &str =
    "SELECT coalesce(group_concat(receipt, ', '), 'no save') FROM relaunch_saves";

/// One hook of the agent session on `terminal`, through the journal ingress
/// path, as its hook helper sends it.
fn send(mux: &Arc<Mux>, terminal: &TerminalPublicId, event: &str) {
    let native = json!({ "session_id": SESSION, "cwd": "/srv/project" });
    let ingress = crate::agent_hooks::agent_hook_journal_ingress(
        "claude",
        event,
        Some(terminal.as_str()),
        native,
    )
    .unwrap();
    let key = format!("turn-end-order-{}", crate::workspace_registry::new_uuid_v4());
    mux.append_journal_ingress(&ingress, "test", &key).unwrap();
}

/// The turn end's journal rows after `sequence`, in order: the kind and the
/// resource revision of each.
fn turn_end_rows(registry: &WorkspaceRegistry, mut sequence: u64) -> Vec<(String, Option<u64>)> {
    let mut rows = Vec::new();
    loop {
        let page = registry.session_journal_after(sequence, 500).unwrap();
        let Some(last) = page.records.last() else { return rows };
        sequence = last.sequence;
        rows.extend(
            page.records
                .iter()
                .filter(|record| {
                    [TURN_END, TOOL_ERROR, NOTIFICATION, REPORT].contains(&record.kind.as_str())
                })
                .map(|record| (record.kind.clone(), record.resource_revision)),
        );
    }
}

fn kinds(rows: Vec<(String, Option<u64>)>) -> Vec<String> {
    rows.into_iter().map(|(kind, _)| kind).collect()
}

/// A daemon on a registry file, with an agent whose turn is open.
struct OpenTurn {
    root: PathBuf,
    mux: Arc<Mux>,
    terminal: TerminalPublicId,
    /// The journal head before the turn's end.
    head: u64,
}

impl OpenTurn {
    /// `shell`: the terminal is the shell of a workspace, which stays in the
    /// registry across a restart; otherwise a seeded terminal with no process.
    fn open(session: &str, shell: bool) -> Self {
        let mut turn = Self::no_hook_yet(session, shell);
        send(&turn.mux, &turn.terminal, "SessionStart");
        send(&turn.mux, &turn.terminal, "UserPromptSubmit");
        settled(&turn.mux);
        turn.head = turn.mux.session_journal_head().unwrap();
        turn
    }

    /// A daemon on a registry file and a terminal that no agent hook named
    /// yet (`shell`: as for `open`).
    fn no_hook_yet(session: &str, shell: bool) -> Self {
        let root = std::env::temp_dir()
            .join(format!("cmux-{session}-{}", crate::workspace_registry::new_uuid_v4()));
        let mux = open_persistent_test_mux(session, &root);
        // The maintenance worker commits on its own clock.
        mux.stop_journal_maintenance();
        let terminal = if shell {
            mux.new_workspace(None, None).unwrap().terminal_public_id().cloned().unwrap()
        } else {
            let workspace = mux.create_empty_workspace(None, None, None).unwrap().key;
            mux.seed_running_terminal_for_test(TERMINAL, INCARNATION, &workspace).unwrap();
            mux.workspace_registry.lock().unwrap().terminal_resource_id(TERMINAL).unwrap().unwrap()
        };
        let head = mux.session_journal_head().unwrap();
        Self { root, mux, terminal, head }
    }

    /// The `Stop` hook: the end of the turn, its notification and its report.
    fn end_turn(&self) {
        send(&self.mux, &self.terminal, "Stop");
    }

    fn sql(&self, sql: &str) {
        self.mux.workspace_registry.lock().unwrap().execute_sql_for_test(sql).unwrap();
    }

    fn rows(&self) -> Vec<(String, Option<u64>)> {
        turn_end_rows(&self.mux.workspace_registry.lock().unwrap(), self.head)
    }

    /// The hooks whose projection waits for a retry.
    fn pending(&self) -> usize {
        self.mux.workspace_registry.lock().unwrap().pending_agent_hook_projections().unwrap().len()
    }

    /// The notifications in the daemon's memory: what a person sees.
    fn posted(&self) -> usize {
        self.mux.resource_notifications(16).len()
    }

    /// What the commit of a notification installs: the feed's items and the
    /// unread marker of the terminal (its source).
    fn installed(&self) -> (usize, Option<NotificationSource>) {
        let feed = self.mux.feed_local_list(&cmux_feed_core::ListFilter::default()).len();
        (feed, self.mux.terminal_notification(&self.terminal).map(|marker| marker.source))
    }

    fn text(&self, sql: &str) -> String {
        self.mux.workspace_registry.lock().unwrap().query_text_for_test(sql).unwrap()
    }

    fn receipt(&self) -> String {
        self.text(RECEIPT_STATE)
    }

    fn close(self) {
        drop(self.mux);
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

#[test]
fn the_notification_record_is_one_revision_below_the_agent_report() {
    let turn = OpenTurn::open("turn-end-order", false);
    let events = turn.mux.subscribe();
    turn.end_turn();
    let events: Vec<&str> = events
        .try_iter()
        .filter_map(|event| match event {
            MuxEvent::Notification(_) => Some("notification"),
            MuxEvent::AgentChanged { .. } => Some("agent"),
            _ => None,
        })
        .collect();
    let rows = turn.rows();
    let (pending, posted, installed) = (turn.pending(), turn.posted(), turn.installed());
    turn.close();

    let revisions: Vec<Option<u64>> = rows.iter().map(|(_, revision)| *revision).collect();
    assert_eq!(
        kinds(rows),
        [TURN_END, NOTIFICATION, REPORT],
        "the journal rows of the turn end: the hook, then the notification, then the report"
    );
    let (notification, report) = (revisions[1].unwrap(), revisions[2].unwrap());
    assert_eq!(
        report,
        notification + 1,
        "the notification's record is one resource revision below the report's"
    );
    assert_eq!(
        (pending, posted),
        (0, 1),
        "the hook is projected (no retry row) and its notification is posted one time"
    );
    assert_eq!(
        installed,
        (1, Some(NotificationSource::Agent)),
        "the commit of both installed the notification: one feed item and the terminal's \
         unread marker"
    );
    assert_eq!(
        events,
        ["notification", "agent"],
        "the notification's event comes before the agent report's event"
    );
}

#[test]
fn a_hook_that_reports_nothing_commits_its_notification_alone() {
    let turn = OpenTurn::open("turn-end-no-report", false);
    // A failed tool call of a working agent: a notification, and the roster
    // state stays as it is, so the hook has no agent report.
    send(&turn.mux, &turn.terminal, "PostToolUseFailure");
    let rows = kinds(turn.rows());
    let seen = (turn.pending(), turn.posted(), turn.installed(), turn.receipt());
    turn.close();

    assert_eq!(
        rows,
        [TOOL_ERROR, NOTIFICATION],
        "the hook's journal row and the notification's record; no agent report"
    );
    assert_eq!(
        (seen.0, seen.1, seen.2, seen.3.as_str()),
        (0, 1, (1, Some(NotificationSource::Agent)), "committed"),
        "no retry row; the notification is posted one time, with its feed item and the \
         terminal's unread marker; its receipt is `committed`"
    );
}

#[test]
fn the_relaunch_record_is_saved_before_the_notification_receipt_is_executing() {
    // The turn end is the first hook of its agent session on the terminal,
    // so the terminal's relaunch record takes the session: one more commit.
    let turn = OpenTurn::no_hook_yet("turn-end-relaunch-save", true);
    turn.sql(NOTE_THE_RECEIPT_AT_A_RELAUNCH_SAVE);
    // The hook makes each of its commits before it answers.
    let before = turn.mux.write_path_stats().wal_commits;
    turn.end_turn();
    let commits = turn.mux.write_path_stats().wal_commits - before;
    let (rows, receipt) = (kinds(turn.rows()), turn.receipt());
    let saves = turn.text(RECEIPT_AT_EACH_RELAUNCH_SAVE);
    turn.close();

    assert_eq!(
        (rows, receipt.as_str()),
        (vec![TURN_END.to_owned(), NOTIFICATION.to_owned(), REPORT.to_owned()], "committed"),
        "setup: the turn end has its notification and its report in the journal"
    );
    assert_eq!(
        saves, "none",
        "the state of the notification's receipt at each save of the terminal's relaunch \
         record. `none` = one save, before the receipt is there. `executing` = the save is in \
         the span where a daemon stop loses the notification. `no save` = setup: the record \
         did not change"
    );
    assert_eq!(
        commits, 5,
        "the commits of the registry's file that this hook made before its answer: the 4 of a \
         turn end (`agent_turn_end_commits.rs`) and the save of the relaunch record"
    );
}

#[test]
fn a_commit_of_both_that_fails_posts_the_notification_one_time() {
    let turn = OpenTurn::open("turn-end-report-fails", false);
    turn.sql(FAIL_THE_REPORT);
    turn.end_turn();
    let failed = (kinds(turn.rows()), turn.pending(), turn.posted());
    turn.sql("DROP TRIGGER fail_the_report");
    turn.mux.retry_pending_agent_hooks().unwrap();
    let retried = (kinds(turn.rows()), turn.pending(), turn.posted());
    turn.close();

    assert_eq!(
        failed.0,
        [TURN_END, NOTIFICATION],
        "the commit of both failed at the report's rows, so the notification committed alone"
    );
    assert_eq!((failed.1, failed.2), (1, 1), "the hook waits for a retry; one notification");
    assert_eq!(
        retried.0,
        [TURN_END, NOTIFICATION, REPORT],
        "the retry commits the report and no second notification"
    );
    assert_eq!((retried.1, retried.2), (0, 1), "no retry row is left; one notification");
}

#[test]
fn a_report_that_refuses_leaves_the_notification_durable() {
    let turn = OpenTurn::open("turn-end-report-refuses", false);
    // The terminal's row is deleted under the hook, as when the terminal
    // closes while its hook is on the way: the report refuses.
    turn.sql(&format!(
        "UPDATE resource_terminals
         SET lifecycle = 'tombstoned', deleted_revision = updated_revision
         WHERE public_id = '{}'",
        turn.terminal.as_str()
    ));
    turn.end_turn();
    let (rows, posted) = (kinds(turn.rows()), turn.posted());
    turn.close();

    assert_eq!(
        rows,
        [TURN_END, NOTIFICATION],
        "the report refused before its commit, so the notification committed alone"
    );
    assert_eq!(posted, 1, "the notification is posted one time");
}

#[test]
fn a_daemon_stop_before_the_commit_of_both_keeps_the_report_and_posts_nothing_later() {
    let session = "turn-end-daemon-stop";
    let turn = OpenTurn::open(session, true);
    turn.sql(STOP_BEFORE_THE_OUTCOME);
    turn.end_turn();
    let stopped = (kinds(turn.rows()), turn.pending(), turn.receipt());
    turn.sql("DROP TRIGGER stop_before_the_outcome");
    let OpenTurn { root, mux, head, .. } = turn;
    mux.shutdown();
    drop(mux);

    // The file as the next start's open leaves it, before a daemon retries.
    let registry = WorkspaceRegistry::open(&root, session).unwrap();
    let opened = (
        kinds(turn_end_rows(&registry, head)),
        registry.pending_agent_hook_projections().unwrap().len(),
        registry.query_text_for_test(RECEIPT_STATE).unwrap(),
    );
    drop(registry);
    // The next daemon: its start retries the hooks that wait.
    let restarted = open_persistent_test_mux(session, &root);
    let posted = restarted.resource_notifications(16).len();
    restarted.shutdown();
    drop(restarted);
    let registry = WorkspaceRegistry::open(&root, session).unwrap();
    let rows = kinds(turn_end_rows(&registry, head));
    let pending = registry.pending_agent_hook_projections().unwrap().len();
    drop(registry);
    let _ = std::fs::remove_dir_all(&root);

    assert_eq!(
        (stopped.0, stopped.1, stopped.2.as_str()),
        (vec![TURN_END.to_owned()], 1, "executing"),
        "setup: the daemon stops with the hook's journal row, its retry row and the \
         notification's receipt `executing`; no notification record and no report"
    );
    assert_eq!(
        (opened.0, opened.1, opened.2.as_str()),
        (vec![TURN_END.to_owned()], 1, "indeterminate"),
        "the next start keeps the hook's retry row, so the report is not lost, and it does not \
         know if the notification was posted"
    );
    let count = |kind: &str| rows.iter().filter(|row| row.as_str() == kind).count();
    assert_eq!(
        (count(NOTIFICATION), posted),
        (0, 0),
        "after the restart the notification has no record and is not posted again \
         (journal rows of the turn end: {rows:?})"
    );
    // The start's retry reports if the terminal is there, keeps the row if
    // the terminal can come back, and drops it if the terminal is gone.
    assert!(
        count(REPORT) + pending <= 1,
        "the report is not doubled: {} rows in the journal and {pending} hooks that wait",
        count(REPORT)
    );
}

#[test]
fn the_retry_after_an_interrupted_notification_reports_and_posts_no_second_time() {
    let turn = OpenTurn::open("turn-end-interrupted", false);
    turn.sql(STOP_BEFORE_THE_OUTCOME);
    turn.end_turn();
    let interrupted = (kinds(turn.rows()), turn.pending(), turn.posted(), turn.receipt());
    // What the next daemon start does with a receipt that it finds
    // `executing` (`effect_store.rs`).
    turn.sql(
        "DROP TRIGGER stop_before_the_outcome;
         UPDATE resource_effect_receipts SET state = 'indeterminate' WHERE state = 'executing'",
    );
    turn.mux.retry_pending_agent_hooks().unwrap();
    let retried = (kinds(turn.rows()), turn.pending(), turn.posted(), turn.receipt());
    turn.close();

    assert_eq!(
        (interrupted.0, interrupted.1, interrupted.2, interrupted.3.as_str()),
        (vec![TURN_END.to_owned()], 1, 1, "executing"),
        "setup: the hook's journal row, its retry row, the one post in memory and the \
         notification's receipt `executing`"
    );
    assert_eq!(
        retried.0,
        [TURN_END, REPORT],
        "the retry commits the report; the notification gets no record"
    );
    assert_eq!(
        (retried.1, retried.2, retried.3.as_str()),
        (0, 1, "indeterminate"),
        "no retry row is left, the notification is not posted a second time, and its receipt \
         stays `indeterminate`"
    );
}
