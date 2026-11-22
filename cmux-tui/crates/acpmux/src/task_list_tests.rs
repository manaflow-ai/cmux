use super::*;
use serde_json::json;

fn item(content: &str, status: TaskStatus) -> TaskItem {
    TaskItem { content: content.into(), status }
}

#[test]
fn the_summary_names_the_step_at_work_and_the_one_after_it() {
    let list = TaskList {
        source: TaskListSource::Harness,
        items: vec![
            item("a", TaskStatus::Pending),
            item("b", TaskStatus::Completed),
            item("c", TaskStatus::InProgress),
            item("d", TaskStatus::Completed),
            item("e", TaskStatus::Pending),
        ],
        updated_at: 7,
        turn: 1,
    };
    let s = list.summary();
    assert_eq!((s.done, s.total), (2, 5));
    assert_eq!(s.current.as_deref(), Some("c"));
    assert_eq!(s.next.as_deref(), Some("e"));
    let none_running = TaskList { items: list.items[..2].to_vec(), ..list };
    assert_eq!(none_running.summary().current, None);
    assert_eq!(none_running.summary().next.as_deref(), Some("a"));
}

#[test]
fn a_plan_is_read_leniently_and_a_set_strictly() {
    let plan = json!({"entries": [
        {"content": "  one  ", "status": "completed"},
        {"content": "", "status": "pending"},
        {"content": "two", "status": "weird"},
        {"status": "pending"},
    ]});
    assert_eq!(
        plan_items(&plan),
        Some(vec![item("one", TaskStatus::Completed), item("two", TaskStatus::Pending)])
    );
    assert_eq!(plan_items(&json!({"sessionUpdate": "plan"})), None);
    assert!(
        set_items(&json!([{"content": "x", "status": "weird"}])).unwrap_err().contains("status")
    );
    assert!(
        set_items(&json!([{"content": " ", "status": "pending"}])).unwrap_err().contains("content")
    );
    let many: Vec<Value> =
        (0..=MAX_ITEMS).map(|n| json!({"content": n.to_string(), "status": "pending"})).collect();
    assert!(set_items(&Value::Array(many)).is_err());
}

#[test]
fn an_empty_plan_clears_only_a_harness_list() {
    let kept = TaskList {
        source: TaskListSource::Chief,
        items: vec![item("x", TaskStatus::Pending)],
        updated_at: 1,
        turn: 4,
    };
    assert_eq!(after_plan(Some(&kept), vec![], 2, 4), None);
    let harness = TaskList { source: TaskListSource::Harness, ..kept.clone() };
    assert_eq!(after_plan(Some(&harness), vec![], 2, 4), Some(None));
    let replaced =
        after_plan(Some(&kept), vec![item("y", TaskStatus::InProgress)], 3, 4).unwrap().unwrap();
    assert_eq!(replaced.source, TaskListSource::Harness);
    // The same steps again in the same turn change nothing, not even the time.
    assert_eq!(after_plan(Some(&harness), harness.items.clone(), 9, 4), None);
    // In a later turn they note that the agent went back to the list.
    let again = after_plan(Some(&harness), harness.items.clone(), 9, 6).unwrap().unwrap();
    assert_eq!((again.turn, again.updated_at), (6, 9));
}

/// Leo, 2026-11-22, on an "Earlier plan · 0 of 1" over a coordinator's hours-old ops note and a
/// sidebar row's "0/1": "we need to figure out how to do better plans and have them expired".
#[test]
fn a_list_expires_once_a_turn_that_never_touched_it_ends() {
    let list = TaskList {
        source: TaskListSource::Harness,
        items: vec![item("08:41Z merge cmux#45744 pinned; then close #45720", TaskStatus::Pending)],
        updated_at: 1,
        turn: 5,
    };
    // The turn that wrote it, running and ended.
    assert!(list.current(5, true));
    assert!(list.current(5, false));
    // The next turn may finish it while it runs ...
    assert!(list.current(6, true));
    // ... but once it ended without touching the list, the list has expired.
    assert!(!list.current(6, false));
    assert!(!list.current(7, true));
    assert!(!list.current(140, false));
    // The agent's own list (`_acpmux/task_list/set`) expires the same way.
    let agent = TaskList { source: TaskListSource::Agent, ..list.clone() };
    assert!(!agent.current(7, true));
    // The person's side keeps its list until it changes it.
    let chief = TaskList { source: TaskListSource::Chief, ..list.clone() };
    assert!(chief.current(140, false));
    // A list saved before turns were noted reads as turn 0: expired past a chat's second turn.
    let old: TaskList = serde_json::from_value(json!({
        "source": "harness", "items": [{"content": "x", "status": "pending"}], "updatedAt": 1,
    }))
    .unwrap();
    assert_eq!(old.turn, 0);
    assert!(old.current(1, true));
    assert!(!old.current(2, true));
}
