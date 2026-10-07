//! Checks the CLI against the checked-in cmux VM OpenAPI document, so a new
//! documented error status cannot silently fall back to the generic exit code.

use std::collections::BTreeMap;

use cmux_vm::exit;

#[test]
fn every_documented_error_status_has_its_own_exit_code() {
    let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../../../openapi.json");
    let text = std::fs::read_to_string(path).expect("read workers/cmux-vm/openapi.json");
    let doc: serde_json::Value = serde_json::from_str(&text).expect("parse openapi.json");

    let mut statuses = std::collections::BTreeSet::new();
    for item in doc["paths"].as_object().expect("paths").values() {
        for operation in item.as_object().expect("path item").values() {
            let Some(responses) = operation.get("responses").and_then(|r| r.as_object()) else {
                continue;
            };
            for status in responses.keys() {
                if let Ok(code) = status.parse::<u16>()
                    && code >= 400
                {
                    statuses.insert(code);
                }
            }
        }
    }
    assert!(!statuses.is_empty(), "no error statuses found in {path}");

    let mut by_exit: BTreeMap<i32, u16> = BTreeMap::new();
    for status in statuses {
        let code = exit::for_status(status);
        assert_ne!(
            code,
            exit::UNEXPECTED,
            "HTTP {status} is documented in openapi.json but has no exit code in exit::for_status"
        );
        if let Some(other) = by_exit.insert(code, status) {
            panic!("HTTP {status} and HTTP {other} share exit code {code}");
        }
    }
}
