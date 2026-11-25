use super::*;
use serde_json::json;

fn create(id: &str) -> Value {
    json!({ "op": "create", "id": id, "type": "Text", "props": {} })
}

#[test]
fn creates_count_up_to_the_cap_and_one_more_is_over() {
    let mut nodes = SceneNodes::default();
    let batch: Vec<Value> = (0..MAX_NODES).map(|i| create(&format!("n{i}"))).collect();
    assert!(nodes.apply(&batch));
    assert_eq!(nodes.len(), MAX_NODES);
    assert!(!nodes.apply(&[create("one-more")]), "node 4097 is over the cap");
}

#[test]
fn a_remove_releases_the_whole_subtree() {
    let mut nodes = SceneNodes::default();
    let mut batch: Vec<Value> = ["root", "a", "b", "c"].iter().map(|id| create(id)).collect();
    batch.push(json!({ "op": "children", "id": "root", "children": ["a", "b"] }));
    batch.push(json!({ "op": "children", "id": "a", "children": ["c"] }));
    batch.push(json!({ "op": "root", "id": "root" }));
    assert!(nodes.apply(&batch));
    assert!(nodes.apply(&[json!({ "op": "remove", "id": "a" })]));
    assert_eq!(nodes.len(), 2, "a and its child c are gone");
}

#[test]
fn a_list_that_churns_rows_never_reaches_the_cap() {
    let mut nodes = SceneNodes::default();
    for i in 0..(MAX_NODES * 4) {
        let id = format!("row{i}");
        assert!(nodes.apply(&[create(&id), json!({ "op": "remove", "id": id })]));
    }
    assert_eq!(nodes.len(), 0);
}

#[test]
fn hostile_child_lists_cannot_loop_or_grow_the_record() {
    let mut nodes = SceneNodes::default();
    assert!(nodes.apply(&[
        create("a"),
        create("b"),
        json!({ "op": "children", "id": "a", "children": ["b", "ghost"] }),
        json!({ "op": "children", "id": "b", "children": ["a"] }),
        json!({ "op": "children", "id": "never-created", "children": ["a"] }),
        json!({ "op": "remove", "id": "a" }),
    ]));
    assert_eq!(nodes.len(), 0, "the cycle a -> b -> a is removed once");
}

#[test]
fn clear_starts_a_fresh_tree() {
    let mut nodes = SceneNodes::default();
    let batch: Vec<Value> = (0..MAX_NODES).map(|i| create(&format!("n{i}"))).collect();
    assert!(nodes.apply(&batch));
    nodes.clear();
    assert!(nodes.apply(&batch), "the new tree gets the full cap");
}
