use super::super::SubagentTree;
use super::RECENT_SUBAGENTS;
use serde_json::{Value, json};

fn update(tree: &mut SubagentTree, update: Value) {
    let mut params = json!({"sessionId": "s1", "update": update});
    tree.annotate(&mut params);
}

fn spawn(tree: &mut SubagentTree, id: &str, name: &str) {
    update(
        tree,
        json!({"sessionUpdate": "subagent_spawned", "subagentSessionId": id, "name": name}),
    );
}

fn state(tree: &mut SubagentTree, id: &str, state: &str) {
    update(
        tree,
        json!({"sessionUpdate": "subagent_state_update", "subagentSessionId": id, "state": state}),
    );
}

/// The sidebar lists a chat's subagents under its row: each one's id, title, parent and state, oldest
/// first, and the summary counts every one it started.
#[test]
fn the_list_names_each_subagent_with_its_state_and_parent() {
    let mut tree = SubagentTree::default();
    spawn(&mut tree, "t1", "Checkout: label the form fields");
    spawn(&mut tree, "t2", "Images: lazy-load below the fold");
    update(
        &mut tree,
        json!({"sessionUpdate": "subagent_spawned", "subagentSessionId": "t3", "task": "Bundle size"}),
    );
    let mut nested = json!({"sessionId": "t2", "update": {"sessionUpdate": "subagent_spawned",
        "subagentSessionId": "t4", "task": "Measure the layout shift"}});
    tree.annotate(&mut nested);
    state(&mut tree, "t1", "completed");
    state(&mut tree, "t2", "failed");
    let list = tree.recent(true);
    let ids: Vec<_> = list.iter().map(|s| s.id.as_str()).collect();
    assert_eq!(ids, ["t1", "t2", "t3", "t4"]);
    assert_eq!(list[0].title.as_deref(), Some("Checkout: label the form fields"));
    assert_eq!(list[0].state, "done");
    assert_eq!(list[1].state, "failed");
    assert_eq!(list[2].state, "running");
    assert_eq!(list[3].parent.as_deref(), Some("t2"));
    assert_eq!(list[3].title.as_deref(), Some("Measure the layout shift"));
    assert_eq!(tree.seen(), 4);
    assert_eq!(
        serde_json::to_value(&list[3]).unwrap(),
        json!({"id": "t4", "parent": "t2", "title": "Measure the layout shift", "state": "running"})
    );
}

/// A chat that starts many subagents costs the same: the list keeps the latest few, a running one
/// last of all, while `subagentsSeen` counts every one.
#[test]
fn the_list_is_bounded_and_drops_finished_ones_first() {
    let mut tree = SubagentTree::default();
    spawn(&mut tree, "keeps-running", "Watch CI");
    for i in 0..20 {
        let id = format!("t{i}");
        spawn(&mut tree, &id, "Helper");
        state(&mut tree, &id, "completed");
    }
    let list = tree.recent(true);
    assert_eq!(list.len(), RECENT_SUBAGENTS);
    assert_eq!(list[0].id, "keeps-running");
    assert_eq!(list[0].state, "running");
    assert_eq!(list.last().unwrap().id, "t19");
    assert_eq!(tree.seen(), 21);
}

/// A foreground subagent whose turn ended without its end reads stopped, not running forever; a
/// cancelled one reads stopped too.
#[test]
fn one_that_runs_no_more_reads_stopped() {
    let mut tree = SubagentTree::default();
    spawn(&mut tree, "t1", "Review");
    spawn(&mut tree, "t2", "Audit");
    state(&mut tree, "t2", "cancelled");
    assert_eq!(tree.recent(true)[0].state, "running");
    tree.end_foreground();
    let list = tree.recent(false);
    assert_eq!(list[0].state, "stopped");
    assert_eq!(list[1].state, "stopped");
}

/// Each live change of the list moves its revision (the tap tells watchers then); a repeated state
/// or a replayed update does not.
#[test]
fn a_live_change_moves_the_revision_once() {
    let mut tree = SubagentTree::default();
    let start = tree.recent_revision();
    spawn(&mut tree, "t1", "Review");
    let spawned = tree.recent_revision();
    assert_ne!(spawned, start);
    update(
        &mut tree,
        json!({"sessionUpdate": "subagent_progress", "subagentSessionId": "t1", "toolUses": 3}),
    );
    assert_eq!(tree.recent_revision(), spawned, "progress changes no state");
    state(&mut tree, "t1", "completed");
    assert_ne!(tree.recent_revision(), spawned);
    let done = tree.recent_revision();
    let mut replay = json!({"sessionId": "s1", "update": {"sessionUpdate": "subagent_spawned",
        "subagentSessionId": "t9", "name": "Old"}});
    tree.annotate_live(&mut replay, false);
    assert_eq!(tree.recent_revision(), done, "a replay tells no watcher");
    assert_eq!(tree.recent(false).last().unwrap().id, "t9", "but it lists the subagent");
}

/// A tree rebuilt from the log brings its list; one this tree lists keeps this tree's state.
#[test]
fn adopting_the_log_keeps_live_states() {
    let mut log = SubagentTree::default();
    spawn(&mut log, "t1", "Review");
    spawn(&mut log, "t2", "Audit");
    let mut live = SubagentTree::default();
    spawn(&mut live, "t1", "Review");
    state(&mut live, "t1", "completed");
    live.adopt(log);
    let list = live.recent(true);
    let got: Vec<_> = list.iter().map(|s| (s.id.as_str(), s.state)).collect();
    assert_eq!(got, [("t1", "done"), ("t2", "running")]);
}

/// A subagent titled by its task (its prompt) never carries a credential out on the list.
#[test]
fn a_listed_title_has_its_secrets_masked() {
    let mut tree = SubagentTree::default();
    let token: String = format!("gh{}_{}", "p", "aZ3kQ9mX7pL2vB8nR4tW6yC1dF5gH0jSaZ3k");
    let task = format!("Push with GITHUB_TOKEN={token} and open the PR");
    update(
        &mut tree,
        json!({"sessionUpdate": "subagent_spawned", "subagentSessionId": "a", "task": task}),
    );
    let title = tree.recent(true)[0].title.clone().unwrap();
    assert!(!title.contains(&token), "the token survives in {title:?}");
    assert!(title.starts_with("Push with"), "{title:?}");
}

/// A host checkpoint saves the tree (#47558): the list and each state come back as they were, and a
/// checkpoint written before the list existed still loads, with no list.
#[test]
fn the_list_survives_a_checkpoint() {
    let mut tree = SubagentTree::default();
    spawn(&mut tree, "t1", "Checkout: label the form fields");
    spawn(&mut tree, "t2", "Images: lazy-load below the fold");
    state(&mut tree, "t1", "completed");
    state(&mut tree, "t2", "failed");
    let saved = serde_json::to_value(&tree).unwrap();
    let back: SubagentTree = serde_json::from_value(saved.clone()).unwrap();
    let states: Vec<_> = back.recent(true).iter().map(|s| (s.id.clone(), s.state)).collect();
    assert_eq!(states, [("t1".to_owned(), "done"), ("t2".to_owned(), "failed")]);

    let mut old = saved;
    let fields = old.as_object_mut().unwrap();
    fields.remove("recent");
    fields.remove("recent_revision");
    let back: SubagentTree = serde_json::from_value(old).unwrap();
    assert!(back.recent(true).is_empty());
}
