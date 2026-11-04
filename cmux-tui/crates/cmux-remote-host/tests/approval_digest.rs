//! The approval request's canonical JSON and digest against fixtures made
//! without this code, and against Lane 1's shared fixture
//! (`schemas/computer-use/approval-fixtures.json`) when that file is present.

use std::path::PathBuf;

use cmux_remote_host::approval::{ApprovalRequest, canonical, digest_of};
use serde_json::Value;

fn check_cases(value: &Value, source: &str) -> usize {
    let mut checked = 0;
    match value {
        Value::Object(object) => {
            if let (Some(request), Some(digest)) = (object.get("request"), object.get("digest").and_then(Value::as_str)) {
                let mut without = request.clone();
                if let Some(map) = without.as_object_mut() {
                    map.remove("digest");
                }
                if let Some(expected) = object.get("canonical").and_then(Value::as_str) {
                    assert_eq!(canonical(&without).unwrap(), expected, "{source}: canonical JSON");
                }
                assert_eq!(digest_of(request).unwrap(), digest, "{source}: digest");
                if request.get("digest").is_some() {
                    ApprovalRequest::parse_verified(request).unwrap_or_else(|error| panic!("{source}: {error}"));
                }
                checked += 1;
            }
            for child in object.values() {
                checked += check_cases(child, source);
            }
        }
        Value::Array(items) => {
            for item in items {
                checked += check_cases(item, source);
            }
        }
        _ => {}
    }
    checked
}

#[test]
fn digests_match_the_independent_fixture() {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/approval-digest.json");
    let fixture: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    assert_eq!(check_cases(&fixture, "approval-digest.json"), 4);
}

#[test]
fn digests_match_lane_1s_shared_fixture_when_present() {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../schemas/computer-use/approval-fixtures.json");
    let Ok(bytes) = std::fs::read(&path) else {
        eprintln!("{} is not on this branch yet; skipped", path.display());
        return;
    };
    let fixture: Value = serde_json::from_slice(&bytes).unwrap();
    assert!(check_cases(&fixture, "approval-fixtures.json") > 0, "the shared fixture has request/digest cases");
}

#[test]
fn a_tampered_request_does_not_verify() {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/approval-digest.json");
    let fixture: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    let mut request = fixture["cases"][0]["request"].clone();
    request["tool"] = Value::from("type_text");
    assert!(ApprovalRequest::parse_verified(&request).is_err());
}
