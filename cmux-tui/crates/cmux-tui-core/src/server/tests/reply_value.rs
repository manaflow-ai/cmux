//! A reply's JSON value is built by moving its payload in, and is the value
//! `serde_json::to_value` made, so the reply bytes do not change.

use super::*;
use crate::resource::{RequestId, ResourceError, ResponseEnvelope};

fn responses() -> Vec<Response> {
    let tree =
        json!({"workspaces": [{"id": 1, "screens": [{"panes": [{"tabs": [{"surface": 2}]}]}]}]});
    let mut responses = Vec::new();
    for id in [None, Some(json!(7)), Some(json!("r-1")), Some(Value::Null)] {
        for (ok, data, error, error_code) in [
            (true, Some(tree.clone()), None, None),
            (true, Some(Value::Null), None, None),
            (true, None, None, None),
            (false, None, Some("bad request: no"), None),
            (false, None, Some("refused"), Some("pinned_column")),
        ] {
            for error_delivery in [
                None,
                Some(ResponseErrorDelivery::KnownNotDelivered),
                Some(ResponseErrorDelivery::Ambiguous),
            ] {
                responses.push(Response {
                    id: id.clone(),
                    ok,
                    data: data.clone(),
                    error: error.map(str::to_owned),
                    error_code: error_code.map(str::to_owned),
                    error_delivery,
                });
            }
        }
    }
    responses
}

#[test]
fn a_reply_value_is_the_serialized_reply_with_its_data_moved_in() {
    for response in responses() {
        let serialized = serde_json::to_value(&response).unwrap();
        let bytes = serde_json::to_string(&serialized).unwrap();
        let moved = response.into_value();
        assert_eq!(moved, serialized);
        assert_eq!(serde_json::to_string(&moved).unwrap(), bytes, "the reply bytes");
    }
}

#[test]
fn a_v2_reply_value_is_the_serialized_envelope_with_its_result_moved_in() {
    let id = RequestId::parse("line-1").unwrap();
    let envelopes = [
        ResponseEnvelope::success(id.clone(), json!({"session": {"workspaces": [1, 2, 3]}})),
        ResponseEnvelope::success(id.clone(), Value::Null),
        ResponseEnvelope::failure(id.clone(), ResourceError::validation_invalid(Some("id"), "no")),
        ResponseEnvelope::failure(
            id,
            ResourceError::operation_failed("response.encode", "failed", json!({"error": "x"})),
        ),
    ];
    for envelope in envelopes {
        let serialized = serde_json::to_value(&envelope).unwrap();
        let bytes = serde_json::to_string(&serialized).unwrap();
        let moved = envelope.into_value().unwrap();
        assert_eq!(moved, serialized);
        assert_eq!(serde_json::to_string(&moved).unwrap(), bytes, "the reply bytes");
    }
}
