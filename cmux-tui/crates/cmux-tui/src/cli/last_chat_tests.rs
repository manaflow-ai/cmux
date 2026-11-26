use serde_json::{Map, Value, json};

use super::{Last, pick, pruned, records};

fn book(entries: &[(&str, &str, Option<&str>, u64)]) -> Map<String, Value> {
    entries
        .iter()
        .map(|(terminal, session, vm, at)| {
            ((*terminal).to_owned(), json!({"session": session, "vm": vm, "at": at}))
        })
        .collect()
}

#[test]
fn the_daemons_own_children_record_no_chat() {
    assert!(records(None));
    assert!(records(Some(std::ffi::OsStr::new(""))));
    assert!(!records(Some(std::ffi::OsStr::new("1"))));
}

#[test]
fn this_terminals_chat_else_the_newest() {
    let book = book(&[("term_1", "s-1", None, 10), ("term_2", "s-2", Some("vm_a"), 20)]);
    assert_eq!(pick(&book, "term_1"), Some(Last { session: "s-1".into(), vm: None }));
    assert_eq!(
        pick(&book, "term_9"),
        Some(Last { session: "s-2".into(), vm: Some("vm_a".into()) })
    );
    assert_eq!(pick(&Map::new(), "term_1"), None);
}

#[test]
fn only_the_newest_entries_stay() {
    let book = book(&[("a", "1", None, 1), ("b", "2", None, 3), ("c", "3", None, 2)]);
    let kept = pruned(book, 2);
    assert_eq!(kept.keys().cloned().collect::<Vec<_>>(), ["b", "c"]);
}
