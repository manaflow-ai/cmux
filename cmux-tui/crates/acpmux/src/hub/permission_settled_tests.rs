use super::*;

#[test]
fn a_settled_answer_is_told_for_a_while_and_the_store_stays_bounded() {
    let mut s = Settled::default();
    let t0 = Instant::now();
    let by = json!({"id": "tailnet:ana", "name": "Ana"});
    let outcome = json!({"outcome": "selected", "optionId": "yes", "_meta": {"updatedInput": {}}});
    s.remember_at(t0, "p-1", Some(&by), &outcome);
    let told = s.lost_at(t0, "p-1").unwrap();
    assert_eq!(
        told,
        json!({"answeredBy": by, "outcome": {"outcome": "selected", "optionId": "yes"}})
    );
    assert_eq!(s.lost_at(t0 + KEEP, "p-1"), None, "kept past KEEP");
    s.remember_at(t0, "p-2", None, &json!({"outcome": "cancelled"}));
    assert_eq!(s.lost_at(t0, "p-2").unwrap()["answeredBy"], Value::Null);
    for i in 0..(MAX * 2) {
        s.remember_at(t0, &format!("q-{i}"), None, &json!({"outcome": "cancelled"}));
    }
    assert_eq!(s.0.len(), MAX);
    // A remember drops what expired.
    s.remember_at(t0 + KEEP, "late", None, &json!({}));
    assert_eq!(s.0.len(), 1);
}
