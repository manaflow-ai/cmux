use crate::frames::{FrameNode, flatten};
use serde_json::json;

fn node(value: serde_json::Value) -> FrameNode {
    serde_json::from_value(value).unwrap()
}

#[test]
fn parents_before_children_in_document_order() {
    let root = node(json!({
        "frameId": "1", "url": "https://a.test/",
        "children": [
            {"frameId": "2", "url": "https://b.test/", "children": [{"frameId": "4"}]},
            {"frameId": "3", "url": "https://c.test/"},
        ],
    }));
    let records = flatten(&root);
    let ids: Vec<_> = records.iter().map(|r| r.frame_id.as_str()).collect();
    assert_eq!(ids, ["1", "2", "4", "3"]);
    assert!(records[0].is_main && records[0].parent_frame_id.is_none());
    assert_eq!(records[2].parent_frame_id.as_deref(), Some("2"));
    assert_eq!(records[2].url, "");
    assert!(!records[3].is_main);
}

#[test]
fn a_node_without_an_id_drops_its_subtree() {
    let root = node(json!({
        "frameId": "1",
        "children": [{"url": "https://x.test/", "children": [{"frameId": "9"}]}, {"frameId": "2"}],
    }));
    let ids: Vec<_> = flatten(&root).into_iter().map(|r| r.frame_id).collect();
    assert_eq!(ids, ["1", "2"]);
    assert!(flatten(&node(json!({}))).is_empty());
}
