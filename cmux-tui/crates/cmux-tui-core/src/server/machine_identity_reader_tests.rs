//! Default raw identify replies remain readable by strict pre-metadata SDKs.
use super::*;
use serde::{Deserialize, Serialize};

// Frozen field set from f1fde42e's IdentifyResult, also exercised by the
// target-base Python raw codec. Serialize keeps every decoded field observable.
#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct LegacyIdentity {
    app: String,
    version: String,
    protocol: u32,
    session: String,
    pid: u32,
    #[serde(default)]
    capabilities: Vec<String>,
    build_commit: Option<String>,
    ghostty_commit: Option<String>,
    session_id: Option<String>,
    machine_name: Option<String>,
    registry_id: String,
    generation: String,
    workspace_revision: u64,
    terminal_revision: u64,
    daemon_handoff: u32,
    lifecycle_ready: Option<bool>,
    launch_snapshot_path: Option<String>,
    build_id: Option<String>,
    cli_path: Option<String>,
}

fn identify(reader: &Publisher, mux: &Arc<Mux>, options: Value) -> Value {
    let mut request = json!({"id":1,"cmd":"identify"});
    request.as_object_mut().unwrap().extend(options.as_object().unwrap().clone());
    reader.frame(mux, request)
}

fn assert_legacy(reply: &Value) {
    assert_eq!(reply["ok"], true, "{reply}");
    let decoded = serde_json::from_value::<LegacyIdentity>(reply["data"].clone());
    assert!(decoded.is_ok(), "default identify must keep the frozen SDK shape: {decoded:?}");
    let decoded = decoded.unwrap();
    assert_eq!(decoded.app, "cmux-tui");
    assert_eq!(decoded.daemon_handoff, 1);
    assert_eq!(serde_json::to_value(decoded).unwrap()["protocol"], PROTOCOL_VERSION);
}

#[test]
fn cmux_next_machine_identity_reader_frozen_old_command_accepts_an_explicit_flag() {
    // Exact serde representation of the target-base Command::Identify. This
    // must execute before a new handshake can safely send this flag to old hosts.
    #[derive(Deserialize)]
    #[serde(tag = "cmd", rename_all = "kebab-case")]
    enum FrozenCommand {
        Identify,
    }
    for options in [json!({}), json!({"machine_metadata":true}), json!({"machine_metadata":false})]
    {
        let mut request = json!({"cmd":"identify"});
        request.as_object_mut().unwrap().extend(options.as_object().unwrap().clone());
        assert!(matches!(
            serde_json::from_value::<FrozenCommand>(request),
            Ok(FrozenCommand::Identify)
        ));
    }
}

#[test]
fn cmux_next_machine_identity_reader_frozen_reply_decoder_control() {
    let mux = mux();
    let reader = Publisher::new(&mux, ClientTransport::Unix, false);
    let mut reply = identify(&reader, &mux, json!({}));
    for key in ["machine_id", "machine_platform", "machine_capabilities"] {
        reply["data"].as_object_mut().unwrap().remove(key);
    }
    assert_legacy(&reply);
}

#[test]
fn cmux_next_machine_identity_reader_default_preserves_the_frozen_reply_shape() {
    let mux = mux();
    let reader = Publisher::new(&mux, ClientTransport::Unix, false);
    assert_legacy(&identify(&reader, &mux, json!({})));
}

#[test]
fn cmux_next_machine_identity_reader_explicit_metadata_matches_the_owner_catalog() {
    let mux = mux();
    let reader = Publisher::new(&mux, ClientTransport::Unix, false);
    let reply = identify(&reader, &mux, json!({"machine_metadata":true}));
    assert_eq!(reply["ok"], true, "{reply}");
    let owner = &dispatch(&mux, ResourceOperation::MachineList, None).unwrap()[0];
    assert_eq!(reply["data"]["machine_id"], owner["id"]);
    assert_eq!(reply["data"]["machine_platform"], owner["platform"]);
    assert_eq!(reply["data"]["machine_capabilities"], owner["capabilities"]);
    assert!(
        reply["data"]["capabilities"].as_array().unwrap().contains(&json!("machine-identity-v1"))
    );
}

#[test]
fn cmux_next_machine_identity_reader_metadata_is_per_request_and_false_is_legacy() {
    let mux = mux();
    let reader = Publisher::new(&mux, ClientTransport::Unix, false);
    assert_eq!(identify(&reader, &mux, json!({"machine_metadata":true}))["ok"], true);
    assert_legacy(&identify(&reader, &mux, json!({"machine_metadata":false})));
    assert_legacy(&identify(&reader, &mux, json!({})));
}

#[test]
fn cmux_next_machine_identity_reader_malformed_metadata_options_are_refused() {
    let mux = mux();
    let reader = Publisher::new(&mux, ClientTransport::Unix, false);
    for flag in [json!("true"), json!(1), Value::Null] {
        let reply = identify(&reader, &mux, json!({"machine_metadata":flag}));
        assert_eq!(reply["ok"], false, "a malformed option must be refused: {reply}");
    }
}
