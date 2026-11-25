//! The expiry rules (`subagent_expiry.rs`): task_gone, the heard end, aged_out and harness_exit.

use super::*;
use serde_json::{Value, json};

const T0: u64 = 1_800_000_000_000;

fn annotate(tree: &mut SubagentTree, at: u64, update: Value, live: bool) -> Vec<Value> {
    tree.set_clock(at);
    let mut params = json!({"sessionId": "s1", "update": update});
    tree.annotate_live(&mut params, live);
    params.pointer("/_meta/acpmux/subagents").and_then(Value::as_array).cloned().unwrap_or_default()
}

/// A background subagent `id` that Claude knows as task `agent`, started at `at`.
fn background(tree: &mut SubagentTree, at: u64, id: &str, agent: &str) {
    annotate(
        tree,
        at,
        json!({"sessionUpdate": "subagent_spawned", "subagentSessionId": id, "name": id, "background": true}),
        true,
    );
    progress(tree, at, id, agent);
}

fn progress(tree: &mut SubagentTree, at: u64, id: &str, agent: &str) {
    annotate(
        tree,
        at,
        json!({"sessionUpdate": "subagent_progress", "subagentSessionId": id, "agentId": agent}),
        true,
    );
}

/// What the hub writes for `ended` (`hub/subagent_expiry.rs` `end_subagents`): each end
/// through the tree, as the harness's own end would go.
fn end(tree: &mut SubagentTree, at: u64, ended: &[Ended]) -> Vec<Value> {
    ended
        .iter()
        .flat_map(|e| {
            annotate(
                tree,
                at,
                json!({"sessionUpdate": "subagent_state_update", "subagentSessionId": e.id,
                    "state": e.state, "reason": e.reason}),
                true,
            )
        })
        .collect()
}

fn tree() -> SubagentTree {
    let mut tree = SubagentTree::default();
    tree.set_own(Some("s1"));
    tree
}

fn ids(ended: &[Ended]) -> Vec<&str> {
    ended.iter().map(|e| e.id.as_str()).collect()
}

/// Leo's coordinator (2026-11-22, "^ 99+"): background helpers Claude no longer lists as live
/// ended with no end the bridge could tell. Claude's whole task list ends them (`task_gone`),
/// once quiet past the grace; the ones it lists run on.
#[test]
fn a_background_subagent_missing_from_claudes_task_list_ends() {
    let mut tree = tree();
    background(&mut tree, T0, "gone", "a-gone");
    background(&mut tree, T0, "live", "a-live");
    let live: HashSet<&str> = ["a-live"].into();
    assert!(
        tree.reconcile_tasks(&live, T0 + TASK_GONE_GRACE_MS - 1).is_empty(),
        "within the grace its end may still be on its way"
    );
    let ended = tree.reconcile_tasks(&live, T0 + TASK_GONE_GRACE_MS);
    assert_eq!(
        ended,
        vec![Ended { id: "gone".into(), state: "disconnected", reason: "task_gone" }]
    );
    let records = end(&mut tree, T0 + TASK_GONE_GRACE_MS, &ended);
    assert_eq!(records[0]["state"], json!("disconnected"));
    assert_eq!(records[0]["reason"], json!("task_gone"));
    assert_eq!(records[0]["name"], json!("gone"), "the end names it, for a page holding only it");
    assert_eq!(records[0]["background"], json!(true));
    assert_eq!(tree.running_count(), 1);
    assert_eq!(tree.background_running(), 1);
    assert!(tree.reconcile_tasks(&live, T0 + 10 * TASK_GONE_GRACE_MS).is_empty(), "once");
}

/// A notification the bridge could not tie to its Agent call (after a restart, or a resumed
/// agent's notification naming another call) still says how it ended: that is its end.
#[test]
fn a_heard_notification_gives_the_end_its_status() {
    for (status, state) in [
        ("completed", "completed"),
        ("failed", "failed"),
        ("stopped", "cancelled"),
        ("killed", "cancelled"),
    ] {
        let mut tree = tree();
        background(&mut tree, T0, "a", "agent-a");
        tree.note_task_ended("agent-a", status);
        let ended = tree.reconcile_tasks(&HashSet::new(), T0 + TASK_GONE_GRACE_MS);
        assert_eq!(ended, vec![Ended { id: "a".into(), state, reason: "task_gone" }], "{status}");
    }
    // A notification for a task no running subagent is changes nothing.
    let mut tree = tree();
    tree.note_task_ended("unknown", "completed");
    background(&mut tree, T0, "b", "agent-b");
    let ended = tree.reconcile_tasks(&HashSet::new(), T0 + TASK_GONE_GRACE_MS);
    assert_eq!(ended[0].state, "disconnected");
}

/// Claude's list has only background tasks: a foreground subagent (its turn ends it) and one
/// whose agent id is not known yet are never ended by it.
#[test]
fn the_task_list_ends_only_known_background_agents() {
    let mut tree = tree();
    annotate(
        &mut tree,
        T0,
        json!({"sessionUpdate": "subagent_spawned", "subagentSessionId": "fg", "background": false}),
        true,
    );
    progress(&mut tree, T0, "fg", "agent-fg");
    annotate(
        &mut tree,
        T0,
        json!({"sessionUpdate": "subagent_spawned", "subagentSessionId": "new", "background": true}),
        true,
    );
    assert_eq!(tree.running_count(), 2);
    assert!(tree.reconcile_tasks(&HashSet::new(), T0 + AGE_OUT_MS).is_empty());
}

/// A subagent heard from recently is not ended by a list that missed it, and a progress after
/// the grace started counts from that progress.
#[test]
fn a_recent_event_holds_off_the_task_list() {
    let mut tree = tree();
    background(&mut tree, T0, "a", "agent-a");
    progress(&mut tree, T0 + TASK_GONE_GRACE_MS, "a", "agent-a");
    assert!(tree.reconcile_tasks(&HashSet::new(), T0 + TASK_GONE_GRACE_MS + 1).is_empty());
    assert_eq!(ids(&tree.reconcile_tasks(&HashSet::new(), T0 + 2 * TASK_GONE_GRACE_MS)), ["a"]);
}

/// Any harness (Codex has no task list): a running subagent with no event for `AGE_OUT_MS`
/// ages out; the check runs at most once a minute; a later event of one that was alive runs it
/// again.
#[test]
fn a_quiet_subagent_ages_out_and_a_later_event_revives_it() {
    let mut tree = tree();
    background(&mut tree, T0, "quiet", "agent-q");
    background(&mut tree, T0, "busy", "agent-b");
    assert!(tree.sweep_aged(T0 + 1, false).is_empty());
    progress(&mut tree, T0 + AGE_OUT_MS - 1, "busy", "agent-b");
    let ended = tree.sweep_aged(T0 + AGE_OUT_MS, false);
    assert_eq!(
        ended,
        vec![Ended { id: "quiet".into(), state: "disconnected", reason: "aged_out" }]
    );
    let records = end(&mut tree, T0 + AGE_OUT_MS, &ended);
    assert_eq!(records[0]["reason"], json!("aged_out"));
    assert_eq!(tree.running_count(), 1);
    // Not checked again within the minute, even when due; forced, it is.
    assert!(tree.sweep_aged(T0 + 2 * AGE_OUT_MS, false).len() == 1);
    assert!(tree.sweep_aged(T0 + 2 * AGE_OUT_MS + 1, false).is_empty(), "once a minute");
    assert_eq!(tree.sweep_aged(T0 + 2 * AGE_OUT_MS + 1, true).len(), 1, "forced");
    // It was alive after all: its next event runs it again.
    progress(&mut tree, T0 + AGE_OUT_MS + 5, "quiet", "agent-q");
    assert_eq!(tree.running_count(), 2);
    assert_eq!(tree.background_running(), 2);
}

/// A running subagent with no event time yet (a tree read without stamps) counts from the first
/// check, never from the epoch.
#[test]
fn an_unstamped_subagent_counts_from_the_first_check() {
    let mut tree = tree();
    background(&mut tree, 0, "a", "agent-a");
    assert!(tree.sweep_aged(T0, true).is_empty());
    assert_eq!(ids(&tree.sweep_aged(T0 + AGE_OUT_MS, true)), ["a"]);
}

/// The harness exited: every subagent that ran then is an orphan to end (`harness_exit`), not
/// only the ones acpmux can resume; one whose end the log has after the exit is not, and a
/// replayed `running` of it is history, not its end.
#[test]
fn a_harness_exit_leaves_orphans_until_their_end_is_logged() {
    let mut tree = tree();
    background(&mut tree, T0, "a", "agent-a");
    background(&mut tree, T0, "b", "agent-b");
    background(&mut tree, T0, "c", "agent-c");
    end(&mut tree, T0, &[Ended { id: "c".into(), state: "completed", reason: "x" }]);
    tree.end_background();
    assert_eq!(tree.running_count(), 0);
    // A resumable one got its `disconnected` end in the log (`subagents_lost`).
    end(
        &mut tree,
        T0 + 1,
        &[Ended { id: "b".into(), state: "disconnected", reason: "harness_exit" }],
    );
    annotate(
        &mut tree,
        T0 + 2,
        json!({"sessionUpdate": "subagent_progress", "subagentSessionId": "a"}),
        false,
    );
    assert_eq!(
        tree.take_orphans(),
        vec![Ended { id: "a".into(), state: "disconnected", reason: "harness_exit" }]
    );
    assert!(tree.take_orphans().is_empty(), "taken once");
}

/// A daemon rebuilds a chat's subagents from its log (`hub/hosts/journal.rs` `subagents_from_log`): the
/// live tree takes the log's orphans, agent ids and event times, except for the subagents it
/// already knows, whose state is its own.
#[test]
fn adopting_the_logs_tree_takes_its_expiry() {
    let mut log = tree();
    background(&mut log, T0, "old", "agent-old");
    background(&mut log, T0, "known", "agent-known");
    log.end_background();
    background(&mut log, T0 + 1, "quiet", "agent-quiet");
    let mut live = tree();
    background(&mut live, T0 + 5, "known", "agent-known");
    live.adopt(log);
    assert_eq!(ids(&live.take_orphans()), ["old"]);
    assert_eq!(ids(&live.sweep_aged(T0 + AGE_OUT_MS + 2, true)), ["quiet"]);
    assert_eq!(
        ids(&live.reconcile_tasks(&HashSet::new(), T0 + AGE_OUT_MS)),
        ["known", "quiet"],
        "both agent ids are known"
    );
}
