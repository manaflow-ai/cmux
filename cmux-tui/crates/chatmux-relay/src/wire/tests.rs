use super::*;

#[test]
fn hello_frame_serializes_the_v2_wire_shape() {
    let roots = vec!["/srv".to_owned()];
    let hello = HelloFrame {
        version: FRAME_VERSION,
        frame_type: "hello",
        relay_protocol_version: 2,
        cli_version: CLI_VERSION,
        machine_id: "dev_1",
        token: "tok_1",
        allowed_roots: Some(&roots),
        managed_enrollment: None,
    };
    let encoded = serde_json::to_value(&hello).expect("serializes");
    assert_eq!(encoded.get("type"), Some(&Value::from("hello")));
    assert_eq!(encoded.get("machineId"), Some(&Value::from("dev_1")));
    assert_eq!(encoded.get("allowedRoots"), Some(&serde_json::json!(["/srv"])));
    assert_eq!(encoded.get("managedEnrollment"), None);
}
