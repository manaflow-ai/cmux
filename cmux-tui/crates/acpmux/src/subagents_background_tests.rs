//! `SubagentTree` background and running subagents (`subagents.rs`).

use super::*;

fn annotate(tree: &mut SubagentTree, update: Value, live: bool) {
    let mut params = json!({"sessionId": "s1", "update": update});
    tree.annotate_live(&mut params, live);
}

/// manaflow-ai/cmux#25230: the background subagents a chat runs past its turn, from their
/// start to their end; a foreground one ends with its turn, and a replay changes nothing.
#[test]
fn background_subagents_run_from_their_start_to_their_end() {
    let mut tree = SubagentTree::default();
    tree.set_own(Some("s1"));
    let spawn = |id: &str, background: bool| json!({"sessionUpdate": "subagent_spawned", "subagentSessionId": id, "background": background});
    let end = |id: &str| json!({"sessionUpdate": "subagent_state_update", "subagentSessionId": id, "state": "completed"});
    annotate(&mut tree, spawn("fg", false), true);
    assert_eq!(tree.background_running(), 0);
    annotate(&mut tree, spawn("replayed", true), false);
    assert_eq!(tree.background_running(), 0, "a replay starts nothing");
    annotate(&mut tree, spawn("bg", true), true);
    // Moved to the background later (Claude's task_started is_backgrounded).
    annotate(
        &mut tree,
        json!({"sessionUpdate": "subagent_progress", "subagentSessionId": "fg", "background": true}),
        true,
    );
    assert_eq!(tree.background_running(), 2);
    // Progress without the mark keeps it.
    annotate(
        &mut tree,
        json!({"sessionUpdate": "subagent_progress", "subagentSessionId": "bg"}),
        true,
    );
    assert_eq!(tree.background_running(), 2);
    annotate(&mut tree, end("bg"), true);
    annotate(&mut tree, end("fg"), true);
    assert_eq!(tree.background_running(), 0);
    annotate(&mut tree, spawn("bg2", true), true);
    tree.end_background();
    assert_eq!(tree.background_running(), 0, "its harness exited");
}

/// The hover card's live count (cmux NEXT sidebar, Leo 2026-11-01: "this hover preview being
/// able to see the # of associated subagents"): every running subagent, foreground or
/// background, nested ones too, with its name; a replay counts none, and without a running
/// turn only the background ones still run.
#[test]
fn running_subagents_are_counted_with_their_names_from_start_to_end() {
    let mut tree = SubagentTree::default();
    tree.set_own(Some("s1"));
    let spawn = |id: &str, name: &str, background: bool| json!({"sessionUpdate": "subagent_spawned", "subagentSessionId": id, "name": name, "background": background});
    let end = |id: &str| json!({"sessionUpdate": "subagent_state_update", "subagentSessionId": id, "state": "completed"});
    annotate(&mut tree, spawn("replayed", "Old", false), false);
    assert_eq!(tree.running_count(), 0, "a replay starts nothing");
    annotate(&mut tree, spawn("a", "Review the sidebar", false), true);
    annotate(&mut tree, spawn("b", "Fix   the\nbuild", true), true);
    annotate(&mut tree, spawn("c", &"x".repeat(80), false), true);
    assert_eq!(tree.running_count(), 3);
    let names: Vec<_> =
        tree.running_now(true).into_iter().map(|(_, l)| l.unwrap().to_owned()).collect();
    assert_eq!(names[0], "Review the sidebar");
    assert_eq!(names[1], "Fix the build", "one line, single spaces");
    assert_eq!(names[2].chars().count(), LABEL_CHARS, "a long name is cut");
    assert_eq!(tree.running_now(false).len(), 1, "between turns only the background one runs");
    annotate(&mut tree, end("a"), true);
    assert_eq!(tree.running_count(), 2);
    assert_eq!(tree.running_now(true)[0].0, "b", "oldest first");
    tree.end_background();
    assert_eq!(tree.running_count(), 0, "its harness exited");
}

/// A subagent named by its task (its prompt) never carries a credential out to the summary.
#[test]
fn a_running_subagents_task_label_has_its_secrets_masked() {
    let mut tree = SubagentTree::default();
    tree.set_own(Some("s1"));
    let token: String = format!("gh{}_{}", "p", "aZ3kQ9mX7pL2vB8nR4tW6yC1dF5gH0jSaZ3k");
    let task = format!("Push with GITHUB_TOKEN={token} and open the PR");
    annotate(
        &mut tree,
        json!({"sessionUpdate": "subagent_spawned", "subagentSessionId": "a", "task": task}),
        true,
    );
    let label = tree.running_now(true)[0].1.unwrap().to_owned();
    assert!(!label.contains(&token), "the token survives in {label:?}");
    assert!(label.starts_with("Push with"), "{label:?}");
}

/// Two turns in a row: the first turn's foreground subagents, whose ends the harness never
/// sent, are gone once it ends, and only its background one runs on into the next.
#[test]
fn a_turns_foreground_subagents_do_not_show_again_in_the_next_turn() {
    let mut tree = SubagentTree::default();
    tree.set_own(Some("s1"));
    let spawn = |id: &str, background: bool| json!({"sessionUpdate": "subagent_spawned", "subagentSessionId": id, "name": id, "background": background});
    annotate(&mut tree, spawn("fg1", false), true);
    annotate(&mut tree, spawn("bg1", true), true);
    assert_eq!(tree.running_now(true).len(), 2, "turn 1");
    tree.end_foreground();
    annotate(&mut tree, spawn("fg2", false), true);
    let ids: Vec<_> = tree.running_now(true).into_iter().map(|(id, _)| id).collect();
    assert_eq!(ids, vec!["bg1", "fg2"], "turn 2 shows its own and the background one");
}

/// A legacy activity echo of the native root that arrives before the root is known counts as
/// running background work; recognizing the root afterwards must stop counting it.
#[test]
fn a_late_root_seed_stops_counting_its_echo_as_background_work() {
    let mut tree = SubagentTree::default();
    tree.set_own(Some("s1"));
    annotate(
        &mut tree,
        json!({"sessionUpdate": "tool_call_update", "toolCallId": "echo-root",
               "_meta": {"codex": {"subagent": {"threadId": "root-native",
                 "path": "/root", "activity": "working"}}}}),
        true,
    );
    assert_eq!(tree.background_running(), 1, "the echo was counted before the root was known");
    tree.set_root("root-native");
    assert_eq!(tree.background_running(), 0, "the native root is not background work");
}

/// A background Claude agent that fails (an API error ends it) and runs again (the model
/// resumes it with SendMessage) says `running` without the background mark. It is background
/// work again: uncounted, the chat read as idle with no subagent running while the agent worked,
/// and only the commands it ran kept its harness from hibernating under it. A daemon that adopts
/// the host reads the same updates back from the log (`work_below.rs`), so it counts it too.
#[test]
fn a_background_subagent_that_runs_again_after_failing_is_background_work() {
    let mut tree = SubagentTree::default();
    tree.set_own(Some("s1"));
    let state = |state: &str| json!({"sessionUpdate": "subagent_state_update", "subagentSessionId": "bg", "state": state, "agentId": "a1"});
    annotate(
        &mut tree,
        json!({"sessionUpdate": "subagent_spawned", "subagentSessionId": "bg", "name": "Toast fix", "background": true}),
        true,
    );
    assert_eq!(tree.background_running(), 1);
    annotate(&mut tree, state("failed"), true);
    assert_eq!(tree.background_running(), 0, "a failed agent no longer runs");
    annotate(&mut tree, state("running"), false);
    assert_eq!(tree.background_running(), 0, "a replay starts nothing");
    annotate(&mut tree, state("running"), true);
    assert_eq!(tree.background_running(), 1, "the resumed agent is background work again");
    assert_eq!(tree.running_now(false), vec![("bg", Some("Toast fix"))], "it runs past the turn");
    annotate(&mut tree, state("completed"), true);
    assert_eq!(tree.background_running(), 0);
}

/// Only a background subagent's mark carries across its end: a foreground one that runs again
/// stays foreground.
#[test]
fn a_foreground_subagent_that_runs_again_is_not_background_work() {
    let mut tree = SubagentTree::default();
    tree.set_own(Some("s1"));
    for state in ["running", "failed", "running"] {
        annotate(
            &mut tree,
            json!({"sessionUpdate": "subagent_state_update", "subagentSessionId": "fg", "state": state}),
            true,
        );
    }
    assert_eq!(tree.background_running(), 0);
}
