//! The optimistic overlay's golden vectors (`tests/data/optimistic_vectors.json`): each case
//! is a request the app's store sends and the view it shows today, taken from the Swift store's
//! tests and rules it names (`swift`). Every case answers exactly that view, and a request read
//! back from its own JSON answers the same.
//!
//! A split, dock or pane removal case also holds the whole `screen` and the `view` it shows
//! (`null`: nothing). The app's walks build exactly its `request` from the screen, the rules
//! answer its `response` patch, and the patch spliced into the screen is that view
//! (`support/optimistic_app.rs`, the reference the Swift store follows).

#[path = "support/optimistic_app.rs"]
mod optimistic_app;

use cmux_layout_reducer::optimistic::{Patch, Request, respond};
use optimistic_app::{Screen, View, request, splice};
use serde_json::Value;

fn vectors() -> Vec<Value> {
    serde_json::from_str(include_str!("data/optimistic_vectors.json")).expect("vectors parse")
}

#[test]
fn optimistic_vectors_answer_the_swift_view() {
    let cases = vectors();
    assert!(cases.len() >= 70, "the vectors lost cases: {}", cases.len());
    for case in cases {
        let name = case["name"].as_str().expect("name");
        let request: Request = serde_json::from_value(case["request"].clone())
            .unwrap_or_else(|e| panic!("{name}: request does not parse: {e}"));
        let answer = respond(&request);
        assert_eq!(answer, case["response"], "{name} ({})", case["swift"]);
    }
}

#[test]
fn optimistic_patches_splice_into_the_swift_view() {
    let mut spliced = 0;
    for case in vectors() {
        let Some(screen) = case.get("screen") else { continue };
        let name = case["name"].as_str().expect("name");
        let screen: Screen = serde_json::from_value(screen.clone()).expect("screen");
        let built = request(&screen, &case["request"]).expect("a split, dock or removal");
        assert_eq!(built.request, case["request"], "{name}: the app's walks build another request");
        let view = &case["view"];
        assert_eq!(case["response"].is_null(), view.is_null(), "{name}: shows nothing iff null");
        if view.is_null() {
            continue;
        }
        let patch: Patch = serde_json::from_value(case["response"].clone()).expect("patch");
        let want: View = serde_json::from_value(view.clone()).expect("view");
        assert_eq!(splice(&screen, &built, &patch), want, "{name}");
        spliced += 1;
    }
    assert!(spliced >= 28, "only {spliced} patches spliced");
}

#[test]
fn optimistic_requests_round_trip_their_json() {
    for case in vectors() {
        let request: Request = serde_json::from_value(case["request"].clone()).expect("request");
        let again: Request =
            serde_json::from_value(serde_json::to_value(&request).expect("encode"))
                .expect("decode");
        assert_eq!(request, again, "{}", case["name"]);
    }
}

#[test]
fn optimistic_ratio_and_width_come_back_bit_for_bit() {
    let split = r#"{"op":"split","target":3,"dir":"right","ratio":0.30000000000000004,"leaf":9,
        "split_id":"s","facts":{"panes":1,"target_index":0,"in_screen":true,"span":[0,0]},
        "spots":[{"root":true,"node":{"type":"leaf","pane":3}}]}"#;
    let request: Request = serde_json::from_str(split).expect("split");
    let ratio = respond(&request)["spots"][0]["node"]["ratio"].as_f64().expect("ratio");
    assert_eq!(ratio.to_bits(), (0.1f64 + 0.2).to_bits());
    let column = split.replace(
        r#""split_id":"s""#,
        r#""split_id":"s","column":{"handle":9,"width":0.6666666666666666}"#,
    );
    let request: Request = serde_json::from_str(&column).expect("column");
    let width = respond(&request)["columns"][1]["width"].as_f64().expect("width");
    assert_eq!(width.to_bits(), (2.0f64 / 3.0).to_bits());
}

#[test]
fn optimistic_unknown_op_is_refused() {
    assert!(serde_json::from_str::<Request>(r#"{"op":"nope"}"#).is_err());
}

#[test]
fn optimistic_refuses_a_whole_screen_request() {
    let old = r#"{"op":"split","screen":{"layout":{"type":"leaf","pane":3},"panes":[3]},
        "target":3,"dir":"right","ratio":0.5,"leaf":9,"split_id":"s"}"#;
    assert!(serde_json::from_str::<Request>(old).is_err());
}
