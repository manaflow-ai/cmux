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
    };
    assert_eq!(after_plan(Some(&kept), vec![], 2), None);
    let harness = TaskList { source: TaskListSource::Harness, ..kept.clone() };
    assert_eq!(after_plan(Some(&harness), vec![], 2), Some(None));
    let replaced =
        after_plan(Some(&kept), vec![item("y", TaskStatus::InProgress)], 3).unwrap().unwrap();
    assert_eq!(replaced.source, TaskListSource::Harness);
    // The same steps again change nothing, not even the time.
    assert_eq!(after_plan(Some(&harness), harness.items.clone(), 9), None);
}
