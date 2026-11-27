//! The optimistic overlay's golden vectors (`tests/data/optimistic_vectors.json`): each case
//! is a request the app's store sends and the view it shows today, taken from the Swift store's
//! tests and rules it names (`swift`). Every case answers exactly that view, and a request read
//! back from its own JSON answers the same.

use cmux_layout_reducer::optimistic::{Request, respond};
use serde_json::Value;

fn vectors() -> Vec<Value> {
    serde_json::from_str(include_str!("data/optimistic_vectors.json")).expect("vectors parse")
}

#[test]
fn optimistic_vectors_answer_the_swift_view() {
    let cases = vectors();
    assert!(cases.len() >= 50, "the vectors lost cases: {}", cases.len());
    for case in cases {
        let name = case["name"].as_str().expect("name");
        let request: Request = serde_json::from_value(case["request"].clone())
            .unwrap_or_else(|e| panic!("{name}: request does not parse: {e}"));
        let answer = respond(&request);
        assert_eq!(answer, case["response"], "{name} ({})", case["swift"]);
    }
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
    let split = r#"{"op":"split","screen":{"layout":{"type":"leaf","pane":3},"panes":[3]},
        "target":3,"dir":"right","ratio":0.30000000000000004,"leaf":9,"split_id":"s"}"#;
    let request: Request = serde_json::from_str(split).expect("split");
    let ratio = respond(&request)["layout"]["ratio"].as_f64().expect("ratio");
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
