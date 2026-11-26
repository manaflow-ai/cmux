//! `dead_letters.rs`: what a dead letter says.

use super::*;

#[test]
fn a_dead_letter_names_the_target_the_reason_and_the_text() {
    let d: Delivery = serde_json::from_value(json!({
        "id": "d1", "target": "far/lane", "caller": "s1", "state": "failed", "attempts": 4,
        "request": {"sessionId": "far/lane", "prompt": [{"type": "text", "text": "hi"}]},
        "error": "failed attempt 4", "createdAt": 1, "updatedAt": 2
    }))
    .unwrap();
    let line = line(&d);
    assert_eq!(line["deliveryId"], "d1");
    assert_eq!(line["target"], "far/lane");
    assert_eq!(line["sender"], "s1");
    assert_eq!(line["reason"], "failed attempt 4");
    assert_eq!(line["text"], "hi");
    let long = "x".repeat(TEXT_CHARS + 5);
    let mut d = d;
    d.request["prompt"][0]["text"] = json!(long);
    assert_eq!(super::text_of(&d).chars().count(), TEXT_CHARS + 1);
}
