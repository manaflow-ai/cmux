use super::*;

#[test]
fn descriptor_requires_only_action_and_rejects_extra_fields() {
    let schema = descriptor()["inputSchema"].clone();
    assert_eq!(schema["required"], json!(["action"]));
    assert_eq!(schema["additionalProperties"], false);
    let mut args = Map::new();
    args.insert("action".into(), json!("status"));
    args.insert("extra".into(), json!(true));
    assert!(request(&args).is_err());
}

#[test]
fn start_pins_source_and_defaults_args_without_accepting_file_paths() {
    let mut args = Map::new();
    args.insert("action".into(), json!("start"));
    args.insert("name".into(), json!("nightly"));
    args.insert("source".into(), json!("return await pipeline([], async x => x);"));
    let request = request(&args).unwrap();
    assert_eq!(request["args"], json!([]));
    assert!(request.get("file").is_none());
}

#[test]
fn pause_and_resume_require_a_run_id() {
    for action in ["pause", "resume"] {
        let mut args = Map::new();
        args.insert("action".into(), json!(action));
        assert!(request(&args).is_err());
    }
}
