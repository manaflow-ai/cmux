use super::*;

#[test]
fn initialize_answers_a_version_we_speak() {
    let version = |v: Value| protocol_version(&json!({"protocolVersion": v}));
    assert_eq!(version(json!("2024-11-05")), "2024-11-05");
    assert_eq!(version(json!("2099-01-01")), PROTOCOL_VERSIONS[0]);
    assert_eq!(version(json!(7)), PROTOCOL_VERSIONS[0]);
    assert_eq!(protocol_version(&Value::Null), PROTOCOL_VERSIONS[0]);
}
