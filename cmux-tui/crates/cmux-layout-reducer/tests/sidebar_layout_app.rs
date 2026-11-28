//! The request the app sends through `cmux_layout_reducer_json` op
//! `sidebar_layout_reduce` to show a sidebar layout edit before the daemon
//! confirms it (cx-qvj1): the wire JSON of the visible document and one op in,
//! the next document or the reject reason out, as the daemon's
//! `sidebar_layout.update` decides it.

use cmux_layout_reducer::sidebar_layout::{self, Request};
use serde_json::{Value, json};

const CASES: &str = include_str!(
    "../../../../Packages/macOS/CmuxNext/Tests/CmuxNextSidebarTests/Fixtures/sidebar-layout-cases.json"
);

fn reply(document: &Value, op: &Value) -> Value {
    let request: Request =
        serde_json::from_value(json!({"document": document, "op": op})).expect("request");
    serde_json::to_value(sidebar_layout::respond(&request)).expect("reply")
}

fn defaults() -> Value {
    serde_json::to_value(sidebar_layout::defaults()).expect("defaults")
}

#[test]
fn sidebar_layout_app_request_answers_every_shared_case() {
    let file: Value = serde_json::from_str(CASES).expect("fixture");
    let cases = file["cases"].as_array().expect("cases");
    assert!(cases.len() >= 20);
    for case in cases {
        let name = case["name"].as_str().expect("name");
        let reply = reply(&defaults(), &case["op"]);
        match case["expect"].as_str().expect("expect") {
            "accept" => {
                assert!(reply.get("reject").is_none(), "{name}: {reply}");
                let document = &reply["document"];
                assert_eq!(document["revision"], case["revision"], "{name}");
                if let Some(id) = case["section"].as_str() {
                    let section = document["sections"]
                        .as_array()
                        .expect("sections")
                        .iter()
                        .find(|s| s["id"] == id)
                        .unwrap_or_else(|| panic!("{name}: no section {id}"));
                    if let Some(items) = case["items"].as_array() {
                        let ids: Vec<_> = section["items"]
                            .as_array()
                            .expect("items")
                            .iter()
                            .map(|i| i["id"].clone())
                            .collect();
                        assert_eq!(&ids, items, "{name}");
                    }
                    if let Some(arrangement) = case.get("arrangement") {
                        assert_eq!(&section["arrangement"], arrangement, "{name}");
                    }
                }
            }
            "reject" => {
                assert!(reply.get("document").is_none(), "{name}: {reply}");
                assert_eq!(reply["reject"], case["reason"], "{name}");
            }
            other => panic!("{name}: unknown expectation {other}"),
        }
    }
}

/// The app folds each pending edit onto the document the previous one
/// returned, so a reply's document is the next request's document, newer
/// keys included.
#[test]
fn sidebar_layout_reply_document_feeds_the_next_request() {
    let mut document = defaults();
    document["sections"][0]["from_a_newer_app"] = json!({"kept": true});
    let first = reply(&document, &json!({"kind": "item.remove", "id": "itm_home"}));
    let second = reply(&first["document"], &json!({"kind": "item.remove", "id": "itm_app_store"}));
    let top = &second["document"]["sections"][0];
    assert_eq!(second["document"]["revision"], 2);
    assert_eq!(top["items"], json!([]));
    assert_eq!(top["from_a_newer_app"], json!({"kept": true}));
}
