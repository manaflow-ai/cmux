use super::*;

#[test]
fn reopened_tabs_keep_their_ids_both_ways() {
    let mut ids = TabIds::default();
    let params = json!({"targetId": "A", "frameId": "A", "url": "A?"});
    assert_eq!(ids.mapped(&params), None, "no relaunch, no mapping");
    ids.relaunched(vec![("A".into(), "B".into()), ("C".into(), "C".into())]);
    assert_eq!(ids.mapped(&params), Some(json!({"targetId": "B", "frameId": "B", "url": "A?"})));
    let mut rows = json!([{"targetId": "B", "openerTargetId": "D"}]);
    ids.to_stable(&mut rows);
    assert_eq!(rows, json!([{"targetId": "A", "openerTargetId": "D"}]));
    // A second relaunch maps from the first one's ids.
    ids.relaunched(vec![(ids.stable("B").to_owned(), "E".into())]);
    assert_eq!(ids.real("A"), "E");
    assert_eq!(ids.stable("B"), "B", "the dead browser's ids are dropped");
    ids.closed("A");
    assert_eq!(ids.real("A"), "A");
    assert_eq!(ids.stable("E"), "E");
}
