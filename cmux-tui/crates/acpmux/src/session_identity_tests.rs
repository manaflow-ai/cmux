use super::*;
use serde_json::json;

#[test]
fn receipt_round_trips_with_a_qualified_id() {
    let receipt = SessionReceipt::new("build-host", "mux-123", Some("agent-456".to_owned()), 17);
    assert_eq!(receipt.qualified_id(), "build-host/mux-123");
    assert_eq!(
        receipt.to_value(),
        json!({
            "hostId": "build-host",
            "muxSessionId": "mux-123",
            "agentSessionId": "agent-456",
            "generation": 17,
        })
    );
    assert_eq!(serde_json::from_value::<SessionReceipt>(receipt.to_value()).unwrap(), receipt);
}

#[test]
fn qualified_id_parser_rejects_ambiguous_forms() {
    assert_eq!(SessionReceipt::split_qualified_id("host/mux"), Some(("host", "mux")));
    for value in ["mux", "/mux", "host/", "host/mux/extra"] {
        assert_eq!(SessionReceipt::split_qualified_id(value), None, "{value}");
    }
}
