use super::*;
use cmux_json::JsonSet as _;

#[test]
fn a_row_round_trips_and_lists_with_no_member_twice() {
    let summary = json!({
        "sessionId": "s1", "name": "hb/x", "status": "running", "peer": "hb",
        "stale": false, "peerState": "old", "tags": {"mux.parent": "p", "mux.handle": "h"},
        "title": "t".repeat(400), "tools": [{"name": "a"}], "toolsMutable": true,
        "updatedAt": 5, "createdAt": 3, "pendingPermissions": 2,
    });
    let row = PeerRow::new(&summary);
    assert_eq!(row.value(), summary);
    assert_eq!(row, PeerRow::new(&row.value()));
    assert_eq!(row.pair(), Some(("p".into(), "h".into())));
    assert_eq!((row.updated_ms(), row.created_at(), row.pending_permissions()), (5, Some(3), 2));
    let listed: Value = serde_json::from_str(&row.listed(Some("connected"), false)).unwrap();
    let mut want = super::super::views::without_summary_tools(summary.clone());
    want.set("peerState", json!("connected"));
    assert_eq!(listed, want);
    let with: Value = serde_json::from_str(&row.listed(None, true)).unwrap();
    assert_eq!(with, summary);
    assert_eq!(row.listed(None, true).matches("\"stale\"").count(), 1);
    assert_eq!(row.listed(Some("x"), true).matches("\"peerState\"").count(), 1);
    assert_eq!(serde_json::to_value(&row).unwrap(), summary);
}

#[test]
fn an_empty_or_non_object_row_lists_as_it_was() {
    let empty = PeerRow::new(&json!({}));
    assert_eq!(empty.listed(Some("ok"), false), r#"{"stale":false,"peerState":"ok"}"#);
    assert_eq!(PeerRow::new(&Value::Null).listed(None, false), "null");
    assert_eq!(PeerRow::new(&json!([1])).value(), json!([1]));
}
