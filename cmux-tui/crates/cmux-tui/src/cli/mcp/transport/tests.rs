use super::*;

#[test]
fn an_id_prefix_resolves_only_when_unique() {
    let records = json!([
        {"id": "ws_1a2b0000000000000000000000000000"},
        {"id": "ws_1a2c0000000000000000000000000000"},
        {"id": "ws_9f000000000000000000000000000000"},
    ]);
    assert_eq!(
        unique_prefix("workspace", "ws_9", &records).ok().as_deref(),
        Some("ws_9f000000000000000000000000000000")
    );
    let ambiguous = unique_prefix("workspace", "ws_1a", &records).unwrap_err();
    assert_eq!(ambiguous["code"], "selector.ambiguous");
    assert_eq!(ambiguous["details"]["candidates"].as_array().map(Vec::len), Some(2));
    let missing = unique_prefix("workspace", "ws_77", &records).unwrap_err();
    assert_eq!(missing["code"], "selector.not_found");
}

#[test]
fn a_partial_id_has_fewer_than_32_hex_digits() {
    assert!(is_partial_id("ws_1a", "ws"));
    assert!(!is_partial_id("ws_0123456789abcdef0123456789abcdef", "ws"));
    assert!(!is_partial_id("ws_", "ws"));
    assert!(!is_partial_id("ws_XY", "ws"));
}
