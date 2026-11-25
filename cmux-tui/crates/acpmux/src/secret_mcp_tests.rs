use super::*;

#[test]
fn initialize_answers_a_version_we_speak() {
    let version = |v: Value| protocol_version(&json!({"protocolVersion": v}));
    assert_eq!(version(json!("2024-11-05")), "2024-11-05");
    assert_eq!(version(json!("2099-01-01")), PROTOCOL_VERSIONS[0]);
    assert_eq!(version(json!(7)), PROTOCOL_VERSIONS[0]);
    assert_eq!(protocol_version(&Value::Null), PROTOCOL_VERSIONS[0]);
}

/// An approved server is kept and served to the agents its scope names (`cmux mcp serve`'s
/// `mcp_servers`), so the connect card is on by default, with no preview switch.
#[test]
fn connect_mcp_server_is_listed_by_default() {
    let names: Vec<String> = tools()
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|t| t["name"].as_str().map(str::to_owned))
        .collect();
    assert!(names.iter().any(|n| n == "connect_mcp_server"), "{names:?}");
}
