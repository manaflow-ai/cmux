//! `sidebar_session_tree` through the C ABI: replays `schemas/sidebar-session-tree/vectors.json`,
//! random cases a line-by-line transliteration of `SidebarSessionTree.swift` answered, so the Rust
//! rules draw the same badge, folds and hidden rows the Swift did.

use cmux_layout_reducer_ffi::{ERR_BUFFER, ERR_INVALID, OK, cmux_layout_reducer_json};
use serde_json::{Value, json};

const VECTORS: &str = include_str!("../../../../schemas/sidebar-session-tree/vectors.json");

fn raw(request: &[u8]) -> (i32, Option<Value>) {
    let mut capacity = 4096;
    loop {
        let mut output = vec![0u8; capacity];
        let mut len = 0usize;
        let code = unsafe {
            cmux_layout_reducer_json(
                request.as_ptr(),
                request.len(),
                c"sidebar_session_tree".as_ptr(),
                output.as_mut_ptr(),
                output.len(),
                &mut len,
            )
        };
        if code == ERR_BUFFER {
            capacity = len.max(capacity * 2);
            continue;
        }
        let body =
            (code == OK).then(|| serde_json::from_slice(&output[..len]).expect("answer is JSON"));
        return (code, body);
    }
}

fn call(request: Value) -> Value {
    let (code, body) = raw(request.to_string().as_bytes());
    assert_eq!(code, OK, "{request}");
    body.expect("reply")
}

fn vectors() -> Value {
    serde_json::from_str(VECTORS).expect("vectors are JSON")
}

#[test]
fn the_badge_matches_the_swift_for_every_case() {
    let cases = vectors()["badges"].as_array().expect("badges").clone();
    assert!(cases.len() >= 100);
    for case in cases {
        let answer = call(json!({"op": "badge", "items": case[0]}));
        assert_eq!(answer, case[1], "{}", case[0]);
    }
}

#[test]
fn openable_and_repository_match_the_swift_for_every_url() {
    let all = vectors();
    for case in all["openable"].as_array().expect("openable") {
        let answer = call(json!({"op": "openable", "url": case[0], "enterpriseHost": case[1]}));
        assert_eq!(answer["openable"], case[2], "{} {}", case[0], case[1]);
    }
    for case in all["repository"].as_array().expect("repository") {
        let answer = call(json!({"op": "repository", "url": case[0]}));
        assert_eq!(answer["repository"], case[1], "{}", case[0]);
    }
}

#[test]
fn folds_and_hidden_rows_match_the_swift_for_every_tree() {
    for case in vectors()["trees"].as_array().expect("trees") {
        let tree = &case["tree"];
        let mut hidden = tree.clone();
        hidden["op"] = json!("hidden_started");
        hidden["ids"] = case["ids"].clone();
        hidden["needsPerson"] = case["needsPerson"].clone();
        assert_eq!(call(hidden)["hidden"], case["hidden"], "{case}");
        let folds = json!({"collapsed": tree["collapsed"], "opened": tree["opened"]});
        for probe in case["probes"].as_array().expect("probes") {
            let id = &probe["id"];
            let ancestors = call(json!({"op": "drawn_ancestors", "parents": tree["parents"],
                "id": id, "list": case["lists"][0]}));
            assert_eq!(ancestors["ancestors"], probe["ancestors"], "{probe}");
            let mut folded = tree.clone();
            folded["op"] = json!("is_folded");
            folded["id"] = id.clone();
            folded["depth"] = probe["depth"].clone();
            assert_eq!(call(folded)["folded"], probe["isFolded"], "{probe}");
            let mut hides = tree.clone();
            hides["op"] = json!("hides_in_fold");
            hides["id"] = id.clone();
            hides["lists"] = case["lists"].clone();
            assert_eq!(call(hides)["hides"], probe["hidesInFold"], "{probe}");
            let parents = if probe["liveParents"] == json!(true) {
                tree["parents"].clone()
            } else {
                Value::Null
            };
            let mut toggle = folds.clone();
            toggle["op"] = json!("toggle");
            toggle["id"] = id.clone();
            toggle["folded"] = probe["folded"].clone();
            toggle["parents"] = parents.clone();
            toggle["keeping"] = probe["keeping"].clone();
            assert_eq!(call(toggle), probe["toggle"], "{probe}");
            let mut reveal = folds.clone();
            reveal["op"] = json!("reveal");
            reveal["id"] = id.clone();
            reveal["parents"] = tree["parents"].clone();
            reveal["lists"] = case["lists"].clone();
            assert_eq!(call(reveal), probe["reveal"], "{probe}");
            let mut prune = folds.clone();
            prune["op"] = json!("prune");
            prune["parents"] = parents;
            prune["keeping"] = probe["keeping"].clone();
            assert_eq!(call(prune), probe["prune"], "{probe}");
        }
    }
}

#[test]
fn a_malformed_request_is_refused() {
    assert_eq!(raw(br#"{"op":"openable"}"#).0, ERR_INVALID);
    assert_eq!(raw(br#"{"op":"nope"}"#).0, ERR_INVALID);
}
