use super::super::SubagentTree;
use serde_json::{Value, json};

fn update(tree: &mut SubagentTree, update: Value) {
    let mut params = json!({"sessionId": "s1", "update": update});
    tree.annotate(&mut params);
}

fn spawn(tree: &mut SubagentTree, id: &str, name: &str) {
    update(
        tree,
        json!({"sessionUpdate": "subagent_spawned", "subagentSessionId": id, "name": name,
            "background": true}),
    );
}

fn state(tree: &mut SubagentTree, id: &str, state: &str) {
    update(
        tree,
        json!({"sessionUpdate": "subagent_state_update", "subagentSessionId": id, "state": state}),
    );
}

/// The panel lists every running subagent however many the chat started, not the summary's
/// latest eight: a coordinator with a hundred helpers running sees a hundred (Leo, 2026-11-24:
/// "this bugged? or had an ultra slow load").
#[test]
fn every_running_subagent_is_listed_past_the_summarys_eight() {
    let mut tree = SubagentTree::default();
    for n in 0..120 {
        spawn(&mut tree, &format!("a{n}"), &format!("Helper {n}"));
    }
    for n in 0..20 {
        state(&mut tree, &format!("a{n}"), "completed");
    }
    state(&mut tree, "a20", "failed");
    let list = tree.listing(false, 100);
    assert_eq!(list.running.len(), 99);
    assert_eq!(list.running[0].id, "a21", "oldest running first");
    assert_eq!(list.running[0].title.as_deref(), Some("Helper 21"));
    assert!(list.running[0].background);
    assert!(list.running[0].started_at.is_some());
    assert_eq!(list.ended.len(), 21);
    assert_eq!(list.ended[0].id, "a20", "latest ended first");
    assert_eq!(list.ended[0].state, "failed");
    assert_eq!(list.ended[1].state, "done");
    assert!(list.ended[1].ended_at.is_some());
    assert_eq!(list.seen, 120);
    assert_eq!(list.ended_omitted, 0);
}

/// The ended ones are bounded, the rest counted.
#[test]
fn the_ended_list_is_bounded_and_counts_what_it_leaves_out() {
    let mut tree = SubagentTree::default();
    for n in 0..30 {
        spawn(&mut tree, &format!("a{n}"), "Helper");
        state(&mut tree, &format!("a{n}"), "completed");
    }
    let list = tree.listing(false, 10);
    assert!(list.running.is_empty());
    assert_eq!(list.ended.len(), 10);
    assert_eq!(list.ended[0].id, "a29");
    assert_eq!(list.ended_omitted, 20);
}

/// A foreground subagent of a turn that ended without saying so reads stopped, as the summary's
/// list reads it.
#[test]
fn a_foreground_one_past_its_turn_reads_stopped() {
    let mut tree = SubagentTree::default();
    update(
        &mut tree,
        json!({"sessionUpdate": "subagent_spawned", "subagentSessionId": "f1", "name": "Look"}),
    );
    assert_eq!(tree.listing(true, 10).running.len(), 1);
    let between = tree.listing(false, 10);
    assert!(between.running.is_empty());
    assert_eq!(between.ended[0].state, "stopped");
}

/// A tree rebuilt from the log (a daemon restart) lists what the log saw; one this tree knew
/// already keeps its own state.
#[test]
fn a_rebuilt_tree_adopts_the_logs_list() {
    let mut log = SubagentTree::default();
    spawn(&mut log, "old", "From the log");
    state(&mut log, "old", "completed");
    spawn(&mut log, "both", "Both");
    let mut tree = SubagentTree::default();
    spawn(&mut tree, "both", "Both");
    state(&mut tree, "both", "failed");
    tree.adopt(log);
    let list = tree.listing(false, 10);
    let ended: Vec<_> = list.ended.iter().map(|s| (s.id.as_str(), s.state)).collect();
    assert!(ended.contains(&("old", "done")));
    assert!(ended.contains(&("both", "failed")));
}

/// What one `_acpmux/subagents` answer costs at the size of the coordinator chat Leo opened
/// (a coordinator chat, 2026-11-24: 3,805 subagents seen, 8 running): the list and its JSON, timed. Run with
/// `cargo test -p acpmux --release --lib listing_cost_at_a_coordinators_size -- --ignored --nocapture`
/// (scripts/cmux-next/background-tasks-list-bench.py times the live call).
#[test]
#[ignore]
fn listing_cost_at_a_coordinators_size() {
    let mut tree = SubagentTree::default();
    for n in 0..3805 {
        spawn(&mut tree, &format!("toolu_{n:05}"), &format!("Helper {n} with a long enough name"));
    }
    for n in 0..3797 {
        state(&mut tree, &format!("toolu_{n:05}"), "completed");
    }
    let rounds = 200;
    let started = std::time::Instant::now();
    let mut bytes = 0;
    for _ in 0..rounds {
        let list = tree.listing(false, super::LISTED_ENDED_DEFAULT);
        bytes = serde_json::to_vec(&list).map(|v| v.len()).unwrap_or(0);
    }
    let each = started.elapsed() / rounds;
    let list = tree.listing(false, super::LISTED_ENDED_DEFAULT);
    println!(
        "listing: {} running, {} ended listed, {} omitted, {bytes} bytes, {each:?} per call",
        list.running.len(),
        list.ended.len(),
        list.ended_omitted
    );
    assert_eq!(list.running.len(), 8);
}
