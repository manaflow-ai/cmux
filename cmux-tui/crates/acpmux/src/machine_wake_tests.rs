use super::*;
use serde_json::json;

#[test]
fn finds_paused_lease_in_host_record_or_tags() {
    assert_eq!(
        paused_lease(&json!({"host": {"lease": {"leaseId": "l1", "state": "paused"}}})),
        Some("l1".into())
    );
    assert_eq!(
        paused_lease(&json!({"host": {"lease": "l2", "state": "paused"}})),
        Some("l2".into())
    );
    assert_eq!(paused_lease(&json!({"tags": {"lease": "l3"}, "status": "idle"})), None);
}
