use serde_json::{Map, Value, json};

use super::Follows;

fn row(id: &str, at: i64, title: &str) -> Value {
    json!({"id": id, "kind": "command", "at_ms": at.to_string(), "title": title})
}

fn window(count: i64) -> Vec<Value> {
    (0..count).map(|index| row(&format!("command:{index}"), 1_000_000 - index, "a")).collect()
}

fn fields(text: &str) -> Map<String, Value> {
    json!({"text": text, "limit": 1000}).as_object().cloned().unwrap_or_default()
}

/// What a reader holds after applying `answer` to `held`: the removed and
/// changed ids dropped, each entry inserted at its index in order.
fn apply(held: &[Value], answer: &super::Answer) -> Vec<Value> {
    let Some(delta) = &answer.delta else { return answer.entries.clone() };
    let removed: Vec<&str> =
        delta["removed"].as_array().unwrap().iter().filter_map(Value::as_str).collect();
    let changed: Vec<&str> =
        answer.entries.iter().filter_map(|entry| entry["id"].as_str()).collect();
    let mut rows: Vec<Value> = held
        .iter()
        .filter(|row| {
            let id = row["id"].as_str().unwrap_or("");
            !removed.contains(&id) && !changed.contains(&id)
        })
        .cloned()
        .collect();
    for (entry, at) in answer.entries.iter().zip(delta["at"].as_array().unwrap()) {
        rows.insert(at.as_u64().unwrap() as usize, entry.clone());
    }
    rows
}

#[test]
fn a_followed_list_after_one_change_answers_only_that_entry() {
    let follows = Follows::default();
    let first = follows.answer(&fields(""), None, window(1000));
    assert!(first.delta.is_none(), "a reader without a cursor gets the whole window");
    assert_eq!(first.entries.len(), 1000);

    // One command ran: a new newest entry, and the oldest fell out of the window.
    let mut next = vec![row("command:new", 2_000_000, "b")];
    next.extend(window(999));
    let second = follows.answer(&fields(""), Some(&first.follow), next.clone());
    let delta = second.delta.as_ref().expect("a delta over the held window");
    assert_eq!(second.entries.len(), 1, "only the new entry is sent");
    assert_eq!(delta["removed"], json!(["command:999"]));
    assert_eq!(delta["at"], json!([0]));
    assert_eq!(apply(&first.entries, &second), next);

    // An entry changed in place and moved to the top.
    let mut moved = next.clone();
    let touched = moved.remove(500);
    let mut touched = touched;
    touched["at_ms"] = json!("3000000");
    moved.insert(0, touched);
    let third = follows.answer(&fields(""), Some(&second.follow), moved.clone());
    assert_eq!(third.entries.len(), 1);
    assert_eq!(apply(&next, &third), moved);
}

#[test]
fn a_cursor_of_another_query_run_or_too_big_a_change_reads_whole() {
    let follows = Follows::default();
    let first = follows.answer(&fields(""), None, window(100));
    let other = follows.answer(&fields("cargo"), Some(&first.follow), window(100));
    assert!(other.delta.is_none(), "another query");
    let foreign = follows.answer(&fields(""), Some("feedface.1"), window(100));
    assert!(foreign.delta.is_none(), "another daemon run");
    let fresh: Vec<Value> =
        (0..100).map(|index| row(&format!("page:{index}"), 5_000_000 - index, "c")).collect();
    let big = follows.answer(&fields(""), Some(&foreign.follow), fresh);
    assert!(big.delta.is_none(), "a change of most of the window");
    assert_eq!(big.entries.len(), 100);
}

#[test]
fn a_reorder_the_reader_cannot_make_by_insertion_reads_whole() {
    let follows = Follows::default();
    let rows = window(10);
    let first = follows.answer(&fields(""), None, rows.clone());
    let mut swapped = rows;
    swapped.swap(2, 7);
    let second = follows.answer(&fields(""), Some(&first.follow), swapped.clone());
    // Swapping two unchanged rows is no delta a reader could apply.
    match &second.delta {
        None => assert_eq!(second.entries, swapped),
        Some(_) => assert_eq!(apply(&first.entries, &second), swapped),
    }
}

#[test]
fn an_unchanged_list_answers_nothing() {
    let follows = Follows::default();
    let first = follows.answer(&fields(""), None, window(1000));
    let second = follows.answer(&fields(""), Some(&first.follow), window(1000));
    assert!(second.entries.is_empty());
    assert_eq!(second.delta, Some(json!({"removed": [], "at": []})));
}
